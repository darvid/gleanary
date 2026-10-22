import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

@Suite(.serialized) struct GraphFilingTests {
    @Test func primaryMembershipWinsAndScopesNeverReplaceItWithASecondaryHome() async throws {
        let fixture = try await GraphScaleFixture(count: 4, linksPerNode: 0)
        defer { fixture.clean() }
        let primary = UUID(), secondary = UUID()
        try await fixture.store.saveCategory(id: primary, code: "31.01", name: "Synthetic systems")
        try await fixture.store.saveCategory(
            id: secondary,
            code: "12.01",
            name: "Synthetic reading"
        )
        try await fixture.store.fileNote(fixture.ids[0], categoryID: primary)
        try await fixture.store.fileNote(fixture.ids[0], categoryID: secondary, primary: false)
        try await fixture.store.fileNote(fixture.ids[1], categoryID: primary, primary: false)
        try await fixture.store.fileNote(fixture.ids[1], categoryID: secondary, primary: false)
        let before = try await fixture.store.libraryChangeSequence()
        let snapshot = try await fixture.store.libraryGraph()
        let first = GraphNode.documentID(fixture.ids[0])
        let fallback = GraphNode.documentID(fixture.ids[1])
        #expect(snapshot.nodeFilings[first]?.map(\.id) == [primary, secondary])
        #expect(snapshot.nodeFilings[fallback]?.map(\.id) == [secondary, primary])
        #expect(snapshot.nodeFilings[GraphNode.documentID(fixture.ids[2])] == nil)
        let scoped = try await fixture.store.libraryGraph(LibraryGraphRequest(
            scope: .category(secondary),
            limit: 1
        ))
        let loaded = try #require(scoped.graph.nodes.first)
        #expect(scoped.nodeFilings.keys.allSatisfy { $0 == loaded.id })
        #expect(scoped.nodeFilings[loaded.id] == snapshot.nodeFilings[loaded.id])
        #expect(try await fixture.store.libraryChangeSequence() == before)
        try await fixture.store.archive(fixture.ids[0], reason: "Synthetic fixture")
        let archived = try await fixture.store.libraryGraph()
        #expect(archived.nodeFilings[first] == nil)
        // Read-only projections must not emit filing changes.
        let sequence = try await fixture.store.libraryChangeSequence()
        _ = try await fixture.store.libraryGraph(includingReasons: false)
        #expect(try await fixture.store.libraryChangeSequence() == sequence)
    }

    @Test @MainActor func refilingChangesThePaletteButNeverPositionsSelectionOrCamera(
    ) async throws {
        let fixture = try await GraphScaleFixture(count: 4)
        defer { fixture.clean() }
        let graph = LibraryGraphModel()
        graph.reduceMotion = true
        defer { graph.stop() }
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        try await settle(graph)
        let node = try #require(graph.snapshot.nodes.first)
        let noteID = try #require(node.noteID)
        #expect(graph.nodeStyle(for: node).filingHue == nil)
        #expect(graph.accessibilityLabel(for: node).contains("Unfiled"))
        let home = UUID()
        try await fixture.store.saveCategory(id: home, code: "31.01", name: "Synthetic systems")
        try await fixture.store.fileNote(noteID, categoryID: home)
        let positions = graph.positions, reset = graph.cameraReset
        let camera = GraphCamera(scale: 0.75, pan: CGSize(width: 100, height: -50))
        graph.camera = camera
        graph.select(node.id)
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(!graph.layingOut)
        #expect(graph.positions == positions)
        #expect(graph.camera == camera && graph.cameraReset == reset)
        #expect(graph.selectedID == node.id)
        #expect(graph.nodeStyle(for: node).filingHue == AtlasHierarchy.hue(for: "31.01"))
        #expect(graph.accessibilityLabel(for: node)
            .contains("Primary filing: 31.01 Synthetic systems"))
        _ = try await fixture.store.removeHome(noteID, categoryID: home)
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(graph.nodeStyle(for: node).filingHue == nil)
        #expect(!graph.layingOut && graph.positions == positions && graph.camera == camera)
    }

    @Test @MainActor func sourcesAndSummariesUseTheirOwnFilingAndKeepDistinctShapes() async throws {
        let fixture = try await GraphScaleFixture(count: 2, linksPerNode: 0)
        defer { fixture.clean() }
        let url = try #require(URL(string: "https://fixture.example/filing-source"))
        _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(url))
        let job = try #require(await fixture.store.claimCapture())
        let sourceID = try await fixture.store.publishCapture(job, document: CapturedDocument(
            title: "Synthetic retained source", sourceURL: url, coverage: .article,
            blocks: [.init(
                kind: .paragraph,
                markdown: "Synthetic evidence.",
                text: "Synthetic evidence."
            )]
        ), artifacts: [])
        let sourceHome = UUID(), summaryHome = UUID()
        try await fixture.store.saveCategory(id: sourceHome, code: "21", name: "Synthetic sources")
        try await fixture.store.saveCategory(
            id: summaryHome,
            code: "34",
            name: "Synthetic summaries"
        )
        try await fixture.store.fileNote(sourceID, categoryID: sourceHome)
        let source = try #require(await fixture.store.document(id: sourceID))
        let capture = try #require(await fixture.store.captureID(for: sourceID))
        let summary = try await fixture.store.publishSummaryNote(
            "Synthetic checked summary.",
            for: source,
            captureID: capture,
            engine: "Synthetic fixture"
        )
        try await fixture.store.fileNote(summary.id, categoryID: summaryHome)
        let graph = LibraryGraphModel()
        graph.reduceMotion = true
        defer { graph.stop() }
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        let sourceNode = try #require(graph.snapshot.nodes.first { $0.noteID == sourceID })
        let summaryNode = try #require(graph.snapshot.nodes.first { $0.noteID == summary.id })
        #expect(graph.filings(for: sourceNode).first?.id == sourceHome)
        #expect(graph.filings(for: summaryNode).first?.id == summaryHome)
        #expect(graph.nodeStyle(for: sourceNode).isSource)
        #expect(!graph.nodeStyle(for: summaryNode).isSource)
        #expect(graph.nodeStyle(for: sourceNode).filingHue != graph.nodeStyle(for: summaryNode)
            .filingHue)
        #expect(graph.accessibilityLabel(for: summaryNode)
            .contains("Also filed in: 21 Synthetic sources"))
        let concept = GraphNode(
            id: "concept:synthetic",
            kind: .concept,
            label: "Synthetic concept",
            noteID: sourceID
        )
        #expect(graph.filings(for: concept).isEmpty)
        #expect(graph.nodeStyle(for: concept).filingHue == nil)
        #expect(graph.accessibilityLabel(for: concept) == "Synthetic concept, concept")
    }

    @Test func drawingBucketsSeparateFilingAndShapeWithoutUsingCategoryIdentity() {
        let note = GraphNodeStyle(kind: .document, isSource: false, filingHue: 1)
        let source = GraphNodeStyle(kind: .document, isSource: true, filingHue: 1)
        let other = GraphNodeStyle(kind: .document, isSource: false, filingHue: 2)
        #expect(Set([note, source, other]).count == 3)
        #expect([source, other, note].sorted() == [note, other, source])
        // Subcategories reuse their parent's existing Map palette slot.
        #expect(AtlasHierarchy.hue(for: "31.01") == AtlasHierarchy.hue(for: "31.09"))
    }

    @MainActor private func settle(_ graph: LibraryGraphModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while graph.layingOut, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!graph.layingOut)
    }
}
