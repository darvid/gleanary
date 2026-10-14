import Foundation
import GRDB

struct DocumentSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let sourceURL: URL?
    let faviconData: Data?
    let faviconChecked: Bool
    var kind: String = "note"
    var filing: String?
    var updatedAt: Date?
    var coverage: String?
    var previewImage: Data?

    var kindLabel: String {
        Self.kindLabel(for: kind)
    }

    static func kindLabel(for kind: String) -> String {
        switch kind {
        case "source": "Source"
        case "summary": "Summary"
        case "comparison": "Comparison"
        default: "Note"
        }
    }
}

enum LibraryScope: Hashable, Sendable {
    case all, sources, notes, unfiled, captures, category(UUID)
    /// Archived items, which every other scope leaves out.
    case archived
}

struct DocumentPage: Sendable {
    let documents: [DocumentSummary]
    let total: Int
    let changeSequence: Int64
}

extension DocumentStore {
    /// Only display metadata crosses the actor boundary. Bodies are read when opened.
    func documentPage(
        query: String = "",
        offset: Int = 0,
        limit: Int = 80,
        scope: LibraryScope = .all
    ) throws -> DocumentPage {
        try readyDatabase().read { db in
            let filter = Self.libraryFilter(query, scope: scope)
            let total = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM notes n WHERE \(filter.sql)",
                arguments: filter.arguments
            ) ?? 0
            var arguments = filter.arguments
            arguments += [min(80, max(1, limit)), max(0, offset)]
            let rows = try Row.fetchAll(db, sql: """
            SELECT n.id, n.name, n.sourceURL, n.faviconData, n.faviconCheckedAt, n.updatedAt,
                n.previewImage,
                \(Self.libraryKindSQL) AS kind,
                (SELECT c.code || ' ' || c.name FROM note_categories nc
                    JOIN decimal_categories c ON c.id = nc.categoryID WHERE nc.noteID = n.id
                    ORDER BY nc.isPrimary DESC, c.code LIMIT 1) AS filing,
                (SELECT json_extract(CAST(document AS TEXT), '$.coverage') FROM captures
                    WHERE noteID = n.id ORDER BY createdAt DESC LIMIT 1) AS coverage
            FROM notes n WHERE \(filter.sql)
            ORDER BY n.updatedAt DESC, n.id LIMIT ? OFFSET ?
            """, arguments: arguments)
            return try DocumentPage(documents: rows.map { row in
                let source: String? = row["sourceURL"]
                let checked: Double? = row["faviconCheckedAt"]
                return try DocumentSummary(
                    id: Self.uuid(row["id"]),
                    name: row["name"],
                    sourceURL: source.flatMap(URL.init(string:)),
                    faviconData: row["faviconData"],
                    faviconChecked: checked != nil,
                    kind: row["kind"], filing: row["filing"],
                    updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
                    coverage: row["coverage"],
                    previewImage: row["previewImage"]
                )
            }, total: total, changeSequence: Self.libraryChangeSequence(in: db))
        }
    }

    /// Every live item with its filing memberships, for the Knowledge Atlas. Bodies stay unread.
    func atlasSnapshot() throws -> AtlasSnapshot {
        try readyDatabase().read { db in
            var memberships: [String: [UUID]] = [:]
            for row in try Row.fetchAll(db, sql: """
            SELECT nc.noteID, nc.categoryID FROM note_categories nc
            JOIN decimal_categories c ON c.id = nc.categoryID
            ORDER BY nc.noteID, nc.isPrimary DESC, c.code
            """) {
                try memberships[row["noteID"], default: []].append(Self.uuid(row["categoryID"]))
            }
            let items = try Row.fetchAll(db, sql: """
            SELECT n.id, n.name, n.sourceURL, n.updatedAt, \(Self.libraryKindSQL) AS kind,
                n.previewImage IS NOT NULL AS hasPreview
            FROM notes n WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
            """).map { row in
                let id: String = row["id"]
                let source: String? = row["sourceURL"]
                return try AtlasItem(
                    id: Self.uuid(id), title: row["name"], kind: row["kind"],
                    host: source.flatMap(URL.init(string:))?.host(),
                    updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
                    categoryIDs: memberships[id] ?? [],
                    hasPreview: row["hasPreview"]
                )
            }
            let categories = try Row.fetchAll(
                db,
                sql: "SELECT id, code, name FROM decimal_categories ORDER BY code"
            )
            .map {
                try DecimalCategory(id: Self.uuid($0["id"]), code: $0["code"], name: $0["name"])
            }
            return AtlasSnapshot(categories: categories, items: items)
        }
    }

    /// IDs of every live item matching the Library's full-text search, without pagination.
    func libraryMatches(query: String) throws -> Set<UUID> {
        try readyDatabase().read { db in
            let filter = Self.libraryFilter(query, scope: .all)
            return try Set(String.fetchAll(
                db,
                sql: "SELECT n.id FROM notes n WHERE \(filter.sql)",
                arguments: filter.arguments
            ).map(Self.uuid))
        }
    }

    func document(id: UUID) throws -> MarkdownDocument? {
        try readyDatabase().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM notes WHERE id = ? AND deletedAt IS NULL",
                arguments: [id.uuidString]
            ).map(Self.document)
        }
    }

    func libraryChangeSequence() throws -> Int64 {
        try readyDatabase().read(Self.libraryChangeSequence)
    }

    func saveFavicon(_ favicon: StoredFavicon?, for id: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE notes SET faviconURL = ?, faviconData = ?, faviconCheckedAt = ?
            WHERE id = ? AND deletedAt IS NULL AND faviconCheckedAt IS NULL
            """, arguments: [favicon?.url.absoluteString, favicon?.data,
                             Date().timeIntervalSince1970, id.uuidString])
        }
    }

    private static func libraryChangeSequence(in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT coalesce(max(sequence), 0) FROM local_changes") ?? 0
    }

    /// Summary-first captures predate authored_artifacts. Use their persisted artifact/hash
    /// evidence, not the filename or the presence of a source association, to identify them.
    static let legacySummarySQL = """
    EXISTS (SELECT 1 FROM captures c, json_each(CAST(c.artifacts AS TEXT)) artifact
        WHERE c.noteID = n.id AND json_extract(artifact.value, '$.name') = 'Summary.md'
        AND json_extract(artifact.value, '$.kind') = 'markdown'
        AND json_extract(artifact.value, '$.hash') = n.contentHash)
    """

    private static let libraryKindSQL = """
    coalesce((SELECT kind FROM authored_artifacts WHERE noteID = n.id),
        CASE WHEN \(legacySummarySQL) THEN 'summary'
        WHEN EXISTS (SELECT 1 FROM captures WHERE noteID = n.id) THEN 'source' ELSE 'note' END)
    """

    private static func libraryFilter(_ query: String, scope: LibraryScope)
        -> (sql: String, arguments: StatementArguments)
    {
        let text = String(query.prefix(1000)).trimmingCharacters(in: .whitespacesAndNewlines)
        var sql = scope == .archived ? "n.deletedAt IS NULL AND n.archivedAt IS NOT NULL"
            : "n.deletedAt IS NULL AND n.archivedAt IS NULL"
        var arguments = StatementArguments()
        switch scope {
        case .all, .archived: break
        case .sources:
            sql += " AND EXISTS (SELECT 1 FROM captures WHERE noteID = n.id) AND NOT EXISTS (SELECT 1 FROM authored_artifacts WHERE noteID = n.id) AND NOT (\(legacySummarySQL))"
        case .notes:
            sql += " AND (NOT EXISTS (SELECT 1 FROM captures WHERE noteID = n.id) OR EXISTS (SELECT 1 FROM authored_artifacts WHERE noteID = n.id) OR \(legacySummarySQL))"
        case .unfiled:
            sql += " AND NOT EXISTS (SELECT 1 FROM note_categories WHERE noteID = n.id)"
        case let .category(id):
            sql += " AND EXISTS (SELECT 1 FROM note_categories WHERE noteID = n.id AND categoryID = ?)"
            arguments += [id.uuidString]
        case .captures: return ("0", [])
        }
        guard !text.isEmpty else { return (sql, arguments) }
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return ("0", []) }
        sql += """
         AND n.id IN (
            SELECT p.noteID FROM passage_fts JOIN passages p ON p.rowid = passage_fts.rowid
            WHERE passage_fts MATCH ?
        )
        """
        arguments += [pattern]
        return (sql, arguments)
    }

    func relatedLibraryDocuments(to id: UUID) throws -> [DocumentSummary] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT n.id, n.name, n.sourceURL,
                \(Self.libraryKindSQL) AS kind
            FROM notes n
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL AND n.id != ? AND n.id IN (
                SELECT peer.noteID FROM note_sources peer JOIN note_sources current ON current.sourceID = peer.sourceID
                WHERE current.noteID = ?
            ) ORDER BY n.updatedAt DESC, n.id LIMIT 20
            """, arguments: [id.uuidString, id.uuidString]).map { row in
                let source: String? = row["sourceURL"]
                return try DocumentSummary(
                    id: Self.uuid(row["id"]),
                    name: row["name"],
                    sourceURL: source.flatMap(URL.init(string:)),
                    faviconData: nil,
                    faviconChecked: true,
                    kind: row["kind"]
                )
            }
        }
    }

    func previewImages(for ids: [UUID]) throws -> [UUID: Data] {
        try readyDatabase().read { db in
            var images: [UUID: Data] = [:]
            for id in ids {
                if let data = try Data.fetchOne(
                    db,
                    sql: "SELECT previewImage FROM notes WHERE id = ? AND previewImage IS NOT NULL",
                    arguments: [id.uuidString]
                ) {
                    images[id] = data
                }
            }
            return images
        }
    }

    /// The page's look and provenance for the detail header.
    func libraryItemDetails(for id: UUID) throws -> LibraryItemDetails {
        try readyDatabase().read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT sourceURL, faviconData, previewImage, createdAt, archivedAt, archiveReason
                FROM notes WHERE id = ?
                """,
                arguments: [id.uuidString]
            )
            return LibraryItemDetails(
                sourceURL: (row?["sourceURL"] as String?).flatMap(URL.init(string:)),
                favicon: row?["faviconData"],
                previewImage: row?["previewImage"],
                saved: (row?["createdAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                archived: (row?["archivedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                archiveReason: row?["archiveReason"]
            )
        }
    }

    func libraryAuthorProvider(for id: UUID) throws -> String? {
        try readyDatabase().read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT coalesce((SELECT provider FROM authored_artifacts WHERE noteID = n.id),
                    CASE WHEN \(Self.legacySummarySQL) THEN coalesce(n.summaryEngine, 'Apple Intelligence') END)
                FROM notes n WHERE n.id = ? AND n.deletedAt IS NULL
                """,
                arguments: [id.uuidString]
            )
        }
    }
}

struct LibraryItemDetails: Sendable, Equatable {
    var sourceURL: URL?
    var favicon: Data?
    var previewImage: Data?
    var saved: Date?
    var archived: Date?
    var archiveReason: String?
}
