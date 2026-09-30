import Foundation
import GRDB

struct DocumentSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let sourceURL: URL?
    let faviconData: Data?
    let faviconChecked: Bool
}

struct DocumentPage: Sendable {
    let documents: [DocumentSummary]
    let total: Int
    let changeSequence: Int64
}

extension DocumentStore {
    /// Only display metadata crosses the actor boundary. Bodies are read when opened.
    func documentPage(query: String = "", offset: Int = 0, limit: Int = 80) throws -> DocumentPage {
        try readyDatabase().read { db in
            let filter = Self.libraryFilter(query)
            let total = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM notes n WHERE \(filter.sql)",
                arguments: filter.arguments
            ) ?? 0
            var arguments = filter.arguments
            arguments += [min(80, max(1, limit)), max(0, offset)]
            let rows = try Row.fetchAll(db, sql: """
            SELECT n.id, n.name, n.sourceURL, n.faviconData, n.faviconCheckedAt
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
                    faviconChecked: checked != nil
                )
            }, total: total, changeSequence: Self.libraryChangeSequence(in: db))
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

    private static func libraryFilter(_ query: String)
        -> (sql: String, arguments: StatementArguments)
    {
        let text = String(query.prefix(1000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("n.deletedAt IS NULL", []) }
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return ("0", []) }
        return ("""
        n.deletedAt IS NULL AND n.id IN (
            SELECT p.noteID FROM passage_fts JOIN passages p ON p.rowid = passage_fts.rowid
            WHERE passage_fts MATCH ?
        )
        """, [pattern])
    }
}
