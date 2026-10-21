import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

struct GraphScaleFixture {
    let directory: URL
    let store: DocumentStore
    let ids: [UUID]

    init(count: Int, linksPerNode: Int = 2, hub: Bool = false) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        ids = (0 ..< count).map { _ in UUID() }
        _ = try await store.open(seed: [])
        let identifiers = ids
        try await DatabaseQueue(path: store.url.path).write { db in
            let note = try db.makeStatement(sql: """
            INSERT INTO notes(id, name, markdown, revision, contentHash, createdAt, updatedAt)
            VALUES (?, ?, 'Synthetic scale fixture.', ?, 'synthetic', 0, 0)
            """)
            for (index, id) in identifiers.enumerated() {
                try note.execute(arguments: [
                    id.uuidString,
                    "Synthetic note \(index)",
                    UUID().uuidString,
                ])
            }
            let link = try db
                .makeStatement(
                    sql: "INSERT OR IGNORE INTO note_links VALUES (?, ?, ?, 'Synthetic checked relationship.', 0)"
                )
            for index in identifiers.indices {
                for offset in 1 ... max(1, linksPerNode) where linksPerNode > 0 {
                    let target = hub ? 0 : (index + offset) % count
                    guard target != index else { continue }
                    let pair = [identifiers[index].uuidString, identifiers[target].uuidString]
                        .sorted()
                    try link.execute(arguments: [pair[0], pair[1], UUID().uuidString])
                }
            }
        }
    }

    func clean() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func snapshot(count: Int) -> GraphSnapshot {
        let nodes = (0 ..< count).map {
            GraphNode(id: "scale-\($0)", kind: .document, label: "Synthetic graph item \($0)")
        }
        let edges = (1 ..< count).map {
            GraphEdge(source: nodes[$0 - 1].id, target: nodes[$0].id, predicate: .relatedTo)
        }
        return GraphSnapshot(nodes: nodes, edges: edges, totalNodes: count)
    }

    static func positions(count: Int) -> [String: GraphPosition] {
        Dictionary(uniqueKeysWithValues: (0 ..< count).map { index in
            let angle = Double(index) * 2.399963229728653
            let radius = 55 * sqrt(Double(index + 1))
            return ("scale-\(index)", GraphPosition(x: cos(angle) * radius, y: sin(angle) * radius))
        })
    }
}

private actor ScaleFrames {
    var positions: [String: GraphPosition] = [:]
    var count = 0
    func accept(_ next: [String: GraphPosition]) {
        positions = next; count += 1
    }
}

@Suite(.serialized) struct GraphScaleTests {
    @Test(arguments: [
        (5000, 2, false),
        (5000, 0, false),
        (5000, 1, true),
        (5000, 16, false),
        (10000, 2, false),
    ])
    func thousandsOfItemsKeepCompleteCanonicalTopology(
        count: Int,
        links: Int,
        hub: Bool
    ) async throws {
        let fixture = try await GraphScaleFixture(count: count, linksPerNode: links, hub: hub)
        defer { fixture.clean() }
        let graph = try await fixture.store.libraryGraph(
            LibraryGraphRequest(limit: count),
            includingReasons: false
        )
        #expect(graph.graph.nodes.count == count)
        #expect(graph.graph.totalNodes == count)
        #expect(graph.graph.edges.count == (hub ? count - 1 : count * links))
        #expect(!graph.graph.truncatedEdges)
        #expect(!graph.truncatedReasons)
        #expect(graph.connections.allSatisfy { $0.reasons.count == 0 })
        let ids = Set(graph.graph.nodes.map(\.id))
        #expect(graph.graph.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
        if let edge = graph.graph.edges.last {
            let reasons = try await fixture.store.libraryGraphReasons(
                for: edge,
                request: LibraryGraphRequest()
            )
            #expect(reasons.count == 1)
        }
    }

