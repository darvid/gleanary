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
}

extension DocumentStore {
    /// What the planner needs: automatic saves in the last day and which links are already
    /// in the library.
    func acquisitionContext(identities: [String]) throws -> (savedToday: Int, saved: Set<String>) {
        try readyDatabase().read { db in
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
            return (savedToday, saved)
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
                    context, provenance, hop, score, state, reason, automatic, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(foundInNoteID, identity) DO NOTHING
                """, arguments: [
                    UUID().uuidString, plan.link.identity, plan.link.url.absoluteString,
                    plan.link.title, noteID.uuidString, plan.link.context,
                    plan.score.provenance.rawValue, hop, plan.score.value, plan.state.rawValue,
                    plan.reason, plan.state == .approved, now, now,
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
            let candidates = try Self.acquisitionCandidates(
                sql: "foundInNoteID IN (\(placeholders)) AND state IN ('suggested','approved','queued')",
                arguments: StatementArguments(noteIDs.map(\.uuidString)), in: db
            )
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

    /// Only a suggestion can be dismissed; a queued save is undone like any capture.
    func dismissAcquisition(_ id: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE acquisition_candidates SET state = 'rejected', reason = 'Dismissed', updatedAt = ?
            WHERE id = ? AND state = 'suggested'
            """, arguments: [Date().timeIntervalSince1970, id.uuidString])
        }
    }

    /// Links a source Gleanary saved on its own to the source that recommended it.
    func linkAcquiredSource(jobID: UUID, noteID: UUID) throws {
        try readyDatabase().write { db in
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

    private static func acquisitionCandidates(
        sql condition: String,
        arguments: StatementArguments,
        in db: Database
    ) throws -> [AcquisitionCandidate] {
        try Row.fetchAll(db, sql: """
        SELECT * FROM acquisition_candidates WHERE \(condition) ORDER BY createdAt, rowid
        """, arguments: arguments).compactMap { row in
            guard let url = URL(string: row["url"]),
                  let provenance = AcquisitionProvenance(rawValue: row["provenance"]),
                  let state = AcquisitionState(rawValue: row["state"]) else { return nil }
            let job: String? = row["captureJobID"]
            return try AcquisitionCandidate(
                id: uuid(row["id"]), identity: row["identity"], url: url, title: row["title"],
                foundInNoteID: uuid(row["foundInNoteID"]), context: row["context"],
                provenance: provenance, hop: row["hop"], score: row["score"], state: state,
                reason: row["reason"], captureJobID: job.map(uuid)
            )
        }
    }
}
