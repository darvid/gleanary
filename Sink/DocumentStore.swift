import Foundation
import GRDB

actor DocumentStore {
    static let defaultURL = URL.applicationSupportDirectory.appending(path: "Sink/library.sqlite")
    nonisolated let url: URL
    private let legacyURL: URL
    private var pool: DatabasePool?

    init(url: URL = DocumentStore.defaultURL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL ?? url.deletingLastPathComponent()
            .appending(path: "documents.json")
    }

    func database() throws -> DatabasePool {
        if let pool {
            return pool
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        // GRDB defaults WAL writers to NORMAL. Notes are canonical, not a disposable cache.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        try DatabaseSchema.migrate(pool)
        self.pool = pool
        return pool
    }

    func readyDatabase() throws -> DatabasePool {
        let pool = try database()
        guard try pool.read({ try Self.metadata("initialized", in: $0) }) == "1" else {
            throw SinkError.invalidDatabase
        }
        return pool
    }

    /// A legacy file is imported exactly once, in a transaction. It is never removed or changed.
    /// Invalid JSON leaves initialization pending instead of silently replacing the user's notes.
    func open(
        seed: [MarkdownDocument] = [],
        loadDocuments: Bool = true
    ) throws -> [MarkdownDocument] {
        let pool = try database()
        if try pool.read({ try Self.metadata("initialized", in: $0) }) != "1" {
            let initial: [MarkdownDocument] = if FileManager.default
                .fileExists(atPath: legacyURL.path)
            {
                try JSONDecoder().decode([MarkdownDocument].self, from: Data(contentsOf: legacyURL))
            } else {
                seed
            }
            // Validate before entering the transaction. Duplicate legacy IDs are a recoverable
            // error.
            guard Set(initial.map(\.id)).count == initial.count
            else { throw SinkError.invalidDatabase }
            try initial.forEach(Self.validate)
            try pool.write { db in
                guard try Self.metadata("initialized", in: db) != "1" else { return }
                for document in initial {
                    _ = try Self.writeNote(document, in: db)
                }
                try Self.setMetadata("chunker", value: MarkdownChunker.version, in: db)
                try Self.setMetadata("initialized", value: "1", in: db)
            }
        }
        // A pipeline change replaces only derived passages; canonical notes and revisions stay
        // intact.
        try pool.write { db in
            guard try Self.metadata("chunker", in: db) != MarkdownChunker.version else { return }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM notes WHERE deletedAt IS NULL") {
                let document = try Self.document(row)
                try Self.replacePassages(document, in: db)
                try Self.enqueue(document, in: db)
            }
            try Self.setMetadata("chunker", value: MarkdownChunker.version, in: db)
        }
        return try loadDocuments ? documents() : []
    }

    func documents() throws -> [MarkdownDocument] {
        try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM notes WHERE deletedAt IS NULL ORDER BY name, id"
            )
            .map(Self.document)
        }
    }

    func save(_ document: MarkdownDocument) throws -> MarkdownDocument {
        try Self.validate(document)
        let result = try readyDatabase().write { db -> SaveResult in
            if try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM purged_notes WHERE noteID = ?)",
                arguments: [document.id.uuidString]
            ) == true {
                throw SinkError.noteDeleted
            }
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM notes WHERE id = ?",
                arguments: [document.id.uuidString]
            ) {
                let current = try Self.document(row)
                let deleted: Double? = row["deletedAt"]
                if current.revision != document.revision || deleted != nil {
                    // Preserve the losing draft and its base revision; do not overwrite the winner.
                    try Self.recordRevision(document, revision: UUID(), kind: "conflict", in: db)
                    return .conflict(deleted: deleted != nil)
                }
                if current.name == document.name, current.markdown == document.markdown {
                    return .saved(current)
                }
            } else if document.revision != nil {
                throw SinkError.invalidDatabase
            }
            return try .saved(Self.writeNote(document, in: db))
        }
        switch result {
        case let .saved(saved): return saved
        case let .conflict(deleted): throw deleted ? SinkError.noteDeleted : SinkError.editConflict
        }
    }

    func importDocuments(_ documents: [MarkdownDocument]) throws {
        try documents.forEach(Self.validate)
        try readyDatabase().write { db in
            for document in documents {
                let duplicate = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM notes WHERE deletedAt IS NULL AND name = ? AND markdown = ?)
                """, arguments: [document.name, document.markdown]) ?? false
                if !duplicate {
                    // File names are labels, not identity. Reimporting edited content cannot
                    // overwrite a note.
                    _ = try Self.writeNote(
                        MarkdownDocument(name: document.name, markdown: document.markdown),
                        in: db
                    )
                }
            }
        }
    }

    func remove(_ document: MarkdownDocument) throws {
        try readyDatabase().write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM notes WHERE id = ?",
                arguments: [document.id.uuidString]
            ) else {
                throw SinkError.invalidDatabase
            }
            let deleted: Double? = row["deletedAt"]
            if deleted != nil {
                return
            }
            let current = try Self.document(row)
            guard current.revision == document.revision else { throw SinkError.editConflict }
            let revision = UUID()
            let now = Date().timeIntervalSince1970
            try Self.recordRevision(current, revision: revision, kind: "delete", in: db)
            try db.execute(
                sql: "UPDATE notes SET revision = ?, updatedAt = ?, deletedAt = ? WHERE id = ?",
                arguments: [revision.uuidString, now, now, document.id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM passages WHERE noteID = ?",
                arguments: [document.id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM index_jobs WHERE noteID = ?",
                arguments: [document.id.uuidString]
            )
            try Self.removeGraph(document.id, in: db)
            try Self.activateIfReady(in: db)
            try Self.pruneUnusedVectors(in: db)
        }
    }

    func history(for id: UUID) throws -> [NoteRevision] {
        try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM note_revisions WHERE noteID = ? ORDER BY createdAt DESC, id",
                arguments: [id.uuidString]
            ).map { row in
                let parent: String? = row["parentID"]
                return try NoteRevision(
                    id: Self.uuid(row["id"]),
                    parentID: parent.map(Self.uuid),
                    name: row["name"],
                    markdown: row["markdown"],
                    createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                    isDeleted: row["isDeleted"]
                )
            }
        }
    }

    func readImports(_ urls: [URL]) throws -> [MarkdownDocument] {
        try urls.map { url in
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()),
                  size <= 1_000_000
            else {
                throw SinkError.invalidFile(url.lastPathComponent)
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
                throw SinkError.invalidFile(url.lastPathComponent)
            }
            return MarkdownDocument(name: url.lastPathComponent, markdown: text)
        }
    }

    static func validate(_ document: MarkdownDocument) throws {
        guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.name.count <= 255,
              document.markdown.utf8.count <= CaptureLimits.markdownBytes
        else { throw SinkError.invalidNote }
    }

    static func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw SinkError.invalidDatabase }
        return id
    }

    static func document(_ row: Row) throws -> MarkdownDocument {
        try MarkdownDocument(
            id: uuid(row["id"]),
            name: row["name"],
            markdown: row["markdown"],
            revision: uuid(row["revision"])
        )
    }

    static func metadata(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = ?", arguments: [key])
    }

    static func setMetadata(_ key: String, value: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value]
        )
    }

    private enum SaveResult { case saved(MarkdownDocument), conflict(deleted: Bool) }

    static func writeNote(
        _ document: MarkdownDocument,
        in db: Database
    ) throws -> MarkdownDocument {
        let revision = UUID()
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
        INSERT INTO notes(id, name, markdown, revision, contentHash, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, markdown = excluded.markdown,
            revision = excluded.revision, contentHash = excluded.contentHash, updatedAt = excluded.updatedAt
        """, arguments: [
            document.id.uuidString,
            document.name,
            document.markdown,
            revision.uuidString,
            ContentHash.of(document.markdown),
            now,
            now,
        ])
        try recordRevision(document, revision: revision, kind: "save", in: db)
        var saved = document
        saved.revision = revision
        try replacePassages(saved, in: db)
        try enqueue(saved, in: db)
        try enqueueGraph(saved, in: db)
        return saved
    }

    private static func recordRevision(
        _ document: MarkdownDocument,
        revision: UUID,
        kind: String,
        in db: Database
    ) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
        INSERT INTO note_revisions(id, noteID, parentID, name, markdown, createdAt, isDeleted)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, arguments: [revision.uuidString, document.id.uuidString, document.revision?.uuidString,
                         document.name, document.markdown, now, kind == "delete"])
        try db.execute(
            sql: "INSERT INTO local_changes(changeID, noteID, revision, kind, createdAt) VALUES (?, ?, ?, ?, ?)",
            arguments: [UUID().uuidString, document.id.uuidString, revision.uuidString, kind, now]
        )
    }

    static func enqueue(_ document: MarkdownDocument, in db: Database) throws {
        guard let revision = document.revision else { throw SinkError.invalidDatabase }
        let target = try metadata("targetProfile", in: db)
        try db.execute(sql: """
        INSERT INTO index_jobs(noteID, revision, profileID) VALUES (?, ?, ?)
        ON CONFLICT(noteID) DO UPDATE SET revision = excluded.revision, profileID = excluded.profileID, lastError = NULL
        """, arguments: [document.id.uuidString, revision.uuidString, target])
    }

    static func replacePassages(_ document: MarkdownDocument, in db: Database) throws {
        let old = try Row.fetchAll(
            db,
            sql: "SELECT id, contentHash FROM passages WHERE noteID = ? ORDER BY ordinal",
            arguments: [document.id.uuidString]
        )
        var ids: [String: [String]] = [:]
        for row in old {
            let hash: String = row["contentHash"]
            ids[hash, default: []].append(row["id"])
        }
        try db.execute(
            sql: "DELETE FROM passages WHERE noteID = ?",
            arguments: [document.id.uuidString]
        )
        let chunks = try capturePassages(document, in: db)
            ?? MarkdownChunker.chunks(document.markdown).map { PassageDraft(text: $0) }
        // Even an empty note remains discoverable by its title.
        let drafts = chunks.isEmpty ? [PassageDraft(text: document.name)] : chunks
        for (offset, draft) in drafts.enumerated() {
            let text = draft.text
            let hash = ContentHash.of(text)
            let id = ids[hash]?.isEmpty == false ? ids[hash]?.removeFirst() : nil
            try db.execute(
                sql: "INSERT INTO passages(id, noteID, name, ordinal, text, contentHash, citation) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    id ?? UUID().uuidString,
                    document.id.uuidString,
                    document.name,
                    offset + 1,
                    text,
                    hash,
                    draft.citation.map { try JSONEncoder().encode($0) },
                ]
            )
        }
    }
}