    @Test @MainActor func topologyRefreshReusesPositionsAndNeverResetsAnExistingCamera(
    ) async throws {
        let fixture = try await GraphScaleFixture(count: 12)
        defer { fixture.clean() }
        let model = LibraryGraphModel()
        model.reduceMotion = true
        defer { model.stop() }
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        let deadline = ContinuousClock.now + .seconds(3)
        while model.layingOut,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.layingOut)
        let positions = model.positions, reset = model.cameraReset
        let camera = GraphCamera(scale: 0.6, pan: CGSize(width: 123, height: -45))
        model.camera = camera
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(!model.layingOut)
        #expect(model.positions == positions)
        #expect(model.camera == camera)
        let added = try await fixture.store.save(MarkdownDocument(
            name: "New fixture note",
            markdown: "Synthetic."
        ))
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(model.snapshot.nodes.contains { $0.noteID == added.id })
        #expect(positions.allSatisfy { model.positions[$0.key] == $0.value })
        #expect(model.camera == camera)
        #expect(model.cameraReset == reset)
        model.stop()
    }

    @Test @MainActor func evidenceLoadsOnSelectionAndPagesWithoutLosingOrDuplicatingSupport(
    ) async throws {
        let fixture = try await GraphScaleFixture(count: 2, linksPerNode: 0)
        defer { fixture.clean() }
        let edge = GraphEdge(
            source: GraphNode.documentID(fixture.ids[0]),
            target: GraphNode.documentID(fixture.ids[1]),
            predicate: .linksTo
        )
        try await DatabaseQueue(path: fixture.store.url.path).write { db in
            for id in fixture.ids {
                try db.execute(
                    sql: "INSERT INTO graph_nodes(id, kind, label, noteID) VALUES (?, 'document', 'Synthetic', ?)",
                    arguments: [GraphNode.documentID(id), id.uuidString]
                )
            }
            try db.execute(
                sql: "INSERT INTO graph_edges VALUES (?, ?, ?, ?)",
                arguments: [edge.id, edge.source, edge.target, edge.predicate.rawValue]
            )
            for index in 0 ..< 97 {
                try db.execute(sql: """
                INSERT INTO graph_evidence(id, edgeID, noteID, revision, quote, offset, origin, chunk)
                SELECT ?, ?, id, revision, 'Synthetic supporting evidence.', 0, 'explicit', 0 FROM notes WHERE id = ?
                """, arguments: [
                    String(format: "support-%03d", index),
                    edge.id,
                    fixture.ids[0].uuidString,
                ])
            }
        }
        let model = LibraryGraphModel()
        model.reduceMotion = true
        defer { model.stop() }
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(model.evidence.isEmpty)
        #expect(model.data.connections.allSatisfy { $0.reasons.count == 0 })
        model.select(edge.source, edgeID: edge.id)
        try await waitForEvidence(model)
        #expect(model.evidence.count == 80)
        #expect(model.evidenceHasMore)
        model.loadEvidence()
        try await waitForEvidence(model)
        #expect(model.evidence.count == 97)
        #expect(Set(model.evidence.map(\.id)).count == 97)
        #expect(!model.evidenceHasMore)
        model.select(edge.source, edgeID: edge.id)
        model.select(edge.target)
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.evidence.isEmpty)
        #expect(!model.evidenceLoading)
    }

    @MainActor private func waitForEvidence(_ model: LibraryGraphModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.evidenceLoading,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.evidenceLoading)
        #expect(model.evidenceError == nil)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["GLEANARY_GRAPH_SCALE"] == "1"),
        arguments: [1000, 5000, 10000]
    )
    func profileActualVisibleGraph(count: Int) async throws {
        let fixture = try await GraphScaleFixture(count: count)
        defer { fixture.clean() }
        let start = ContinuousClock.now
        let loaded = try await fixture.store.libraryGraph(
            LibraryGraphRequest(limit: count),
            includingReasons: false
        )
        let queryTime = start.duration(to: .now)
        #expect(loaded.graph.nodes.count == count)
        #expect(loaded.graph.edges.count == count * 2)
        let snapshot = loaded.graph
        let frames = ScaleFrames()
        let layoutStart = ContinuousClock.now
        try await GraphLayout()
            .settle(snapshot, positions: [:], animate: false) { await frames.accept($0) }
        let layoutTime = layoutStart.duration(to: .now)
        let positions = await frames.positions
        #expect(positions.count == count)
        #expect(positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let geometryStart = ContinuousClock.now
        let geometry = GraphGeometry(snapshot: snapshot, positions: positions)
        let geometryTime = geometryStart.duration(to: .now)
        let pickingStart = ContinuousClock.now
        for point in geometry.points.prefix(1000) {
            _ = geometry.nearestNode(to: point, radius: 24)
            _ = geometry.nearestEdge(to: point, radius: 6)
        }
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        print("GRAPH MEMORY \(count): process peak RSS \(Double(usage.ru_maxrss) / 1_048_576) MiB")
        await print(
            "GRAPH GEOMETRY \(count): build \(geometryTime); 1000 node+edge picks \(pickingStart.duration(to: .now)); layout publications \(frames.count)"
        )
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let points = GraphScaleFixture.positions(count: count).values.map {
            CGPoint(x: 600 + $0.x * 0.05, y: 400 + $0.y * 0.05)
        }
        let obstacles = points.map { CGRect(x: $0.x - 10, y: $0.y - 10, width: 20, height: 20) }
        let labelStart = ContinuousClock.now
        var labels = GraphLabelPlacement(bounds: bounds, nodes: obstacles)
        for point in points {
            _ = labels.place(size: CGSize(width: 160, height: 16), near: point, radius: 10)
        }
        print(
            "GRAPH SCALE \(count): loaded \(loaded.graph.nodes.count) nodes / \(loaded.graph.edges.count) edges; query \(queryTime); layout \(layoutTime); label collision \(labelStart.duration(to: .now))"
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_GRAPH_SCALE_NATIVE"] == "1"))
    @MainActor func profileNativeCanvas() async throws {
        _ = NSApplication.shared
        for count in [1000, 5000, 10000] {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let model =
                KnowledgeGraphModel(store: DocumentStore(url: directory
                        .appending(path: "unused.sqlite")))
            model.snapshot = GraphScaleFixture.snapshot(count: count)
            model.positions = GraphScaleFixture.positions(count: count)
            let view = KnowledgeGraphView(graph: model, openNote: { _ in })
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            for density in [1, 2] {
                var durations: [Double] = []
                for index in 0 ..< 8 {
                    model.select("scale-\(index)")
                    host.layoutSubtreeIfNeeded()
                    let start = ContinuousClock.now
                    let bitmap = try #require(NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(host.bounds.width) * density,
                        pixelsHigh: Int(host.bounds.height) * density,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0
                    ))
                    bitmap.size = host.bounds.size
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let duration = start.duration(to: .now)
                    durations.append(Double(duration.components.seconds) +
                        Double(duration.components.attoseconds) / 1e18)
                }
                print(
                    "GRAPH NATIVE \(count) \(density)x: snapshot median \(durations.sorted()[4])s; maximum \(durations.max() ?? 0)s"
                )
            }
        }
    }
}
