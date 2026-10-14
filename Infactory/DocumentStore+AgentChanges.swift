import Foundation
import GRDB

/// One change the library agent proposed. It touches nothing until applied, and keeps what it
/// replaced so Undo can put it back.
struct AgentChange: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case title, summary, filing, category
    }

    let id: UUID
    let taskID: UUID
    let kind: Kind
    let noteID: UUID?
    /// The category code a filing moves to, or the code a new category takes.
    let code: String?
    /// What the change replaces: a title, a note body, a filing label, or empty for a category.
    let before: String
    /// The new title, body or category name; for a filing, the destination label.
    let after: String
    let reason: String
    let status: String
}

/// A change as the agent proposes it, before it's saved for review.
struct AgentChangeDraft: Sendable, Equatable {
    var kind: AgentChange.Kind
    var noteID: UUID?
    var code: String?
    var before: String
    var after: String
    var reason: String
    var baseRevision: UUID?
}

struct AgentApplyReport: Sendable, Equatable {
    var applied = 0
    /// Changes skipped because their item was edited, deleted or refiled since the proposal.
    var stale = 0
}

private struct FilingSnapshot: Codable {
    let categoryID: String
    let primary: Bool
}

extension DocumentStore {
    func saveAgentChanges(_ drafts: [AgentChangeDraft], taskID: UUID) throws {
        guard !drafts.isEmpty else { return }
        try readyDatabase().write { db in
            let now = Date().timeIntervalSince1970
            for (ordinal, draft) in drafts.enumerated() {
                try db.execute(sql: """
                INSERT INTO agent_changes(id, taskID, ordinal, kind, noteID, code, before, after,
                    reason, baseRevision, status, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
                """, arguments: [
                    UUID().uuidString, taskID.uuidString, ordinal, draft.kind.rawValue,
                    draft.noteID?.uuidString, draft.code, draft.before, draft.after,
                    draft.reason, draft.baseRevision?.uuidString, now,
                ])
            }
        }
    }

