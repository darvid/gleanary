import Foundation

/// A multilevel spatial hash. Long edges occupy coarse cells, not thousands of tiny cells.
struct GraphSpatialIndex {
    private struct Cell: Hashable { let x: Int; let y: Int }
    /// Buckets are mutable only while constructing the index; avoid dictionary COW per insertion.
    private final class Level {
        let size: Double
        var cells: [Cell: [Int]] = [:]
        var indices: [Int] = []
        init(size: Double) {
            self.size = size
        }
    }

    private let rectangles: [CGRect]
    private var levels: [Int: Level] = [:]

    init(rectangles: [CGRect]) {
        self.rectangles = rectangles
        for (index, rect) in rectangles.enumerated() where Self.isUsable(rect) {
            let extent = max(128, max(rect.width, rect.height))
            let exponent = min(40, max(0, Int(ceil(log2(extent / 128)))))
            let size = 128 * pow(2, Double(exponent))
            let level = levels[exponent] ?? Level(size: size)
            for x in Int(floor(rect.minX / size)) ... Int(floor(rect.maxX / size)) {
                for y in Int(floor(rect.minY / size)) ... Int(floor(rect.maxY / size)) {
                    level.cells[Cell(x: x, y: y), default: []].append(index)
                }
            }
            level.indices.append(index)
            levels[exponent] = level
        }
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && [rect.minX, rect.minY, rect.maxX, rect.maxY]
            .allSatisfy { $0.isFinite && abs($0) <= 1e15 }
    }

