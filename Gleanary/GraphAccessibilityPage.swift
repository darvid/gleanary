/// Bounds virtual accessibility views without changing the rendered graph or its scope.
struct GraphAccessibilityPage {
    static let size = 80
    let nodes: ArraySlice<GraphNode>
    let previousID: String?
    let nextID: String?
    let value: String

    init(nodes: [GraphNode], selectedID: String?) {
        let index = nodes.firstIndex { $0.id == selectedID } ?? 0
        let start = index / Self.size * Self.size
        let end = min(nodes.count, start + Self.size)
        self.nodes = nodes[start ..< end]
        previousID = start > 0 ? nodes[start - 1].id : nil
        nextID = end < nodes.count ? nodes[end].id : nil
        value = nodes.isEmpty ? "No items" : "Items \(start + 1) through \(end) of \(nodes.count)"
    }
}
