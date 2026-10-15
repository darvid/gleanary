import Foundation
import GRDB

extension DocumentStore {
    /// Returns the knowledge projection used by the canvas. Document nodes stay in SQLite as
    /// provenance anchors, but filenames are deliberately excluded from the visual graph.
    func graphSnapshot(
        focus: String? = nil,
        query: String = "",
        noteIDs: [UUID] = [],
        limit: Int = 200
    ) throws -> GraphSnapshot {
        try readyDatabase().read { db in
            let limit = min(500, max(1, limit))
            let total = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM graph_nodes WHERE kind != 'document' AND EXISTS (
                    SELECT 1 FROM graph_edges
                    JOIN graph_evidence ON graph_evidence.edgeID = graph_edges.id
                    JOIN graph_jobs ON graph_jobs.noteID = graph_evidence.noteID
                    WHERE graph_jobs.state = 'ready'
                        AND (graph_edges.source = graph_nodes.id OR graph_edges.target = graph_nodes.id)
                )
                """
            ) ?? 0
            var matching = try Self.graphEntityIDs(noteIDs: Array(noteIDs.prefix(60)), in: db)
            let terms = query.split(whereSeparator: \.isWhitespace).prefix(20)
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            if !terms.isEmpty {
                try matching.formUnion(String.fetchAll(db, sql: """
                SELECT graph_node_fts.id FROM graph_node_fts
                JOIN graph_nodes ON graph_nodes.id = graph_node_fts.id
                WHERE graph_node_fts MATCH ? AND graph_nodes.kind != 'document'
                    AND EXISTS (
                        SELECT 1 FROM graph_edges
                        JOIN graph_evidence ON graph_evidence.edgeID = graph_edges.id
                        JOIN graph_jobs ON graph_jobs.noteID = graph_evidence.noteID
                        WHERE graph_jobs.state = 'ready' AND
                            (graph_edges.source = graph_nodes.id OR graph_edges.target = graph_nodes.id)
                    )
                ORDER BY rank LIMIT 60
                """, arguments: [terms.joined(separator: " OR ")]))
            }
            let seeds = focus.map { [$0] } ?? matching.sorted()
            var nodes: [GraphNode] = if seeds.isEmpty, query.isEmpty, noteIDs.isEmpty {
                try Self.overviewGraphNodes(limit: limit, in: db)
            } else if seeds.isEmpty {
                []
            } else {
                try Self.graphNodes(seeds, in: db).filter { $0.kind != .document }
            }
            nodes = Array(nodes.prefix(limit))
            var seen = Set(nodes.map(\.id))
            let overview = focus == nil && query.isEmpty && noteIDs.isEmpty
            for _ in 0 ..< (focus == nil ? 1 : 2)
                where !overview && !seen.isEmpty && nodes.count < limit
            {
                let rows = try Self.contextGraphRows(for: seen.sorted(), limit: limit * 2, in: db)
                try Self.appendGraphNodes(rows, to: &nodes, seen: &seen, limit: limit)
            }
            // Small or disconnected libraries should still feel like a knowledge map.
            if overview, nodes.count < limit {
                let rows = try Self.overviewGraphRows(limit: limit, in: db)
                try Self.appendGraphNodes(rows, to: &nodes, seen: &seen, limit: limit)
            }
            let ids = nodes.map(\.id)
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let edges = ids.isEmpty ? [] : try Row.fetchAll(db, sql: """
            SELECT graph_edges.* FROM graph_edges
            JOIN graph_nodes source ON source.id = graph_edges.source
            JOIN graph_nodes target ON target.id = graph_edges.target
            WHERE graph_edges.source IN (\(placeholders))
                AND graph_edges.target IN (\(placeholders))
                AND source.kind != 'document' AND target.kind != 'document'
                AND EXISTS (
                    SELECT 1 FROM graph_evidence
                    JOIN graph_jobs ON graph_jobs.noteID = graph_evidence.noteID
                    WHERE graph_evidence.edgeID = graph_edges.id AND graph_jobs.state = 'ready'
                )
            ORDER BY graph_edges.id LIMIT 1201
            """, arguments: StatementArguments(ids + ids)).map(Self.graphEdge)
            return GraphSnapshot(
                nodes: nodes,
                edges: Array(edges.prefix(1200)),
                totalNodes: total,
                matchingIDs: matching,
                truncatedEdges: edges.count > 1200
            )
        }
    }

    private static func graphEntityIDs(noteIDs: [UUID], in db: Database) throws -> Set<String> {
        guard !noteIDs.isEmpty else { return [] }
        let ids = noteIDs.map(\.uuidString)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try Set(String.fetchAll(db, sql: """
        SELECT DISTINCT graph_nodes.id FROM graph_nodes
        JOIN graph_edges ON graph_edges.source = graph_nodes.id OR graph_edges.target = graph_nodes.id
        JOIN graph_evidence ON graph_evidence.edgeID = graph_edges.id
        JOIN graph_jobs ON graph_jobs.noteID = graph_evidence.noteID
        WHERE graph_evidence.noteID IN (\(placeholders)) AND graph_nodes.kind != 'document'
            AND graph_jobs.state = 'ready'
        """, arguments: StatementArguments(ids)))
    }

    private static func overviewGraphNodes(limit: Int, in db: Database) throws -> [GraphNode] {
        try overviewGraphRows(limit: limit, in: db).map(graphNode)
    }

    private static func overviewGraphRows(limit: Int, in db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: """
        SELECT graph_nodes.* FROM graph_nodes
        LEFT JOIN graph_edges ON graph_edges.source = graph_nodes.id OR graph_edges.target = graph_nodes.id
        LEFT JOIN graph_evidence ON graph_evidence.edgeID = graph_edges.id
        LEFT JOIN graph_jobs ON graph_jobs.noteID = graph_evidence.noteID
        WHERE graph_nodes.kind != 'document' AND graph_jobs.state = 'ready'
        GROUP BY graph_nodes.id
        ORDER BY COUNT(DISTINCT graph_evidence.noteID) DESC, graph_nodes.label, graph_nodes.id LIMIT ?
        """, arguments: [limit])
    }

    private static func contextGraphRows(
        for ids: [String],
        limit: Int,
        in db: Database
    ) throws -> [Row] {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try Row.fetchAll(db, sql: """
        SELECT graph_nodes.* FROM graph_nodes
        JOIN graph_edges ON graph_edges.source = graph_nodes.id OR graph_edges.target = graph_nodes.id
        JOIN graph_evidence ON graph_evidence.edgeID = graph_edges.id
        JOIN graph_jobs ON graph_jobs.noteID = graph_evidence.noteID
        WHERE graph_nodes.kind != 'document' AND graph_evidence.noteID IN (
            SELECT DISTINCT seed_evidence.noteID FROM graph_evidence seed_evidence
            JOIN graph_edges seed_edge ON seed_edge.id = seed_evidence.edgeID
            JOIN graph_jobs seed_job ON seed_job.noteID = seed_evidence.noteID
            WHERE seed_job.state = 'ready' AND
                (seed_edge.source IN (\(placeholders)) OR seed_edge.target IN (\(placeholders)))
        ) AND graph_jobs.state = 'ready'
        GROUP BY graph_nodes.id
        ORDER BY COUNT(DISTINCT graph_evidence.noteID) DESC, graph_nodes.label, graph_nodes.id LIMIT ?
        """, arguments: StatementArguments(ids + ids) + [limit])
    }

    private static func appendGraphNodes(
        _ rows: [Row],
        to nodes: inout [GraphNode],
        seen: inout Set<String>,
        limit: Int
    ) throws {
        for row in rows {
            guard nodes.count < limit else { break }
            let node = try graphNode(row)
            guard node.kind != .document else { continue }
            if seen.insert(node.id).inserted {
                nodes.append(node)
            }
        }
    }

    private static func graphNodes(_ ids: [String], in db: Database) throws -> [GraphNode] {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM graph_nodes WHERE id IN (\(placeholders)) AND EXISTS (
                SELECT 1 FROM graph_edges
                JOIN graph_evidence ON graph_evidence.edgeID = graph_edges.id
                JOIN graph_jobs ON graph_jobs.noteID = graph_evidence.noteID
                WHERE graph_jobs.state = 'ready' AND
                    (graph_edges.source = graph_nodes.id OR graph_edges.target = graph_nodes.id)
            ) ORDER BY label, id
            """,
            arguments: StatementArguments(ids)
        ).map(graphNode)
    }

