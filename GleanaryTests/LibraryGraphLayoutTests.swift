import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

@Suite(.serialized) @MainActor struct LibraryGraphLayoutTests {
    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LIBRARY_GRAPH_SCREENSHOTS"] == "1"))
    func graphAndNoteConnectionsRenderInBothAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        let notes = try await store.open(seed: [
            MarkdownDocument(
                name: "Evidence-first research",
                markdown: "Ground claims in checked sources."
            ),
            MarkdownDocument(
                name: "Prompt engineering",
                markdown: "Make context and constraints explicit."
            ),
            MarkdownDocument(
                name: "Context management",
                markdown: "Keep evidence available at the point of use."
            ),
            MarkdownDocument(
                name: "Evaluation",
                markdown: "Test behavior with representative examples."
            ),
        ])
        try await DatabaseQueue(path: store.url.path).write { db in
            for note in notes.dropFirst() {
                let ids = [notes[0].id.uuidString, note.id.uuidString].sorted()
                try db.execute(
                    sql: "INSERT INTO note_links VALUES (?, ?, ?, ?, 0)",
                    arguments: [
                        ids[0],
                        ids[1],
                        UUID().uuidString,
                        "A checked connection between research practices.",
                    ]
                )
            }
        }
        let capturedSource = try await addSource(to: notes[0].id, store: store)
        let isolated = try await store.save(MarkdownDocument(
            name: "An isolated note",
            markdown: "No links yet."
        ))
        for dark in [false, true] {
            for width in [680.0, 980.0] {
                let model = LibraryGraphModel()
                model.reduceMotion = true
                await model.load(from: store, request: LibraryGraphRequest())
                defer { model.stop() }
                let view = LibraryGraphView(
                    graph: model, store: store, refreshToken: 0, scope: .all,
                    kind: .constant(.all), query: .constant(""), focus: .constant(nil),
                    openNote: { _ in }, openSource: { _ in }
                )
                try await capture(
                    view,
                    width: width,
                    height: 600,
                    dark: dark,
                    name: "library-\(Int(width))"
                )
                if width == 980 {
                    model.select(GraphNode.documentID(capturedSource))
                    try await capture(
                        view,
                        width: width, height: 600, dark: dark, name: "source-selected-contrast",
                        increasedContrast: true
                    )
                }
                #expect(model.snapshot.nodes.count == 6)
                #expect(model.positions.count == 6)
                #expect(model.positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            }
            let connections = NoteConnectionsView(
                noteID: notes[0].id, store: store, refreshToken: 0,
                explore: { _ in }, openNote: { _ in }, openSource: { _ in }
            )
            try await capture(
                ScrollView { connections.padding(20) },
                width: 420,
                height: 660,
                dark: dark,
                name: "note"
            )
            let empty = NoteConnectionsView(
                noteID: isolated.id, store: store, refreshToken: 0,
                explore: { _ in }, openNote: { _ in }, openSource: { _ in }
            )
            try await capture(
                empty.padding(20),
                width: 420,
                height: 180,
                dark: dark,
                name: "isolated"
            )
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LIBRARY_GRAPH_SCREENSHOTS"] == "1"))
    func contextualInspectorRendersLongTitlesAndEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        let notes = try await store.open(seed: [
            MarkdownDocument(
                name: "Clear instructions and logical boundaries",
                markdown: "Fixture."
            ),
            MarkdownDocument(
                name: "Eval-driven prompt development and fair model comparisons",
                markdown: "Fixture."
            ),
            MarkdownDocument(
                name: "Context engineering: grounding, long documents, and prompt chains",
                markdown: "Fixture."
            ),
            MarkdownDocument(
                name: "Prompt engineering in 2026: official guidance organized into connected practice clusters",
                markdown: "Fixture."
            ),
        ])
        try await DatabaseQueue(path: store.url.path).write { db in
            for note in notes.dropFirst() {
                let ids = [notes[0].id.uuidString, note.id.uuidString].sorted()
                try db.execute(
                    sql: "INSERT INTO note_links VALUES (?, ?, ?, ?, 0)",
                    arguments: [ids[0], ids[1], UUID().uuidString,
                                "Code-managed prompts make changes to instructions and output constraints reviewable and testable throughout deployment and model upgrades."]
                )
            }
        }
        _ = try await addSource(to: notes[0].id, store: store)
        let task = try await store.beginConversation("Inspector fixture", owner: .researcher)
        for note in notes.dropFirst() {
            let proposal = try await store.proposeLink(
                notes[0], note, rationale: "A second supporting entry, available on demand.",
                taskID: task
            )
            try await store.reviewProposal(proposal, action: "apply")
        }
        let graph = LibraryGraphModel()
        graph.reduceMotion = true
        await graph.load(from: store, request: LibraryGraphRequest())
        defer { graph.stop() }
        let node = GraphNode.documentID(notes[0].id)
        let edge = try #require(graph.data.connections.first {
            $0.edge.predicate == .relatedTo && ($0.edge.source == node || $0.edge.target == node)
        })
        for dark in [false, true] {
            for width in [280.0, 360.0] {
                for state in ["browse", "item", "evidence"] {
                    graph.deselect()
                    if state != "browse" {
                        graph.select(node, edgeID: state == "evidence" ? edge.id : nil)
                    }
                    try await capture(
                        LibraryGraphDetails(
                            graph: graph, openNote: { _ in }, openSource: { _ in },
                            focusNote: { _ in }, close: {}
                        ),
                        width: width, height: 600, dark: dark,
                        name: "inspector-\(state)-\(Int(width))"
                    )
                }
            }
            graph.select(node)
            for width in [420.0, 720.0] {
                try await capture(
                    ScrollView {
                        LibraryGraphDetails(
                            graph: graph, openNote: { _ in }, openSource: { _ in }, compact: true
                        ).padding(20)
                    },
                    width: width, height: 460, dark: dark,
                    name: "connections-rows-\(Int(width))"
                )
            }
        }
    }

    @Test func inspectorStateSymbolsAreAvailable() {
        for name in ["rectangle.righthalf.inset.filled", "sidebar.right"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
    }

    @Test func presentationControlsKeepTheirSizeAcrossSelections() async throws {
        let choices: [LibraryPresentation] = [.map, .list, .graph]
        let sizes = choices.map { choice in
            NSHostingView(rootView: LibraryPresentationPicker(selection: .constant(choice)))
                .fittingSize
        }
        for size in sizes {
            #expect(size == sizes[0])
            #expect(size.width > 0 && size.height > 0)
        }
        if ProcessInfo.processInfo.environment["GLEANARY_LIBRARY_GRAPH_SCREENSHOTS"] == "1" {
            for dark in [false, true] {
                try await capture(
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(choices, id: \.rawValue) { choice in
                            HStack {
                                Text(choice.rawValue.capitalized).frame(
                                    width: 48,
                                    alignment: .leading
                                )
                                LibraryPresentationPicker(selection: .constant(choice))
                            }
                        }
                    }.padding(16),
                    width: 240, height: 164, dark: dark, name: "presentation-picker"
                )
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LIBRARY_GRAPH_SCREENSHOTS"] == "1"))
    func spacingLayoutsAndSettingsRenderInBothAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        let names = [
            "Research practices",
            "Clear instructions and boundaries",
            "Context engineering and grounding",
            "Prompt evaluation and comparisons",
            "Long-document workflows",
            "Structured output constraints",
            "Tool use and error recovery",
            "Versioned prompts and deployment",
        ]
        let notes = try await store.open(seed: names.map { MarkdownDocument(
            name: $0,
            markdown: "Synthetic fixture."
        ) })
        try await DatabaseQueue(path: store.url.path).write { db in
            for note in notes.dropFirst() {
                let ids = [notes[0].id.uuidString, note.id.uuidString].sorted()
                try db.execute(
                    sql: "INSERT INTO note_links VALUES (?, ?, ?, 'Synthetic relation.', 0)",
                    arguments: [ids[0], ids[1], UUID().uuidString]
                )
            }
        }
        _ = try await addSource(to: notes[0].id, store: store)
        let graph = LibraryGraphModel()
        graph.reduceMotion = true
        await graph.load(from: store, request: LibraryGraphRequest())
        try await awaitLayout(graph)
        defer { graph.stop() }
        graph.select(GraphNode.documentID(notes[0].id))
        let camera = GraphCamera(scale: 0.8, pan: .zero)
        graph.camera = camera
        for dark in [false, true] {
            for value in [0.0, 1.0] {
                graph.setSpacing(value)
                graph.finishSpacingChange()
                try await awaitLayout(graph)
                try await capture(
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            GraphDocumentLegend()
                            Spacer()
                            GraphArrangementControl(graph: graph)
                        }.padding(.horizontal, 18)
                        KnowledgeGraphView(graph: graph, openNote: { _ in }, camera: Binding(
                            get: { graph.camera }, set: { graph.camera = $0 }
                        ))
                    },
                    width: 680, height: 500, dark: dark,
                    name: "spacing-\(value == 0 ? "compact" : "spacious")"
                )
                #expect(graph.camera == camera)
            }
            try await capture(
                GraphArrangementSettings(graph: graph).padding(16),
                width: 292, height: 180, dark: dark, name: "spacing-settings"
            )
        }
    }

    private func awaitLayout(_ graph: LibraryGraphModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while graph.layingOut, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!graph.layingOut)
    }

    private func addSource(to noteID: UUID, store: DocumentStore) async throws -> UUID {
        let url = try #require(URL(string: "https://example.com/inspector-evidence"))
        _ = try await store.enqueueCapture(CaptureRequest(
            url: url, identity: "fixture:inspector-source", label: "Official source"
        ))
        let job = try #require(await store.claimCapture())
        let sourceID = try await store.publishCapture(job, document: CapturedDocument(
            title: "Official guidance on instruction hierarchy and prompt evaluation",
            sourceURL: url, coverage: .document,
            blocks: [ContentBlock(
                kind: .paragraph, markdown: "Synthetic evidence.", text: "Synthetic evidence."
            )]
        ), artifacts: [])
        let source = try await store.researchSource(noteID: sourceID)
        try await DatabaseQueue(path: store.url.path).write { db in
            for id in source.sourceIDs {
                try db.execute(
                    sql: "INSERT INTO note_sources(noteID, sourceID) VALUES (?, ?)",
                    arguments: [noteID.uuidString, id.uuidString]
                )
            }
        }
        return sourceID
    }

    private func capture(
        _ view: some View,
        width: Double,
        height: Double,
        dark: Bool,
        name: String,
        increasedContrast: Bool = false
    ) async throws {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: width, height: height))
        host.appearance = NSAppearance(named: increasedContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(1600))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(abs(host.fittingSize.width - width) < 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png
            .write(to: URL(filePath: "/tmp/gleanary-graph-\(name)-\(dark ? "dark" : "light").png"))
    }
}

