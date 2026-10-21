import Foundation
import GRDB

extension DocumentStore {
    /// Local reads only: no requests are queued and no URLs are fetched.
    func linkedSources(in document: MarkdownDocument) throws -> [LinkedSource] {
        let links = try LinkedSourceLink.extract(from: document.markdown)
        return try readyDatabase().read { db in
            try links.map { link in
                var source = LinkedSource(link: link)
                if let row = try Self.savedLinkedSource(identity: link.id, in: db) {
                    let noteID = try Self.uuid(row["id"])
                    source.noteID = noteID
                    source.archived = row["archivedAt"] as Double? != nil
                    source.summaries = try Self.librarySummaries(for: noteID, in: db)
                } else if let row = try Row.fetchOne(db, sql: """
                SELECT * FROM ingestion_jobs
                WHERE json_extract(CAST(request AS TEXT), '$.identity') = ?
                    AND json_extract(CAST(request AS TEXT), '$.replacingNoteID') IS NULL
                ORDER BY CASE WHEN state IN ('queued','fetching','extracting') THEN 0 ELSE 1 END,
                    createdAt DESC, rowid DESC LIMIT 1
                """, arguments: [link.id]) {
                    let job = try Self.captureJob(row)
                    // A ready job whose note was deleted must not block a fresh capture.
                    if job.state != .ready {
                        source.job = job
                    }
                }
                return source
            }
        }
    }

    static func savedLinkedSource(identity: String, in db: Database) throws -> Row? {
        try Row.fetchOne(db, sql: """
        SELECT notes.id, notes.archivedAt FROM sources
        JOIN captures ON captures.sourceID = sources.id
        JOIN notes ON notes.id = captures.noteID
        WHERE sources.identity = ? AND notes.deletedAt IS NULL
        ORDER BY captures.createdAt DESC LIMIT 1
        """, arguments: [identity])
    }

    static func activeCapture(identity: String, in db: Database) throws -> CaptureJob? {
        guard let row = try Row.fetchOne(db, sql: """
        SELECT * FROM ingestion_jobs WHERE state IN ('queued','fetching','extracting')
            AND json_extract(CAST(request AS TEXT), '$.identity') = ?
            AND json_extract(CAST(request AS TEXT), '$.replacingNoteID') IS NULL
        ORDER BY createdAt, rowid LIMIT 1
        """, arguments: [identity]) else { return nil }
        return try captureJob(row)
    }

    static func mergeCaptureReferences(
        _ request: CaptureRequest,
        into job: CaptureJob,
        in db: Database
    ) throws {
        guard !(request.referencingNoteIDs ?? []).isEmpty else { return }
        var merged = job.request
        merged.referencingNoteIDs = Array(Set(
            (merged.referencingNoteIDs ?? []) + (request.referencingNoteIDs ?? [])
        )).sorted { $0.uuidString < $1.uuidString }
        try db.execute(
            sql: "UPDATE ingestion_jobs SET request = ? WHERE id = ?",
            arguments: [JSONEncoder().encode(merged), job.id.uuidString]
        )
    }

    /// The current durable request may include references added after the worker claimed it.
    static func attachLinkedSourceReferences(
        _ request: CaptureRequest, to target: UUID, changeID: UUID, in db: Database
    ) throws {
        for id in Set(request.referencingNoteIDs ?? []) where id != target {
            guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM notes WHERE id = ? AND deletedAt IS NULL
            """, arguments: [id.uuidString]) else { continue }
            let note = try Self.document(row)
            // Editing a link away while the capture runs must not create a stale reference.
            guard let links = try? LinkedSourceLink.extract(from: note.markdown),
                  links.contains(where: { $0.id == request.identity }) else { continue }
            let ids = [id.uuidString, target.uuidString].sorted()
            try db.execute(sql: """
            INSERT OR IGNORE INTO note_links(leftID, rightID, changeID, rationale, createdAt)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [ids[0], ids[1], changeID.uuidString,
                             "Captured from an external link in “\(note.name)”.",
                             Date().timeIntervalSince1970])
        }
    }
}
