import Foundation
import GRDB

extension DocumentStore {
    func mindMapSnapshot(noteID: UUID? = nil) throws -> MindMapSnapshot {
        try readyDatabase().read { db in
            let row: Row? = if let noteID {
                try Row.fetchOne(db, sql: """
                SELECT mind_maps.noteID, notes.name FROM mind_maps
                JOIN notes ON notes.id = mind_maps.noteID
                WHERE mind_maps.noteID = ? AND notes.deletedAt IS NULL
                """, arguments: [noteID.uuidString])
            } else {
                try Row.fetchOne(db, sql: """
                SELECT mind_maps.noteID, notes.name FROM mind_maps
                JOIN notes ON notes.id = mind_maps.noteID
                WHERE notes.deletedAt IS NULL ORDER BY mind_maps.generatedAt DESC LIMIT 1
                """)
            }
            guard let row else { return MindMapSnapshot() }
            let id = try Self.uuid(row["noteID"])
            let nodeRows = try Row.fetchAll(db, sql: """
            SELECT mind_map_nodes.*, COALESCE(mind_map_state.collapsed, CASE WHEN (
                SELECT COUNT(*) FROM mind_map_nodes child
                WHERE child.parentID = mind_map_nodes.id
            ) > 0 AND mind_map_nodes.depth > 0 AND mind_map_nodes.ordinal != (
                SELECT MIN(branch.ordinal) FROM mind_map_nodes branch
                WHERE branch.noteID = mind_map_nodes.noteID AND branch.depth = 1 AND EXISTS (
                    SELECT 1 FROM mind_map_nodes child WHERE child.parentID = branch.id
                )
            ) THEN 1 ELSE 0 END) AS collapsed
            FROM mind_map_nodes
            LEFT JOIN mind_map_state ON mind_map_state.nodeID = mind_map_nodes.id
            WHERE mind_map_nodes.noteID = ?
            ORDER BY mind_map_nodes.ordinal
            """, arguments: [id.uuidString])
            let childTitles = Dictionary(
                grouping: nodeRows.compactMap { node -> (String, String)? in
                    guard let parentID: String = node["parentID"] else { return nil }
                    return (parentID, node["title"])
                },
                by: \.0
            ).mapValues { $0.map(\.1) }
            let nodes = nodeRows.compactMap { node -> MindMapNode? in
                guard let role = MindMapRole(rawValue: node["role"]) else { return nil }
                let nodeID: String = node["id"]
                let depth: Int = node["depth"]
                let titles = childTitles[nodeID] ?? []
                return MindMapNode(
                    id: nodeID,
                    noteID: id,
                    parentID: node["parentID"],
                    title: node["title"],
                    summary: depth == 1 && !titles.isEmpty
                        ? Self.mindMapBranchPreview(titles) : node["summary"],
                    role: role,
                    ordinal: node["ordinal"],
                    depth: depth,
                    collapsed: node["collapsed"]
                )
            }
            return MindMapSnapshot(noteID: id, title: row["name"], nodes: nodes)
        }
    }

    private static func mindMapBranchPreview(_ titles: [String]) -> String {
        let shown = titles.prefix(3)
        let topicLabel = titles.count == 1 ? "1 topic" : "\(titles.count) topics"
        let preview = shown.joined(separator: ", ")
        let remaining = titles.count - shown.count
        guard remaining > 0 else { return "\(topicLabel): \(preview)." }
        return "\(topicLabel): \(preview), and \(remaining) more."
    }

    func mindMapSummaries() throws -> [MindMapSummary] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT mind_maps.noteID, mind_maps.generatedAt, notes.name
            FROM mind_maps JOIN notes ON notes.id = mind_maps.noteID
            WHERE notes.deletedAt IS NULL
            ORDER BY mind_maps.generatedAt DESC, notes.name COLLATE NOCASE
            """).map { row in
                try MindMapSummary(
                    id: Self.uuid(row["noteID"]),
                    title: row["name"],
                    generatedAt: Date(timeIntervalSince1970: row["generatedAt"])
                )
            }
        }
    }

    func setMindMapCollapsed(_ nodeID: String, noteID: UUID, collapsed: Bool) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            INSERT INTO mind_map_state(nodeID, noteID, collapsed) VALUES (?, ?, ?)
            ON CONFLICT(nodeID) DO UPDATE SET collapsed = excluded.collapsed
            """, arguments: [nodeID, noteID.uuidString, collapsed])
        }
    }

    func mindMapEvidence(nodeID: String) throws -> [MindMapEvidence] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT mind_map_evidence.*, notes.name FROM mind_map_evidence
            JOIN notes ON notes.id = mind_map_evidence.noteID
            WHERE mind_map_evidence.nodeID = ? ORDER BY mind_map_evidence.id
            """, arguments: [nodeID]).map { row in
                let citation: Data? = row["citation"]
                return try MindMapEvidence(
                    id: row["id"],
                    nodeID: row["nodeID"],
                    noteID: Self.uuid(row["noteID"]),
                    noteName: row["name"],
                    quote: row["quote"],
                    citation: citation.map {
                        try JSONDecoder().decode(SourceCitation.self, from: $0)
                    },
                    offset: row["offset"]
                )
            }
        }
    }
}
