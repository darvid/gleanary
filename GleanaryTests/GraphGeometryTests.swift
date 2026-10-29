import Foundation
@testable import Gleanary
import Testing

struct GraphGeometryTests {
    @Test func spatialQueriesMatchBruteForceIncludingLongCrossingEdges() {
        let snapshot = GraphScaleFixture.snapshot(count: 1000)
        let positions = GraphScaleFixture.positions(count: 1000)
        let geometry = GraphGeometry(snapshot: snapshot, positions: positions)
        for step in 0 ..< 80 {
            let rect = CGRect(
                x: Double(step * 63 - 2000),
                y: Double(step * 31 - 1000),
                width: 400,
                height: 300
            )
            let expected = Set(geometry.points.indices
                .filter { rect.contains(geometry.points[$0]) })
            #expect(Set(geometry.visibleNodes(in: rect)) == expected)
            let point = CGPoint(x: rect.midX, y: rect.midY)
            let nearest = geometry.points.indices.filter {
                hypot(geometry.points[$0].x - point.x, geometry.points[$0].y - point.y) <= 120
            }.min {
                hypot(geometry.points[$0].x - point.x, geometry.points[$0].y - point.y)
                    < hypot(geometry.points[$1].x - point.x, geometry.points[$1].y - point.y)
            }
            #expect(geometry.nearestNode(to: point, radius: 120)?.id == nearest
                .map { geometry.nodes[$0].id })
        }
        let nodes = [GraphNode(id: "left", kind: .document, label: "Left"),
                     GraphNode(id: "right", kind: .document, label: "Right")]
        let edge = GraphEdge(source: "left", target: "right", predicate: .linksTo)
        let crossing = GraphGeometry(
            snapshot: GraphSnapshot(nodes: nodes, edges: [edge]),
            positions: [
                "left": GraphPosition(x: -100_000, y: 0), "right": GraphPosition(x: 100_000, y: 0),
            ]
        )
        #expect(crossing.visibleNodes(in: CGRect(x: -100, y: -100, width: 200, height: 200))
            .isEmpty)
        #expect(crossing.visibleEdges(in: CGRect(x: -100, y: -100, width: 200, height: 200)) == [0])
        #expect(crossing.nearestEdge(to: CGPoint(x: 0, y: 4), radius: 6) == edge)
        #expect(crossing.nearestEdge(to: CGPoint(x: 0, y: 8), radius: 6) == nil)
    }

    @Test func invalidPositionsAndMissingEndpointsDoNotEnterTheIndex() {
        let snapshot = GraphScaleFixture.snapshot(count: 4)
        let geometry = GraphGeometry(snapshot: snapshot, positions: [
            "scale-0": GraphPosition(x: 0, y: 0), "scale-1": GraphPosition(x: .nan, y: 0),
            "scale-2": GraphPosition(x: 0, y: .infinity),
            "scale-3": GraphPosition(x: 1e308, y: -1e308),
        ])
        #expect(geometry.nodes.count == 1)
        #expect(geometry.segments.isEmpty)
        #expect(geometry.nearestNode(to: .zero, radius: 24)?.id == "scale-0")
        #expect(GraphGeometry().bounds.isNull)
        #expect(GraphViewport.fit(
            bounds: .null,
            size: CGSize(width: 1000, height: 600),
            compact: false
        ) == nil)
    }

    @Test func aNarrowCanvasStillFitsTheGraphAcrossMostOfIt() throws {
        // A library graph's settled width, in a canvas the panes beside it have squeezed.
        let bounds = CGRect(x: -1040, y: -800, width: 2080, height: 1600)
        let size = CGSize(width: 290, height: 700)
        let camera = try #require(GraphViewport.fit(bounds: bounds, size: size, compact: false))
        #expect(bounds.width * camera.scale >= size.width * 0.75 - 1)
        #expect(bounds.width * camera.scale <= size.width)
    }

    @Test func largeGraphsFitAndCoordinateTransformsRoundTrip() throws {
        let size = CGSize(width: 1200, height: 800)
        let bounds = CGRect(x: -10000, y: -9000, width: 20000, height: 18000)
        let camera = try #require(GraphViewport.fit(bounds: bounds, size: size, compact: false))
        #expect(camera.scale < 0.15)
        let viewport = GraphViewport(size: size, scale: camera.scale, pan: camera.pan)
        #expect(CGRect(origin: .zero, size: size).contains(viewport.screen(CGPoint(
            x: bounds.minX,
            y: bounds.minY
        ))))
        #expect(CGRect(origin: .zero, size: size).contains(viewport.screen(CGPoint(
            x: bounds.maxX,
            y: bounds.maxY
        ))))
        let point = CGPoint(x: 731, y: -195)
        let restored = viewport.world(viewport.screen(point))
        #expect(abs(restored.x - point.x) < 0.00001)
        #expect(abs(restored.y - point.y) < 0.00001)
        #expect(GraphViewport.labelBudget(count: 10000, scale: 0.05, size: size) == 0)
        #expect(GraphViewport.labelBudget(count: 10000, scale: 1, size: size) <= 100)
        #expect(GraphViewport.labelBudget(count: 6, scale: 0.1, size: size) == 6)
    }

    @Test func drawingBatchesBoundCrossingPathComplexity() {
        var batch = GraphDrawingBatch()
        for index in 0 ..< 1000 {
            batch.line(from: CGPoint(x: index, y: 0), to: CGPoint(x: -index, y: 100))
        }
        #expect(batch.paths.count == (1000 + GraphDrawingBatch.maximumSize - 1) / GraphDrawingBatch
            .maximumSize)
        #expect(batch.paths.allSatisfy { !$0.isEmpty })
        let invalid = GraphSpatialIndex(rectangles: [
            .null,
            .infinite,
            CGRect(x: 1e308, y: 0, width: 1, height: 1),
        ])
        #expect(invalid.intersecting(CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }

    @Test func edgeIdentityRemainsCompatibleWithStoredJSON() throws {
        let edge = GraphEdge(source: "a", target: "b", predicate: .derivedFrom)
        let encoded = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(GraphEdge.self, from: encoded)
        #expect(decoded == edge)
        #expect(edge.id == ContentHash.of("a\u{0}derived_from\u{0}b"))
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(Set(fields.keys) == ["source", "target", "predicate"])
    }
}
