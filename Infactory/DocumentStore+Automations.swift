import Foundation
import GRDB

/// One item listed in a digest.
struct DigestItem: Sendable, Equatable {
    let id: UUID
    let title: String
    let host: String?
    /// The item's primary home, if it has one.
    let code: String?
    let category: String?
}

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
                config.recheck = row["recheck"]
                config.usesWriter = row["usesWriter"]
                config.lastRunAt = (row["lastRunAt"] as Double?)
                    .map(Date.init(timeIntervalSince1970:))
            }
            return config
        }
    }

    func saveAutomation(_ config: AutomationConfig) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            INSERT INTO automations(id, enabled, interval, batchLimit, cloudAllowed, dailyCalls,
                recheck, usesWriter, lastRunAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled, interval = excluded.interval,
                batchLimit = excluded.batchLimit, cloudAllowed = excluded.cloudAllowed,
                dailyCalls = excluded.dailyCalls, recheck = excluded.recheck,
                usesWriter = excluded.usesWriter, lastRunAt = excluded.lastRunAt
            """, arguments: [
                config.kind.rawValue, config.enabled, config.interval, config.batchLimit,
                config.cloudAllowed, config.dailyCalls, config.recheck, config.usesWriter,
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
                proposed = ?, skipped = ?, calls = ?, report = ?, entries = ?, fine = ?
            WHERE id = ?
            """, arguments: [
                ended, run.status.rawValue, run.examined, run.changed, run.proposed, run.skipped,
                run.calls, run.report.joined(separator: "\n"),
                String(decoding: JSONEncoder().encode(run.entries), as: UTF8.self), run.fine,
                run.id.uuidString,
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
            try Self.insertAppliedChange(
                draft, appliedRevision: appliedRevision, runID: runID, at: Date(), in: db
            )
        }
    }

    private static func insertAppliedChange(
        _ draft: AgentChangeDraft,
        appliedRevision: UUID?,
        runID: UUID,
        at date: Date,
        in db: Database
    ) throws {
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
            appliedRevision?.uuidString, date.timeIntervalSince1970,
        ])
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

    /// Which of these runs still have applied changes, and which had theirs all undone.
    func runUndoState(_ runIDs: [UUID]) throws -> (applied: Set<UUID>, undone: Set<UUID>) {
        guard !runIDs.isEmpty else { return ([], []) }
        return try readyDatabase().read { db in
            let marks = runIDs.map { _ in "?" }.joined(separator: ",")
            var applied = Set<UUID>()
            var undone = Set<UUID>()
            for row in try Row.fetchAll(db, sql: """
            SELECT taskID, sum(status = 'applied') AS applied, sum(status = 'undone') AS undone
            FROM agent_changes WHERE taskID IN (\(marks)) GROUP BY taskID
            """, arguments: StatementArguments(runIDs.map(\.uuidString))) {
                guard let id = UUID(uuidString: row["taskID"]) else { continue }
                if (row["applied"] as Int) > 0 {
                    applied.insert(id)
                } else if (row["undone"] as Int) > 0 {
                    undone.insert(id)
                }
            }
            return (applied, undone)
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

    /// Inbox items holding fetched full text and no summary, newest first. An item whose
    /// summary failed waits until `retryBefore` before it's tried again.
    func inboxSummaryCandidates(limit: Int, retryBefore: Date) throws -> [UUID] {
        let (sql, arguments) = Self.inboxSummaryQuery(retryBefore: retryBefore)
        return try readyDatabase().read { db in
            try String.fetchAll(
                db, sql: "SELECT n.id \(sql) ORDER BY n.createdAt DESC, n.id LIMIT ?",
                arguments: arguments + [limit]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    /// Sources whose original link is due a check: never checked (newest first), then those
    /// checked before `checkedBefore` or failing and last tried before `retryBefore` (longest
    /// ago first).
    func linkCheckCandidates(
        limit: Int,
        checkedBefore: Date,
        retryBefore: Date
    ) throws -> [(id: UUID, url: URL, title: String)] {
        let (sql, arguments) = Self.linkCheckQuery(
            checkedBefore: checkedBefore, retryBefore: retryBefore
        )
        return try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT n.id, n.sourceURL, n.name \(sql) \(Self.newThenOldest) LIMIT ?",
                arguments: arguments + [limit]
            ).compactMap { row in
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let url = (row["sourceURL"] as String?).flatMap(URL.init(string:))
                else { return nil }
                return (id, url, row["name"])
            }
        }
    }

    /// Items with no links yet: never looked at (newest first), then the longest ago.
    func crossLinkCandidates(limit: Int, checkedBefore: Date) throws -> [UUID] {
        let (sql, arguments) = Self.crossLinkQuery(checkedBefore: checkedBefore)
        return try readyDatabase().read { db in
            try String.fetchAll(
                db, sql: "SELECT n.id \(sql) \(Self.newThenOldest) LIMIT ?",
                arguments: arguments + [limit]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    /// How many items each selector would return without a limit, counted in SQLite.
    func inboxSummaryBacklog(retryBefore: Date) throws -> Int {
        try count(Self.inboxSummaryQuery(retryBefore: retryBefore))
    }

    func linkCheckBacklog(checkedBefore: Date, retryBefore: Date) throws -> Int {
        try count(Self.linkCheckQuery(checkedBefore: checkedBefore, retryBefore: retryBefore))
    }

    func crossLinkBacklog(checkedBefore: Date) throws -> Int {
        try count(Self.crossLinkQuery(checkedBefore: checkedBefore))
    }

    /// Titles for many items in one query, for listing proposals.
    /// Which of these items no longer exist, such as a digest removed by Undo.
    func missingNotes(_ ids: [UUID]) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        return try readyDatabase().read { db in
            var live = Set<UUID>()
            for chunk in stride(from: 0, to: ids.count, by: 500).map({
                Array(ids[$0 ..< min($0 + 500, ids.count)])
            }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for id in try String.fetchAll(
                    db, sql: "SELECT id FROM notes WHERE deletedAt IS NULL AND id IN (\(marks))",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    if let uuid = UUID(uuidString: id) {
                        live.insert(uuid)
                    }
                }
            }
            return Set(ids).subtracting(live)
        }
    }

    func noteTitles(_ ids: [UUID]) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        return try readyDatabase().read { db in
            var titles: [UUID: String] = [:]
            // Chunked under SQLite's variable limit.
            for chunk in stride(from: 0, to: ids.count, by: 500).map({
                Array(ids[$0 ..< min($0 + 500, ids.count)])
            }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for row in try Row.fetchAll(
                    db, sql: "SELECT id, name FROM notes WHERE id IN (\(marks))",
                    arguments: StatementArguments(chunk.map(\.uuidString))
                ) {
                    if let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)) {
                        titles[id] = row["name"]
                    }
                }
            }
            return titles
        }
    }

    private func count(_ query: (sql: String, arguments: StatementArguments)) throws -> Int {
        try readyDatabase().read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) \(query.sql)", arguments: query.arguments)
                ?? 0
        }
    }

    /// Never-checked items first, newest of those first, so what you just saved is in the next
    /// run; then whatever was checked longest ago.
    private static let newThenOldest = """
    ORDER BY ic.checkedAt IS NOT NULL, CASE WHEN ic.checkedAt IS NULL THEN n.createdAt END DESC,
        ic.checkedAt, n.id
    """

    private static func inboxSummaryQuery(retryBefore: Date)
        -> (sql: String, arguments: StatementArguments)
    {
        ("""
        FROM notes n
        JOIN note_categories nc ON nc.noteID = n.id AND nc.isPrimary = 1
        JOIN decimal_categories dc ON dc.id = nc.categoryID AND dc.code = ?
        WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL AND n.sourceURL IS NOT NULL
            AND NOT (\(legacySummarySQL))
            AND EXISTS (SELECT 1 FROM captures c WHERE c.noteID = n.id
                AND c.markdownHash = n.contentHash
                AND coalesce(json_extract(CAST(c.document AS TEXT), '$.coverage'), '') != 'bookmark')
            AND NOT EXISTS (SELECT 1 FROM item_checks ic WHERE ic.noteID = n.id
                AND ic.kind = 'summary' AND ic.state = 'failed' AND ic.checkedAt > ?)
        """, [DecimalCategory.inboxCode, retryBefore.timeIntervalSince1970])
    }

    private static func linkCheckQuery(checkedBefore: Date, retryBefore: Date)
        -> (sql: String, arguments: StatementArguments)
    {
        ("""
        FROM notes n
        LEFT JOIN item_checks ic ON ic.noteID = n.id AND ic.kind = 'access'
        WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
            AND (n.sourceURL LIKE 'https://%' OR n.sourceURL LIKE 'http://%')
            AND (ic.checkedAt IS NULL OR ic.checkedAt < ?
                OR (ic.state IN ('gone', 'transient') AND ic.checkedAt < ?))
        """, [checkedBefore.timeIntervalSince1970, retryBefore.timeIntervalSince1970])
    }

    private static func crossLinkQuery(checkedBefore: Date)
        -> (sql: String, arguments: StatementArguments)
    {
        ("""
        FROM notes n
        LEFT JOIN item_checks ic ON ic.noteID = n.id AND ic.kind = 'links'
        WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL AND NOT \(writtenByAutomation)
            AND NOT EXISTS (SELECT 1 FROM note_links WHERE leftID = n.id)
            AND NOT EXISTS (SELECT 1 FROM note_links WHERE rightID = n.id)
            AND NOT EXISTS (SELECT 1 FROM knowledge_links WHERE leftID = n.id)
            AND NOT EXISTS (SELECT 1 FROM knowledge_links WHERE rightID = n.id)
            AND (ic.checkedAt IS NULL OR ic.checkedAt < ?)
        """, [checkedBefore.timeIntervalSince1970])
    }

    /// A note an automation wrote, such as a digest: never something to file, link or list.
    private static let writtenByAutomation = """
    EXISTS (SELECT 1 FROM agent_changes WHERE noteID = n.id AND kind = 'note')
    """

    // MARK: Bookmark fetcher

    /// Imported bookmarks whose page was never fetched, newest first: still unedited, with no
    /// fetch queued, running or failed, and not tried by the fetcher before.
    func bookmarkFetchCandidates(limit: Int) throws -> [(id: UUID, url: URL, title: String)] {
        let (sql, arguments) = Self.bookmarkFetchQuery
        return try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT n.id, n.sourceURL, n.name \(sql) ORDER BY n.createdAt DESC, n.id LIMIT ?",
                arguments: arguments + [limit]
            ).compactMap { row in
                guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)),
                      let url = (row["sourceURL"] as String?).flatMap(URL.init(string:))
                else { return nil }
                return (id, url, row["name"])
            }
        }
    }

    func bookmarkFetchBacklog() throws -> Int {
        try count(Self.bookmarkFetchQuery)
    }

    private static var bookmarkFetchQuery: (sql: String, arguments: StatementArguments) {
        ("""
        FROM notes n
        JOIN captures c ON c.noteID = n.id AND c.markdownHash = n.contentHash
            AND c.createdAt = (SELECT max(createdAt) FROM captures WHERE noteID = n.id)
        WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
            AND (n.sourceURL LIKE 'https://%' OR n.sourceURL LIKE 'http://%')
            AND json_extract(CAST(c.document AS TEXT), '$.coverage') = 'bookmark'
            AND NOT EXISTS (SELECT 1 FROM item_checks WHERE noteID = n.id AND kind = ?)
            -- Looked up by note, not by state, since failed jobs can number thousands; the
            -- unary + drops n.id's text affinity so the expression index can seek.
            AND NOT EXISTS (SELECT 1 FROM ingestion_jobs INDEXED BY ingestion_jobs_replacing
                WHERE json_extract(CAST(request AS TEXT), '$.replacingNoteID') = +n.id
                AND state IN ('queued', 'fetching', 'extracting', 'failed'))
        """, [AutomationEngine.fetchCheck])
    }

    // MARK: Failed-capture retry

    /// Failed captures whose next automatic try is due, the longest waiting first. Only ones
    /// that failed for a reason that may pass and need nothing from you; never more than
    /// `maxRetries` tries, and never for an item since deleted or archived.
    func captureRetryCandidates(
        limit: Int,
        now: Date,
        firstWait: TimeInterval,
        maxRetries: Int
    ) throws -> [CaptureJob] {
        let (sql, arguments) = Self.captureRetryQuery(
            now: now, firstWait: firstWait, maxRetries: maxRetries
        )
        return try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT j.* \(sql) ORDER BY coalesce(j.retryAt, j.updatedAt + ?), j.id LIMIT ?",
                arguments: arguments + [firstWait, limit]
            ).map(Self.captureJob)
        }
    }

    func captureRetryBacklog(now: Date, firstWait: TimeInterval, maxRetries: Int) throws -> Int {
        try count(Self.captureRetryQuery(now: now, firstWait: firstWait, maxRetries: maxRetries))
    }

    private static func captureRetryQuery(now: Date, firstWait: TimeInterval, maxRetries: Int)
        -> (sql: String, arguments: StatementArguments)
    {
        ("""
        FROM ingestion_jobs j
        WHERE j.state = 'failed' AND j.retryable = 1 AND j.recovery IS NULL
            AND j.autoRetries < ? AND coalesce(j.retryAt, j.updatedAt + ?) <= ?
            AND NOT EXISTS (SELECT 1 FROM notes n
                WHERE n.id = json_extract(CAST(j.request AS TEXT), '$.replacingNoteID')
                AND (n.deletedAt IS NOT NULL OR n.archivedAt IS NOT NULL))
        """, [maxRetries, firstWait, now.timeIntervalSince1970])
    }

    /// Queues a failed capture again and counts the try, only while the policy allows it: a
    /// failure that may pass, needing nothing from you, under `maxRetries` tries.
    func retryCaptureAutomatically(_ id: UUID, maxRetries: Int) throws -> Bool {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE ingestion_jobs SET state = 'queued', token = ?, progress = 'Retry queued',
                error = NULL, retryAt = NULL, autoRetries = autoRetries + 1
            WHERE id = ? AND state = 'failed' AND retryable = 1 AND recovery IS NULL
                AND autoRetries < ?
            """, arguments: [UUID().uuidString, id.uuidString, maxRetries])
            return db.changesCount > 0
        }
    }

    /// When a capture that failed again may next be tried.
    func scheduleCaptureRetry(_ id: UUID, at date: Date) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE ingestion_jobs SET retryAt = ? WHERE id = ? AND state = 'failed'",
                arguments: [date.timeIntervalSince1970, id.uuidString]
            )
        }
    }

    // MARK: Unfiled filer

    /// Items filed nowhere and not waiting on a filing already proposed: never looked at
    /// (newest first), then those looked at before `checkedBefore`, or whose look failed
    /// before `retryBefore`.
    func unfiledCandidates(
        limit: Int,
        checkedBefore: Date,
        retryBefore: Date
    ) throws -> [FilingCandidate] {
        let (sql, arguments) = Self.unfiledQuery(
            checkedBefore: checkedBefore, retryBefore: retryBefore
        )
        return try readyDatabase().read { db in
            // IDs first, so the sort doesn't carry every unfiled item's text.
            let ids = try String.fetchAll(
                db, sql: "SELECT n.id \(sql) \(Self.newThenOldest) LIMIT ?",
                arguments: arguments + [limit]
            )
            return try ids.compactMap { id in
                try Row.fetchOne(
                    db,
                    sql: "SELECT id, revision, name, sourceURL, markdown FROM notes WHERE id = ?",
                    arguments: [id]
                ).map { row in
                    let source = (row["sourceURL"] as String?).flatMap(URL.init(string:))
                    let name: String = row["name"]
                    return try FilingCandidate(
                        id: Self.uuid(row["id"]),
                        revision: Self.uuid(row["revision"]),
                        title: name,
                        host: source?.host(),
                        text: FilingText.classification(
                            name: name, sourceURL: source, markdown: row["markdown"]
                        )
                    )
                }
            }
        }
    }

    func unfiledBacklog(checkedBefore: Date, retryBefore: Date) throws -> Int {
        try count(Self.unfiledQuery(checkedBefore: checkedBefore, retryBefore: retryBefore))
    }

    private static func unfiledQuery(checkedBefore: Date, retryBefore: Date)
        -> (sql: String, arguments: StatementArguments)
    {
        ("""
        FROM notes n
        LEFT JOIN item_checks ic ON ic.noteID = n.id AND ic.kind = ?
        WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL AND NOT \(writtenByAutomation)
            AND NOT EXISTS (SELECT 1 FROM note_categories WHERE noteID = n.id)
            AND NOT EXISTS (SELECT 1 FROM filing_suggestions
                WHERE noteID = n.id AND status = 'pending')
            AND NOT EXISTS (SELECT 1 FROM agent_changes
                WHERE noteID = n.id AND kind = 'filing' AND status = 'pending')
            AND (ic.checkedAt IS NULL OR ic.checkedAt < ?
                OR (ic.state = 'failed' AND ic.checkedAt < ?))
        """, [
            AutomationEngine.filingCheck, checkedBefore.timeIntervalSince1970,
            retryBefore.timeIntervalSince1970,
        ])
    }

    /// Whether filing this item under `code` was proposed, applied, undone or turned down
    /// before, here or in Categorize Unfiled, so it isn't proposed again.
    func filingConsidered(_ noteID: UUID, code: String) throws -> Bool {
        try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM agent_changes WHERE noteID = ?1 AND kind = 'filing'
                    AND code = ?2 AND status IN ('pending', 'applied', 'rejected', 'undone'))
                OR EXISTS(SELECT 1 FROM filing_suggestions s
                    JOIN decimal_categories c ON c.id = s.categoryID
                    WHERE s.noteID = ?1 AND c.code = ?2 AND s.status = 'rejected')
            """, arguments: [noteID.uuidString, code]) ?? false
        }
    }

    // MARK: Weekly digest

    /// Items saved from `start` until `end`, newest first, with their primary home. Digests
    /// themselves are left out.
    func digestItems(from start: Date, to end: Date, limit: Int) throws -> [DigestItem] {
        let (sql, arguments) = Self.digestQuery(from: start, to: end)
        return try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT n.id, n.name, n.sourceURL, dc.code, dc.name AS category \(sql)
            ORDER BY n.createdAt DESC, n.id LIMIT ?
            """, arguments: arguments + [limit]).map { row in
                try DigestItem(
                    id: Self.uuid(row["id"]),
                    title: row["name"],
                    host: (row["sourceURL"] as String?).flatMap(URL.init(string:))?.host(),
                    code: row["code"],
                    category: row["category"]
                )
            }
        }
    }

    func digestBacklog(from start: Date, to end: Date) throws -> Int {
        try count(Self.digestQuery(from: start, to: end))
    }

    private static func digestQuery(from start: Date, to end: Date)
        -> (sql: String, arguments: StatementArguments)
    {
        ("""
        FROM notes n
        LEFT JOIN note_categories nc ON nc.noteID = n.id AND nc.isPrimary = 1
        LEFT JOIN decimal_categories dc ON dc.id = nc.categoryID
        WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL AND NOT \(writtenByAutomation)
            AND n.createdAt >= ? AND n.createdAt < ?
        """, [start.timeIntervalSince1970, end.timeIntervalSince1970])
    }

    /// When the latest digest still standing was written; one that was undone doesn't count,
    /// so the next covers its week again.
    func lastDigestAt() throws -> Date? {
        try readyDatabase().read { db in
            try Double.fetchOne(db, sql: """
            SELECT max(createdAt) FROM agent_changes WHERE kind = 'note' AND status = 'applied'
                AND taskID IN (SELECT id FROM automation_runs WHERE automationID = ?)
            """, arguments: [AutomationKind.weeklyDigest.rawValue])
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Writes an automation's new note in the Inbox, recording it as the run's change so Undo
    /// removes it. One transaction, so a note never exists without its Undo.
    func writeAutomationNote(
        _ document: MarkdownDocument,
        reason: String,
        runID: UUID,
        at date: Date
    ) throws -> MarkdownDocument {
        try readyDatabase().write { db in
            let note = try Self.writeNote(document, graph: false, in: db)
            if let inbox = try String.fetchOne(
                db, sql: "SELECT id FROM decimal_categories WHERE code = ?",
                arguments: [DecimalCategory.inboxCode]
            ) {
                try Self.fileImported(note.id, categoryID: Self.uuid(inbox), in: db)
            }
            try Self.insertAppliedChange(
                AgentChangeDraft(
                    kind: .note, noteID: note.id, before: "", after: note.name, reason: reason
                ),
                appliedRevision: note.revision, runID: runID, at: date, in: db
            )
            return note
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

    /// Whether updating this item's link to `url` was already proposed, or turned down.
    func relinkConsidered(_ noteID: UUID, to url: URL) throws -> Bool {
        try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM agent_changes WHERE kind = 'relink' AND noteID = ?
                AND after = ? AND status IN ('pending', 'rejected'))
            """, arguments: [noteID.uuidString, url.absoluteString]) ?? false
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
            report: report.isEmpty ? [] : report.components(separatedBy: "\n"),
            entries: (try? JSONDecoder().decode(
                [AutomationEntry].self, from: Data((row["entries"] as String).utf8)
            )) ?? [],
            fine: row["fine"]
        )
    }
}
