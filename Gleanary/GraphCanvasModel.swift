import Observation

/// Shared canvas interactions, independent of extraction and of any other graph's camera.
@MainActor protocol GraphCanvasModel: AnyObject, Observable {
    var snapshot: GraphSnapshot { get }
    var positions: [String: GraphPosition] { get }
    var geometry: GraphGeometry { get }
    var usesFilingColors: Bool { get }
    var nodeFilings: [String: [DecimalCategory]] { get }
    var maximumVisibleNodes: Int { get }
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

/// A bounded palette bucket, independent of selection and of the camera.
struct GraphNodeStyle: Hashable, Comparable {
    let kind: GraphNode.Kind
    let isSource: Bool
    let filingHue: Int?

    static func < (lhs: Self, rhs: Self) -> Bool {
        // Keep overlapping colors stable between draws, regardless of dictionary order.
        (lhs.kind.rawValue, lhs.isSource ? 1 : 0, lhs.filingHue ?? -1)
            < (rhs.kind.rawValue, rhs.isSource ? 1 : 0, rhs.filingHue ?? -1)
    }
}

extension GraphCanvasModel {
    var usesFilingColors: Bool {
        false
    }

    var nodeFilings: [String: [DecimalCategory]] {
        [:]
    }

    func filings(for node: GraphNode) -> [DecimalCategory] {
        node.kind == .document ? nodeFilings[node.id] ?? [] : []
    }

    func nodeStyle(for node: GraphNode) -> GraphNodeStyle {
        GraphNodeStyle(
            kind: node.kind,
            isSource: isSource(node),
            filingHue: filings(for: node).first.map { AtlasHierarchy.hue(for: $0.code) }
        )
    }

    func accessibilityLabel(for node: GraphNode) -> String {
        let identity = "\(node.label), \(kindLabel(for: node))"
        guard usesFilingColors, node.kind == .document else { return identity }
        let homes = filings(for: node)
        guard let primary = homes.first else { return identity + ", Unfiled" }
        let secondary = homes.dropFirst().map(\.label).joined(separator: ", ")
        return identity + ", Primary filing: " + primary.label
            + (secondary.isEmpty ? "" : ", Also filed in: " + secondary)
    }

    var maximumVisibleNodes: Int {
        500
    }

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
