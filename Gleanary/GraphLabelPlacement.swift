import Foundation

/// Screen-space label placement, independent of simulation scale and reading order.
struct GraphLabelPlacement {
    let bounds: CGRect
    let nodes: [CGRect]
    private(set) var occupied: [CGRect] = []
    private let nodeIndex: GraphSpatialIndex

    init(bounds: CGRect, nodes: [CGRect]) {
        self.bounds = bounds
        self.nodes = nodes
        nodeIndex = GraphSpatialIndex(rectangles: nodes)
    }

    mutating func place(size: CGSize, near center: CGPoint, radius: CGFloat) -> CGRect? {
        guard size.width > 0, size.height > 0,
              size.width <= bounds.width, size.height <= bounds.height,
              bounds.contains(center) else { return nil }
        let gap = radius + 8
        let x = min(max(center.x - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(center.y - size.height / 2, bounds.minY), bounds.maxY - size.height)
        let candidates = [
            CGRect(origin: CGPoint(x: x, y: center.y + gap), size: size),
            CGRect(origin: CGPoint(x: x, y: center.y - gap - size.height), size: size),
            CGRect(origin: CGPoint(x: center.x + gap, y: y), size: size),
            CGRect(origin: CGPoint(x: center.x - gap - size.width, y: y), size: size),
        ]
        guard let rect = candidates.first(where: { candidate in
            let padded = candidate.insetBy(dx: -4, dy: -3)
            return bounds.contains(candidate)
                && !nodeIndex.containsIntersection(padded)
                && !occupied.contains { $0.intersects(padded) }
        }) else { return nil }
        occupied.append(rect.insetBy(dx: -4, dy: -3))
        return rect
    }
}
