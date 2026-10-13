import CoreGraphics
import Foundation

/// A positioned Atlas node. Tiles are stored depth-first so a subtree is the contiguous range
/// `index ..< end`, which lets rendering and hit testing skip culled subtrees in one step.
struct AtlasTile: Sendable {
    /// The node's own data; `children` is emptied because the tiles that follow hold them.
    let node: AtlasNode
    let parent: Int?
    let depth: Int
    let rect: CGRect
    /// Area holding the children, below the label band. Equal to `rect` for items.
    let contentRect: CGRect
    var end: Int
    let childCount: Int
    let hasItemChildren: Bool

    var id: AtlasNodeID {
        node.id
    }
}

/// A deterministic, space-filling layout in a logical coordinate space.
///
/// Categories use an *ordered* squarified treemap: siblings keep Johnny Decimal code order
/// instead of being sorted by size, so a region stays put when counts change slightly. Items use
/// a uniform grid, newest first, because equal-weight tiles read better as rows than as a
/// squarified mosaic.
struct AtlasLayout: Sendable {
    private(set) var tiles: [AtlasTile] = []
    private(set) var index: [AtlasNodeID: Int] = [:]
    let bounds: CGRect

    /// Share of a region's height reserved for its label band.
    static let labelBand = 0.24
    /// Smallest share of the parent's weight given to an empty or tiny category, so it stays
    /// discoverable without dominating.
    static let minimumShare = 0.015

    init(root: AtlasNode, bounds: CGRect) {
        self.bounds = bounds
        place(root, in: bounds, parent: nil, depth: 0)
    }

    var root: AtlasTile? {
        tiles.first
    }

    func tile(_ id: AtlasNodeID) -> AtlasTile? {
        index[id].map { tiles[$0] }
    }

    func children(of position: Int) -> [Int] {
        var result: [Int] = []
        var child = position + 1
        while child < tiles[position].end {
            result.append(child)
            child = tiles[child].end
        }
        return result
    }

    /// Indices from the root to `position`, inclusive.
    func path(to position: Int) -> [Int] {
        var result = [position]
        while let parent = tiles[result[0]].parent {
            result.insert(parent, at: 0)
        }
        return result
    }

    /// The smallest item tile, which bounds how far zooming in is useful.
    var smallestItemSize: CGSize? {
        tiles.lazy.filter { $0.node.kind == .item }.map(\.rect.size)
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    private mutating func place(_ node: AtlasNode, in rect: CGRect, parent: Int?, depth: Int) {
        let position = tiles.count
        let itemChildren = node.children.first?.kind == .item
        let content = node.kind == .item ? rect : Self.contentRect(for: node, in: rect)
        var stripped = node
        stripped.children = []
        tiles.append(AtlasTile(
            node: stripped, parent: parent, depth: depth, rect: rect, contentRect: content,
            end: position + 1, childCount: node.children.count, hasItemChildren: itemChildren
        ))
        index[node.id] = position
        guard !node.children.isEmpty else { return }

        let cells: [CGRect]
        let gap: CGFloat
        if itemChildren {
            cells = Self.grid(count: node.children.count, in: content)
            gap = min(cells[0].width, cells[0].height) * 0.12
        } else {
            let floor = max(0.5, Double(node.itemCount) * Self.minimumShare)
            cells = Self.squarify(
                node.children.map { max(Double($0.itemCount), floor) },
                in: content
            )
            gap = min(content.width, content.height) * 0.014
        }
        for (child, cell) in zip(node.children, cells) {
            place(child, in: Self.inset(cell, by: gap / 2), parent: position, depth: depth + 1)
        }
        tiles[position].end = tiles.count
    }

    private static func contentRect(for node: AtlasNode, in rect: CGRect) -> CGRect {
        guard node.kind != .library else { return rect }
        let band = min(rect.height * labelBand, rect.width * 0.4)
        let padding = min(rect.width, rect.height) * 0.035
        return CGRect(
            x: rect.minX + padding,
            y: rect.minY + band,
            width: max(0, rect.width - padding * 2),
            height: max(0, rect.height - band - padding)
        )
    }

    private static func inset(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        let dx = min(amount, rect.width / 4)
        let dy = min(amount, rect.height / 4)
        return rect.insetBy(dx: dx, dy: dy)
    }

    /// Row-major grid with cells near a 1.6:1 aspect, leaving any partial row at the bottom.
    static func grid(count: Int, in rect: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let aspect = rect.height > 0 ? Double(rect.width / rect.height) : 1
        var columns = Int((Double(count) * aspect / 1.6).squareRoot().rounded(.up))
        columns = min(count, max(1, columns))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        columns = Int((Double(count) / Double(rows)).rounded(.up))
        let width = rect.width / CGFloat(columns)
        let height = rect.height / CGFloat(rows)
        return (0 ..< count).map { position in
            CGRect(
                x: rect.minX + CGFloat(position % columns) * width,
                y: rect.minY + CGFloat(position / columns) * height,
                width: width, height: height
            )
        }
    }

    /// Squarified treemap (Bruls, Huizing and van Wijk) that keeps input order.
    static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        guard !weights.isEmpty else { return [] }
        let positive = weights.map { $0.isFinite ? max(0, $0) : 0 }
        let total = positive.reduce(0, +)
        let area = Double(rect.width * rect.height)
        let areas = total > 0
            ? positive.map { $0 / total * area }
            : Array(repeating: area / Double(weights.count), count: weights.count)
        var remaining = rect
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            while end < areas.count,
                  worst(areas[start ... end], side: side) <= worst(areas[start ..< end], side: side)
            {
                end += 1
            }
            // The final row absorbs rounding so the siblings tile the rectangle exactly.
            let row = Array(areas[start ..< end])
            result += layoutRow(row, in: &remaining, final: end == areas.count)
            start = end
        }
        return result
    }

    private static func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let smallest = row.min(), let largest = row.max(),
              smallest > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }

    private static func layoutRow(
        _ row: [Double],
        in remaining: inout CGRect,
        final: Bool
    ) -> [CGRect] {
        let sum = row.reduce(0, +)
        let total = sum > 0 ? sum : 1
        var rects: [CGRect] = []
        if remaining.width >= remaining.height {
            // Stack the row as a column along the left edge.
            let width = final ? remaining.width
                : min(remaining.width, CGFloat(sum) / max(remaining.height, .ulpOfOne))
            var y = remaining.minY
            for (offset, area) in row.enumerated() {
                let height = offset == row.count - 1
                    ? remaining.maxY - y : remaining.height * CGFloat(area / total)
                rects.append(CGRect(x: remaining.minX, y: y, width: width, height: height))
                y += height
            }
            remaining = CGRect(
                x: remaining.minX + width, y: remaining.minY,
                width: remaining.width - width, height: remaining.height
            )
        } else {
            let height = final ? remaining.height
                : min(remaining.height, CGFloat(sum) / max(remaining.width, .ulpOfOne))
            var x = remaining.minX
            for (offset, area) in row.enumerated() {
                let width = offset == row.count - 1
                    ? remaining.maxX - x : remaining.width * CGFloat(area / total)
                rects.append(CGRect(x: x, y: remaining.minY, width: width, height: height))
                x += width
            }
            remaining = CGRect(
                x: remaining.minX, y: remaining.minY + height,
                width: remaining.width, height: remaining.height - height
            )
        }
        return rects
    }
}

