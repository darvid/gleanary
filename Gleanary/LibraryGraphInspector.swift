import Foundation

/// Read-only presentation of the current canvas. Inspector search never changes graph scope.
struct LibraryGraphInspector {
    enum Group: String, CaseIterable, Identifiable {
        case notes = "Related notes", sources = "Sources", concepts = "Concepts"
        var id: String {
            rawValue
        }
    }

    struct Neighbor: Identifiable {
        let node: GraphNode
        let connection: LibraryGraphConnection
        let relationship: String
        let group: Group
        var id: String {
            connection.id
        }
    }

    let data: LibraryGraphSnapshot

    func items(matching query: String) -> [GraphNode] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return data.graph.nodes.filter {
            query.isEmpty || $0.label.localizedStandardContains(query)
        }.sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func kind(of node: GraphNode) -> String {
        if data.sourceNodeIDs.contains(node.id) {
            return "Source"
        }
        return node.kind == .document ? "Note" : node.kind.rawValue.capitalized
    }

    func symbol(for node: GraphNode) -> String {
        if data.sourceNodeIDs.contains(node.id) {
            return "doc.richtext"
        }
        return node.kind == .document ? "doc.text" : "circle.hexagongrid"
    }

    func connectionCount(for id: String) -> Int {
        data.graph.edges.filter { $0.source == id || $0.target == id }.count
    }

    func neighbors(of id: String) -> [Neighbor] {
        let nodes = Dictionary(uniqueKeysWithValues: data.graph.nodes.map { ($0.id, $0) })
        return data.connections.compactMap { connection -> Neighbor? in
            let edge = connection.edge
            guard edge.source == id || edge.target == id,
                  let node = nodes[edge.source == id ? edge.target : edge.source]
            else { return nil }
            let group: Group = data.sourceNodeIDs.contains(node.id) ? .sources :
                (node.kind == .document ? .notes : .concepts)
            return Neighbor(
                node: node, connection: connection,
                relationship: Self.relationship(edge.predicate, outgoing: edge.source == id),
                group: group
            )
        }.sorted {
            let order = $0.node.label.localizedStandardCompare($1.node.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Read as “selected item [relationship] neighbor”, reversing directed edges when needed.
    static func relationship(_ predicate: GraphPredicate, outgoing: Bool) -> String {
        let label = predicate.label.prefix(1).uppercased() + predicate.label.dropFirst()
        if outgoing {
            return label
        }
        return incomingLabels[predicate] ?? label
    }

    private static let incomingLabels: [GraphPredicate: String] = [
        .relatedTo: "Related to", .derivedFrom: "Source for", .mentions: "Mentioned by",
        .linksTo: "Linked from", .authoredBy: "Author of", .uses: "Used by",
        .addresses: "Addressed by", .supports: "Supported by", .limits: "Limited by",
        .partOf: "Contains", .comparesWith: "Compared with",
        .evaluatedOn: "Evaluation basis for", .measuredBy: "Measures",
        .improvesOn: "Improved on by",
    ]
}