    func agentChanges(taskID: UUID? = nil) throws -> [AgentChange] {
        try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: taskID == nil
                    ? "SELECT * FROM agent_changes ORDER BY createdAt, ordinal"
                    : "SELECT * FROM agent_changes WHERE taskID = ? ORDER BY ordinal",
                arguments: taskID.map { [$0.uuidString] } ?? []
            ).map(Self.agentChange)
        }
    }

    func rejectAgentChanges(_ ids: [UUID]) throws {
        try readyDatabase().write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE agent_changes SET status = 'rejected' WHERE id = ? AND status = 'pending'",
                    arguments: [id.uuidString]
                )
            }
        }
    }

    /// Applies pending changes in one transaction: new categories, then each note's text in a
    /// single revision, then filings. A change whose item moved on since the proposal is marked
    /// stale, not forced.
    func applyAgentChanges(_ ids: [UUID]) throws -> AgentApplyReport {
        try readyDatabase().write { db in
            let rows = try Self.agentRows(ids, status: "pending", in: db)
            var report = AgentApplyReport()
            func record(_ succeeded: Bool, _ batch: [Row]) throws {
                if succeeded {
                    report.applied += batch.count
                    return
                }
                report.stale += batch.count
                for row in batch {
                    try db.execute(
                        sql: "UPDATE agent_changes SET status = 'stale' WHERE id = ?",
                        arguments: [row["id"] as String]
                    )
                }
            }
            for row in rows where row["kind"] as String == "category" {
                try record(Self.applyCategory(row, in: db), [row])
            }
            for batch in Self.textBatches(rows) {
                try record(Self.applyText(batch, in: db), batch)
            }
            for row in rows where row["kind"] as String == "filing" {
                try record(Self.applyFiling(row, in: db), [row])
            }
            return report
        }
    }

    /// Reverts applied changes: filings first so a category they created can then be removed.
    /// A title or body edited again since is left as it is.
    func undoAgentChanges(_ ids: [UUID]) throws -> Int {
        try readyDatabase().write { db in
            let rows = try Self.agentRows(ids, status: "applied", in: db)
            var undone: [Row] = []
            for row in rows where row["kind"] as String == "filing" {
                if try Self.undoFiling(row, in: db) {
                    undone.append(row)
                }
            }
            for batch in Self.textBatches(rows) where try Self.undoText(batch, in: db) {
                undone += batch
            }
            for row in rows where row["kind"] as String == "category" {
                if try Self.undoCategory(row, in: db) {
                    undone.append(row)
                }
            }
            for row in undone {
                try db.execute(
                    sql: "UPDATE agent_changes SET status = 'undone' WHERE id = ?",
                    arguments: [row["id"] as String]
                )
            }
            return undone.count
        }
    }

    private static func agentRows(_ ids: [UUID], status: String, in db: Database) throws -> [Row] {
        try ids.compactMap {
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM agent_changes WHERE id = ? AND status = ?",
                arguments: [$0.uuidString, status]
            )
        }
    }

    /// Title and body changes grouped by note, so each note changes in one revision.
    private static func textBatches(_ rows: [Row]) -> [[Row]] {
        let text = rows.filter { ["title", "summary"].contains($0["kind"] as String) }
        var order: [String] = []
        var groups: [String: [Row]] = [:]
        for row in text {
            let note: String = row["noteID"]
            if groups[note] == nil {
                order.append(note)
            }
            groups[note, default: []].append(row)
        }
        return order.compactMap { groups[$0] }
    }

    private static func note(for row: Row, in db: Database) -> MarkdownDocument? {
        (row["noteID"] as String?).flatMap(UUID.init(uuidString:))
            .flatMap { try? liveNote($0, in: db) }
    }

    private static func applyCategory(_ row: Row, in db: Database) throws -> Bool {
        guard let code: String = row["code"] else { return false }
        let name: String = row["after"]
        let taken = try Row.fetchAll(db, sql: "SELECT code, name FROM decimal_categories")
            .contains {
                $0["code"] as String == code
                    || DecimalCategory.normalized($0["name"]) == DecimalCategory.normalized(name)
            }
        guard !taken, (try? DecimalCategory.validate(code: code, name: name)) != nil
        else { return false }
        let categoryID = UUID().uuidString
        try db.execute(
            sql: "INSERT INTO decimal_categories(id, code, name) VALUES (?, ?, ?)",
            arguments: [categoryID, code, name]
        )
        try db.execute(
            sql: "UPDATE agent_changes SET status = 'applied', snapshot = ? WHERE id = ?",
            arguments: [categoryID, row["id"] as String]
        )
        return true
    }

    private static func applyText(_ batch: [Row], in db: Database) throws -> Bool {
        guard let first = batch.first, var note = note(for: first, in: db),
              batch.allSatisfy({ note.revision?.uuidString == $0["baseRevision"] as String? })
        else { return false }
        for row in batch {
            if row["kind"] as String == "title" {
                note.name = row["after"]
            } else {
                note.markdown = row["after"]
            }
        }
        let saved = try writeNote(note, graph: false, in: db)
        for row in batch {
            try db.execute(
                sql: "UPDATE agent_changes SET status = 'applied', appliedRevision = ? WHERE id = ?",
                arguments: [saved.revision?.uuidString, row["id"] as String]
            )
        }
        return true
    }

    private static func applyFiling(_ row: Row, in db: Database) throws -> Bool {
        guard let note = note(for: row, in: db), let code: String = row["code"],
              let categoryID = try String.fetchOne(
                  db,
                  sql: "SELECT id FROM decimal_categories WHERE code = ?",
                  arguments: [code]
              ) else { return false }
        let noteID = note.id.uuidString
        let snapshot = try Row.fetchAll(
            db,
            sql: "SELECT categoryID, isPrimary FROM note_categories WHERE noteID = ?",
            arguments: [noteID]
        ).map { FilingSnapshot(categoryID: $0["categoryID"], primary: $0["isPrimary"]) }
        try db.execute(
            sql: "UPDATE note_categories SET isPrimary = 0 WHERE noteID = ?",
            arguments: [noteID]
        )
        try db.execute(sql: """
        INSERT INTO note_categories VALUES (?, ?, 1)
        ON CONFLICT(noteID, categoryID) DO UPDATE SET isPrimary = 1
        """, arguments: [noteID, categoryID])
        try db.execute(
            sql: "UPDATE agent_changes SET status = 'applied', snapshot = ? WHERE id = ?",
            arguments: [
                String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self),
                row["id"] as String,
            ]
        )
        return true
    }

    /// Only an unused category goes; anything filed there since keeps it.
    private static func undoCategory(_ row: Row, in db: Database) throws -> Bool {
        guard let categoryID: String = row["snapshot"],
              try Int.fetchOne(
                  db,
                  sql: """
                  SELECT (SELECT count(*) FROM note_categories WHERE categoryID = ?1)
                       + (SELECT count(*) FROM source_categories WHERE categoryID = ?1)
                  """,
                  arguments: [categoryID]
              ) == 0 else { return false }
        try db.execute(sql: "DELETE FROM decimal_categories WHERE id = ?", arguments: [categoryID])
        return true
    }

    private static func undoText(_ batch: [Row], in db: Database) throws -> Bool {
        guard let first = batch.first, var note = note(for: first, in: db),
              batch.allSatisfy({ note.revision?.uuidString == $0["appliedRevision"] as String? })
        else { return false }
        for row in batch {
            if row["kind"] as String == "title" {
                note.name = row["before"]
            } else {
                note.markdown = row["before"]
            }
        }
        _ = try writeNote(note, graph: false, in: db)
        return true
    }

    private static func undoFiling(_ row: Row, in db: Database) throws -> Bool {
        guard let note = note(for: row, in: db), let snapshot: String = row["snapshot"],
              let previous = try? JSONDecoder().decode(
                  [FilingSnapshot].self, from: Data(snapshot.utf8)
              ) else { return false }
        let noteID = note.id.uuidString
        try db.execute(sql: "DELETE FROM note_categories WHERE noteID = ?", arguments: [noteID])
        for membership in previous {
            try db.execute(
                sql: "INSERT INTO note_categories VALUES (?, ?, ?)",
                arguments: [noteID, membership.categoryID, membership.primary]
            )
        }
        return true
    }

    private static func agentChange(_ row: Row) throws -> AgentChange {
        guard let kind = AgentChange.Kind(rawValue: row["kind"]) else {
            throw InfactoryError.invalidDatabase
        }
        return try AgentChange(
            id: uuid(row["id"]),
            taskID: uuid(row["taskID"]),
            kind: kind,
            noteID: (row["noteID"] as String?).flatMap(UUID.init(uuidString:)),
            code: row["code"],
            before: row["before"],
            after: row["after"],
            reason: row["reason"],
            status: row["status"]
        )
    }
}
