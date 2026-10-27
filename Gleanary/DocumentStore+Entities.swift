import Foundation
import GRDB

/// A person, organization, tool or concept the library's notes mention.
struct EntitySummary: Identifiable, Sendable, Equatable {
    let id: String
    let kind: GraphNode.Kind
    /// As written in the notes, recovered from their quotes; graph labels are lowercased.
    let name: String
    let noteCount: Int
}

/// One passage that mentions an entity, with how the note relates to it.
struct EntityMention: Identifiable, Sendable, Equatable {
    let id: String
    let noteID: UUID
    let noteName: String
    let quote: String
    let predicate: GraphPredicate
    /// The other end of a relationship that isn't between the note and the entity.
    let other: String?
    let citation: SourceCitation?
}

extension DocumentStore {
    /// Entities with current evidence in live, unarchived notes, most mentioned first.
    /// `notes` limits the count to entities those notes mention.
    func entities(
        kind: GraphNode.Kind? = nil,
        matching query: String = "",
        in notes: Set<UUID>? = nil,
        limit: Int = 500
    ) throws -> [EntitySummary] {
        let search = GraphNode.normalize(query)
        let scope = notes.map { ids in
            String(
                decoding: (try? JSONEncoder().encode(ids.map(\.uuidString))) ?? Data("[]".utf8),
                as: UTF8.self
            )
        }
        return try readyDatabase().read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT g.id, g.kind, g.label, count(DISTINCT v.noteID) AS notes,
                (SELECT group_concat(quote, char(31)) FROM (
                    SELECT v2.quote FROM graph_edges e2 JOIN graph_evidence v2 ON v2.edgeID = e2.id
                    WHERE e2.source = g.id OR e2.target = g.id LIMIT 8)) AS quotes
            FROM graph_nodes g
            JOIN graph_edges e ON e.source = g.id OR e.target = g.id
            JOIN graph_evidence v ON v.edgeID = e.id
            JOIN notes n ON n.id = v.noteID AND n.revision = v.revision
            WHERE g.kind != 'document' AND n.deletedAt IS NULL AND n.archivedAt IS NULL
                AND (? IS NULL OR g.kind = ?) AND (? = '' OR g.label LIKE '%' || ? || '%')
                AND (? IS NULL OR v.noteID IN (SELECT value FROM json_each(?)))
            GROUP BY g.id ORDER BY notes DESC, g.label LIMIT ?
            """, arguments: [kind?.rawValue, kind?.rawValue, search, search, scope, scope,
                             max(1, limit)])
            return rows.compactMap { row in
                guard let kind = GraphNode.Kind(rawValue: row["kind"]) else { return nil }
                let label: String = row["label"]
                let quotes = (row["quotes"] as String?)?.components(separatedBy: "\u{1F}") ?? []
                return EntitySummary(
                    id: row["id"], kind: kind, name: Self.entityName(label, in: quotes),
                    noteCount: row["notes"]
                )
            }
        }
    }

    /// Every current passage that mentions the entity, newest notes first.
    func entityMentions(_ id: String, limit: Int = 300) throws -> [EntityMention] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT v.id, v.noteID, n.name, v.quote, v.citation, e.predicate,
                CASE WHEN e.source = ? THEN t.label ELSE s.label END AS otherLabel,
                CASE WHEN e.source = ? THEN t.kind ELSE s.kind END AS otherKind
            FROM graph_edges e JOIN graph_evidence v ON v.edgeID = e.id
            JOIN notes n ON n.id = v.noteID AND n.revision = v.revision
            JOIN graph_nodes s ON s.id = e.source JOIN graph_nodes t ON t.id = e.target
            WHERE (e.source = ? OR e.target = ?) AND n.deletedAt IS NULL AND n.archivedAt IS NULL
            ORDER BY n.updatedAt DESC, v.offset LIMIT ?
            """, arguments: [id, id, id, id, max(1, limit)]).compactMap { row in
                guard let predicate = GraphPredicate(rawValue: row["predicate"]) else { return nil }
                let data: Data? = row["citation"]
                let otherKind: String = row["otherKind"]
                return try EntityMention(
                    id: row["id"], noteID: Self.uuid(row["noteID"]), noteName: row["name"],
                    quote: row["quote"], predicate: predicate,
                    other: otherKind == "document" ? nil : row["otherLabel"],
                    citation: data
                        .flatMap { try? JSONDecoder().decode(SourceCitation.self, from: $0) }
                )
            }
        }
    }

    /// The name as a quote wrote it, else each word capitalized.
    static func entityName(_ label: String, in quotes: [String]) -> String {
        for quote in quotes {
            if let range = quote.range(
                of: label, options: [.caseInsensitive, .diacriticInsensitive]
            ) {
                return String(quote[range])
            }
        }
        return label.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
