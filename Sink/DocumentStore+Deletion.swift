import Foundation
import GRDB

extension DocumentStore {
    /// Retire only untouched copies of the fictional notes that older versions seeded.
    /// Edited notes are preserved, and the migration runs at most once per library.
    func retireBuiltInSamples() throws -> Int {
        let pool = try readyDatabase()
        guard try pool.read({ try Self.metadata("retired-built-in-samples-v1", in: $0) }) != "1"
        else { return 0 }
        let samples = try documents().filter {
            MarkdownDocument.retiredSampleSignatures.contains($0.retiredSampleSignature)
        }
        for sample in samples {
            _ = try permanentlyRemove(sample)
        }
        try pool.write {
            try Self.setMetadata("retired-built-in-samples-v1", value: "1", in: $0)
        }
        return samples.count
    }

    /// Purge payloads atomically. Keep only an ID-only deletion marker for stale writers and future
    /// sync.
    /// Physical file deletion is retried separately because SQLite cannot transact filesystem
    /// changes.
    func permanentlyRemove(_ document: MarkdownDocument) throws -> Set<UUID> {
        try readyDatabase().write { db in
            let id = document.id.uuidString
            guard let revision = try String.fetchOne(
                db,
                sql: "SELECT revision FROM notes WHERE id = ?",
                arguments: [id]
            ) else {
                throw SinkError.noteDeleted
            }
            guard revision == document.revision?.uuidString else { throw SinkError.editConflict }
            try Self.removeGraph(document.id, in: db)
            let identities = try Set(String.fetchAll(db, sql: """
            SELECT sources.identity FROM sources JOIN captures ON captures.sourceID = sources.id
            WHERE captures.noteID = ?
            """, arguments: [id]))
            var hashes = Set<String>()
            for data in try Data.fetchAll(
                db,
                sql: "SELECT artifacts FROM captures WHERE noteID = ?",
                arguments: [id]
            ) {
                try hashes.formUnion(JSONDecoder().decode([Artifact].self, from: data).map(\.hash))
            }
            let removedJobs = try Self.removeCaptureJobs(
                noteID: id,
                identities: identities,
                hashes: &hashes,
                in: db
            )
            try db.execute(
                sql: "DELETE FROM content_blocks WHERE captureID IN (SELECT id FROM captures WHERE noteID = ?)",
                arguments: [id]
            )
            for table in ["captures", "passages", "index_jobs", "local_changes", "note_revisions"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE noteID = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
            try db
                .execute(sql: "DELETE FROM sources WHERE id NOT IN (SELECT sourceID FROM captures)")
            try db.execute(
                sql: "INSERT INTO purged_notes(noteID, deletionID, deletedAt) VALUES (?, ?, ?)",
                arguments: [id, UUID().uuidString, Date().timeIntervalSince1970]
            )
            try Self.activateIfReady(in: db)
            try Self.pruneUnusedVectors(in: db)
            let referenced = try Self.referencedArtifactHashes(in: db)
            for hash in hashes.subtracting(referenced) {
                try db.execute(sql: "DELETE FROM artifacts WHERE hash = ?", arguments: [hash])
                try db.execute(
                    sql: "INSERT OR IGNORE INTO artifact_deletions(hash) VALUES (?)",
                    arguments: [hash]
                )
            }
            return removedJobs
        }
    }

    private static func removeCaptureJobs(
        noteID: String,
        identities: Set<String>,
        hashes: inout Set<String>,
        in db: Database
    ) throws -> Set<UUID> {
        var removed = Set<UUID>()
        for row in try Row.fetchAll(
            db,
            sql: "SELECT id, noteID, state, request, acquired FROM ingestion_jobs"
        ) {
            let request = try JSONDecoder().decode(CaptureRequest.self, from: row["request"])
            let linkedNote: String? = row["noteID"]
            // A pending recapture must not recreate a note immediately after its deletion.
            guard linkedNote == noteID ||
                (linkedNote == nil && identities.contains(request.identity)) else { continue }
            let rawID: String = row["id"]
            guard let jobID = UUID(uuidString: rawID) else { throw SinkError.invalidDatabase }
            removed.insert(jobID)
            try hashes
                .formUnion(JSONDecoder().decode([Artifact].self, from: row["acquired"]).map(\.hash))
            if let artifact = request.artifact {
                hashes.insert(artifact.hash)
            }
            try db.execute(sql: "DELETE FROM ingestion_jobs WHERE id = ?", arguments: [rawID])
        }
        return removed
    }

    private static func referencedArtifactHashes(in db: Database) throws -> Set<String> {
        var referenced = Set<String>()
        for data in try Data.fetchAll(
            db,
            sql: "SELECT artifacts FROM captures UNION ALL SELECT acquired FROM ingestion_jobs"
        ) {
            try referenced.formUnion(JSONDecoder().decode([Artifact].self, from: data).map(\.hash))
        }
        for data in try Data.fetchAll(db, sql: "SELECT request FROM ingestion_jobs") {
            if let artifact = try JSONDecoder().decode(CaptureRequest.self, from: data).artifact {
                referenced.insert(artifact.hash)
            }
        }
        return referenced
    }

    /// Cleanup rechecks shared references before deleting a content-addressed file.
    func queueArtifactCleanup(_ artifact: Artifact) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO artifact_deletions(hash) VALUES (?)",
                arguments: [artifact.hash]
            )
        }
    }

    func hasPendingArtifactDeletions() throws -> Bool {
        try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM artifact_deletions)") ?? false
        }
    }

    /// Call only after removed capture workers have stopped. Other queued/running captures defer
    /// cleanup.
    @discardableResult
    func collectDeletedArtifacts() throws -> Int {
        try readyDatabase().write { db in
            if try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM ingestion_jobs WHERE state IN ('queued', 'fetching', 'extracting')"
            ) != 0 {
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM artifact_deletions") ?? 0
            }
            let referenced = try Self.referencedArtifactHashes(in: db)
            for hash in try String.fetchAll(db, sql: "SELECT hash FROM artifact_deletions") {
                guard hash.count == 64,
                      hash.allSatisfy({ "0123456789abcdef".contains($0) })
                else { throw CaptureError.missingArtifact }
                if !referenced.contains(hash) {
                    let file = url.deletingLastPathComponent().appending(path: "artifacts")
                        .appending(path: String(hash.prefix(2))).appending(path: hash)
                    do { try FileManager.default.removeItem(at: file) }
                    catch CocoaError
                        .fileNoSuchFile
                    {
                    /* A previous cleanup may have removed it before a crash. */ }
                    let directory = file.deletingLastPathComponent()
                    if FileManager.default.fileExists(atPath: directory.path) {
                        try ArtifactStore.syncDirectory(directory)
                    }
                    try db.execute(sql: "DELETE FROM artifacts WHERE hash = ?", arguments: [hash])
                }
                try db.execute(
                    sql: "DELETE FROM artifact_deletions WHERE hash = ?",
                    arguments: [hash]
                )
            }
            return 0
        }
    }
}
