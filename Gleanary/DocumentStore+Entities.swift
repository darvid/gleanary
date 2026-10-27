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

/// How the entity list is ordered.
enum EntitySort: String, CaseIterable, Sendable {
    case mentions, name, recent, kind

    var title: String {
        switch self {
        case .mentions: "Most Mentioned"
        case .name: "Name"
        case .recent: "Recently Mentioned"
        case .kind: "Kind"
        }
    }

    var orderBy: String {
        switch self {
        case .mentions: "notes DESC, sortName"
        case .name: "sortName"
        case .recent: "latest DESC, sortName"
        case .kind: "kindOrder, notes DESC, sortName"
        }
    }
}

/// An entity as resolution sees it: its own node, before merges.
struct EntityNode: Sendable, Equatable {
    let id: String
    let kind: GraphNode.Kind
    let label: String
    let notes: Int
    let mergedInto: String?
    let automatic: Bool
    let keepSeparate: Bool
    let hidden: Bool
}

/// A pair proposed as the same thing, waiting for you.
struct EntitySuggestion: Identifiable, Sendable, Equatable {
    let left: EntitySummary
    let right: EntitySummary
    let reason: String

    var id: String {
        left.id + "|" + right.id
    }
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

    /// Automatic merges, names you kept apart, and pairs proposed as the same thing.
    static func addResolution(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE entity_overrides ADD COLUMN automatic INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE entity_overrides ADD COLUMN keepSeparate INTEGER NOT NULL DEFAULT 0;
        CREATE TABLE entity_merge_suggestions (
            leftID TEXT NOT NULL,
            rightID TEXT NOT NULL,
            reason TEXT NOT NULL,
            state TEXT NOT NULL,
            createdAt REAL NOT NULL,
            PRIMARY KEY(leftID, rightID), CHECK(leftID < rightID)
        );
        """)
    }
}

extension DocumentStore {
    /// Entities with current evidence in live, unarchived notes, a page at a time. Merged
    /// entities count toward the one they were merged into; hidden ones only list when asked.
    func entities(
        kind: GraphNode.Kind? = nil,
        matching query: String = "",
        in notes: Set<UUID>? = nil,
        hidden: Bool = false,
        sort: EntitySort = .mentions,
        offset: Int = 0,
        limit: Int = 500
    ) throws -> [EntitySummary] {
        try readyDatabase().read { db in
            let filter = Self.entityFilter(kind: kind, query: query, notes: notes, hidden: hidden)
            let rows = try Row.fetchAll(db, sql: filter.sql + """
            SELECT m.canonID AS id, cg.kind, cg.label, co.name AS customName,
                coalesce(co.hidden, 0) AS hidden, count(DISTINCT m.noteID) AS notes,
                max(m.updatedAt) AS latest, lower(coalesce(co.name, cg.label)) AS sortName,
                CASE cg.kind WHEN 'person' THEN 0 WHEN 'organization' THEN 1 WHEN 'tool' THEN 2
                    ELSE 3 END AS kindOrder
            FROM matching m JOIN graph_nodes cg ON cg.id = m.canonID
            LEFT JOIN entity_overrides co ON co.entityID = m.canonID
            GROUP BY m.canonID ORDER BY \(sort.orderBy) LIMIT ? OFFSET ?
            """, arguments: filter.arguments + [max(1, limit), max(0, offset)])
            let ids = rows.map { $0["id"] as String }
            // Names come from quotes for this page only; reading them in the grouped query
            // would read quotes for every entity before sorting.
            let quotes = try Self.entityQuotes(ids, in: db)
            let aliases = try Self.entityAliases(ids, in: db)
            return rows.compactMap { row in
                guard let kind = GraphNode.Kind(rawValue: row["kind"]) else { return nil }
                let id: String = row["id"]
                let custom: String? = row["customName"]
                return EntitySummary(
                    id: id, kind: kind,
                    name: custom ?? Self.entityName(row["label"], in: quotes[id] ?? []),
                    noteCount: row["notes"], aliases: aliases[id] ?? [],
                    hidden: row["hidden"], renamed: custom != nil
                )
            }
        }
    }

    /// How many entities the same filters list.
    func entityCount(
        kind: GraphNode.Kind? = nil,
        matching query: String = "",
        hidden: Bool = false
    ) throws -> Int {
        try readyDatabase().read { db in
            let filter = Self.entityFilter(kind: kind, query: query, notes: nil, hidden: hidden)
            return try Int.fetchOne(
                db, sql: filter.sql + "SELECT count(DISTINCT canonID) FROM matching",
                arguments: filter.arguments
            ) ?? 0
        }
    }

    /// A `matching` table of entity evidence in live notes, with merges folded in.
    private static func entityFilter(
        kind: GraphNode.Kind?,
        query: String,
        notes: Set<UUID>?,
        hidden: Bool
    ) -> (sql: String, arguments: StatementArguments) {
        let search = GraphNode.normalize(query)
        let scope = notes.map(noteScope)
        return ("""
        WITH canon AS (
            SELECT g.id AS nodeID, coalesce(o.mergedInto, g.id) AS canonID
            FROM graph_nodes g LEFT JOIN entity_overrides o ON o.entityID = g.id
            WHERE g.kind != 'document'
        ), matching AS (
            SELECT c.canonID, v.noteID, n.updatedAt FROM canon c
            JOIN graph_nodes cg ON cg.id = c.canonID
            LEFT JOIN entity_overrides co ON co.entityID = c.canonID
            JOIN graph_edges e ON e.source = c.nodeID OR e.target = c.nodeID
            JOIN graph_evidence v ON v.edgeID = e.id
            JOIN notes n ON n.id = v.noteID AND n.revision = v.revision
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
                AND (? IS NULL OR cg.kind = ?)
                AND (? = '' OR cg.label LIKE '%' || ? || '%' OR co.name LIKE '%' || ? || '%')
                AND (? IS NULL OR v.noteID IN (SELECT value FROM json_each(?)))
                AND coalesce(co.hidden, 0) = ?
        )

        """, [kind?.rawValue, kind?.rawValue, search, search, search, scope, scope, hidden])
    }

    private static func entityQuotes(
        _ ids: [String],
        in db: Database
    ) throws -> [String: [String]] {
        var quotes: [String: [String]] = [:]
        for id in ids {
            quotes[id] = try String.fetchAll(db, sql: """
            SELECT v.quote FROM graph_edges e JOIN graph_evidence v ON v.edgeID = e.id
            WHERE e.source = ?1 OR e.target = ?1 LIMIT 8
            """, arguments: [id])
        }
        return quotes
    }

    private static func entityAliases(
        _ ids: [String],
        in db: Database
    ) throws -> [String: [(id: String, name: String)]] {
        guard !ids.isEmpty else { return [:] }
        let scope = String(
            decoding: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8),
            as: UTF8.self
        )
        var aliases: [String: [(id: String, name: String)]] = [:]
        for row in try Row.fetchAll(db, sql: """
        SELECT o.entityID, o.mergedInto, g.label FROM entity_overrides o
        JOIN graph_nodes g ON g.id = o.entityID
        WHERE o.mergedInto IN (SELECT value FROM json_each(?))
        """, arguments: [scope]) {
            aliases[row["mergedInto"], default: []]
                .append((row["entityID"], entityName(row["label"], in: [])))
        }
        return aliases
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
                automatic = 0, keepSeparate = 0, updatedAt = excluded.updatedAt
            """, arguments: [id, canonical, now])
        }
    }

    /// Splits an entity back out; automatic merging leaves it apart from then on.
    func unmergeEntity(_ id: String) throws {
        try updateEntityOverride(id) { db in
            try db.execute(sql: """
            UPDATE entity_overrides SET mergedInto = NULL, automatic = 0, keepSeparate = 1
            WHERE entityID = ?
            """, arguments: [id])
        }
    }

    // MARK: Resolution

    /// Every entity node with live evidence, for finding duplicates.
    func entityNodes() throws -> [EntityNode] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT g.id, g.kind, g.label, count(DISTINCT v.noteID) AS notes, o.mergedInto,
                coalesce(o.automatic, 0) AS automatic, coalesce(o.keepSeparate, 0) AS keepSeparate,
                coalesce(o.hidden, 0) AS hidden
            FROM graph_nodes g LEFT JOIN entity_overrides o ON o.entityID = g.id
            JOIN graph_edges e ON e.source = g.id OR e.target = g.id
            JOIN graph_evidence v ON v.edgeID = e.id
            JOIN notes n ON n.id = v.noteID AND n.revision = v.revision
            WHERE g.kind != 'document' AND n.deletedAt IS NULL AND n.archivedAt IS NULL
            GROUP BY g.id
            """).compactMap { row in
                guard let kind = GraphNode.Kind(rawValue: row["kind"]) else { return nil }
                return EntityNode(
                    id: row["id"], kind: kind, label: row["label"], notes: row["notes"],
                    mergedInto: row["mergedInto"], automatic: row["automatic"],
                    keepSeparate: row["keepSeparate"], hidden: row["hidden"]
                )
            }
        }
    }

    /// Merges names that share a match key, marked automatic. Entities you kept apart, or
    /// merged yourself, are left alone.
    func autoMergeEntities(_ merges: [(id: String, into: String)]) throws {
        try readyDatabase().write { db in
            let now = Date().timeIntervalSince1970
            for merge in merges where merge.id != merge.into {
                try db.execute(sql: """
                UPDATE entity_overrides SET mergedInto = ?, updatedAt = ?
                WHERE mergedInto = ? AND automatic = 1
                """, arguments: [merge.into, now, merge.id])
                try db.execute(sql: """
                INSERT INTO entity_overrides(entityID, mergedInto, automatic, updatedAt)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(entityID) DO UPDATE SET mergedInto = excluded.mergedInto,
                    automatic = 1, updatedAt = excluded.updatedAt
                WHERE entity_overrides.keepSeparate = 0
                    AND (entity_overrides.mergedInto IS NULL OR entity_overrides.automatic = 1)
                """, arguments: [merge.id, merge.into, now])
            }
        }
    }

    /// Recent passages, for "long form (ABBR)" pairs.
    func entityEvidenceQuotes(limit: Int = 3000) throws -> [String] {
        try readyDatabase().read { db in
            try String.fetchAll(db, sql: """
            SELECT v.quote FROM graph_evidence v JOIN notes n ON n.id = v.noteID
            WHERE n.deletedAt IS NULL GROUP BY v.quote ORDER BY max(n.updatedAt) DESC LIMIT ?
            """, arguments: [limit])
        }
    }

    static func pairKey(_ left: String, _ right: String) -> (String, String) {
        left < right ? (left, right) : (right, left)
    }

    /// Pairs already proposed, judged or decided, so none is asked about twice.
    func knownEntityPairs() throws -> Set<String> {
        try readyDatabase().read { db in
            try Set(Row.fetchAll(db, sql: "SELECT leftID, rightID FROM entity_merge_suggestions")
                .map { ($0["leftID"] as String) + "|" + ($0["rightID"] as String) })
        }
    }

    /// `state` is pending for you to review, or rejected when a model judged them different.
    func recordEntityPairs(
        _ pairs: [(left: String, right: String, reason: String, state: String)]
    ) throws {
        try readyDatabase().write { db in
            for pair in pairs {
                let (left, right) = Self.pairKey(pair.left, pair.right)
                try db.execute(sql: """
                INSERT OR IGNORE INTO entity_merge_suggestions(leftID, rightID, reason, state,
                    createdAt) VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    left,
                    right,
                    pair.reason,
                    pair.state,
                    Date().timeIntervalSince1970,
                ])
            }
        }
    }

    /// Pending pairs whose two sides are still separate, visible entities.
    func entitySuggestions() throws -> [EntitySuggestion] {
        let rows: [(String, String, String)] = try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT leftID, rightID, reason FROM entity_merge_suggestions WHERE state = 'pending'
            ORDER BY createdAt
            """).map { ($0["leftID"], $0["rightID"], $0["reason"]) }
        }
        guard !rows.isEmpty else { return [] }
        let byID = try Dictionary(
            entities(limit: 100_000).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return rows.compactMap { left, right, reason in
            guard let leftEntity = byID[left], let rightEntity = byID[right] else { return nil }
            return EntitySuggestion(left: leftEntity, right: rightEntity, reason: reason)
        }
    }

    /// Merging folds the less mentioned side into the other; a tie keeps the longer, more
    /// descriptive name, such as the spelled-out form of an abbreviation.
    func resolveEntitySuggestion(_ suggestion: EntitySuggestion, merge: Bool) throws {
        if merge {
            let leftFirst = (suggestion.left.noteCount, suggestion.left.name.count)
                >= (suggestion.right.noteCount, suggestion.right.name.count)
            let (keep, fold) = leftFirst
                ? (suggestion.left, suggestion.right) : (suggestion.right, suggestion.left)
            try mergeEntity(fold.id, into: keep.id)
        }
        let (left, right) = Self.pairKey(suggestion.left.id, suggestion.right.id)
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE entity_merge_suggestions SET state = ? WHERE leftID = ? AND rightID = ?
            """, arguments: [merge ? "merged" : "dismissed", left, right])
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
