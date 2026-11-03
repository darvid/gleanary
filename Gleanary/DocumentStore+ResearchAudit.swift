import Foundation
import GRDB

/// An item's text as an audit reads it, with what limits that reading.
struct AuditSourceText: Sendable {
    let source: WriterSourceText
    let revision: String
    let coverage: Coverage

    /// Captures that kept only part of the original could hold an answer the audit can't see.
    var partial: Bool {
        [.abstractOnly, .partial, .bookmark].contains(coverage)
    }
}

extension DocumentStore {
    func beginResearchAudit(_ audit: ResearchAudit) throws {
        try readyDatabase().write { db in
            guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM conversation_tasks
                WHERE id = ? AND state IN ('queued','running','awaiting_user'))
            """, arguments: [audit.taskID.uuidString]) == true else { throw CancellationError() }
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            INSERT INTO research_audits(taskID, request, brief, candidates, selection, scopeLimit,
                status, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                audit.taskID.uuidString, audit.request, Self.auditJSON(audit.brief),
                Self.auditJSON(audit.candidates), Self.auditJSON(audit.selection),
                audit.scopeLimit, audit.status.rawValue, now, now,
            ])
        }
    }

    func researchAudit(taskID: UUID) throws -> ResearchAudit? {
        try readyDatabase().read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM research_audits WHERE taskID = ?",
                arguments: [taskID.uuidString]
            ).map(Self.researchAudit)
        }
    }

    /// Audits chat shows: scopes waiting for confirmation and finished reports. A report whose
    /// items changed or were deleted is marked stale, and quotes from deleted items are dropped.
    func conversationAudits() throws -> [ResearchAudit] {
        try readyDatabase().read { db in
            let audits = try Row.fetchAll(db, sql: """
            SELECT a.* FROM research_audits a JOIN conversation_tasks t ON t.id = a.taskID
            WHERE (a.status = 'awaiting' AND t.state = 'awaiting_user') OR a.status = 'completed'
            ORDER BY a.createdAt DESC LIMIT 20
            """).map(Self.researchAudit)
            return try audits.map { audit in
                guard var report = audit.report else { return audit }
                var audit = audit
                let cited = Set(report.results.flatMap(\.evidence).map(\.itemID))
                let ids = Array(cited.union(report.revisions.keys))
                let live = try Self.liveRevisions(ids, in: db)
                audit.stale = report.revisions.contains { live[$0.key] != $0.value }
                    || cited.contains { live[$0] == nil }
                for index in report.results.indices {
                    report.results[index].evidence.removeAll { live[$0.itemID] == nil }
                }
                audit.report = report
                return audit
            }
        }
    }

    /// The person's confirmation: items the audit gathered and criteria it proposed, at least
    /// one of each. Only an awaiting audit can be confirmed, once; the task then runs again.
    func confirmResearchAudit(taskID: UUID, selection: [UUID], accepted: Set<String>) throws {
        try readyDatabase().write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM research_audits WHERE taskID = ?",
                arguments: [taskID.uuidString]
            ) else { throw WriterError.scopeChanged }
            var audit = try Self.researchAudit(row)
            let proposed = Set(audit.brief.dimensions.map(\.id))
            guard audit.status == .awaiting, !selection.isEmpty,
                  Set(selection).count == selection.count,
                  Set(selection).isSubset(of: audit.candidates.map(\.id)),
                  !accepted.isEmpty, accepted.isSubset(of: proposed)
            else { throw WriterError.scopeChanged }
            guard selection.count <= audit.scopeLimit else { throw WriterError.scopeChanged }
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            UPDATE conversation_tasks SET state = 'running', progress = 'Starting', updatedAt = ?
            WHERE id = ? AND state = 'awaiting_user'
            """, arguments: [now, taskID.uuidString])
            guard db.changesCount > 0 else { throw WriterError.scopeChanged }
            for index in audit.brief.dimensions.indices {
                audit.brief.dimensions[index].accepted = accepted
                    .contains(audit.brief.dimensions[index].id)
            }
            try db.execute(sql: """
            UPDATE research_audits SET status = 'auditing', selection = ?, brief = ?, updatedAt = ?
            WHERE taskID = ?
            """, arguments: [
                Self.auditJSON(selection), Self.auditJSON(audit.brief), now, taskID.uuidString,
            ])
        }
    }

    /// Whether the task waits on a scope card: a Writer scope or an audit.
    func awaitsConfirmation(_ taskID: UUID) throws -> Bool {
        try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM writer_requests WHERE taskID = ?1 AND status = 'awaiting')
                OR EXISTS(SELECT 1 FROM research_audits WHERE taskID = ?1 AND status = 'awaiting')
            """, arguments: [taskID.uuidString]) ?? false
        }
    }

    func setResearchAuditStatus(_ taskID: UUID, _ status: ResearchAudit.Status) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE research_audits SET status = ?, updatedAt = ? WHERE taskID = ?",
                arguments: [status.rawValue, Date().timeIntervalSince1970, taskID.uuidString]
            )
        }
    }

    /// Saves the report only while the task is still running, so Stop at any stage keeps
    /// nothing.
    func completeResearchAudit(_ taskID: UUID, report: AuditReport) throws {
        try readyDatabase().write { db in
            guard try String.fetchOne(
                db, sql: "SELECT state FROM conversation_tasks WHERE id = ?",
                arguments: [taskID.uuidString]
            ) == "running" else { throw CancellationError() }
            try db.execute(sql: """
            UPDATE research_audits SET status = 'completed', report = ?, updatedAt = ?
            WHERE taskID = ? AND status = 'auditing'
            """, arguments: [
                Self.auditJSON(report),
                Date().timeIntervalSince1970,
                taskID.uuidString,
            ])
            guard db.changesCount > 0 else { throw WriterError.scopeChanged }
        }
    }

    /// Dismissing hides a finding; it doesn't make it false, so the result keeps its coverage.
    func setAuditFindingDismissed(taskID: UUID, dimensionID: String, dismissed: Bool) throws {
        try readyDatabase().write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM research_audits WHERE taskID = ? AND status = 'completed'",
                arguments: [taskID.uuidString]
            ) else { throw WriterError.scopeChanged }
            guard var report = try Self.researchAudit(row).report,
                  let index = report.results.firstIndex(where: { $0.id == dimensionID })
            else { throw WriterError.scopeChanged }
            report.results[index].dismissed = dismissed
            let request: String = row["request"]
            if let fingerprint = ResearchAudit
                .fingerprint(report.results[index], request: request)
            {
                if dismissed {
                    try db.execute(sql: """
                    INSERT OR REPLACE INTO audit_dismissals(fingerprint, cited, dismissedAt)
                    VALUES (?, ?, ?)
                    """, arguments: [
                        fingerprint, ResearchAudit.cited(report.results[index]),
                        Date().timeIntervalSince1970,
                    ])
                } else {
                    try db.execute(
                        sql: "DELETE FROM audit_dismissals WHERE fingerprint = ?",
                        arguments: [fingerprint]
                    )
                }
            }
            try db.execute(
                sql: "UPDATE research_audits SET report = ?, updatedAt = ? WHERE taskID = ?",
                arguments: [
                    Self.auditJSON(report), Date().timeIntervalSince1970, taskID.uuidString,
                ]
            )
        }
    }

    /// Findings dismissed in an earlier audit of the same question stay dismissed, unless the
    /// items they rest on changed.
    func applyEarlierDismissals(_ report: AuditReport, request: String) throws -> AuditReport {
        try readyDatabase().read { db in
            var report = report
            for index in report.results.indices {
                guard let fingerprint = ResearchAudit.fingerprint(
                    report.results[index], request: request
                ),
                    let cited = try String.fetchOne(
                        db, sql: "SELECT cited FROM audit_dismissals WHERE fingerprint = ?",
                        arguments: [fingerprint]
                    ),
                    cited == ResearchAudit.cited(report.results[index])
                else { continue }
                report.results[index].dismissed = true
            }
            return report
        }
    }

    /// The latest finished audit of the same question, to reuse its criteria.
    func previousAudit(question request: String) throws -> ResearchAudit? {
        let key = ResearchAudit.questionKey(request)
        return try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT * FROM research_audits WHERE status = 'completed'
            ORDER BY createdAt DESC LIMIT 50
            """).map(Self.researchAudit).first { ResearchAudit.questionKey($0.request) == key }
        }
    }

    // MARK: Reading

    func auditSource(_ id: UUID) throws -> AuditSourceText? {
        guard let source = try writerSource(id) else { return nil }
        let coverage = try researchSource(noteID: id).document.coverage
        let revision = try readyDatabase().read { db in
            try String.fetchOne(
                db, sql: "SELECT revision FROM notes WHERE id = ?", arguments: [id.uuidString]
            )
        }
        return AuditSourceText(source: source, revision: revision ?? "", coverage: coverage)
    }

    /// Where each item comes from: its captured source URL's host and its saved text, so
    /// imbalance can tell one site from several and mirrors from distinct sources.
    func auditOrigins(_ ids: [UUID]) throws -> [UUID: AuditImbalance.Origin] {
        var origins: [UUID: AuditImbalance.Origin] = [:]
        for id in Set(ids) {
            guard let source = try? researchSource(noteID: id) else { continue }
            let hash = try readyDatabase().read { db in
                try String.fetchOne(db, sql: """
                SELECT markdownHash FROM captures WHERE noteID = ? ORDER BY createdAt DESC LIMIT 1
                """, arguments: [id.uuidString])
            }
            origins[id] = AuditImbalance.Origin(
                host: AuditImbalance.host(of: source.document.sourceURL), contentHash: hash
            )
        }
        return origins
    }

    /// Questions asked in your own notes among these items, in item order: notes you wrote,
    /// not sources or model-written items.
    func auditQuestions(in ids: [UUID], limit: Int) throws -> [(
        note: UUID,
        title: String,
        question: String
    )] {
        guard limit > 0, !ids.isEmpty else { return [] }
        let notes = try readyDatabase().read { db in
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            return try Row.fetchAll(db, sql: """
            SELECT n.id, n.name, n.markdown FROM notes n
            WHERE n.id IN (\(marks)) AND n.deletedAt IS NULL AND (\(Self.libraryKindSQL)) = 'note'
            """, arguments: StatementArguments(ids.map(\.uuidString))).map { row in
                try (
                    id: Self.uuid(row["id"]),
                    title: row["name"] as String,
                    markdown: row["markdown"] as String
                )
            }
        }
        var found: [(note: UUID, title: String, question: String)] = []
        for id in ids {
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            for question in NoteQuestions.find(in: note.markdown, limit: limit - found.count)
                where !found.contains(where: { $0.question == question })
            {
                found.append((note.id, note.title, question))
            }
            if found.count >= limit {
                break
            }
        }
        return found
    }

    /// Live items in the search index, the denominator of a library search.
    func searchableItemCount() throws -> Int {
        try readyDatabase().read { db in
            try Int.fetchOne(db, sql: """
            SELECT count(*) FROM notes n WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
            AND EXISTS (SELECT 1 FROM passages p WHERE p.noteID = n.id)
            """) ?? 0
        }
    }

    /// Titles of the items an audit may treat as evidence: live sources and the person's own
    /// notes. Summaries, research results and composed documents are model-written, so they
    /// never count as evidence.
    func auditableItems(_ ids: [UUID]) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        return try readyDatabase().read { db in
            var titles: [UUID: String] = [:]
            for batch in stride(from: 0, to: ids.count, by: 400).map({
                Array(ids[$0 ..< min($0 + 400, ids.count)])
            }) {
                let marks = batch.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: """
                SELECT n.id, n.name FROM notes n
                WHERE n.id IN (\(marks)) AND n.deletedAt IS NULL AND n.archivedAt IS NULL
                AND (\(Self.libraryKindSQL)) IN ('source', 'note')
                """, arguments: StatementArguments(batch.map(\.uuidString))) {
                    try titles[Self.uuid(row["id"])] = row["name"]
                }
            }
            return titles
        }
    }

    // MARK: Rows

    private static func liveRevisions(_ ids: [UUID], in db: Database) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")
        var revisions: [UUID: String] = [:]
        for row in try Row.fetchAll(db, sql: """
        SELECT id, revision FROM notes
        WHERE id IN (\(marks)) AND deletedAt IS NULL AND archivedAt IS NULL
        """, arguments: StatementArguments(ids.map(\.uuidString))) {
            try revisions[uuid(row["id"])] = row["revision"]
        }
        return revisions
    }

    private static func researchAudit(_ row: Row) throws -> ResearchAudit {
        func decode<Value: Decodable>(_ column: String) throws -> Value {
            let text: String = row[column]
            return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        }
        let report: String? = row["report"]
        guard let status = ResearchAudit.Status(rawValue: row["status"])
        else { throw GleanaryError.invalidDatabase }
        return try ResearchAudit(
            taskID: uuid(row["taskID"]), request: row["request"], brief: decode("brief"),
            candidates: decode("candidates"), selection: decode("selection"),
            scopeLimit: row["scopeLimit"], status: status,
            report: report.map { try JSONDecoder().decode(AuditReport.self, from: Data($0.utf8)) }
        )
    }

    private static func auditJSON(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }
}
