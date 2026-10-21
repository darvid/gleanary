import SwiftUI

/// Bound compound-path complexity: one giant path makes crossing-edge rasterization quadratic.
struct GraphDrawingBatch {
    static let maximumSize = 128
    private(set) var paths: [CGMutablePath] = []
    private var count = maximumSize

    mutating func append(_ shape: CGPath) {
        nextPath().addPath(shape)
    }

    mutating func line(from start: CGPoint, to end: CGPoint) {
        let path = nextPath()
        path.move(to: start)
        path.addLine(to: end)
    }

    private mutating func nextPath() -> CGMutablePath {
        if count >= Self.maximumSize {
            paths.append(CGMutablePath())
            count = 0
        }
        count += 1
        return paths[paths.count - 1]
    }
}
