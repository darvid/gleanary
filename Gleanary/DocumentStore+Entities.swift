import Foundation
import GRDB

/// A person, organization, tool or concept the library's notes mention.
struct EntitySummary: Identifiable, Sendable, Equatable {
    let id: String
    let kind: GraphNode.Kind
    /// Your name for it, else as written in the notes, recovered from their quotes.
    let name: String
    let noteCount: Int
    /// Entities merged into this one, by name, with their IDs for unmerging.
    var aliases: [(id: String, name: String)] = []
    var hidden = false
    var renamed = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.noteCount == rhs.noteCount
            && lhs.aliases.map(\.id) == rhs.aliases.map(\.id) && lhs.hidden == rhs.hidden
    }
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

/// Your fixes to entities, kept by entity ID so later extraction of the same name follows
/// them: a name, a merge into another entity, or hiding it.
enum EntitySchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE entity_overrides (
            entityID TEXT PRIMARY KEY NOT NULL,
            name TEXT,
            mergedInto TEXT,
            hidden INTEGER NOT NULL DEFAULT 0,
            updatedAt REAL NOT NULL
        );
        CREATE INDEX entity_overrides_merged ON entity_overrides(mergedInto);
        """)
    }
}

extension DocumentStore {
    /// Entities with current evidence in live, unarchived notes, most mentioned first. Merged
    /// entities count toward the one they were merged into; hidden ones only list when asked.
    func entities(
        kind: GraphNode.Kind? = nil,
        matching query: String = "",
        in notes: Set<UUID>? = nil,
        hidden: Bool = false,
        limit: Int = 500
    ) throws -> [EntitySummary] {
        let search = GraphNode.normalize(query)
        let scope = notes.map(Self.noteScope)
        return try readyDatabase().read { db in
            let rows = try Row.fetchAll(db, sql: """
            WITH canon AS (
                SELECT g.id AS nodeID, coalesce(o.mergedInto, g.id) AS canonID
                FROM graph_nodes g LEFT JOIN entity_overrides o ON o.entityID = g.id
                WHERE g.kind != 'document'
            )
            SELECT c.canonID AS id, cg.kind, cg.label, co.name AS customName,
                coalesce(co.hidden, 0) AS hidden, count(DISTINCT v.noteID) AS notes,
                (SELECT group_concat(quote, char(31)) FROM (
                    SELECT v2.quote FROM graph_edges e2 JOIN graph_evidence v2 ON v2.edgeID = e2.id
                    WHERE e2.source = cg.id OR e2.target = cg.id LIMIT 8)) AS quotes
            FROM canon c JOIN graph_nodes cg ON cg.id = c.canonID
            LEFT JOIN entity_overrides co ON co.entityID = c.canonID
            JOIN graph_edges e ON e.source = c.nodeID OR e.target = c.nodeID
            JOIN graph_evidence v ON v.edgeID = e.id
            JOIN notes n ON n.id = v.noteID AND n.revision = v.revision
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
                AND (? IS NULL OR cg.kind = ?)
                AND (? = '' OR cg.label LIKE '%' || ? || '%' OR co.name LIKE '%' || ? || '%')
                AND (? IS NULL OR v.noteID IN (SELECT value FROM json_each(?)))
                AND coalesce(co.hidden, 0) = ?
            GROUP BY c.canonID ORDER BY notes DESC, cg.label LIMIT ?
            """, arguments: [kind?.rawValue, kind?.rawValue, search, search, search, scope, scope,
                             hidden, max(1, limit)])
            let aliasRows = try Row.fetchAll(db, sql: """
            SELECT o.entityID, o.mergedInto, g.label FROM entity_overrides o
            JOIN graph_nodes g ON g.id = o.entityID WHERE o.mergedInto IS NOT NULL
            """)
            var aliases: [String: [(id: String, name: String)]] = [:]
            for row in aliasRows {
                aliases[row["mergedInto"], default: []]
                    .append((row["entityID"], Self.entityName(row["label"], in: [])))
            }
            return rows.compactMap { row in
                guard let kind = GraphNode.Kind(rawValue: row["kind"]) else { return nil }
                let label: String = row["label"]
                let custom: String? = row["customName"]
                let quotes = (row["quotes"] as String?)?.components(separatedBy: "\u{1F}") ?? []
                let id: String = row["id"]
                return EntitySummary(
                    id: id, kind: kind,
                    name: custom ?? Self.entityName(label, in: quotes),
                    noteCount: row["notes"], aliases: aliases[id] ?? [],
                    hidden: row["hidden"], renamed: custom != nil
                )
            }
        }
    }

    /// Every current passage that mentions the entity or one merged into it, newest notes
    /// first.
    func entityMentions(_ id: String, limit: Int = 300) throws -> [EntityMention] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            WITH ids(id) AS (
                SELECT ? UNION SELECT entityID FROM entity_overrides WHERE mergedInto = ?
            )
            SELECT v.id, v.noteID, n.name, v.quote, v.citation, e.predicate,
                CASE WHEN e.source IN (SELECT id FROM ids) THEN t.label ELSE s.label END AS otherLabel,
                CASE WHEN e.source IN (SELECT id FROM ids) THEN t.kind ELSE s.kind END AS otherKind
            FROM graph_edges e JOIN graph_evidence v ON v.edgeID = e.id
            JOIN notes n ON n.id = v.noteID AND n.revision = v.revision
            JOIN graph_nodes s ON s.id = e.source JOIN graph_nodes t ON t.id = e.target
            WHERE (e.source IN (SELECT id FROM ids) OR e.target IN (SELECT id FROM ids))
                AND n.deletedAt IS NULL AND n.archivedAt IS NULL
            ORDER BY n.updatedAt DESC, v.offset LIMIT ?
            """, arguments: [id, id, max(1, limit)]).compactMap { row in
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

    /// Your own name for an entity; nil or empty goes back to the name in the notes.
    func renameEntity(_ id: String, to name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stored = trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        try updateEntityOverride(id) { db in
            try db.execute(
                sql: "UPDATE entity_overrides SET name = ? WHERE entityID = ?",
                arguments: [stored, id]
            )
        }
    }

    func hideEntity(_ id: String, hidden: Bool) throws {
        try updateEntityOverride(id) { db in
            try db.execute(
                sql: "UPDATE entity_overrides SET hidden = ? WHERE entityID = ?",
                arguments: [hidden, id]
            )
        }
    }

    /// Folds one entity into another, such as "OpenAI, Inc." into "OpenAI". Anything already
    /// merged into it moves along, so merges never chain.
    func mergeEntity(_ id: String, into target: String) throws {
        try readyDatabase().write { db in
            let canonical = try String.fetchOne(
                db, sql: "SELECT mergedInto FROM entity_overrides WHERE entityID = ?",
                arguments: [target]
            ) ?? target
            guard canonical != id,
                  try Bool.fetchOne(
                      db,
                      sql: "SELECT EXISTS(SELECT 1 FROM graph_nodes WHERE id = ? AND kind != 'document')",
                      arguments: [canonical]
                  ) == true
            else { throw GleanaryError.invalidDatabase }
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            UPDATE entity_overrides SET mergedInto = ?, updatedAt = ? WHERE mergedInto = ?
            """, arguments: [canonical, now, id])
            try db.execute(sql: """
            INSERT INTO entity_overrides(entityID, mergedInto, updatedAt) VALUES (?, ?, ?)
            ON CONFLICT(entityID) DO UPDATE SET mergedInto = excluded.mergedInto,
                updatedAt = excluded.updatedAt
            """, arguments: [id, canonical, now])
        }
    }

    func unmergeEntity(_ id: String) throws {
        try updateEntityOverride(id) { db in
            try db.execute(
                sql: "UPDATE entity_overrides SET mergedInto = NULL WHERE entityID = ?",
                arguments: [id]
            )
        }
    }

    private func updateEntityOverride(_ id: String, _ change: (Database) throws -> Void) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            INSERT INTO entity_overrides(entityID, updatedAt) VALUES (?, ?)
            ON CONFLICT(entityID) DO UPDATE SET updatedAt = excluded.updatedAt
            """, arguments: [id, Date().timeIntervalSince1970])
            try change(db)
        }
    }

    private static func noteScope(_ ids: Set<UUID>) -> String {
        String(
            decoding: (try? JSONEncoder().encode(ids.map(\.uuidString))) ?? Data("[]".utf8),
            as: UTF8.self
        )
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
