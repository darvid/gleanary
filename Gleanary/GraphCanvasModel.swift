import Observation

/// Shared canvas interactions, independent of extraction and of any other graph's camera.
@MainActor protocol GraphCanvasModel: AnyObject, Observable {
    var snapshot: GraphSnapshot { get }
    var positions: [String: GraphPosition] { get }
    var selectedID: String? { get }
    var selectedEdgeID: String? { get }
    var selection: GraphNode? { get }
    var reduceMotion: Bool { get set }
    var cameraReset: Int { get }
    var overviewAction: (() -> Void)? { get }
    var scopeLabel: String { get }
    var preparingInitialGraph: Bool { get }
    var layingOut: Bool { get }
    var visibleLimit: Int { get }
    var canvasCountLabel: String { get }
    func isSource(_ node: GraphNode) -> Bool
    func select(_ id: String, edgeID: String?)
    func deselect()
    func expand()
    func move(_ id: String, to position: GraphPosition)
    func persistPosition(_ id: String)
    func startLayout()
}

extension GraphCanvasModel {
    func isSource(_: GraphNode) -> Bool {
        false
    }

    func kindLabel(for node: GraphNode) -> String {
        guard node.kind == .document else { return node.kind.rawValue }
        return GraphDocumentMark(isSource: isSource(node)).label
    }

    func select(_ id: String) {
        select(id, edgeID: nil)
    }
}

extension KnowledgeGraphModel: GraphCanvasModel {
    var overviewAction: (() -> Void)? {
        guard hasScopedView else { return nil }
        return { self.overview() }
    }

    var canvasCountLabel: String {
        "\(snapshot.nodes.count) of \(snapshot.totalNodes) knowledge nodes"
    }
}
