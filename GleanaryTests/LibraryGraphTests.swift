import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

private struct LibraryGraphFixture {
    let directory: URL
    let store: DocumentStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    }

    func clean() {
        try? FileManager.default.removeItem(at: directory)
    }

    func link(_ left: UUID, _ right: UUID, reason: String = "A checked connection.") throws {
        let ids = [left.uuidString, right.uuidString].sorted()
        try DatabaseQueue(path: store.url.path).write { db in
            try db.execute(
                sql: "INSERT INTO note_links VALUES (?, ?, ?, ?, ?)",
                arguments: [ids[0], ids[1], UUID().uuidString, reason, 0]
            )
        }
    }

    func counts() throws -> [Int] {
        try DatabaseQueue(path: store.url.path).read { db in
            try ["graph_nodes", "graph_edges", "graph_jobs", "graph_layout", "note_links"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)") ?? 0
            }
        }
    }
}

struct LibraryGraphTests {
    @Test func canonicalLinksWorkWithoutExtractionAndGraphReadsNeverWrite() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "Retrieval", markdown: "Synthetic retrieval."),
            MarkdownDocument(name: "Context", markdown: "Synthetic context."),
            MarkdownDocument(name: "Isolated", markdown: "No connections."),
        ])
        let first = try #require(notes.first)
        let second = notes[1]
        try fixture.link(first.id, second.id)
        let before = try fixture.counts()
        let graph = try await fixture.store.libraryGraph()
        #expect(graph.graph.nodes.count == 3)
        #expect(graph.graph.edges.count == 1)
        #expect(graph.graph.edges.first?.predicate == .relatedTo)
        #expect(graph.connections.first?.reasons.first?.text == "A checked connection.")
        #expect(graph.graph.nodes.allSatisfy { $0.noteID != nil })
        #expect(try fixture.counts() == before)
        let scoped = try await fixture.store.libraryGraph(LibraryGraphRequest(focus: first.id))
        #expect(Set(scoped.graph.nodes.compactMap(\.noteID)) == [first.id, second.id])
        #expect(scoped.graph.matchingIDs == [GraphNode.documentID(first.id)])
        let isolated = try await fixture.store.libraryGraph(LibraryGraphRequest(focus: notes[2].id))
        #expect(isolated.graph.nodes.count == 1)
        #expect(isolated.graph.edges.isEmpty)
    }

    @Test func proposalsRequireApprovalDeduplicateAndUndoWithoutLosingOtherOrigins() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "One", markdown: "Synthetic one."),
            MarkdownDocument(name: "Two", markdown: "Synthetic two."),
        ])
        let task = try await fixture.store.beginConversation("Fixture links", owner: .researcher)
        let proposal = try await fixture.store.proposeLink(
            notes[1],
            notes[0],
            rationale: "Reviewed rationale.",
            taskID: task
        )
        #expect(try await fixture.store.libraryGraph().graph.edges.isEmpty)
        try await fixture.store.reviewProposal(proposal, action: "apply")
        #expect(try await fixture.store.libraryGraph().graph.edges.count == 1)
        try fixture.link(notes[0].id, notes[1].id, reason: "Writer rationale.")
        let duplicate = try await fixture.store.libraryGraph()
        #expect(duplicate.graph.edges.count == 1)
        #expect(Set(duplicate.connections.flatMap(\.reasons).map(\.text)) == [
            "Reviewed rationale.",
            "Writer rationale.",
        ])
        try await fixture.store.reviewProposal(proposal, action: "undo")
        #expect(try await fixture.store.libraryGraph().connections.first?.reasons
            .map(\.text) == ["Writer rationale."])
    }

    @Test func focusExpandsTwoHopsAndScopesMatchTheLibrary() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: (0 ..< 4).map {
            MarkdownDocument(name: "Beacon \($0)", markdown: "cobaltbeacon evidence \($0)")
        })
        try fixture.link(notes[0].id, notes[1].id)
        try fixture.link(notes[1].id, notes[2].id)
        try fixture.link(notes[2].id, notes[3].id)
        #expect(try await fixture.store.libraryGraph(LibraryGraphRequest(focus: notes[0].id)).graph
            .nodes.count == 2)
        #expect(try await fixture.store.libraryGraph(LibraryGraphRequest(
            focus: notes[0].id,
            depth: 2
        )).graph.nodes.count == 3)
        let category = UUID()
        try await fixture.store.saveCategory(id: category, code: "25", name: "Synthetic")
        try await fixture.store.fileNote(notes[0].id, categoryID: category)
        try await fixture.store.fileNote(notes[1].id, categoryID: category)
        for request in [
            LibraryGraphRequest(scope: .category(category)),
            LibraryGraphRequest(scope: .unfiled),
            LibraryGraphRequest(kind: .notes, query: "cobalt"),
            LibraryGraphRequest(kind: .sources),
            LibraryGraphRequest(query: "\" OR { ( : * '"),
        ] {
            let graph = try await fixture.store.libraryGraph(request)
            let page = try await fixture.store.documentPage(
                query: request.query,
                scope: request.scope,
                kind: request.kind
            )
            #expect(Set(graph.graph.nodes.compactMap(\.noteID)) == Set(page.documents.map(\.id)))
            let ids = Set(graph.graph.nodes.map(\.id))
            #expect(graph.graph.edges
                .allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
        }
    }

    @Test func archivedAndDeletedEndpointsDisappearAndUnarchiveRestoresLinks() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "One", markdown: "One."),
            MarkdownDocument(name: "Two", markdown: "Two."),
        ])
        try fixture.link(notes[0].id, notes[1].id)
        try await fixture.store.archive(notes[1].id, reason: "Fixture")
        #expect(try await fixture.store.libraryGraph().graph.nodes.count == 1)
        #expect(try await fixture.store.libraryGraph().graph.edges.isEmpty)
        try await fixture.store.unarchive(notes[1].id)
        #expect(try await fixture.store.libraryGraph().graph.edges.count == 1)
        try await fixture.store.remove(notes[1])
        #expect(try await fixture.store.libraryGraph().graph.edges.isEmpty)
    }

    @Test @MainActor func sourceProvenanceAppearsWithoutGraphExtraction() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let url = try #require(URL(string: "https://example.com/graph-fixture"))
        _ = try await fixture.store.enqueueCapture(CaptureRequest(
            url: url,
            identity: "fixture:graph-source",
            label: "Fixture source"
        ))
        let job = try #require(await fixture.store.claimCapture())
        let sourceID = try await fixture.store.publishCapture(job, document: CapturedDocument(
            title: "Captured evidence", sourceURL: url, coverage: .document,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Synthetic evidence.",
                text: "Synthetic evidence."
            )]
        ), artifacts: [])
        let source = try await fixture.store.researchSource(noteID: sourceID)
        let task = try await fixture.store.beginConversation("Fixture summary", owner: .researcher)
        let summary = try await fixture.store.saveResearch(
            "Synthetic summary.",
            name: "A summary",
            sources: [source],
            taskID: task,
            provider: "synthetic-fixture",
            kind: "summary"
        )
        let graph = try await fixture.store.libraryGraph()
        #expect(graph.graph.nodes.count == 2)
        let edge = try #require(graph.graph.edges.first { $0.predicate == .derivedFrom })
        #expect(edge.source == GraphNode.documentID(summary.id))
        #expect(edge.target == GraphNode.documentID(sourceID))
        #expect(graph.sourceNodeIDs == [GraphNode.documentID(sourceID)])
        let model = LibraryGraphModel()
        model.reduceMotion = true
        defer { model.stop() }
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        let canvas: any GraphCanvasModel = model
        let sourceNode = try #require(model.snapshot.nodes.first { $0.noteID == sourceID })
        let noteNode = try #require(model.snapshot.nodes.first { $0.noteID == summary.id })
        #expect(canvas.isSource(sourceNode))
        #expect(!canvas.isSource(noteNode))
        #expect(canvas.kindLabel(for: sourceNode) == "Source")
        #expect(canvas.kindLabel(for: noteNode) == "Note")
        let inspector = LibraryGraphInspector(data: graph)
        #expect(inspector.neighbors(of: edge.source).first?.group == .sources)
        #expect(inspector.neighbors(of: edge.target).first?.group == .notes)
        let focused = try await fixture.store.libraryGraph(LibraryGraphRequest(focus: summary.id))
        #expect(focused.graph.nodes.count == 2)
        let notesOnly = try await fixture.store.libraryGraph(LibraryGraphRequest(kind: .notes))
        #expect(notesOnly.graph.nodes.compactMap(\.noteID) == [summary.id])
        #expect(notesOnly.graph.edges.isEmpty)
        #expect(notesOnly.sourceNodeIDs.isEmpty)
    }

    @Test func conceptLayerRequiresCurrentReadyEvidenceAndPreservesQuotations() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let note = try #require(await fixture.store.open(seed: [
            MarkdownDocument(name: "Orion", markdown: "Orion uses retrieval."),
        ]).first)
        let work = try #require(await fixture.store.nextGraphWork())
        let proposal = GraphProposal(entities: [
            ProposedEntity(name: "Orion", kind: .tool, quote: note.markdown),
            ProposedEntity(name: "retrieval", kind: .concept, quote: note.markdown),
        ], relations: [ProposedRelation(
            source: "Orion",
            target: "retrieval",
            predicate: .uses,
            quote: note.markdown
        )])
        try await fixture.store.publishGraph(
            work,
            claims: GraphValidation.claims(proposal, work: work)
        )
        let plain = try await fixture.store.libraryGraph()
        #expect(plain.graph.nodes.count == 1)
        #expect(plain.graph.edges.isEmpty)
        let enriched = try await fixture.store
            .libraryGraph(LibraryGraphRequest(includesConcepts: true))
        #expect(enriched.graph.nodes.count == 3)
        #expect(enriched.connections.contains { $0.edge.predicate == .uses })
        #expect(enriched.connections.flatMap(\.reasons)
            .allSatisfy { $0.text == note.markdown && $0.noteID == note.id })
        try await fixture.store.archive(note.id, reason: "Fixture")
        #expect(try await fixture.store.libraryGraph(LibraryGraphRequest(includesConcepts: true))
            .graph.nodes.isEmpty)
        try await fixture.store.unarchive(note.id)
        var edited = note
        edited.markdown = "A replacement with no extracted concepts."
        _ = try await fixture.store.save(edited)
        let stale = try await fixture.store
            .libraryGraph(LibraryGraphRequest(includesConcepts: true))
        #expect(stale.graph.nodes.count == 1)
        #expect(stale.graph.edges.isEmpty)
    }

    @Test func savedExplicitLinksAreVisibleEvenWhenConceptExtractionIsUnavailable() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "One", markdown: "Read the other note."),
            MarkdownDocument(name: "Two", markdown: "Synthetic source."),
        ])
        let work = try #require(await fixture.store.nextGraphWork())
        let source = GraphNode(
            id: GraphNode.documentID(notes[0].id),
            kind: .document,
            label: notes[0].name,
            noteID: notes[0].id
        )
        let target = GraphNode(
            id: GraphNode.documentID(notes[1].id),
            kind: .document,
            label: notes[1].name,
            noteID: notes[1].id
        )
        try await fixture.store.publishGraph(work, claims: [
            GraphClaim(
                source: source,
                target: target,
                predicate: .linksTo,
                quote: "Read the other note.",
                citation: nil,
                offset: 0,
                origin: "link"
            ),
        ])
        try await DatabaseQueue(path: fixture.store.url.path).write { db in
            try db.execute(sql: "UPDATE graph_jobs SET state = 'unavailable'")
        }
        let graph = try await fixture.store.libraryGraph()
        #expect(graph.graph.edges.count == 1)
        #expect(graph.graph.edges.first?.predicate == .linksTo)
        #expect(graph.connections.first?.reasons.first?.label == "Saved link")
    }

    @Test func visibleLimitsKeepTheFocusedNoteAndDiscloseTruncation() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: (0 ..< 45).map {
            MarkdownDocument(name: "Fixture \($0)", markdown: "Synthetic fixture.")
        })
        for note in notes.dropFirst() {
            try fixture.link(notes[0].id, note.id)
        }
        let graph = try await fixture.store.libraryGraph(LibraryGraphRequest(
            focus: notes[0].id,
            limit: 10
        ))
        #expect(graph.graph.nodes.count == 10)
        #expect(graph.graph.totalNodes == 45)
        #expect(graph.graph.nodes.first?.noteID == notes[0].id)
        #expect(graph.graph.edges.count == 9)
        #expect(Set(graph.graph.edges.map(\.id)).count == graph.graph.edges.count)
    }

    @Test @MainActor func surfacesKeepIndependentSelectionAndRefreshAfterUndo() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "One", markdown: "One."),
            MarkdownDocument(name: "Two", markdown: "Two."),
        ])
        let task = try await fixture.store.beginConversation("Fixture", owner: .researcher)
        let proposal = try await fixture.store.proposeLink(
            notes[0],
            notes[1],
            rationale: "Checked.",
            taskID: task
        )
        try await fixture.store.reviewProposal(proposal, action: "apply")
        let library = LibraryGraphModel(), embedded = LibraryGraphModel()
        library.reduceMotion = true
        embedded.reduceMotion = true
        defer { library.stop(); embedded.stop() }
        await library.load(from: fixture.store, request: LibraryGraphRequest())
        await embedded.load(from: fixture.store, request: LibraryGraphRequest(focus: notes[0].id))
        let edge = try #require(library.snapshot.edges.first)
        library.select(edge.source, edgeID: edge.id)
        embedded.select(edge.target)
        library.camera = GraphCamera(scale: 0.5, pan: CGSize(width: 20, height: 30))
        embedded.camera = GraphCamera(scale: 1.2, pan: .zero)
        await library.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(library.camera?.scale == 0.5)
        #expect(library.camera != embedded.camera)
        embedded.move(edge.target, to: GraphPosition(x: 15, y: 20))
        #expect(library.selectedID == edge.source)
        #expect(library.selectedEdgeID == edge.id)
        #expect(embedded.selectedID == edge.target)
        #expect(library.positions[edge.target] != embedded.positions[edge.target])
        try await fixture.store.reviewProposal(proposal, action: "undo")
        await library.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(library.snapshot.edges.isEmpty)
        #expect(library.selectedEdgeID == nil)
        #expect(embedded.snapshot.edges.count == 1)
        await embedded.load(from: fixture.store, request: LibraryGraphRequest(focus: notes[0].id))
        #expect(embedded.snapshot.nodes.count == 1)
        #expect(embedded.selectedID == nil || embedded.selectedID == GraphNode
            .documentID(notes[0].id))
    }

    @Test @MainActor func inspectorNavigationDoesNotChangeScopeOrCamera() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "Inspection", markdown: "Synthetic note."),
            MarkdownDocument(name: "Evidence", markdown: "Synthetic evidence."),
        ])
        try fixture.link(notes[0].id, notes[1].id)
        let graph = LibraryGraphModel()
        graph.reduceMotion = true
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        graph.stop()
        let edge = try #require(graph.snapshot.edges.first)
        let camera = GraphCamera(scale: 1.5, pan: CGSize(width: 20, height: 30))
        graph.camera = camera
        let request = graph.request
        let reset = graph.cameraReset
        let positions = graph.positions
        graph.select(edge.source)
        #expect(graph.selectedEdgeID == nil)
        graph.select(edge.source, edgeID: edge.id)
        #expect(graph.selectedConnections.map(\.id) == [edge.id])
        graph.select(edge.source)
        #expect(graph.selectedEdgeID == nil)
        graph.deselect()
        #expect(graph.selection == nil)
        #expect(graph.request == request)
        #expect(graph.camera == camera)
        #expect(graph.cameraReset == reset)
        #expect(graph.positions == positions)
    }

    @Test @MainActor func selectionUpdatesSynchronouslyWithoutAStore() {
        let graph = LibraryGraphModel()
        let camera = GraphCamera(scale: 0.8, pan: CGSize(width: 10, height: -5))
        graph.camera = camera
        graph.select("note:fixture", edgeID: "edge:fixture")
        #expect(graph.selectedID == "note:fixture")
        #expect(graph.selectedEdgeID == "edge:fixture")
        #expect(!graph.loading)
        #expect(graph.error == nil)
        #expect(graph.camera == camera)
        graph.deselect()
        #expect(graph.selectedID == nil)
        #expect(graph.selectedEdgeID == nil)
    }

    @Test @MainActor func spacingChangesPreserveCameraSelectionScopeAndOtherSurfaces() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: (0 ..< 5).map {
            MarkdownDocument(name: "Spacing \($0)", markdown: "Synthetic fixture.")
        })
        for note in notes.dropFirst() {
            try fixture.link(notes[0].id, note.id)
        }
        let graph = LibraryGraphModel(), embedded = LibraryGraphModel()
        graph.reduceMotion = true
        embedded.reduceMotion = true
        defer { graph.stop(); embedded.stop() }
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        await embedded.load(from: fixture.store, request: LibraryGraphRequest(focus: notes[0].id))
        try await waitForLayout(graph)
        try await waitForLayout(embedded)
        let nodeID = GraphNode.documentID(notes[0].id)
        let edge = try #require(graph.snapshot.edges.first)
        graph.select(nodeID, edgeID: edge.id)
        let anchor = graph.positions[nodeID]
        let camera = GraphCamera(scale: 0.7, pan: CGSize(width: 15, height: -20))
        graph.camera = camera
        let reset = graph.cameraReset
        let request = graph.request
        let snapshot = graph.snapshot
        let embeddedPositions = embedded.positions
        let counts = try fixture.counts()
        for value in [0.1, 0.3, 1] {
            graph.setSpacing(value)
        }
        graph.finishSpacingChange()
        try await waitForLayout(graph)
        #expect(graph.spacing.value == 1)
        #expect(graph.camera == camera)
        #expect(graph.cameraReset == reset)
        #expect(graph.request == request)
        #expect(graph.snapshot == snapshot)
        #expect(graph.selectedID == nodeID)
        #expect(graph.selectedEdgeID == edge.id)
        #expect(graph.positions[nodeID] == anchor)
        #expect(embedded.spacing == .standard)
        #expect(embedded.positions == embeddedPositions)
        #expect(try fixture.counts() == counts)
        graph.resetSpacing()
        try await waitForLayout(graph)
        #expect(graph.spacing == .standard)
        #expect(graph.camera == camera)
        #expect(graph.selectedID == nodeID)
        #expect(graph.request == request)
    }

    @Test @MainActor func stoppingCancelsPendingSpacingPreviews() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [MarkdownDocument(
            name: "Fixture",
            markdown: "Fixture."
        )])
        let graph = LibraryGraphModel()
        graph.reduceMotion = true
        defer { graph.stop() }
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        try await waitForLayout(graph)
        let positions = graph.positions
        graph.setSpacing(0.9)
        graph.stop()
        try await Task.sleep(for: .milliseconds(180))
        #expect(graph.positions == positions)
        #expect(!graph.layingOut)
        #expect(graph.spacing.value == 0.9)
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        try await waitForLayout(graph)
        #expect(graph.spacing.value == 0.9)
        graph.setSpacing(0.1)
        graph.finishSpacingChange()
        #expect(graph.layingOut)
        graph.stop()
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(graph.layingOut)
        try await waitForLayout(graph)
        #expect(graph.spacing.value == 0.1)
    }

    @MainActor private func waitForLayout(_ graph: LibraryGraphModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while graph.layingOut, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!graph.layingOut)
    }

    @Test func denseGraphsKeepAllEdgesAndPageEvidenceIndependently() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: (0 ..< 72).map {
            MarkdownDocument(name: "Dense \($0)", markdown: "Synthetic dense fixture.")
        })
        try await DatabaseQueue(path: fixture.store.url.path).write { db in
            for (index, left) in notes.enumerated() {
                for right in notes.dropFirst(index + 1) {
                    let ids = [left.id.uuidString, right.id.uuidString].sorted()
                    try db.execute(
                        sql: "INSERT INTO note_links VALUES (?, ?, ?, 'Synthetic connection.', 0)",
                        arguments: [ids[0], ids[1], UUID().uuidString]
                    )
                }
            }
        }
        let graph = try await fixture.store.libraryGraph()
        #expect(graph.graph.nodes.count == 72)
        #expect(graph.graph.edges.count == 72 * 71 / 2)
        #expect(!graph.graph.truncatedEdges)
        #expect(graph.truncatedReasons)
        #expect(graph.connections.count == graph.graph.edges.count)
        let missing = try #require(graph.connections.first { $0.reasons.isEmpty })
        let reasons = try await fixture.store.libraryGraphReasons(
            for: missing.edge,
            request: LibraryGraphRequest()
        )
        #expect(reasons.count == 1)
        #expect(reasons.first?.text == "Synthetic connection.")
    }

    @Test @MainActor func failedLoadsClearOldNotesAndCanRetry() async throws {
        let fixture = try LibraryGraphFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [MarkdownDocument(
            name: "Fixture",
            markdown: "Fixture."
        )])
        let model = LibraryGraphModel()
        defer { model.stop() }
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        let id = try #require(model.snapshot.nodes.first?.id)
        model.select(id)
        let unopened = DocumentStore(url: fixture.directory.appending(path: "unopened.sqlite"))
        await model.load(from: unopened, request: LibraryGraphRequest())
        #expect(model.error != nil)
        #expect(model.snapshot.nodes.isEmpty)
        #expect(model.selectedID == nil)
        await model.load(from: fixture.store, request: LibraryGraphRequest())
        #expect(model.error == nil)
        #expect(model.snapshot.nodes.count == 1)
    }

    @Test func historyDistinguishesGraphFocusAndOpenedNotes() {
        let id = UUID()
        let overview = NavigationLocation(
            chatting: false,
            scope: .all,
            atlasFocus: .library,
            atlasItem: nil,
            presentation: .graph
        )
        var focused = overview
        focused.graphFocus = id
        var opened = focused
        opened.atlasItem = id
        var history = NavigationHistory<NavigationLocation>()
        history.visit(overview); history.visit(focused); history.visit(opened)
        #expect(history.back() == focused)
        #expect(history.back() == overview)
        #expect(history.forward() == focused)
        #expect(history.forward() == opened)
    }
}
