import Foundation
import GRDB

extension DocumentStore {
    func enqueueCapture(_ request: CaptureRequest, deduplicate: Bool = true) throws -> UUID {
        let id = UUID()
        let now = Date().timeIntervalSince1970
        let acquired = request.artifact.map { [$0] } ?? []
        try readyDatabase().write { db in
            for artifact in acquired {
                try Self.recordArtifact(artifact, in: db)
            }
            let existingNoteID: String? = if deduplicate {
                try String.fetchOne(db, sql: """
                SELECT captures.noteID FROM sources
                JOIN captures ON captures.sourceID = sources.id
                JOIN notes ON notes.id = captures.noteID
                WHERE sources.identity = ? AND notes.deletedAt IS NULL
                ORDER BY captures.createdAt DESC LIMIT 1
                """, arguments: [request.identity])
            } else {
                nil
            }
            try db.execute(
                sql: """
                INSERT INTO ingestion_jobs(
                    id, token, request, acquired, state, progress, noteID, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString,
                    UUID().uuidString,
                    JSONEncoder().encode(request),
                    JSONEncoder().encode(acquired),
                    existingNoteID == nil ? "queued" : "ready",
                    existingNoteID == nil ? "" : "Already captured; existing note kept",
                    existingNoteID,
                    now,
                    now,
                ]
            )
        }
        return id
    }

    func captureJobs(limit: Int = 30) throws -> [CaptureJob] {
        try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM ingestion_jobs ORDER BY CASE WHEN state IN ('queued','fetching','extracting') THEN 0 ELSE 1 END, createdAt DESC LIMIT ?",
                arguments: [limit]
            ).map(Self.captureJob)
        }
    }

    func recoverCaptureJobs() throws {
        try readyDatabase().write { db in
            for row in try Row.fetchAll(
                db,
                sql: "SELECT id FROM ingestion_jobs WHERE state IN ('fetching','extracting')"
            ) {
                let id: String = row["id"]
                try db.execute(
                    sql: "UPDATE ingestion_jobs SET token = ?, state = 'queued', progress = 'Resuming retained original', error = NULL WHERE id = ?",
                    arguments: [UUID().uuidString, id]
                )
            }
        }
    }

    func claimCapture() throws -> CaptureJob? {
        try readyDatabase().write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM ingestion_jobs WHERE state = 'queued' ORDER BY createdAt, id LIMIT 1"
            ) else { return nil }
            let job = try Self.captureJob(row)
            try db.execute(
                sql: "UPDATE ingestion_jobs SET state = 'fetching', progress = 'Preparing source' WHERE id = ?",
                arguments: [job.id.uuidString]
            )
            return job
        }
    }

    func checkpoint(_ job: CaptureJob, acquired: [Artifact], progress: String) throws {
        try readyDatabase().write { db in
            try Self.requireActive(job, in: db)
            for artifact in acquired {
                try Self.recordArtifact(artifact, in: db)
            }
            try db.execute(
                sql: "UPDATE ingestion_jobs SET acquired = ?, state = 'extracting', progress = ?, updatedAt = ? WHERE id = ?",
                arguments: [
                    JSONEncoder().encode(acquired),
                    progress,
                    Date().timeIntervalSince1970,
                    job.id.uuidString,
                ]
            )
        }
    }

    func failCapture(_ job: CaptureJob, error: String, recovery: CaptureRecovery? = nil) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE ingestion_jobs SET state = 'failed', error = ?, recovery = ?, progress = '', updatedAt = ? WHERE id = ? AND token = ? AND state IN ('fetching','extracting')",
                arguments: [
                    error,
                    recovery?.rawValue,
                    Date().timeIntervalSince1970,
                    job.id.uuidString,
                    job.token.uuidString,
                ]
            )
        }
    }

    func cancelCapture(_ id: UUID, token: UUID? = nil) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE ingestion_jobs SET state = 'cancelled', token = ?, progress = 'Cancelled; original retained', error = NULL WHERE id = ? AND state != 'ready' AND (? IS NULL OR token = ?)",
                arguments: [UUID().uuidString, id.uuidString, token?.uuidString, token?.uuidString]
            )
        }
    }

    func retryCapture(_ id: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE ingestion_jobs SET state = 'queued', token = ?, progress = 'Retry queued', error = NULL, recovery = NULL WHERE id = ? AND state IN ('failed','cancelled')",
                arguments: [UUID().uuidString, id.uuidString]
            )
        }
    }

    func resumeMedia(
        _ job: CaptureJob,
        artifacts: [Artifact]? = nil,
        audioLocale: String? = nil,
        downloadModel: Bool = false
    ) throws {
        try readyDatabase().write { db in
            guard let row = try Row
                .fetchOne(
                    db,
                    sql: "SELECT * FROM ingestion_jobs WHERE id = ? AND token = ? AND state = 'failed'",
                    arguments: [job.id.uuidString, job.token.uuidString]
                )
            else { throw CaptureError.staleJob }
            let current = try Self.captureJob(row)
            guard current.recovery == (artifacts == nil ? .audio : .browser)
            else { throw CaptureError.staleJob }
            var request = current.request
            if let audioLocale {
                request.audioLocale = audioLocale; request.downloadSpeechModel = downloadModel
            }
            let retained = artifacts ?? current.acquired
            for artifact in retained {
                try Self.recordArtifact(artifact, in: db)
            }
            try db.execute(
                sql: "UPDATE ingestion_jobs SET token = ?, state = 'queued', request = ?, acquired = ?, recovery = NULL, error = NULL, progress = 'Capture queued' WHERE id = ?",
                arguments: [
                    UUID().uuidString,
                    JSONEncoder().encode(request),
                    JSONEncoder().encode(retained),
                    job.id.uuidString,
                ]
            )
        }
    }

    /// File bytes are already atomically retained. Publishing the note, provenance, FTS,
    /// indexing job and ingestion result is one SQLite transaction.
    func publishCapture(
        _ job: CaptureJob,
        document: CapturedDocument,
        artifacts: [Artifact],
        favicon: StoredFavicon? = nil
    ) throws -> UUID {
        var document = document
        try document.validate()
        let fingerprint = try document.fingerprint
        return try readyDatabase().write { db in
            try Self.requireActive(job, in: db)
            let sourceID = try String.fetchOne(
                db,
                sql: "SELECT id FROM sources WHERE identity = ?",
                arguments: [job.request.identity]
            ) ?? UUID().uuidString
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: "INSERT OR IGNORE INTO sources(id, identity, createdAt) VALUES (?, ?, ?)",
                arguments: [sourceID, job.request.identity, now]
            )
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT noteID FROM captures WHERE sourceID = ? AND fingerprint = ? AND extractorVersion = ?",
                arguments: [sourceID, fingerprint, CapturedDocument.extractorVersion]
            )
            let noteID: UUID
            if let existing {
                noteID = try Self.uuid(existing["noteID"])
                // A duplicate never resurrects a deleted note or overwrites a human-edited copy.
                let deleted = try Double.fetchOne(
                    db,
                    sql: "SELECT deletedAt FROM notes WHERE id = ?",
                    arguments: [noteID.uuidString]
                )
                if deleted != nil {
                    throw CaptureError.deletedCapture
                }
            } else {
                let captureID = UUID()
                let note = try Self.writeNote(
                    MarkdownDocument(name: document.title, markdown: document.markdown),
                    in: db
                )
                noteID = note.id
                var metadata = document
                metadata.blocks = []
                try db.execute(sql: """
                INSERT INTO captures(id, sourceID, noteID, fingerprint, markdownHash, extractorVersion, document, artifacts, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [captureID.uuidString, sourceID, noteID.uuidString, fingerprint,
                                 ContentHash.of(document.markdown),
                                 CapturedDocument.extractorVersion,
                                 JSONEncoder().encode(metadata),
                                 JSONEncoder().encode(artifacts),
                                 now])
                for (ordinal, block) in document.blocks.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO content_blocks(captureID, ordinal, block) VALUES (?, ?, ?)",
                        arguments: [captureID.uuidString, ordinal, JSONEncoder().encode(block)]
                    )
                }
                try Self.replacePassages(note, in: db)
                try Self.refreshGraphLinks(in: db)
            }
            try db.execute(sql: """
            UPDATE notes SET sourceURL = coalesce(sourceURL, ?),
                faviconURL = coalesce(?, faviconURL), faviconData = coalesce(?, faviconData),
                faviconCheckedAt = coalesce(faviconCheckedAt, ?)
            WHERE id = ?
            """, arguments: [document.sourceURL?.absoluteString ?? job.request.url?.absoluteString,
                             favicon?.url.absoluteString, favicon?.data,
                             favicon == nil ? nil : now, noteID.uuidString])
            try db.execute(
                sql: "UPDATE ingestion_jobs SET state = 'ready', noteID = ?, error = NULL, progress = ?, updatedAt = ? WHERE id = ?",
                arguments: [
                    noteID.uuidString,
                    existing == nil
                        ? "Saved locally · \(document.coverage.label)\(document.warnings.isEmpty ? "" : " · Review extraction notes")"
                        : "Already captured; existing note kept · \(document.coverage.label)",
                    now,
                    job.id.uuidString,
                ]
            )
            return noteID
        }
    }

    func captureDetail(id: UUID) throws -> CaptureDetail {
        try readyDatabase().read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM captures WHERE id = ?",
                arguments: [id.uuidString]
            ) else { throw SinkError.invalidDatabase }
            var document = try JSONDecoder().decode(CapturedDocument.self, from: row["document"])
            document.blocks = try Self.captureBlocks(id.uuidString, in: db)
            return try CaptureDetail(
                id: id,
                document: document,
                artifacts: JSONDecoder().decode(
                    [Artifact].self,
                    from: row["artifacts"]
                ),
                capturedAt: Date(timeIntervalSince1970: row["createdAt"])
            )
        }
    }

    func captureID(for noteID: UUID) throws -> UUID? {
        try readyDatabase().read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM captures WHERE noteID = ?",
                arguments: [noteID.uuidString]
            ).map(Self.uuid)
        }
    }

    static func capturePassages(
        _ document: MarkdownDocument,
        in db: Database
    ) throws -> [PassageDraft]? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, document FROM captures WHERE noteID = ? AND markdownHash = ?",
            arguments: [document.id.uuidString, ContentHash.of(document.markdown)]
        ) else { return nil }
        let id: String = row["id"]
        let metadata = try JSONDecoder().decode(CapturedDocument.self, from: row["document"])
        let blocks = try captureBlocks(id, in: db)
        return try blocks.enumerated().flatMap { ordinal, block in
            let citation = try SourceCitation(
                captureID: uuid(id),
                blockOrdinal: ordinal,
                page: block.page,
                section: block.section,
                url: block.sourceURL ?? metadata.sourceURL,
                startTime: block.startTime,
                endTime: block.endTime
            )
            return CaptureChunker.chunks(block).map { PassageDraft(text: $0, citation: citation) }
        }
    }

    private static func captureBlocks(_ id: String, in db: Database) throws -> [ContentBlock] {
        try Data.fetchAll(
            db,
            sql: "SELECT block FROM content_blocks WHERE captureID = ? ORDER BY ordinal",
            arguments: [id]
        )
        .map { try JSONDecoder().decode(ContentBlock.self, from: $0) }
    }

    private static func requireActive(_ job: CaptureJob, in db: Database) throws {
        guard try Bool
            .fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM ingestion_jobs WHERE id = ? AND token = ? AND state IN ('fetching','extracting'))",
                arguments: [job.id.uuidString, job.token.uuidString]
            ) == true
        else { throw CaptureError.staleJob }
    }

    private static func recordArtifact(_ artifact: Artifact, in db: Database) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO artifacts(hash, descriptor, createdAt) VALUES (?, ?, ?)",
            arguments: [
                artifact.hash,
                JSONEncoder().encode(artifact),
                Date().timeIntervalSince1970,
            ]
        )
    }

    private static func captureJob(_ row: Row) throws -> CaptureJob {
        let stateString: String = row["state"]
        guard let state = CaptureState(rawValue: stateString)
        else { throw SinkError.invalidDatabase }
        let note: String? = row["noteID"]
        return try CaptureJob(
            id: uuid(row["id"]),
            token: uuid(row["token"]),
            request: JSONDecoder().decode(
                CaptureRequest.self,
                from: row["request"]
            ),
            state: state,
            acquired: JSONDecoder().decode(
                [Artifact].self,
                from: row["acquired"]
            ),
            progress: row["progress"],
            error: row["error"],
            noteID: note.map(uuid),
            recovery: (row["recovery"] as String?).flatMap(CaptureRecovery.init(rawValue:))
        )
    }
}

