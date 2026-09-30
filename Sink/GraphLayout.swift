import ForceSimulation
import Foundation

/// Each simulation belongs to one actor invocation; no mutable Grape buffers cross actors.
actor GraphLayout {
    func settle(
        _ snapshot: GraphSnapshot,
        positions: [String: GraphPosition],
        animate: Bool,
        frame: @Sendable ([String: GraphPosition]) async -> Void
    ) async throws {
        guard !snapshot.nodes.isEmpty else { return }
        let ids = snapshot.nodes.map(\.id)
        let indices = Dictionary(uniqueKeysWithValues: ids.enumerated()
            .map { ($0.element, $0.offset) })
        let initial = ids.enumerated().map { index, id -> SIMD2<Double> in
            if let point = positions[id] {
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
            Kinetics2D.ManyBodyForce(strength: -180)
            Kinetics2D.LinkForce(
                stiffness: .weightedByDegree(k: { _, _ in 0.35 }),
                originalLength: .constant(135)
            )
            Kinetics2D.CenterForce(center: .zero, strength: 0.02)
            Kinetics2D.CollideForce(radius: .constant(44))
        }
        let simulation = Simulation(
            nodeCount: ids.count,
            links: links,
            forceField: forces,
            alphaDecay: 0.045,
            position: initial,
            fixation: ids.map { _ in nil }
        )
        for iteration in 0 ..< 180 {
            try Task.checkCancellation()
            simulation.tick()
            if (animate && iteration % 6 == 0) || iteration == 179 {
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
                if animate {
                    try await Task.sleep(for: .milliseconds(32))
                }
            }
        }
    }
}
