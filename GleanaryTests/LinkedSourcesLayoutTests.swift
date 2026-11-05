import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

@Suite(.serialized) @MainActor struct LinkedSourcesLayoutTests {
    @Test func initialScanRunsWhenTheEmptySectionIsNestedBetweenNoteContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        let notes = try await store.open(seed: [MarkdownDocument(
            name: "Fixture", markdown: "[Guide](<https://example.org/guide>)"
        )])
        let note = try #require(notes.first)
        let sources = LinkedSourcesModel()
        let context = LinkedSourceContext(
            store: store,
            revision: "fixture",
            canAdd: true
        ) { _, _, _ in }
        let host = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Saved note body")
                LinkedSourcesView(
                    document: note,
                    context: context,
                    openDocument: { _ in },
                    model: sources
                )
                Text("Connections")
            }
        }.frame(width: 760, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        // The scan is fast alone but can take seconds while the full suite runs in parallel.
        let deadline = ContinuousClock.now + .seconds(10)
        while sources.sources.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sources.sources.count == 1)
        #expect(sources.error == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LINKED_SOURCES_SCREENSHOTS"] == "1"))
    func linkedSourcesAppearInsideTheActualDocumentPreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        let markdown = """
        Context engineering uses checked sources and explicit constraints ([1](<https://example.org/guide>); [2](<https://example.org/design>)).

        ## Sources

        1. [Prompt engineering | Example API](<https://example.org/guide>) — web text read 2026-10-18. Captured coverage: article.
        2. [Prompt design strategies | Example API](<https://example.org/design>) — web text read 2026-10-18. Captured coverage: article.
        3. [Prompting best practices - Example Docs](<https://example.org/practices>) — web text read 2026-10-18. Captured coverage: article.
        4. [Best Practices Guide | Example Docs](<https://example.org/best>) — web text read 2026-10-18. Captured coverage: article.
        """
        let notes = try await store.open(seed: [MarkdownDocument(
            name: "Context engineering fixture",
            markdown: markdown
        )])
        let note = try #require(notes.first)
        #expect(try LinkedSourceLink.extract(from: note.markdown).count == 4)
        let model = DocumentPreviewModel()
        model.selectedID = note.id
        await model.load(from: store)
        let context = LinkedSourceContext(
            store: store,
            revision: "fixture",
            canAdd: true
        ) { _, _, _ in }
        let host = NSHostingView(rootView: DocumentPreview(model: model)
            .environment(\.linkedSourceContext, context)
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: 760, height: 1200))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 1200)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(filePath: "/tmp/gleanary-linked-sources-full-note.png"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LINKED_SOURCES_SCREENSHOTS"] == "1"))
    func suggestionsAndCaptureStatesFitNarrowAndWideNotesInBothAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        let names = [
            "Clear instructions and logical boundaries",
            "Eval-driven prompt development and fair model comparisons",
            "Context engineering and grounding",
            "Structured outputs: from format instructions to response schemas",
            "Prompt engineering in 2026: official guidance organized into connected practice clusters",
            "Tool use and failure recovery",
        ]
        let note = MarkdownDocument(
            name: "Synthetic Writer note",
            markdown: names.enumerated().map {
                "[\($0.element)](https://example.org/source-\($0.offset))"
            }.joined(separator: "\n")
        )
        _ = try await store.open(seed: [note])
        let links = try LinkedSourceLink.extract(from: note.markdown)
        for mixed in [false, true] {
            if mixed {
                for index in 0 ..< 4 {
                    let id = try await store.enqueueCapture(CaptureRequest.webLink(
                        links[index].url,
                        referencing: note.id
                    ))
                    if index == 0 {
                        let job = try #require(await store.claimCapture())
                        let summary = "A synthetic overview."
                        let artifact = try await ArtifactStore(root: directory
                            .appending(path: "artifacts"))
                            .retain(Data(summary.utf8), kind: .markdown, name: "Summary.md")
                        let saved = try await store.publishCapture(job, document: CapturedDocument(
                            title: names[index], sourceURL: links[index].url, coverage: .document,
                            blocks: [ContentBlock(
                                kind: .paragraph,
                                markdown: "Synthetic evidence.",
                                text: "Synthetic evidence."
                            )]
                        ), artifacts: [artifact], summary: summary)
                        let source = try #require(await store.linkedSources(in: note).first)
                        #expect(source.noteID == saved)
                        #expect(source.summaries.map(\.id) == [saved])
                        try await store.archive(saved, reason: "Synthetic fixture")
                    } else if index == 1 {
                        let job = try #require(await store.claimCapture())
                        try await store.failCapture(
                            job,
                            error: "The source returned HTTP 503. Try again later."
                        )
                    } else if index == 2 {
                        try await store.cancelCapture(id)
                    }
                }
                let job = try #require(await store.claimCapture())
                try await store.checkpoint(
                    job,
                    acquired: [],
                    progress: "Writing a brief summary with Fixture"
                )
            }
            for width in [320.0, 680.0] {
                for dark in [false, true] {
                    let context = LinkedSourceContext(
                        store: store,
                        revision: "fixture",
                        canAdd: true
                    ) { _, _, _ in }
                    let view = ScrollView {
                        LinkedSourcesView(document: note, context: context, openDocument: { _ in })
                            .padding(20)
                    }
                    let host = NSHostingView(rootView: view
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .frame(width: width, height: 760))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 760)
                    let window = NSWindow(
                        contentRect: host.frame,
                        styleMask: [],
                        backing: .buffered,
                        defer: false
                    )
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    try await Task.sleep(for: .milliseconds(500))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    #expect(abs(host.fittingSize.width - width) < 1)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png
                        .write(
                            to: URL(
                                filePath: "/tmp/gleanary-linked-sources-\(mixed ? "mixed" : "new")-\(Int(width))-\(dark ? "dark" : "light").png"
                            )
                        )
                }
            }
        }
    }
}