struct LibraryGraphPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_GRAPH_PERFORMANCE"] == "1"))
    func tenThousandNotesStayBoundedWithoutInference() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        _ = try await store.open()
        let ids = (0 ..< 10000).map { _ in UUID().uuidString }
        try await DatabaseQueue(path: store.url.path).write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: """
                INSERT INTO notes(id, name, markdown, revision, contentHash, createdAt, updatedAt)
                VALUES (?, ?, '', ?, '', 0, 0)
                """, arguments: [id, "Synthetic note \(index)", UUID().uuidString])
                if index > 0 {
                    try db.execute(
                        sql: "INSERT INTO note_links VALUES (?, ?, ?, 'Synthetic connection.', 0)",
                        arguments: [min(ids[0], id), max(ids[0], id), UUID().uuidString]
                    )
                }
            }
        }
        let start = ContinuousClock.now
        let overview = try await store.libraryGraph(LibraryGraphRequest(limit: 500))
        let focused = try await store.libraryGraph(LibraryGraphRequest(
            focus: UUID(uuidString: ids[0]),
            depth: 2,
            limit: 500
        ))
        let duration = start.duration(to: .now)
        #expect(overview.graph.totalNodes == 10000)
        #expect(focused.graph.totalNodes == 10000)
        #expect(overview.graph.nodes.count == 500)
        #expect(focused.graph.nodes.count == 500)
        #expect(focused.graph.edges.count <= 1200)
        print("Library graph: 10,000 notes, 500 visible; overview + two-hop query \(duration)")
        #expect(duration < .seconds(5))
    }
}
