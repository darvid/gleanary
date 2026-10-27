import Foundation
import GRDB

extension DocumentStore {
    /// A read-only projection of canonical links and provenance. Extraction is never started here.
    func libraryGraph(
        _ request: LibraryGraphRequest = LibraryGraphRequest(), includingReasons: Bool = true
    ) throws
        -> LibraryGraphSnapshot
    {
        try readyDatabase().read { db in
            let limit = min(LibraryGraphRequest.maximumNodes, max(1, request.limit))
            let projection = Self.libraryGraphSQL(request)
            var arguments = projection.arguments
            let focus = request.focus.map(GraphNode.documentID)
            let neighborhood: String
            if let focus {
                neighborhood = """
                , neighborhood(id, depth) AS (
                    SELECT id, 0 FROM nodes WHERE id = ?
                    UNION
                    SELECT e.target, h.depth + 1
                    FROM neighborhood h JOIN adjacency e ON e.source = h.id
                    WHERE h.depth < ?
                ), visible AS (
                    SELECT n.* FROM nodes n WHERE n.id IN (SELECT id FROM neighborhood)
                )
                """
                arguments += [focus, min(2, max(1, request.depth))]
            } else {
                neighborhood = ", visible AS (SELECT * FROM nodes)"
            }
            let sql = projection.sql + neighborhood
            let total = try Int.fetchOne(
                db,
                sql: sql + " SELECT count(*) FROM visible",
                arguments: arguments
            ) ?? 0
            var nodeArguments = arguments
            nodeArguments += [focus ?? "", limit]
            let nodes = try Row.fetchAll(db, sql: sql + """
             SELECT n.* FROM visible n LEFT JOIN degrees d ON d.id = n.id
             ORDER BY (n.id = ?) DESC,\(focus == nil ? "" : "(SELECT min(depth) FROM neighborhood WHERE id = n.id),")
                coalesce(d.degree, 0) DESC,
                n.label COLLATE NOCASE, n.id LIMIT ?
            """, arguments: nodeArguments).map(Self.graphNode)
            let ids = nodes.map(\.id)
            guard !ids.isEmpty else { return LibraryGraphSnapshot() }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            var edgeArguments = projection.arguments
            edgeArguments += StatementArguments(ids + ids)
            let rows = try Row.fetchAll(db, sql: projection.sql + """
             SELECT source, target, predicate FROM connections
             WHERE source IN (\(placeholders)) AND target IN (\(placeholders))
             GROUP BY source, target, predicate ORDER BY source, target, predicate
            """, arguments: edgeArguments)
            let edges = try rows.map(Self.graphEdge)
            var reasons: [String: [LibraryGraphReason]] = [:]
            // Bound evidence independently of the canvas, including high-degree shared concepts.
            let evidenceRows: [Row] = includingReasons ? try Row.fetchAll(
                db,
                sql: projection.sql + """
                 SELECT * FROM connections
                 WHERE source IN (\(placeholders)) AND target IN (\(placeholders))
                 ORDER BY source, target, predicate, reasonID LIMIT 2401
                """,
                arguments: edgeArguments
            ) : []
            let edgeIDs = Set(edges.map(\.id))
            for row in evidenceRows.prefix(2400) {
                let edge = try Self.graphEdge(row)
                guard edgeIDs.contains(edge.id) else { continue }
                let reason = try Self.libraryGraphReason(row)
                if reasons[edge.id, default: []]
                    .contains(where: { $0.id == reason.id })
                {
                    continue
                }
                reasons[edge.id, default: []].append(reason)
            }
            let sourceNodeIDs = try String.fetchAll(db, sql: """
             SELECT 'note:' || n.id FROM notes n
             WHERE 'note:' || n.id IN (\(placeholders)) AND (\(Self.libraryKindSQL)) = 'source'
            """, arguments: StatementArguments(ids))
            var filings: [String: [DecimalCategory]] = [:]
            let noteIDs = nodes.filter { $0.kind == .document }.compactMap { $0.noteID?.uuidString }
            if !noteIDs.isEmpty {
                let filingRows = try Row.fetchAll(db, sql: """
                 SELECT nc.noteID, c.id, c.code, c.name
                 FROM note_categories nc JOIN decimal_categories c ON c.id = nc.categoryID
                 WHERE nc.noteID IN (\(noteIDs.map { _ in "?" }.joined(separator: ",")))
                 ORDER BY nc.noteID, nc.isPrimary DESC, c.code, c.id
                """, arguments: StatementArguments(noteIDs))
                for row in filingRows {
                    let noteID: String = row["noteID"]
                    try filings["note:" + noteID, default: []].append(DecimalCategory(
                        id: Self.uuid(row["id"]), code: row["code"], name: row["name"]
                    ))
                }
            }
            return LibraryGraphSnapshot(
                graph: GraphSnapshot(
                    nodes: nodes,
                    edges: edges,
                    totalNodes: total,
                    matchingIDs: Set(focus.map { [$0] } ?? []),
                    truncatedEdges: false
                ),
                connections: edges.map { LibraryGraphConnection(
                    edge: $0,
                    reasons: reasons[$0.id] ?? []
                ) },
                titles: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.label) }),
                truncatedReasons: evidenceRows.count > 2400,
                sourceNodeIDs: Set(sourceNodeIDs),
                nodeFilings: filings
            )
        }
    }

    /// Reads current canonical evidence for just one inspected relationship.
    func libraryGraphReasons(
        for edge: GraphEdge, request: LibraryGraphRequest, offset: Int = 0, limit: Int = 81
    ) throws -> [LibraryGraphReason] {
        try readyDatabase().read { db in
            let projection = Self.libraryGraphSQL(request)
            var arguments = projection.arguments
            arguments += [
                edge.source,
                edge.target,
                edge.predicate.rawValue,
                min(201, max(1, limit)),
                max(0, offset),
            ]
            return try Row.fetchAll(db, sql: projection.sql + """
             SELECT DISTINCT reasonID, origin, rationale, evidenceNote, citation FROM connections
             WHERE source = ? AND target = ? AND predicate = ?
             ORDER BY reasonID LIMIT ? OFFSET ?
            """, arguments: arguments).map(Self.libraryGraphReason)
        }
    }

    private static func libraryGraphReason(_ row: Row) throws -> LibraryGraphReason {
        let data: Data? = row["citation"]
        let note: String? = row["evidenceNote"]
        return try LibraryGraphReason(
            id: row["reasonID"], label: row["origin"], text: row["rationale"],
            noteID: note.map(Self.uuid),
            citation: data.map { try JSONDecoder().decode(SourceCitation.self, from: $0) }
        )
    }

    private static func libraryGraphSQL(_ request: LibraryGraphRequest)
        -> (sql: String, arguments: StatementArguments)
    {
        var filter = libraryFilter(request.query, scope: request.scope)
        switch request.kind {
        case .all: break
        case .notes: filter.sql += " AND (\(libraryKindSQL)) != 'source'"
        case .sources: filter.sql += " AND (\(libraryKindSQL)) = 'source'"
        }
        let concepts = request.includesConcepts ? """
        UNION ALL
        SELECT e.source, e.target, e.predicate, v.id, 'Extracted · ' || n.name,
            v.quote, v.noteID, v.citation
        FROM graph_edges e JOIN graph_evidence v ON v.edgeID = e.id
        JOIN eligible n ON n.rawID = v.noteID AND n.revision = v.revision
        JOIN graph_jobs j ON j.noteID = v.noteID AND j.state = 'ready'
        WHERE e.predicate != 'links_to'
        """ : ""
        let entityNodes = request.includesConcepts ? """
        UNION
        SELECT g.id, g.kind, g.label, g.noteID FROM graph_nodes g
        WHERE g.kind != 'document' AND g.id IN (
            SELECT source FROM raw_connections UNION SELECT target FROM raw_connections
        )
        """ : ""
        // Materialize the projection once per query. Membership tests below avoid SQLite's
        // node-pair join plan, which becomes quadratic even for a sparse 10,000-note library.
        return ("""
        WITH RECURSIVE eligible AS MATERIALIZED (
            SELECT 'note:' || n.id AS id, n.id AS rawID, n.name, n.revision
            FROM notes n WHERE \(filter.sql)
        ), raw_connections(source, target, predicate, reasonID, origin, rationale, evidenceNote, citation) AS MATERIALIZED (
            SELECT 'note:' || l.leftID, 'note:' || l.rightID, 'related_to',
                'link:' || l.changeID, 'Linked notes', l.rationale, NULL, NULL
            FROM note_links l WHERE NOT EXISTS (
                SELECT 1 FROM acquisition_candidates a WHERE a.captureJobID = l.changeID
                    AND a.foundInNoteID IN (l.leftID, l.rightID)
                    AND a.savedNoteID IN (l.leftID, l.rightID))
            UNION ALL
            -- Sources Gleanary saved on its own point from where they were found.
            SELECT 'note:' || a.foundInNoteID, 'note:' || a.savedNoteID, 'related_to',
                'link:' || l.changeID, 'Found via', l.rationale, NULL, NULL
            FROM note_links l JOIN acquisition_candidates a ON a.captureJobID = l.changeID
                AND a.foundInNoteID IN (l.leftID, l.rightID)
                AND a.savedNoteID IN (l.leftID, l.rightID)
            UNION ALL
            SELECT 'note:' || l.noteID, 'note:' || l.targetID, 'links_to',
                'property:' || l.noteID || ':' || l.propertyID || ':' || l.targetID,
                'Note property', CASE l.propertyID WHEN 'project' THEN 'Project'
                    WHEN 'participants' THEN 'Participant' ELSE 'Related note' END, NULL, NULL
            FROM note_property_links l
            UNION ALL
            SELECT 'note:' || min(k.leftID, k.rightID), 'note:' || max(k.leftID, k.rightID),
                'related_to', 'proposal:' || k.proposalID, 'Linked notes', p.rationale, NULL, NULL
            FROM knowledge_links k JOIN knowledge_proposals p ON p.id = k.proposalID
            UNION ALL
            SELECT 'note:' || ns.noteID, 'note:' || c.noteID, 'derived_from',
                'source:' || ns.sourceID, 'Source provenance',
                'This item uses the captured source.', NULL, NULL
            FROM note_sources ns JOIN captures c ON c.sourceID = ns.sourceID
            WHERE ns.noteID != c.noteID
            UNION ALL
            SELECT e.source, e.target, e.predicate, v.id, 'Saved link', v.quote, v.noteID, v.citation
            FROM graph_edges e JOIN graph_evidence v ON v.edgeID = e.id
            JOIN eligible n ON n.rawID = v.noteID AND n.revision = v.revision
            WHERE e.predicate = 'links_to'
            \(concepts)
        ), nodes AS MATERIALIZED (
            SELECT id, 'document' AS kind, name AS label, rawID AS noteID FROM eligible
            \(entityNodes)
        ), connections AS MATERIALIZED (
            SELECT r.* FROM raw_connections r
            WHERE r.source != r.target
                AND r.source IN (SELECT id FROM nodes)
                AND r.target IN (SELECT id FROM nodes)
        ), adjacency AS MATERIALIZED (
            SELECT source, target FROM connections
            UNION SELECT target, source FROM connections
        ), degrees AS MATERIALIZED (
            SELECT id, count(*) AS degree FROM (
                SELECT source AS id FROM connections
                UNION ALL SELECT target FROM connections
            ) GROUP BY id
        )
        """, filter.arguments)
    }
}
