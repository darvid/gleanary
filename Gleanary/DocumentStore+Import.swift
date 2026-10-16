import Foundation
import GRDB

struct BookmarkImportReport: Sendable, Equatable {
    var imported = 0
    /// Already in the library, or repeated within the file.
    var duplicates = 0
    /// Addresses the capture policy refuses, such as credentials in the URL.
    var rejected = 0
    var filed = 0
    var categoriesCreated = 0
    /// Imported notes left without a category, for auto-categorization.
    var unfiledIDs: [UUID] = []
}

extension DocumentStore {
    /// Small transactions keep the library responsive and let a cancelled import keep its progress.
    static let bookmarkImportBatch = 250

    /// Writes each new bookmark as a source note from export metadata alone: no fetching, no
    /// model calls, no knowledge-graph work.
    func importBookmarks(
        _ bookmarks: [ImportedBookmark],
        plan: BookmarkFolderPlan,
        original: Artifact,
        progress: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> BookmarkImportReport {
        var report = BookmarkImportReport()
        let created = try addCategories(plan.newCategories)
        report.categoriesCreated = created.count
        let byCode = try Dictionary(
            categories().map { ($0.code, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var start = 0
        let activityBatch = UUID()
        while start < bookmarks.count {
            try Task.checkCancellation()
            let batch = bookmarks[start ..< min(start + Self.bookmarkImportBatch, bookmarks.count)]
            let written = try writeBookmarkBatch(
                batch,
                plan: plan,
                categories: byCode,
                original: original,
                activityBatch: activityBatch,
                seen: &seen
            )
            report.imported += written.imported
            report.duplicates += written.duplicates
            report.rejected += written.rejected
            report.filed += written.filed
            report.unfiledIDs += written.unfiledIDs
            start += batch.count
            await progress(start)
        }
        return report
    }

    private func writeBookmarkBatch(
        _ batch: ArraySlice<ImportedBookmark>,
        plan: BookmarkFolderPlan,
        categories byCode: [String: UUID],
        original: Artifact,
        activityBatch: UUID,
        seen: inout Set<String>
    ) throws -> BookmarkImportReport {
        var accepted = seen
        let partial = try activityWrite(
            actor: "import",
            batchID: activityBatch,
            label: "Imported bookmarks"
        ) { db in
            var partial = BookmarkImportReport()
            try Self.recordArtifact(original, in: db)
            for bookmark in batch {
                guard let canonical = try? CaptureRequest.canonicalURL(bookmark.url) else {
                    partial.rejected += 1
                    continue
                }
                let identity = SourceIdentity.arxiv(bookmark.url)?.identity ?? "url:" + canonical
                guard accepted.insert(identity).inserted,
                      try !Self.hasLiveCapture(identity: identity, in: db)
                else {
                    partial.duplicates += 1
                    continue
                }
                let categoryID: UUID? = switch plan.destination(for: bookmark.folder) {
                case .unfiled: nil
                case let .existing(id): id
                case let .new(code, _): byCode[code]
                }
                let noteID = try Self.writeBookmark(
                    bookmark,
                    identity: identity,
                    original: original,
                    in: db
                )
                partial.imported += 1
                if let categoryID {
                    try Self.fileImported(noteID, categoryID: categoryID, in: db)
                    partial.filed += 1
                } else {
                    partial.unfiledIDs.append(noteID)
                }
            }
            return partial
        }
        // Only a committed batch counts its addresses as seen.
        seen = accepted
        return partial
    }

    /// The address to fetch when someone opens an imported bookmark that is still unedited and
    /// has no fetch in progress. A failed fetch waits for an explicit retry in Captures.
    func unfetchedBookmarkURL(noteID: UUID) throws -> URL? {
        try readyDatabase().read { db in
            guard try Self.unfetchedBookmark(noteID, in: db) != nil,
                  try !(Bool.fetchOne(db, sql: """
                  SELECT EXISTS(SELECT 1 FROM ingestion_jobs
                      WHERE state IN ('queued', 'fetching', 'extracting', 'failed')
                      AND json_extract(CAST(request AS TEXT), '$.replacingNoteID') = ?)
                  """, arguments: [noteID.uuidString]) ?? false)
            else { return nil }
            return try String.fetchOne(
                db,
                sql: "SELECT sourceURL FROM notes WHERE id = ?",
                arguments: [noteID.uuidString]
            ).flatMap(URL.init(string:))
        }
    }

    /// The live note when its newest capture is an import bookmark whose text is unchanged.
    static func unfetchedBookmark(_ id: UUID?, in db: Database) throws -> MarkdownDocument? {
        guard let id, let row = try Row.fetchOne(db, sql: """
        SELECT n.* FROM notes n JOIN captures c ON c.noteID = n.id
        WHERE n.id = ? AND n.deletedAt IS NULL AND c.markdownHash = n.contentHash
            AND json_extract(CAST(c.document AS TEXT), '$.coverage') = 'bookmark'
            AND c.createdAt = (SELECT max(createdAt) FROM captures WHERE noteID = n.id)
        """, arguments: [id.uuidString]) else { return nil }
        return try document(row)
    }

    private static func hasLiveCapture(identity: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM sources s JOIN captures c ON c.sourceID = s.id
            JOIN notes n ON n.id = c.noteID
            WHERE s.identity = ? AND n.deletedAt IS NULL)
        """, arguments: [identity]) ?? false
    }

    private static func writeBookmark(
        _ bookmark: ImportedBookmark,
        identity: String,
        original: Artifact,
        in db: Database
    ) throws -> UUID {
        var document = CapturedDocument(
            title: bookmark.title,
            sourceURL: bookmark.url,
            coverage: .bookmark,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: bookmark.markdown,
                text: bookmark.markdown,
                method: "bookmark-import"
            )]
        )
        try document.validate()
        let markdown = document.markdown
        let note = try writeNote(
            MarkdownDocument(name: document.title, markdown: markdown),
            graph: false,
            in: db
        )
        let created = (bookmark.created ?? Date()).timeIntervalSince1970
        // Keep the library in bookmark order instead of stacking the whole import on top.
        try db.execute(
            sql: "UPDATE notes SET createdAt = ?, updatedAt = ?, sourceURL = ? WHERE id = ?",
            arguments: [created, created, bookmark.url.absoluteString, note.id.uuidString]
        )
        let sourceID = try String.fetchOne(
            db,
            sql: "SELECT id FROM sources WHERE identity = ?",
            arguments: [identity]
        ) ?? UUID().uuidString
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: "INSERT OR IGNORE INTO sources(id, identity, createdAt) VALUES (?, ?, ?)",
            arguments: [sourceID, identity, now]
        )
        let captureID = UUID()
        var metadata = document
        metadata.blocks = []
        try db.execute(sql: """
        INSERT INTO captures(id, sourceID, noteID, fingerprint, markdownHash, extractorVersion, document, artifacts, createdAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            captureID.uuidString, sourceID, note.id.uuidString, document.fingerprint,
            ContentHash.of(markdown), CapturedDocument.extractorVersion,
            JSONEncoder().encode(metadata), JSONEncoder().encode([original]), now,
        ])
        try db.execute(
            sql: "INSERT INTO content_blocks(captureID, ordinal, block) VALUES (?, 0, ?)",
            arguments: [captureID.uuidString, JSONEncoder().encode(document.blocks[0])]
        )
        try db.execute(
            sql: "INSERT OR IGNORE INTO note_sources(noteID, sourceID) VALUES (?, ?)",
            arguments: [note.id.uuidString, sourceID]
        )
        try replacePassages(note, in: db)
        return note.id
    }

    static func fileImported(_ noteID: UUID, categoryID: UUID, in db: Database) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO note_categories VALUES (?, ?, 1)",
            arguments: [noteID.uuidString, categoryID.uuidString]
        )
        for source in try String.fetchAll(
            db,
            sql: "SELECT sourceID FROM note_sources WHERE noteID = ?",
            arguments: [noteID.uuidString]
        ) {
            try db.execute(
                sql: "INSERT OR IGNORE INTO source_categories VALUES (?, ?, 1)",
                arguments: [source, categoryID.uuidString]
            )
        }
    }
}