struct PassageDraft {
    let text: String
    var citation: SourceCitation?
}

enum CaptureChunker {
    static func chunks(_ block: ContentBlock) -> [String] {
        guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let context = block.kind == .heading ? "" : (block.section ?? "")
            .split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
        let budget = context.isEmpty ? 80 : 68
        let pieces: [String]
        if block.kind == .code {
            // Preserve code symbols; the generic Markdown stripper is inappropriate here.
            let words = block.text.split(whereSeparator: \.isWhitespace)
            pieces = stride(from: 0, to: words.count, by: budget).map { start in
                words[start ..< min(start + budget, words.count)].joined(separator: " ")
            }
        } else if block.kind == .table, block.markdown.hasPrefix("|") {
            let lines = block.markdown.components(separatedBy: "\n").filter { !$0.isEmpty }
            let header = lines.prefix(1).joined().split(whereSeparator: \.isWhitespace).prefix(20)
                .joined(separator: " ")
            pieces = lines.dropFirst(2).flatMap { line in
                MarkdownChunker.plainChunks(line, wordLimit: max(1, budget - 20))
                    .map { header + "\n" + $0 }
            }
        } else {
            pieces = block.method == "markdown"
                ? MarkdownChunker.chunks(block.text, wordLimit: budget)
                : MarkdownChunker.plainChunks(block.text, wordLimit: budget)
        }
        return pieces.map { context.isEmpty ? $0 : context + "\n" + $0 }
    }
}