    func containsIntersection(_ rect: CGRect) -> Bool {
        guard Self.isUsable(rect) else { return false }
        for level in levels.values {
            let left = floor(rect.minX / level.size), right = floor(rect.maxX / level.size)
            let top = floor(rect.minY / level.size), bottom = floor(rect.maxY / level.size)
            if (right - left + 1) * (bottom - top + 1) > Double(level.cells.count) {
                if level.indices
                    .contains(where: { rectangles[$0].intersects(rect) })
                {
                    return true
                }
            } else {
                for x in Int(left) ... Int(right) {
                    for y in Int(top) ... Int(bottom) {
                        if (level.cells[Cell(x: x, y: y)] ?? [])
                            .contains(where: { rectangles[$0].intersects(rect) })
                        {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    func intersecting(_ rect: CGRect) -> [Int] {
        guard Self.isUsable(rect) else { return [] }
        var result: Set<Int> = []
        for level in levels.values {
            let left = floor(rect.minX / level.size), right = floor(rect.maxX / level.size)
            let top = floor(rect.minY / level.size), bottom = floor(rect.maxY / level.size)
            // A zoomed-out viewport can cover mostly empty space. Walk occupied entries instead.
            if (right - left + 1) * (bottom - top + 1) > Double(level.cells.count) {
                for index in level.indices where rectangles[index].intersects(rect) {
                    result.insert(index)
                }
            } else {
                for x in Int(left) ... Int(right) {
                    for y in Int(top) ... Int(bottom) {
                        for index in level.cells[Cell(x: x, y: y)] ?? []
                            where rectangles[index].intersects(rect)
                        {
                            result.insert(index)
                        }
                    }
                }
            }
        }
        return Array(result)
    }
}

/// Immutable world-space geometry, rebuilt on topology/position changes, not on pan or zoom.
struct GraphGeometry {
    struct Segment {
        let edge: GraphEdge
        let start: CGPoint
        let end: CGPoint
    }

    let nodes: [GraphNode]
    let points: [CGPoint]
    let segments: [Segment]
    let bounds: CGRect
    private let nodeIndices: [String: Int]
    private let nodeIndex: GraphSpatialIndex
    private let edgeIndex: GraphSpatialIndex

    init(snapshot: GraphSnapshot = GraphSnapshot(), positions: [String: GraphPosition] = [:]) {
        var nodes: [GraphNode] = [], points: [CGPoint] = [], indices: [String: Int] = [:]
        var bounds = CGRect.null
        for node in snapshot.nodes {
            guard let position = positions[node.id], Self.isUsable(position) else { continue }
            indices[node.id] = nodes.count
            nodes.append(node)
            let point = CGPoint(x: position.x, y: position.y)
            points.append(point)
            bounds = bounds.union(CGRect(origin: point, size: CGSize(width: 0.001, height: 0.001)))
        }
        self.nodes = nodes
        self.points = points
        nodeIndices = indices
        self.bounds = bounds
        nodeIndex = GraphSpatialIndex(rectangles: points.map {
            CGRect(x: $0.x - 0.001, y: $0.y - 0.001, width: 0.002, height: 0.002)
        })
        segments = snapshot.edges.compactMap { edge in
            guard let source = indices[edge.source],
                  let target = indices[edge.target] else { return nil }
            return Segment(edge: edge, start: points[source], end: points[target])
        }
        edgeIndex = GraphSpatialIndex(rectangles: segments.map {
            CGRect(
                x: min($0.start.x, $0.end.x),
                y: min($0.start.y, $0.end.y),
                width: abs($0.end.x - $0.start.x),
                height: abs($0.end.y - $0.start.y)
            )
            .insetBy(dx: -0.001, dy: -0.001)
        })
    }

    static func isUsable(_ position: GraphPosition) -> Bool {
        position.x.isFinite && position.y
            .isFinite && abs(position.x) <= 1e12 && abs(position.y) <= 1e12
    }

    func node(for id: String) -> GraphNode? {
        nodeIndices[id].map { nodes[$0] }
    }

    func point(for id: String) -> CGPoint? {
        nodeIndices[id].map { points[$0] }
    }

    func visibleNodes(in rect: CGRect) -> [Int] {
        nodeIndex.intersecting(rect).sorted()
    }

    func visibleEdges(in rect: CGRect) -> [Int] {
        edgeIndex.intersecting(rect)
    }

    func nearestNode(to point: CGPoint, radius: Double) -> GraphNode? {
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var best: (index: Int, distance: Double)?
        for index in nodeIndex.intersecting(rect) {
            let distance = hypot(points[index].x - point.x, points[index].y - point.y)
            if distance <= radius, best == nil || distance < (best?.distance ?? .infinity)
                || (distance == best?.distance && index < (best?.index ?? Int.max))
            {
                best = (index, distance)
            }
        }
        return best.map { nodes[$0.index] }
    }

    func nearestEdge(to point: CGPoint, radius: Double) -> GraphEdge? {
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        var best: (index: Int, distance: Double)?
        for index in edgeIndex.intersecting(rect) {
            let segment = segments[index]
            let dx = segment.end.x - segment.start.x, dy = segment.end.y - segment.start.y
            let length = dx * dx + dy * dy
            guard length > 0 else { continue }
            let fraction = min(
                1,
                max(
                    0,
                    ((point.x - segment.start.x) * dx + (point.y - segment.start.y) * dy) / length
                )
            )
            let distance = hypot(
                point.x - segment.start.x - fraction * dx,
                point.y - segment.start.y - fraction * dy
            )
            if distance < radius, best == nil || distance < (best?.distance ?? .infinity)
                || (distance == best?.distance && index < (best?.index ?? Int.max))
            {
                best = (index, distance)
            }
        }
        return best.map { segments[$0.index].edge }
    }
}

struct GraphViewport {
    let size: CGSize
    let scale: Double
    let pan: CGSize

    func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: size.width / 2 + point.x * scale + pan.width,
            y: size.height / 2 + point.y * scale + pan.height
        )
    }

    func world(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - size.width / 2 - pan.width) / scale,
            y: (point.y - size.height / 2 - pan.height) / scale
        )
    }

    func worldBounds(margin: Double = 30) -> CGRect {
        CGRect(
            origin: world(CGPoint(x: -margin, y: -margin)),
            size: CGSize(
                width: (size.width + margin * 2) / scale,
                height: (size.height + margin * 2) / scale
            )
        )
    }

    static func fit(bounds: CGRect, size: CGSize, compact: Bool) -> GraphCamera? {
        guard !bounds.isNull, !bounds.isInfinite else { return nil }
        let scale = min(1.3, max(0.0001, min(
            max(40, size.width - (compact ? 100 : 220)) / max(1, bounds.width),
            max(40, size.height - (compact ? 100 : 150)) / max(1, bounds.height)
        )))
        return GraphCamera(
            scale: scale,
            pan: CGSize(width: -bounds.midX * scale, height: -bounds.midY * scale)
        )
    }

    static func labelBudget(count: Int, scale: Double, size: CGSize) -> Int {
        if count <= 80 {
            return count
        }
        guard scale >= 0.3 else { return 0 }
        return min(100, max(12, Int(size.width * size.height / 12000)))
    }
}
