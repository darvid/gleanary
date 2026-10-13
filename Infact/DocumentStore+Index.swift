import Foundation
import GRDB

extension DocumentStore {
    func prepareIndex(_ profile: EmbeddingProfile) throws {
        guard profile.dimensions > 0, profile.encoding == "normalized-float32-le-v1",
              profile.pipeline == MarkdownChunker.version
        else { throw InfactError.incompatibleProfile }
        let descriptor = try JSONEncoder().encode(profile)
        try readyDatabase().write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO embedding_profiles(id, descriptor) VALUES (?, ?)",
                arguments: [profile.id, descriptor]
            )
            let changed = try Self.metadata("targetProfile", in: db) != profile.id
            try Self.setMetadata("targetProfile", value: profile.id, in: db)
            // The previous active profile remains queryable while a new one is populated.
            if changed {
                try db.execute(sql: """
                INSERT INTO index_jobs(noteID, revision, profileID)
                SELECT id, revision, ? FROM notes WHERE deletedAt IS NULL
                ON CONFLICT(noteID) DO UPDATE SET revision = excluded.revision,
                    profileID = excluded.profileID, lastError = NULL
                """, arguments: [profile.id])
            }
            if try Self.metadata("activeProfile", in: db) == nil {
                // The first index can become searchable incrementally; replacements remain atomic.
                try Self.setMetadata("activeProfile", value: profile.id, in: db)
            }
            try db.execute(
                sql: "UPDATE index_jobs SET lastError = NULL WHERE profileID = ?",
                arguments: [profile.id]
            )
            // Repair missing/truncated rows without running the model for already valid passages.
            try db.execute(
                sql: "DELETE FROM embeddings WHERE profileID = ? AND length(vector) != ?",
                arguments: [profile.id, profile.dimensions * 4]
            )
            try db.execute(sql: """
            INSERT INTO index_jobs(noteID, revision, profileID)
            SELECT DISTINCT n.id, n.revision, ? FROM notes n JOIN passages p ON p.noteID = n.id
            LEFT JOIN embeddings e ON e.contentHash = p.contentHash AND e.profileID = ?
            WHERE n.deletedAt IS NULL AND e.vector IS NULL
            ON CONFLICT(noteID) DO UPDATE SET revision = excluded.revision,
                profileID = excluded.profileID, lastError = NULL
            """, arguments: [profile.id, profile.id])
            try Self.activateIfReady(in: db)
        }
    }

    func nextJob(for profile: EmbeddingProfile) throws -> IndexJob? {
        try readyDatabase().read { db in
            guard try Self.metadata("targetProfile", in: db) == profile.id,
                  let row = try Row.fetchOne(db, sql: """
                  SELECT j.noteID, j.revision FROM index_jobs j JOIN notes n ON j.noteID = n.id
                  WHERE j.profileID = ? AND j.lastError IS NULL AND n.deletedAt IS NULL ORDER BY n.updatedAt, n.id LIMIT 1
                  """, arguments: [profile.id]) else { return nil }
            let id = try Self.uuid(row["noteID"])
            let passages = try Row.fetchAll(
                db,
                sql: "SELECT * FROM passages WHERE noteID = ? ORDER BY ordinal",
                arguments: [id.uuidString]
            )
            .map { try Self.passage($0, vector: nil) }
            return try IndexJob(
                documentID: id,
                revision: Self.uuid(row["revision"]),
                profile: profile,
                passages: passages
            )
        }
    }

    func cachedVector(hash: String, profile: EmbeddingProfile) throws -> [Float]? {
        try readyDatabase().read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT vector FROM embeddings WHERE profileID = ? AND contentHash = ?",
                arguments: [profile.id, hash]
            ) else { return nil }
            return VectorMath.decode(data, dimensions: profile.dimensions)
        }
    }

    func cacheVector(_ vector: [Float], hash: String, profile: EmbeddingProfile) throws {
        let data = try VectorMath.encode(vector, dimensions: profile.dimensions)
        try readyDatabase().write { db in
            // A late model response after a profile switch must not resurrect the old index.
            guard try Self.metadata("targetProfile", in: db) == profile.id else { return }
            // A late embedding response must not restore vectors for deleted or replaced text.
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM passages WHERE contentHash = ?)",
                arguments: [hash]
            ) == true else { return }
            try db.execute(sql: """
            INSERT INTO embeddings(profileID, contentHash, vector) VALUES (?, ?, ?)
            ON CONFLICT(profileID, contentHash) DO UPDATE SET vector = excluded.vector
            """, arguments: [profile.id, hash, data])
        }
    }

    @discardableResult
    func complete(_ job: IndexJob) throws -> Bool {
        try readyDatabase().write { db in
            guard try Self.metadata("targetProfile", in: db) == job.profile.id,
                  let row = try Row.fetchOne(db, sql: """
                  SELECT j.revision, n.revision AS currentRevision FROM index_jobs j JOIN notes n ON n.id = j.noteID
                  WHERE j.noteID = ? AND j.profileID = ? AND n.deletedAt IS NULL
                  """, arguments: [job.documentID.uuidString, job.profile.id]),
                  row["revision"] as String == job.revision.uuidString,
                  row["currentRevision"] as String == job.revision.uuidString else { return false }
            let vectors = try Row.fetchAll(db, sql: """
            SELECT e.vector FROM passages p LEFT JOIN embeddings e
            ON e.contentHash = p.contentHash AND e.profileID = ? WHERE p.noteID = ?
            """, arguments: [job.profile.id, job.documentID.uuidString])
            for row in vectors {
                let data: Data? = row["vector"]
                guard let data,
                      VectorMath.decode(data, dimensions: job.profile.dimensions) != nil
                else {
                    throw InfactError.invalidVector
                }
            }
            try db.execute(
                sql: "DELETE FROM index_jobs WHERE noteID = ?",
                arguments: [job.documentID.uuidString]
            )
            try Self.activateIfReady(in: db)
            if try Int.fetchOne(db, sql: "SELECT count(*) FROM index_jobs") == 0 {
                try Self.pruneUnusedVectors(in: db)
            }
            return true
        }
    }

    func recordFailure(_ job: IndexJob, message: String) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE index_jobs SET lastError = ? WHERE noteID = ? AND revision = ? AND profileID = ?",
                arguments: [
                    message,
                    job.documentID.uuidString,
                    job.revision.uuidString,
                    job.profile.id,
                ]
            )
        }
    }

    func statistics() throws -> LibraryStatistics {
        try readyDatabase().read { db in
            let target = try Self.metadata("targetProfile", in: db)
            return try LibraryStatistics(
                passages: Int.fetchOne(db, sql: "SELECT count(*) FROM passages") ?? 0,
                embeddedPassages: Int.fetchOne(db, sql: """
                SELECT count(*) FROM passages p JOIN embeddings e ON e.contentHash = p.contentHash AND e.profileID = ?
                """, arguments: [target]) ?? 0,
                pendingNotes: Int.fetchOne(db, sql: "SELECT count(*) FROM index_jobs") ?? 0
            )
        }
    }

    func searchSnapshot(query: String, candidateLimit: Int) throws -> SearchSnapshot {
        let pattern = KeywordQuery.pattern(query)
        return try readyDatabase().read { db in
            let profileID = try Self.metadata("activeProfile", in: db)
            let profile = try Self.profile(profileID, in: db)
            let rows = try Row.fetchAll(db, sql: """
            SELECT p.*, e.vector FROM passages p JOIN notes n ON n.id = p.noteID
            LEFT JOIN embeddings e ON e.contentHash = p.contentHash AND e.profileID = ?
            WHERE n.deletedAt IS NULL ORDER BY p.id
            """, arguments: [profileID])
            let passages = try rows.map { row in
                let data: Data? = row["vector"]
                let vector = profile.flatMap { profile in data.flatMap { VectorMath.decode(
                    $0,
                    dimensions: profile.dimensions
                ) } }
                return try Self.passage(row, vector: vector)
            }
            let keywordIDs: [UUID] = if let pattern {
                try String.fetchAll(db, sql: """
                SELECT p.id FROM passage_fts JOIN passages p ON p.rowid = passage_fts.rowid
                WHERE passage_fts MATCH ? ORDER BY bm25(passage_fts, 4.0, 1.0), p.id LIMIT ?
                """, arguments: [pattern, candidateLimit]).map(Self.uuid)
            } else {
                []
            }
            return SearchSnapshot(profile: profile, passages: passages, keywordIDs: keywordIDs)
        }
    }

    /// Invalid persisted values are never scored. Queue affected notes for repair.
    func repairInvalidVectors() throws {
        try readyDatabase().write { db in
            let targetID = try Self.metadata("targetProfile", in: db)
            guard let profile = try Self.profile(targetID, in: db) else { return }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT contentHash, vector FROM embeddings WHERE profileID = ?",
                arguments: [profile.id]
            )
            for row in rows {
                let data: Data = row["vector"]
                guard VectorMath.decode(data, dimensions: profile.dimensions) == nil
                else { continue }
                let hash: String = row["contentHash"]
                try db.execute(
                    sql: "DELETE FROM embeddings WHERE profileID = ? AND contentHash = ?",
                    arguments: [profile.id, hash]
                )
                try db.execute(sql: """
                INSERT INTO index_jobs(noteID, revision, profileID)
                SELECT DISTINCT n.id, n.revision, ? FROM notes n JOIN passages p ON n.id = p.noteID
                WHERE p.contentHash = ? AND n.deletedAt IS NULL
                ON CONFLICT(noteID) DO UPDATE SET revision = excluded.revision, profileID = excluded.profileID
                """, arguments: [profile.id, hash])
            }
        }
    }

    static func activateIfReady(in db: Database) throws {
        guard let target = try metadata("targetProfile", in: db),
              try Int.fetchOne(db, sql: "SELECT count(*) FROM index_jobs") == 0 else { return }
        try setMetadata("activeProfile", value: target, in: db)
    }

    static func pruneUnusedVectors(in db: Database) throws {
        try db.execute(sql: """
        DELETE FROM embeddings WHERE contentHash NOT IN (SELECT contentHash FROM passages)
        OR profileID NOT IN (SELECT value FROM metadata WHERE key IN ('activeProfile', 'targetProfile'))
        """)
    }

    private static func profile(_ id: String?, in db: Database) throws -> EmbeddingProfile? {
        guard let id else { return nil }
        guard let data = try Data.fetchOne(
            db,
            sql: "SELECT descriptor FROM embedding_profiles WHERE id = ?",
            arguments: [id]
        ) else {
            throw InfactError.invalidDatabase
        }
        let profile = try JSONDecoder().decode(EmbeddingProfile.self, from: data)
        guard profile.id == id else { throw InfactError.invalidDatabase }
        return profile
    }

    private static func passage(_ row: Row, vector: [Float]?) throws -> Passage {
        let citation: Data? = row["citation"]
        return try Passage(
            id: uuid(row["id"]),
            documentID: uuid(row["noteID"]),
            documentName: row["name"],
            ordinal: row["ordinal"],
            text: row["text"],
            contentHash: row["contentHash"],
            vector: vector,
            citation: citation.map { try JSONDecoder().decode(SourceCitation.self, from: $0) }
        )
    }
}
