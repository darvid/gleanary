import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

/// Run with -c release and GLEANARY_GRAPH_SCALE_NATIVE=1. This verifies rendering, not live input
/// latency.
@Suite(.serialized) @MainActor struct GraphScaleNativeTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["GLEANARY_GRAPH_SCALE_NATIVE"] == "1"),
        arguments: [4999, 9999]
    )
    func canonicalLargeGraphsRenderWithSourcesAndSelectedEvidence(count: Int) async throws {
        _ = NSApplication.shared
        let fixture = try await GraphScaleFixture(count: count)
        defer { fixture.clean() }
        let url = try #require(URL(string: "https://example.org/synthetic-graph-source"))
        _ = try await fixture.store.enqueueCapture(CaptureRequest(
            url: url,
            identity: "scale:source",
            label: "Synthetic source"
        ))
        let job = try #require(await fixture.store.claimCapture())
        let source = try await fixture.store.publishCapture(job, document: CapturedDocument(
            title: "Synthetic captured source", sourceURL: url, coverage: .document,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Synthetic evidence.",
                text: "Synthetic evidence."
            )]
        ), artifacts: [])
        let pair = [fixture.ids[0].uuidString, source.uuidString].sorted()
        try await DatabaseQueue(path: fixture.store.url.path).write { db in
            try db.execute(
                sql: "INSERT INTO note_links VALUES (?, ?, ?, 'Synthetic source connection.', 0)",
                arguments: [pair[0], pair[1], UUID().uuidString]
            )
        }
        let model = LibraryGraphModel()
        model.reduceMotion = true
        defer { model.stop() }
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        let deadline = ContinuousClock.now + .seconds(30)
        while model.layingOut,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!model.layingOut)
        #expect(model.snapshot.nodes.count == count + 1)
        #expect(model.snapshot.edges.count == count * 2 + 1)
        #expect(model.data.sourceNodeIDs == [GraphNode.documentID(source)])
        let sourceNode = try #require(model.snapshot.nodes.first { $0.noteID == source })
        #expect(model.isSource(sourceNode))
        let camera = Binding<GraphCamera?>(get: { model.camera }, set: { model.camera = $0 })
        let content = HStack(spacing: 0) {
            KnowledgeGraphView(
                graph: model,
                openNote: { _ in },
                showsDocumentLegend: true,
                camera: camera
            )
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            LibraryGraphDetails(graph: model, openNote: { _ in }, openSource: { _ in })
                .frame(width: 320, height: 800)
        }
        let host = NSHostingView(rootView: content.preferredColorScheme(.light)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
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
        let beforeSelection = try #require(model.camera)
        window.setContentSize(NSSize(width: 1540, height: 800))
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.camera == beforeSelection)
        window.setContentSize(NSSize(width: 1400, height: 800))
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.camera == beforeSelection)
        for selected in [false, true] {
            if selected {
                let edge = try #require(model.snapshot.edges
                    .first { $0.source == sourceNode.id || $0.target == sourceNode.id })
                model.select(edge.source, edgeID: edge.id)
                let deadline = ContinuousClock.now + .seconds(3)
                while model.evidenceLoading,
                      ContinuousClock
                      .now < deadline
                {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(model.evidence.first?.text == "Synthetic source connection.")
                #expect(model.camera == beforeSelection)
            }
            for dark in [false, true] {
                host.rootView = content.preferredColorScheme(dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try await Task.sleep(for: .milliseconds(60))
                host.layoutSubtreeIfNeeded()
                let start = ContinuousClock.now
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                print(
                    "GRAPH CANONICAL NATIVE \(count + 1): selected=\(selected) dark=\(dark) raster \(start.duration(to: .now))"
                )
                if let directory = ProcessInfo.processInfo
                    .environment["GLEANARY_GRAPH_SCALE_SCREENSHOTS"]
                {
                    let output = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(
                        at: output,
                        withIntermediateDirectories: true
                    )
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png
                        .write(to: output
                            .appending(
                                path: "canonical-\(count + 1)-\(selected ? "evidence" : "overview")-\(dark ? "dark" : "light").png"
                            ))
                }
            }
        }
    }
}
