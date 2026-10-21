import ForceSimulation
import Foundation

/// Each simulation belongs to one actor invocation; no mutable Grape buffers cross actors.
actor GraphLayout {
    func settle(
        _ snapshot: GraphSnapshot,
        positions: [String: GraphPosition],
        animate: Bool,
        spacing: GraphSpacing = .standard,
        anchorID: String? = nil,
        frame: @Sendable ([String: GraphPosition]) async -> Void
    ) async throws {
        guard !snapshot.nodes.isEmpty else { return }
        try Task.checkCancellation()
        let ids = snapshot.nodes.map(\.id)
        let indices = Dictionary(uniqueKeysWithValues: ids.enumerated()
            .map { ($0.element, $0.offset) })
        let initial = ids.enumerated().map { index, id -> SIMD2<Double> in
            if let point = positions[id], GraphGeometry.isUsable(point) {
                return SIMD2(point.x, point.y)
            }
            // Deterministic phyllotaxis avoids identical starting positions and random reshuffles.
            let radius = 55 * sqrt(Double(index + 1))
            let angle = Double(index) * 2.399963229728653
            return SIMD2(cos(angle) * radius, sin(angle) * radius)
        }
        let links = snapshot.edges.compactMap { edge -> EdgeID<Int>? in
            guard let source = indices[edge.source],
                  let target = indices[edge.target] else { return nil }
            return EdgeID(source: source, target: target)
        }
        let forces = SealedForce2D {
            Kinetics2D.ManyBodyForce(strength: spacing.repulsion)
            Kinetics2D.LinkForce(
                stiffness: .weightedByDegree(k: { _, _ in 0.35 }),
                originalLength: .constant(spacing.linkLength)
            )
            Kinetics2D.CenterForce(center: .zero, strength: 0.02)
            Kinetics2D.CollideForce(radius: .constant(spacing.collisionRadius))
        }
        let simulation = Simulation(
            nodeCount: ids.count,
            links: links,
            forceField: forces,
            alphaDecay: 0.045,
            position: initial,
            fixation: ids.enumerated().map { index, id in
                id == anchorID ? initial[index] : nil
            }
        )
        let animated = animate && ids.count <= 1000
        if ids.count > 1000 {
            try Task.checkCancellation()
            let seed = Dictionary(uniqueKeysWithValues: zip(ids, initial).map {
                ($0.0, GraphPosition(x: $0.1.x, y: $0.1.y))
            })
            await frame(seed)
        }
        for iteration in 0 ..< 180 {
            try Task.checkCancellation()
            simulation.tick()
            let settled = simulation.kinetics.alpha < simulation.kinetics.alphaMin
            if (animated && iteration % 6 == 0) || iteration == 179 || settled {
                let points = simulation.kinetics.position.asArray()
                var next: [String: GraphPosition] = [:]
                for (index, id) in ids.enumerated() {
                    let point = points[index]
                    if point.x.isFinite, point.y.isFinite {
                        next[id] = GraphPosition(
                            x: point.x,
                            y: point.y
                        )
                    }
                }
                await frame(next)
                if settled {
                    break
                }
                if animated {
                    try await Task.sleep(for: .milliseconds(32))
                }
            }
        }
    }
}
