import Foundation
import GRDB

/// Links found inside saved sources and what became of each. A link found again in the same
/// source keeps its row, so a dismissal or an earlier save sticks.
enum AcquisitionSchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE acquisition_candidates (
            id TEXT PRIMARY KEY NOT NULL,
            identity TEXT NOT NULL,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            foundInNoteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            context TEXT NOT NULL,
            provenance TEXT NOT NULL,
            hop INTEGER NOT NULL,
            score REAL NOT NULL,
            state TEXT NOT NULL,
            reason TEXT NOT NULL,
            automatic INTEGER NOT NULL DEFAULT 0,
            captureJobID TEXT,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            UNIQUE(foundInNoteID, identity)
        );
        CREATE INDEX acquisition_candidates_state ON acquisition_candidates(state, updatedAt);
        CREATE INDEX acquisition_candidates_job ON acquisition_candidates(captureJobID);
        """)
    }

    static func addPageTitle(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE acquisition_candidates ADD COLUMN pageTitle TEXT;
        ALTER TABLE acquisition_candidates ADD COLUMN pageTitleCheckedAt REAL;
        """)
    }

    static func addIntent(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE acquisition_candidates ADD COLUMN intent TEXT")
    }

    /// What became of a saved candidate, for probation and the digest, and sites you muted.
    static func addProbation(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE acquisition_candidates ADD COLUMN savedNoteID TEXT;
        ALTER TABLE acquisition_candidates ADD COLUMN savedAt REAL;
        ALTER TABLE acquisition_candidates ADD COLUMN openedAt REAL;
        CREATE INDEX acquisition_candidates_saved ON acquisition_candidates(savedNoteID);
        CREATE TABLE acquisition_muted_hosts (
            host TEXT PRIMARY KEY NOT NULL,
            createdAt REAL NOT NULL
        );
        """)
    }
}

/// An automatic save, for the weekly digest.
struct AcquisitionDigestItem: Sendable, Equatable {
    let noteID: UUID
    let title: String
    let originID: UUID
    let originTitle: String
    let reason: String
}

extension DocumentStore {
    /// What the planner needs: automatic saves in the last day and which links are already
    /// in the library.
    func acquisitionContext(
        identities: [String]
    ) throws -> (savedToday: Int, saved: Set<String>, muted: Set<String>, bySite: [String: Int]) {
        try readyDatabase().read { db in
            let muted = try Set(String.fetchAll(
                db,
                sql: "SELECT host FROM acquisition_muted_hosts"
            ))
            var bySite: [String: Int] = [:]
            for url in try String.fetchAll(db, sql: """
            SELECT url FROM acquisition_candidates
            WHERE automatic = 1 AND state IN ('approved','queued') AND createdAt > ?
            """, arguments: [Date().timeIntervalSince1970 - 86400]) {
                let host = URL(string: url)?.host(percentEncoded: false) ?? ""
                bySite[AcquisitionScorer.domain(host), default: 0] += 1
            }
            let savedToday = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM acquisition_candidates
            WHERE automatic = 1 AND state IN ('approved','queued') AND createdAt > ?
            """, arguments: [Date().timeIntervalSince1970 - 86400]) ?? 0
            var saved = Set<String>()
            for identity in Set(identities)
                where try Self.savedLinkedSource(identity: identity, in: db) != nil
            {
                saved.insert(identity)
            }
            return (savedToday, saved, muted, bySite)
        }
    }

    @discardableResult
    func recordAcquisitions(
        _ plans: [AcquisitionPlanner.Plan],
        foundIn noteID: UUID,
        hop: Int
    ) throws -> [AcquisitionCandidate] {
        try readyDatabase().write { db in
            let now = Date().timeIntervalSince1970
            for plan in plans {
                try db.execute(sql: """
                INSERT INTO acquisition_candidates(id, identity, url, title, foundInNoteID,
                    context, provenance, hop, score, state, reason, automatic, intent, createdAt,
                    updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(foundInNoteID, identity) DO NOTHING
                """, arguments: [
                    UUID().uuidString, plan.link.identity, plan.link.url.absoluteString,
                    plan.link.title, noteID.uuidString, plan.link.context,
                    plan.score.provenance.rawValue, hop, plan.score.value, plan.state.rawValue,
                    plan.reason, plan.state == .approved, plan.intent?.rawValue, now, now,
                ])
            }
            return try Self.acquisitionCandidates(
                sql: "foundInNoteID = ?", arguments: [noteID.uuidString], in: db
            )
        }
    }

    func approvedAcquisitions(foundIn noteID: UUID?) throws -> [AcquisitionCandidate] {
        try readyDatabase().read { db in
            try Self.acquisitionCandidates(
                sql: "state = 'approved' AND (? IS NULL OR foundInNoteID = ?)",
                arguments: [noteID?.uuidString, noteID?.uuidString], in: db
            )
        }
    }

    func acquisitionCandidate(id: UUID) throws -> AcquisitionCandidate? {
        try readyDatabase().read { db in
            try Self.acquisitionCandidates(sql: "id = ?", arguments: [id.uuidString], in: db)
                .first
        }
    }

    /// Suggestions and saves to show beside these notes; noticed and filtered links stay on
    /// the source itself.
    func acquisitionSuggestions(foundIn noteIDs: Set<UUID>) throws
        -> [UUID: [AcquisitionCandidate]]
    {
        guard !noteIDs.isEmpty else { return [:] }
        return try readyDatabase().read { db in
            let placeholders = Array(repeating: "?", count: noteIDs.count).joined(separator: ",")
            var candidates = try Self.acquisitionCandidates(
                sql: "foundInNoteID IN (\(placeholders)) AND state IN ('suggested','approved','queued')",
                arguments: StatementArguments(noteIDs.map(\.uuidString)), in: db
            )
            // A save whose capture failed says so instead of looking like it's still saving.
            for index in candidates.indices {
                guard candidates[index].state == .queued,
                      let job = candidates[index].captureJobID,
                      let row = try Row.fetchOne(
                          db,
                          sql: "SELECT error FROM ingestion_jobs WHERE id = ? AND state IN ('failed','cancelled')",
                          arguments: [job.uuidString]
                      )
                else { continue }
                candidates[index].captureError = (row[
                    "error"
                ] as String?) ?? "The capture was cancelled."
            }
            return Dictionary(grouping: candidates, by: \.foundInNoteID)
        }
    }

    func markAcquisitionQueued(_ id: UUID, jobID: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE acquisition_candidates SET state = 'queued', captureJobID = ?, updatedAt = ?
            WHERE id = ?
            """, arguments: [jobID.uuidString, Date().timeIntervalSince1970, id.uuidString])
        }
    }

    /// Suggestions whose page title hasn't been looked for yet, newest first.
    func untitledSuggestions(limit: Int) throws -> [AcquisitionCandidate] {
        try readyDatabase().read { db in
            try Self.acquisitionCandidates(
                sql: "state = 'suggested' AND pageTitleCheckedAt IS NULL",
                arguments: [], order: "createdAt DESC", limit: limit, in: db
            )
        }
    }

    /// Records the page's title, or that none could be read, so it is looked for once.
    func setAcquisitionPageTitle(_ id: UUID, _ title: String?) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE acquisition_candidates SET pageTitle = ?, pageTitleCheckedAt = ? WHERE id = ?
            """, arguments: [title, Date().timeIntervalSince1970, id.uuidString])
        }
    }

    func filterAcquisition(_ id: UUID, reason: String) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE acquisition_candidates SET state = 'filtered', reason = ?, updatedAt = ?
            WHERE id = ?
            """, arguments: [reason, Date().timeIntervalSince1970, id.uuidString])
        }
    }

    /// A suggestion, or a save whose capture failed, can be dismissed; a save in progress or
    /// done is undone like any capture.
    func dismissAcquisition(_ id: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE acquisition_candidates SET state = 'rejected', reason = 'Dismissed', updatedAt = ?
            WHERE id = ? AND (state = 'suggested' OR (state = 'queued' AND captureJobID IN (
                SELECT id FROM ingestion_jobs WHERE state IN ('failed','cancelled'))))
            """, arguments: [Date().timeIntervalSince1970, id.uuidString])
        }
    }

    /// Links a source Gleanary saved on its own to the source that recommended it.
    func linkAcquiredSource(jobID: UUID, noteID: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE acquisition_candidates SET savedNoteID = ?, savedAt = coalesce(savedAt, ?)
            WHERE captureJobID = ?
            """, arguments: [noteID.uuidString, Date().timeIntervalSince1970, jobID.uuidString])
            for candidate in try Self.acquisitionCandidates(
                sql: "captureJobID = ?", arguments: [jobID.uuidString], in: db
            ) where candidate.foundInNoteID != noteID {
                guard let origin = try String.fetchOne(
                    db, sql: "SELECT name FROM notes WHERE id = ? AND deletedAt IS NULL",
                    arguments: [candidate.foundInNoteID.uuidString]
                ) else { continue }
                let ids = [candidate.foundInNoteID.uuidString, noteID.uuidString].sorted()
                try db.execute(sql: """
                INSERT OR IGNORE INTO note_links(leftID, rightID, changeID, rationale, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [ids[0], ids[1], jobID.uuidString,
                                 "\(candidate.provenance.label) in “\(origin)”.",
                                 Date().timeIntervalSince1970])
            }
        }
    }

    /// Recorded links not yet saved or ruled out, strongest first, for the Source explorer.
    func acquisitionFrontier(maximumHop: Int, limit: Int) throws -> [AcquisitionCandidate] {
        try readyDatabase().read { db in
            try Self.acquisitionCandidates(
                sql: """
                state IN ('noticed','suggested') AND hop <= ? AND foundInNoteID IN (
                    SELECT id FROM notes WHERE deletedAt IS NULL AND archivedAt IS NULL)
                """,
                arguments: [maximumHop], order: "score DESC, createdAt", limit: limit, in: db
            )
        }
    }

    func acquisitionCandidates(foundIn noteID: UUID) throws -> [AcquisitionCandidate] {
        try readyDatabase().read { db in
            try Self.acquisitionCandidates(
                sql: "foundInNoteID = ?", arguments: [noteID.uuidString], in: db
            )
        }
    }

    /// Re-judges candidates that are still open; saved, dismissed and filtered ones stay.
    func replanAcquisitions(_ plans: [(UUID, AcquisitionPlanner.Plan)]) throws {
        try readyDatabase().write { db in
            for (id, plan) in plans {
                try db.execute(sql: """
                UPDATE acquisition_candidates SET state = ?, score = ?, reason = ?, automatic = ?,
                    provenance = ?, intent = coalesce(?, intent), updatedAt = ?
                WHERE id = ? AND state IN ('noticed','suggested','approved')
                """, arguments: [plan.state.rawValue, plan.score.value, plan.reason,
                                 plan.state == .approved, plan.score.provenance.rawValue,
                                 plan.intent?.rawValue, Date().timeIntervalSince1970,
                                 id.uuidString])
            }
        }
    }

    /// The primary home's code, which picks a per-category acquisition level.
    func primaryCategoryCode(of noteID: UUID) throws -> String? {
        try readyDatabase().read { db in
            try String.fetchOne(db, sql: """
            SELECT dc.code FROM note_categories nc JOIN decimal_categories dc ON dc.id = nc.categoryID
            WHERE nc.noteID = ? ORDER BY nc.isPrimary DESC, dc.code LIMIT 1
            """, arguments: [noteID.uuidString])
        }
    }

    /// How many hops from your own saves this note is: 0 unless Gleanary saved it on its own.
    func acquisitionHop(of noteID: UUID) throws -> Int {
        try readyDatabase().read { db in
            try Int.fetchOne(db, sql: """
            SELECT max(hop) FROM acquisition_candidates WHERE savedNoteID = ?
            """, arguments: [noteID.uuidString]) ?? 0
        }
    }

    /// Opening a saved candidate ends its probation.
    func recordAcquisitionOpened(_ noteID: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE acquisition_candidates SET openedAt = ?
            WHERE savedNoteID = ? AND openedAt IS NULL
            """, arguments: [Date().timeIntervalSince1970, noteID.uuidString])
        }
    }

    /// Archives automatic saves nobody used within `period`: never opened, filed outside the
    /// Inbox, or linked to anything beyond where they were found. Archiving is reversible.
    @discardableResult
    func expireUnusedAcquisitions(
        olderThan period: TimeInterval = AcquisitionPolicy.probation,
        now: Date = Date()
    ) throws -> Int {
        try activityWrite(actor: "app", label: "Archived unused automatic saves") { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.savedNoteID FROM acquisition_candidates c
            JOIN notes n ON n.id = c.savedNoteID
            WHERE c.automatic = 1 AND c.state = 'queued' AND c.openedAt IS NULL
              AND c.savedAt < ? AND n.deletedAt IS NULL AND n.archivedAt IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM note_categories nc JOIN decimal_categories dc ON dc.id = nc.categoryID
                WHERE nc.noteID = n.id AND dc.code != ?)
              AND NOT EXISTS (
                SELECT 1 FROM note_links l
                WHERE (l.leftID = n.id OR l.rightID = n.id)
                  AND l.leftID != c.foundInNoteID AND l.rightID != c.foundInNoteID)
            """, arguments: [now.timeIntervalSince1970 - period, DecimalCategory.inboxCode])
            for row in rows {
                try db.execute(sql: """
                UPDATE notes SET archivedAt = ?, archiveReason = ? WHERE id = ? AND archivedAt IS NULL
                """, arguments: [now.timeIntervalSince1970,
                                 "Saved automatically and not opened within 30 days.",
                                 row["savedNoteID"] as String])
                try db.execute(sql: """
                UPDATE acquisition_candidates SET state = 'expired', reason = 'Unused after probation',
                    updatedAt = ? WHERE id = ?
                """, arguments: [now.timeIntervalSince1970, row["id"] as String])
            }
            return rows.count
        }
    }

    func muteAcquisitionHost(_ host: String) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            INSERT OR IGNORE INTO acquisition_muted_hosts(host, createdAt) VALUES (?, ?)
            """, arguments: [AcquisitionScorer.domain(host), Date().timeIntervalSince1970])
            // Pending suggestions from that site go too.
            try db.execute(sql: """
            UPDATE acquisition_candidates SET state = 'filtered', reason = 'Muted site', updatedAt = ?
            WHERE state IN ('suggested','approved') AND (url LIKE ? OR url LIKE ?)
            """, arguments: [Date().timeIntervalSince1970,
                             "%://\(AcquisitionScorer.domain(host))/%",
                             "%://www.\(AcquisitionScorer.domain(host))/%"])
        }
    }

    func unmuteAcquisitionHost(_ host: String) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "DELETE FROM acquisition_muted_hosts WHERE host = ?",
                arguments: [host]
            )
        }
    }

    func mutedAcquisitionHosts() throws -> [String] {
        try readyDatabase().read { db in
            try String.fetchAll(db, sql: "SELECT host FROM acquisition_muted_hosts ORDER BY host")
        }
    }

    /// Automatic saves in a period with where each was found, and how many probation archived.
    func acquisitionDigest(
        from start: Date,
        to end: Date
    ) throws -> (saved: [AcquisitionDigestItem], expired: Int) {
        try readyDatabase().read { db in
            let saved = try Row.fetchAll(db, sql: """
            SELECT c.savedNoteID, n.name, c.foundInNoteID, o.name AS origin, c.reason
            FROM acquisition_candidates c
            JOIN notes n ON n.id = c.savedNoteID JOIN notes o ON o.id = c.foundInNoteID
            WHERE c.automatic = 1 AND c.savedAt >= ? AND c.savedAt < ?
              AND n.deletedAt IS NULL AND n.archivedAt IS NULL
            ORDER BY c.savedAt
            """, arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]).map {
                try AcquisitionDigestItem(
                    noteID: Self.uuid($0["savedNoteID"]), title: $0["name"],
                    originID: Self.uuid($0["foundInNoteID"]), originTitle: $0["origin"],
                    reason: $0["reason"]
                )
            }
            let expired = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM acquisition_candidates
            WHERE state = 'expired' AND updatedAt >= ? AND updatedAt < ?
            """, arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]) ?? 0
            return (saved, expired)
        }
    }

    private static func acquisitionCandidates(
        sql condition: String,
        arguments: StatementArguments,
        order: String = "createdAt, rowid",
        limit: Int? = nil,
        in db: Database
    ) throws -> [AcquisitionCandidate] {
        try Row.fetchAll(db, sql: """
        SELECT * FROM acquisition_candidates WHERE \(condition) ORDER BY \(order)
        \(limit.map { "LIMIT \(max(0, $0))" } ?? "")
        """, arguments: arguments).compactMap { row in
            guard let url = URL(string: row["url"]),
                  let provenance = AcquisitionProvenance(rawValue: row["provenance"]),
                  let state = AcquisitionState(rawValue: row["state"]) else { return nil }
            let job: String? = row["captureJobID"]
            let intent: String? = row["intent"]
            return try AcquisitionCandidate(
                id: uuid(row["id"]), identity: row["identity"], url: url, title: row["title"],
                foundInNoteID: uuid(row["foundInNoteID"]), context: row["context"],
                provenance: provenance, hop: row["hop"], score: row["score"], state: state,
                reason: row["reason"], captureJobID: job.map(uuid),
                intent: intent.flatMap(LinkIntent.init(rawValue:)), pageTitle: row["pageTitle"]
            )
        }
    }
}
