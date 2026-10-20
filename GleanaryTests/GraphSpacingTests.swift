import Foundation
@testable import Gleanary
import Testing

private actor SpacingFrames {
    var last: [String: GraphPosition] = [:]
    var count = 0
    func accept(_ positions: [String: GraphPosition]) {
        last = positions
        count += 1
    }
}

struct GraphSpacingTests {
    @Test func settingsAreBoundedAndKeepTheExistingDefaultForces() {
        #expect(GraphSpacing(-1).value == 0)
        #expect(GraphSpacing(2).value == 1)
        #expect(GraphSpacing(.nan) == .standard)
        #expect(GraphSpacing(.infinity) == .standard)
        #expect(GraphSpacing.standard.linkLength == 135)
        #expect(GraphSpacing.standard.repulsion == -180)
        #expect(GraphSpacing.standard.collisionRadius == 44)
        #expect(GraphSpacing(0).collisionRadius >= 36)
        #expect(GraphSpacing(1).linkLength > GraphSpacing(0).linkLength)
        #expect(GraphSpacing(1).repulsion < GraphSpacing(0).repulsion)
        #expect(GraphSpacing(0).label == "Compact")
        #expect(GraphSpacing.standard.label == "Balanced")
        #expect(GraphSpacing(1).label == "Spacious")
    }

    @Test func spaciousLayoutGivesLinkedNodesMoreRoomAndRetainsTheAnchor() async throws {
        let nodes = (0 ..< 8).map {
            GraphNode(id: "fixture-\($0)", kind: .document, label: "Fixture \($0)")
        }
        let edges = nodes.dropFirst().map {
            GraphEdge(source: nodes[0].id, target: $0.id, predicate: .relatedTo)
        }
        let snapshot = GraphSnapshot(nodes: nodes, edges: edges)
        let anchor = GraphPosition(x: 30, y: -20)
        var distances: [Double] = []
        for value in [0.0, 1.0] {
            let frames = SpacingFrames()
            try await GraphLayout().settle(
                snapshot, positions: [nodes[0].id: anchor], animate: false,
                spacing: GraphSpacing(value), anchorID: nodes[0].id
            ) { await frames.accept($0) }
            let positions = await frames.last
            #expect(await frames.count == 1)
            #expect(positions.count == nodes.count)
            #expect(positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            #expect(positions[nodes[0].id] == anchor)
            let mean = try edges.map { edge in
                let left = try #require(positions[edge.source])
                let right = try #require(positions[edge.target])
                return hypot(left.x - right.x, left.y - right.y)
            }.reduce(0, +) / Double(edges.count)
            distances.append(mean)
        }
        #expect(distances[1] > distances[0] * 1.2)
    }

    @Test func labelPlacementAvoidsNodesAndPreviouslyPlacedLabels() throws {
        let center = CGPoint(x: 150, y: 100)
        let nodes = [
            CGRect(x: 136, y: 86, width: 28, height: 28),
            CGRect(x: 100, y: 116, width: 100, height: 30),
        ]
        var placement = GraphLabelPlacement(
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300), nodes: nodes
        )
        let size = CGSize(width: 100, height: 16)
        let firstCandidate = placement.place(size: size, near: center, radius: 10)
        let first = try #require(firstCandidate)
        #expect(first.maxY < center.y)
        #expect(nodes.allSatisfy { !$0.intersects(first) })
        let secondCandidate = placement.place(size: size, near: center, radius: 10)
        let second = try #require(secondCandidate)
        #expect(!second.intersects(first))
        #expect(nodes.allSatisfy { !$0.intersects(second) })
        #expect(placement.occupied.count == 2)
    }

    @Test func labelsStayInsideTheViewportAndHideWhenThereIsNoSafePosition() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        var placement = GraphLabelPlacement(bounds: bounds, nodes: [])
        let candidate = placement.place(
            size: CGSize(width: 140, height: 16), near: CGPoint(x: 10, y: 30), radius: 10
        )
        let rect = try #require(candidate)
        #expect(bounds.contains(rect))
        #expect(placement
            .place(size: CGSize(width: 300, height: 16), near: .zero, radius: 10) == nil)
        var blocked = GraphLabelPlacement(bounds: bounds, nodes: [bounds])
        #expect(blocked.place(
            size: CGSize(width: 50, height: 16),
            near: CGPoint(x: 100, y: 60),
            radius: 10
        ) == nil)
        #expect(blocked.occupied.isEmpty)
    }
}