/// Maps logical layout coordinates to view coordinates: `view = logical * scale + offset`.
struct AtlasCamera: Equatable, Sendable {
    var scale: CGFloat = 1
    var offset: CGPoint = .zero

    func screen(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y,
            width: rect.width * scale, height: rect.height * scale
        )
    }

    func logical(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    func visibleRect(in viewport: CGSize) -> CGRect {
        let origin = logical(.zero)
        return CGRect(
            x: origin.x, y: origin.y,
            width: viewport.width / scale, height: viewport.height / scale
        )
    }

    static func fitting(_ rect: CGRect, in viewport: CGSize, margin: CGFloat = 0) -> AtlasCamera {
        let available = CGSize(
            width: max(1, viewport.width - margin * 2),
            height: max(1, viewport.height - margin * 2)
        )
        let scale = min(
            available.width / max(rect.width, .ulpOfOne),
            available.height / max(rect.height, .ulpOfOne)
        )
        return centered(on: CGPoint(x: rect.midX, y: rect.midY), scale: scale, in: viewport)
    }

    static func centered(on point: CGPoint, scale: CGFloat, in viewport: CGSize) -> AtlasCamera {
        AtlasCamera(
            scale: scale,
            offset: CGPoint(
                x: viewport.width / 2 - point.x * scale,
                y: viewport.height / 2 - point.y * scale
            )
        )
    }

    /// Zooms while keeping the logical point under `anchor` fixed on screen.
    func zoomed(by factor: CGFloat, around anchor: CGPoint) -> AtlasCamera {
        let fixed = logical(anchor)
        let scale = scale * factor
        return AtlasCamera(
            scale: scale,
            offset: CGPoint(x: anchor.x - fixed.x * scale, y: anchor.y - fixed.y * scale)
        )
    }

    func panned(by delta: CGSize) -> AtlasCamera {
        AtlasCamera(
            scale: scale,
            offset: CGPoint(x: offset.x + delta.width, y: offset.y + delta.height)
        )
    }

    /// Limits zoom and keeps the viewport centre over the content.
    func clamped(
        to bounds: CGRect,
        viewport: CGSize,
        scales: ClosedRange<CGFloat>
    ) -> AtlasCamera {
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let limited = scale < scales.lowerBound || scale > scales.upperBound
            ? zoomed(
                by: min(max(scale, scales.lowerBound), scales.upperBound) / scale,
                around: center
            )
            : self
        let middle = limited.logical(center)
        let point = CGPoint(
            x: min(max(middle.x, bounds.minX), bounds.maxX),
            y: min(max(middle.y, bounds.minY), bounds.maxY)
        )
        return .centered(on: point, scale: limited.scale, in: viewport)
    }

    /// Interpolates scale geometrically and moves the centre in step with it, so a zoom between
    /// nested regions behaves like zooming about a fixed point instead of drifting sideways.
    static func interpolate(
        from start: AtlasCamera,
        to end: AtlasCamera,
        progress: Double,
        viewport: CGSize
    ) -> AtlasCamera {
        let t = min(1, max(0, progress))
        let scale = start.scale * pow(end.scale / start.scale, CGFloat(t))
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let from = start.logical(center)
        let to = end.logical(center)
        let inverseSpan = 1 / end.scale - 1 / start.scale
        let travel = abs(inverseSpan) < 1e-9
            ? CGFloat(t) : (1 / scale - 1 / start.scale) / inverseSpan
        let point = CGPoint(
            x: from.x + (to.x - from.x) * travel,
            y: from.y + (to.y - from.y) * travel
        )
        return .centered(on: point, scale: scale, in: viewport)
    }
}
