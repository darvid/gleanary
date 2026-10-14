import Foundation
import GRDB

/// When an item was last looked at by one kind of automation check, so walks through the
/// library ("oldest first") move on instead of revisiting the same items.
struct ItemCheck: Sendable, Equatable {
    var state: String
    var failures: Int
    var firstFailureAt: Date?
}

extension DocumentStore {
    // MARK: Configuration and runs

    /// Every built-in automation, with saved settings over its defaults.
    func automationConfigs() throws -> [AutomationConfig] {
        let rows = try readyDatabase().read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM automations")
        }
        var saved: [String: Row] = [:]
        for row in rows {
            saved[row["id"]] = row
        }
        return AutomationKind.allCases.map { kind in
            var config = AutomationConfig(kind: kind)
            if let row = saved[kind.rawValue] {
                config.enabled = row["enabled"]
                config.interval = row["interval"]
                config.batchLimit = row["batchLimit"]
                config.cloudAllowed = row["cloudAllowed"]
                config.dailyCalls = row["dailyCalls"]
                config.lastRunAt = (row["lastRunAt"] as Double?)
                    .map(Date.init(timeIntervalSince1970:))
            }
            return config
        }
    }

    func saveAutomation(_ config: AutomationConfig) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            INSERT INTO automations(id, enabled, interval, batchLimit, cloudAllowed, dailyCalls, lastRunAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled, interval = excluded.interval,
                batchLimit = excluded.batchLimit, cloudAllowed = excluded.cloudAllowed,
                dailyCalls = excluded.dailyCalls, lastRunAt = excluded.lastRunAt
            """, arguments: [
                config.kind.rawValue, config.enabled, config.interval, config.batchLimit,
                config.cloudAllowed, config.dailyCalls,
                config.lastRunAt?.timeIntervalSince1970,
            ])
        }
    }

    func beginAutomationRun(_ kind: AutomationKind, at date: Date) throws -> UUID {
        let id = UUID()
        try readyDatabase().write { db in
            try db.execute(
                sql: "INSERT INTO automation_runs(id, automationID, startedAt, status) VALUES (?, ?, ?, 'running')",
                arguments: [id.uuidString, kind.rawValue, date.timeIntervalSince1970]
            )
        }
        return id
    }

    /// Records the outcome and when the automation last ran, so its next run is scheduled
    /// from here.
    func finishAutomationRun(_ run: AutomationRun) throws {
        try readyDatabase().write { db in
            let ended = (run.endedAt ?? Date()).timeIntervalSince1970
            try db.execute(sql: """
            UPDATE automation_runs SET endedAt = ?, status = ?, examined = ?, changed = ?,
                proposed = ?, skipped = ?, calls = ?, report = ? WHERE id = ?
            """, arguments: [
                ended, run.status.rawValue, run.examined, run.changed, run.proposed, run.skipped,
                run.calls, run.report.joined(separator: "\n"), run.id.uuidString,
            ])
            try db.execute(sql: """
            INSERT INTO automations(id, enabled, interval, batchLimit, cloudAllowed, dailyCalls, lastRunAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET lastRunAt = excluded.lastRunAt
            """, arguments: [
                run.kind.rawValue, run.kind.enabledByDefault, run.kind.defaultInterval,
                run.kind.defaultBatch, true, run.kind.defaultDailyCalls,
                run.startedAt.timeIntervalSince1970,
            ])
        }
    }

    func automationRuns(_ kind: AutomationKind, limit: Int = 20) throws -> [AutomationRun] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT * FROM automation_runs WHERE automationID = ? ORDER BY startedAt DESC LIMIT ?
            """, arguments: [kind.rawValue, limit]).compactMap(Self.automationRun)
        }
    }

    /// A run left `running` by a quit or crash didn't finish; say so rather than show it running.
    func closeInterruptedAutomationRuns() throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE automation_runs SET status = 'cancelled', endedAt = startedAt,
                report = report || CASE WHEN report = '' THEN '' ELSE char(10) END
                    || 'Interrupted when Infactory quit.'
            WHERE status = 'running'
            """)
        }
    }

    /// Model calls this automation made since `start`, for its daily budget.
    func automationCalls(_ kind: AutomationKind, since start: Date) throws -> Int {
        try readyDatabase().read { db in
            try Int.fetchOne(db, sql: """
            SELECT coalesce(sum(calls), 0) FROM automation_runs
            WHERE automationID = ? AND startedAt >= ?
            """, arguments: [kind.rawValue, start.timeIntervalSince1970]) ?? 0
        }
    }

    /// Proposals from this automation's runs still waiting for review.
    func pendingAutomationChanges(_ kind: AutomationKind) throws -> [AgentChange] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT * FROM agent_changes WHERE status = 'pending' AND taskID IN
                (SELECT id FROM automation_runs WHERE automationID = ?)
            ORDER BY createdAt, ordinal
            """, arguments: [kind.rawValue]).map(Self.agentChange)
        }
    }

    /// Records a change an automation already made, so Undo can put it back.
    func recordAppliedChange(
        _ draft: AgentChangeDraft,
        appliedRevision: UUID?,
        runID: UUID
    ) throws {
        try readyDatabase().write { db in
            let ordinal = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM agent_changes WHERE taskID = ?",
                arguments: [runID.uuidString]
            ) ?? 0
            try db.execute(sql: """
            INSERT INTO agent_changes(id, taskID, ordinal, kind, noteID, targetID, code, before,
                after, reason, baseRevision, appliedRevision, status, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'applied', ?)
            """, arguments: [
                UUID().uuidString, runID.uuidString, ordinal, draft.kind.rawValue,
                draft.noteID?.uuidString, draft.targetID?.uuidString, draft.code, draft.before,
                draft.after, draft.reason, draft.baseRevision?.uuidString,
                appliedRevision?.uuidString, Date().timeIntervalSince1970,
            ])
        }
    }

    /// Changes from one run that can still be undone.
    func appliedRunChanges(_ runID: UUID) throws -> [UUID] {
        try readyDatabase().read { db in
            try String.fetchAll(
                db, sql: "SELECT id FROM agent_changes WHERE taskID = ? AND status = 'applied'",
                arguments: [runID.uuidString]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    // MARK: Item checks

    @discardableResult
    func recordCheck(
        _ noteID: UUID,
        kind: String,
        at date: Date,
        state: String,
        failed: Bool = false,
        detail: String? = nil
    ) throws -> ItemCheck {
        try readyDatabase().write { db in
            let previous = try Row.fetchOne(
                db,
                sql: "SELECT failures, firstFailureAt FROM item_checks WHERE noteID = ? AND kind = ?",
                arguments: [noteID.uuidString, kind]
            )
            let failures = failed ? (previous?["failures"] as Int? ?? 0) + 1 : 0
            let first = failed
                ? (previous?["firstFailureAt"] as Double? ?? date.timeIntervalSince1970) : nil
            try db.execute(sql: """
            INSERT INTO item_checks(noteID, kind, checkedAt, state, failures, firstFailureAt, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(noteID, kind) DO UPDATE SET checkedAt = excluded.checkedAt,
                state = excluded.state, failures = excluded.failures,
                firstFailureAt = excluded.firstFailureAt, detail = excluded.detail
            """, arguments: [
                noteID.uuidString, kind, date.timeIntervalSince1970, state, failures, first, detail,
            ])
            return ItemCheck(
                state: state,
                failures: failures,
                firstFailureAt: first.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func itemCheck(_ noteID: UUID, kind: String) throws -> ItemCheck? {
        try readyDatabase().read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM item_checks WHERE noteID = ? AND kind = ?",
                arguments: [noteID.uuidString, kind]
            ).map {
                ItemCheck(
                    state: $0["state"],
                    failures: $0["failures"],
                    firstFailureAt: ($0["firstFailureAt"] as Double?)
                        .map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    // MARK: Selectors

    /// Inbox items holding fetched full text and no summary, oldest first. An item whose
    /// summary failed waits until `retryBefore` before it's tried again.
    func inboxSummaryCandidates(limit: Int, retryBefore: Date) throws -> [UUID] {
        try readyDatabase().read { db in
            try String.fetchAll(db, sql: """
            SELECT n.id FROM notes n
            JOIN note_categories nc ON nc.noteID = n.id AND nc.isPrimary = 1
            JOIN decimal_categories dc ON dc.id = nc.categoryID AND dc.code = ?
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL AND n.sourceURL IS NOT NULL
                AND NOT (\(Self.legacySummarySQL))
                AND EXISTS (SELECT 1 FROM captures c WHERE c.noteID = n.id
                    AND c.markdownHash = n.contentHash
                    AND coalesce(json_extract(CAST(c.document AS TEXT), '$.coverage'), '') != 'bookmark')
                AND NOT EXISTS (SELECT 1 FROM item_checks ic WHERE ic.noteID = n.id
                    AND ic.kind = 'summary' AND ic.state = 'failed' AND ic.checkedAt > ?)
            ORDER BY n.createdAt, n.id LIMIT ?
            """, arguments: [DecimalCategory.inboxCode, retryBefore.timeIntervalSince1970, limit])
                .compactMap(UUID.init(uuidString:))
        }
    }

    /// Sources whose original link is due a check: never checked, checked before
    /// `checkedBefore`, or failing and last tried before `retryBefore`.
    func linkCheckCandidates(
        limit: Int,
        checkedBefore: Date,
        retryBefore: Date
    ) throws -> [(id: UUID, url: URL, title: String)] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT n.id, n.sourceURL, n.name FROM notes n
            LEFT JOIN item_checks ic ON ic.noteID = n.id AND ic.kind = 'access'
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
                AND (n.sourceURL LIKE 'https://%' OR n.sourceURL LIKE 'http://%')
                AND (ic.checkedAt IS NULL OR ic.checkedAt < ?
                    OR (ic.state IN ('gone', 'transient') AND ic.checkedAt < ?))
            ORDER BY coalesce(ic.checkedAt, 0), n.createdAt, n.id LIMIT ?
            """, arguments: [
                checkedBefore.timeIntervalSince1970, retryBefore.timeIntervalSince1970, limit,
            ]).compactMap { row in
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let url = (row["sourceURL"] as String?).flatMap(URL.init(string:))
                else { return nil }
                return (id, url, row["name"])
            }
        }
    }

    /// Items with no links yet, oldest link check first.
    func crossLinkCandidates(limit: Int, checkedBefore: Date) throws -> [UUID] {
        try readyDatabase().read { db in
            try String.fetchAll(db, sql: """
            SELECT n.id FROM notes n
            LEFT JOIN item_checks ic ON ic.noteID = n.id AND ic.kind = 'links'
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
                AND NOT EXISTS (SELECT 1 FROM note_links WHERE n.id IN (leftID, rightID))
                AND NOT EXISTS (SELECT 1 FROM knowledge_links WHERE n.id IN (leftID, rightID))
                AND (ic.checkedAt IS NULL OR ic.checkedAt < ?)
            ORDER BY coalesce(ic.checkedAt, 0), n.createdAt, n.id LIMIT ?
            """, arguments: [checkedBefore.timeIntervalSince1970, limit])
                .compactMap(UUID.init(uuidString:))
        }
    }

    /// Whether these two items are linked, or a link between them was already proposed,
    /// applied or turned down, so it isn't proposed again.
    func linkConsidered(_ left: UUID, _ right: UUID) throws -> Bool {
        let ids = [left.uuidString, right.uuidString].sorted()
        return try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM note_links WHERE leftID = ?1 AND rightID = ?2)
                OR EXISTS(SELECT 1 FROM knowledge_links WHERE leftID = ?1 AND rightID = ?2)
                OR EXISTS(SELECT 1 FROM agent_changes WHERE kind = 'link'
                    AND status IN ('pending', 'applied', 'rejected')
                    AND ((noteID = ?1 AND targetID = ?2) OR (noteID = ?2 AND targetID = ?1)))
            """, arguments: [ids[0], ids[1]]) ?? false
        }
    }

    /// Whether archiving this item is already waiting for review or was turned down.
    func archiveConsidered(_ noteID: UUID) throws -> Bool {
        try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM agent_changes WHERE kind = 'archive' AND noteID = ?
                AND status IN ('pending', 'rejected'))
            """, arguments: [noteID.uuidString]) ?? false
        }
    }

    func isArchived(_ noteID: UUID) throws -> Bool {
        try readyDatabase().read { db in
            try Double.fetchOne(
                db, sql: "SELECT archivedAt FROM notes WHERE id = ?", arguments: [noteID.uuidString]
            ) != nil
        }
    }

    private static func automationRun(_ row: Row) -> AutomationRun? {
        guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
              let kind = AutomationKind(rawValue: row["automationID"]),
              let status = AutomationRun.Status(rawValue: row["status"]) else { return nil }
        let report: String = row["report"]
        return AutomationRun(
            id: id,
            kind: kind,
            startedAt: Date(timeIntervalSince1970: row["startedAt"]),
            endedAt: (row["endedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
            status: status,
            examined: row["examined"],
            changed: row["changed"],
            proposed: row["proposed"],
            skipped: row["skipped"],
            calls: row["calls"],
            report: report.isEmpty ? [] : report.components(separatedBy: "\n")
        )
    }
}
