import Foundation
import GRDB
import SwiftSoup

/// Authors as people's names, from what a page publishes about itself.
enum AuthorNames {
    /// The name in a recorded author, or nil when there isn't one. Social handles such as
    /// "@PietTerheyden" are accounts, not names, and text with digits isn't a name: it's a
    /// byline run into its date ("September 21, 2026Toby Ord") or a read time.
    static func name(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("@") }
        let name = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty, name.count <= 200, !name.contains(where: \.isNumber),
              !name.contains("://")
        else { return nil }
        return name
    }

    /// Authors from the page's structured metadata, most reliable first: scholarly citation
    /// tags, then schema.org as JSON-LD and as microdata, then the author meta tags.
    static func fromPage(_ document: SwiftSoup.Document) throws -> [String] {
        let sources: [() throws -> [String]] = [
            { try meta("citation_author", in: document) },
            { try jsonLD(document) },
            { try microdata(document) },
            { try meta("author", in: document) + meta("article:author", in: document) },
        ]
        for source in sources {
            var seen = Set<String>()
            let names = try source().compactMap(name)
                .filter { seen.insert($0.lowercased()).inserted }
            if !names.isEmpty {
                return names
            }
        }
        return []
    }

    private static func meta(_ key: String, in document: SwiftSoup.Document) throws -> [String] {
        try document.select("meta[name=\"\(key)\"], meta[property=\"\(key)\"]").array()
            .map { try $0.attr("content") }
    }

    /// `author` on schema.org items: a name, a Person with a name, or a list of either.
    /// Organizations are publishers, not people, so they're left out.
    private static func jsonLD(_ document: SwiftSoup.Document) throws -> [String] {
        var names: [String] = []
        func authors(_ value: Any) {
            switch value {
            case let text as String: names.append(text)
            case let list as [Any]: list.forEach(authors)
            case let item as [String: Any]:
                let type = (item["@type"] as? String) ?? ""
                if type != "Organization", let name = item["name"] as? String {
                    names.append(name)
                }
            default: break
            }
        }
        func visit(_ value: Any) {
            if let list = value as? [Any] {
                list.forEach(visit)
            } else if let item = value as? [String: Any] {
                if let author = item["author"] {
                    authors(author)
                }
                item["@graph"].map(visit)
            }
        }
        for script in try document.select("script[type=\"application/ld+json\"]").array() {
            if let object = try? JSONSerialization.jsonObject(with: Data(script.data().utf8)) {
                visit(object)
            }
        }
        return names
    }

    private static func microdata(_ document: SwiftSoup.Document) throws -> [String] {
        try document.select("[itemprop=\"author\"]").array().map { element in
            if element.hasAttr("content") {
                return try element.attr("content")
            }
            return try element.select("[itemprop=\"name\"]").first()?.text() ?? element.text()
        }
    }
}

extension DocumentStore {
    /// Earlier captures took authors as written, so some became people like "@Handle Name" or
    /// a byline run into its date. Each such author becomes its name, or goes when it has none.
    static func repairAuthorNames(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
        SELECT v.id, v.noteID, v.revision, v.quote, v.citation, v.offset, v.chunk,
            s.id AS sourceID, s.label AS sourceLabel, s.noteID AS sourceNote,
            e.predicate, n.name AS noteName
        FROM graph_evidence v
        JOIN graph_edges e ON e.id = v.edgeID
        JOIN graph_nodes s ON s.id = e.source
        JOIN notes n ON n.id = v.noteID
        WHERE v.origin = 'metadata'
        """)
        for row in rows {
            let quote: String = row["quote"]
            let cleaned = AuthorNames.name(quote)
            guard cleaned != quote,
                  let noteID = UUID(uuidString: row["noteID"]),
                  let revision = UUID(uuidString: row["revision"]),
                  let predicate = GraphPredicate(rawValue: row["predicate"])
            else { continue }
            try db.execute(sql: "DELETE FROM graph_evidence WHERE id = ?", arguments: [row["id"]])
            guard let cleaned else { continue }
            let source = GraphNode(
                id: row["sourceID"], kind: .document, label: row["sourceLabel"],
                noteID: (row["sourceNote"] as String?).flatMap(UUID.init(uuidString:))
            )
            let data: Data? = row["citation"]
            try insertGraphClaim(
                GraphClaim(
                    source: source,
                    target: GraphNode.entity(cleaned, kind: .person, noteID: noteID),
                    predicate: predicate, quote: cleaned,
                    citation: data
                        .flatMap { try? JSONDecoder().decode(SourceCitation.self, from: $0) },
                    offset: row["offset"], origin: "metadata"
                ),
                job: GraphJob(
                    noteID: noteID, revision: revision, token: UUID(), name: row["noteName"],
                    state: "ready", completed: 0, total: 0, error: nil
                ),
                chunk: row["chunk"], in: db
            )
        }
        try pruneGraph(in: db)
    }
}
