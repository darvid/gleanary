import Foundation
@testable import Gleanary
import GRDB
import Testing

private actor PerformanceFrames {
    var count = 0
    func record(_ positions: [String: GraphPosition]) {
        count = positions.count
    }
}

/// Opt in with GLEANARY_GRAPH_PERFORMANCE=1 and swift test -c release.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_GRAPH_PERFORMANCE"] == "1"))
func boundedGraphPerformanceOnTenThousandSyntheticNodes() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    let note = try #require(await store.open(seed: [MarkdownDocument(
        name: "Benchmark",
        markdown: "Synthetic performance fixture."
    )]).first)
    let revision = try #require(note.revision)
    let root = "benchmark-0"
    try await DatabaseQueue(path: store.url.path).write { db in
        for index in 0 ..< 10000 {
            let id = "benchmark-\(index)"
            try db.execute(
                sql: "INSERT INTO graph_nodes(id, kind, label) VALUES (?, 'concept', ?)",
                arguments: [id, "Benchmark \(index)"]
            )
            guard index > 0 else { continue }
            let edge = GraphEdge(source: root, target: id, predicate: .uses)
            try db.execute(
                sql: "INSERT INTO graph_edges(id, source, target, predicate) VALUES (?, ?, ?, 'uses')",
                arguments: [edge.id, root, id]
            )
            try db.execute(
                sql: "INSERT INTO graph_evidence(id, edgeID, noteID, revision, quote, offset, origin, chunk) VALUES (?, ?, ?, ?, 'Synthetic benchmark', 0, 'model', 0)",
                arguments: [edge.id, edge.id, note.id.uuidString, revision.uuidString]
            )
        }
    }
    let start = ContinuousClock.now
    let snapshot = try await store.graphSnapshot(focus: root, limit: 500)
    let queryDuration = start.duration(to: .now)
    #expect(snapshot.totalNodes == 10000)
    #expect(snapshot.nodes.count == 500)
    #expect(snapshot.edges.count <= 1200)
    let hidden = try await store.graphSnapshot(query: "9998")
    #expect(hidden.matchingIDs.contains("benchmark-9998"))
    let frames = PerformanceFrames()
    let layoutStart = ContinuousClock.now
    try await GraphLayout()
        .settle(snapshot, positions: [:], animate: false) { await frames.record($0) }
    let layoutDuration = layoutStart.duration(to: .now)
    #expect(await frames.count == 500)
    print(
        "Synthetic graph benchmark: 10,000 stored / 500 visible; query \(queryDuration); 180 layout ticks \(layoutDuration)"
    )
    #expect(queryDuration < .seconds(1))
    #expect(layoutDuration < .seconds(5))
}