    static func graphNode(_ row: Row) throws -> GraphNode {
        guard let kind = GraphNode.Kind(rawValue: row["kind"])
        else { throw GleanaryError.invalidDatabase }
        let noteID: String? = row["noteID"]
        return try GraphNode(
            id: row["id"],
            kind: kind,
            label: row["label"],
            noteID: noteID.map(uuid)
        )
    }

    static func graphEdge(_ row: Row) throws -> GraphEdge {
        guard let predicate = GraphPredicate(rawValue: row["predicate"])
        else { throw GleanaryError.invalidDatabase }
        return GraphEdge(source: row["source"], target: row["target"], predicate: predicate)
    }

    func graphEvidence(nodeID: String, limit: Int = 100) throws -> [GraphEvidence] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT v.*, e.source, e.target, e.predicate, notes.name,
                a.label AS sourceLabel, b.label AS targetLabel
            FROM graph_evidence v JOIN graph_edges e ON e.id = v.edgeID
            JOIN notes ON notes.id = v.noteID JOIN graph_jobs ON graph_jobs.noteID = v.noteID
            JOIN graph_nodes a ON a.id = e.source JOIN graph_nodes b ON b.id = e.target
            WHERE graph_jobs.state = 'ready' AND (e.source = ? OR e.target = ?)
            ORDER BY e.predicate, notes.name, v.id LIMIT ?
            """, arguments: [nodeID, nodeID, min(1000, max(1, limit))]).map { row in
                let data: Data? = row["citation"]
                return try GraphEvidence(
                    id: row["id"],
                    edge: Self.graphEdge(row),
                    noteID: Self.uuid(row["noteID"]),
                    revision: Self.uuid(row["revision"]),
                    noteName: row["name"],
                    sourceLabel: row["sourceLabel"],
                    targetLabel: row["targetLabel"],
                    quote: row["quote"],
                    citation: data.map { try JSONDecoder().decode(SourceCitation.self, from: $0) },
                    offset: row["offset"],
                    origin: row["origin"]
                )
            }
        }
    }

    func graphPositions(_ ids: [String]) throws -> [String: GraphPosition] {
        guard !ids.isEmpty else { return [:] }
        return try readyDatabase().read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: "SELECT * FROM graph_layout WHERE nodeID IN (\(placeholders))",
                arguments: StatementArguments(ids)
            ).map { row in
                (
                    row["nodeID"] as String,
                    GraphPosition(x: row["x"], y: row["y"])
                )
            })
        }
    }

    func saveGraphPositions(_ positions: [String: GraphPosition]) throws {
        try readyDatabase().write { db in
            for (id, point) in positions where point.x.isFinite && point.y.isFinite {
                // Late layout frames cannot resurrect deleted nodes or their labels.
                try db.execute(sql: """
                INSERT INTO graph_layout(nodeID, x, y, pinned) SELECT id, ?, ?, 0 FROM graph_nodes WHERE id = ?
                ON CONFLICT(nodeID) DO UPDATE SET x = excluded.x, y = excluded.y, pinned = 0
                """, arguments: [point.x, point.y, id])
            }
        }
    }
}
