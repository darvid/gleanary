import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

@Suite(.serialized) @MainActor struct DocumentIdentityTests {
    @Test func notesKeepTheirSubtypeWithoutBecomingSources() {
        for (kind, expected) in [
            ("note", "Note"), ("summary", "Note Summary"),
            ("comparison", "Note Comparison"), ("series-note", "Note Research"),
            ("series-index", "Note Series"), ("web-research", "Note Web research"),
            ("document", "Note Document"), ("unknown", "Note"),
        ] {
            let identity = DocumentIdentity(kind: kind)
            #expect(!identity.isSource)
            #expect(identity.text == expected)
        }
        #expect(DocumentIdentity(kind: "source").text == "Source")
        #expect(DocumentIdentity(kind: "summary", showsCapturedSource: true).text == "Source")
    }

    @Test func mapIdentityUsesTheCardDestinationInsteadOfThePresenceOfAURL() {
        var item = AtlasItem(
            id: UUID(), title: "Synthetic summary", kind: "summary",
            host: "fixture.example", updatedAt: Date()
        )
        #expect(item.identity.text == "Note Summary")
        item.captureID = UUID()
        // A summary-first capture remains a note when its card opens the summary.
        #expect(item.identity.text == "Note Summary")
        item.summaries = [AtlasItem(
            id: UUID(), title: "Another summary", kind: "summary", host: nil, updatedAt: Date()
        )]
        #expect(item.isSourceCard)
        #expect(item.identity.text == "Source")
    }

    @Test func readingIdentityFollowsTheVisibleRepresentationWithoutMutatingTheNote() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let url = try #require(URL(string: "https://fixture.example/legacy"))
        _ = try await store.enqueueCapture(CaptureRequest.webLink(url))
        let job = try #require(await store.claimCapture())
        let summary = "A synthetic checked overview."
        let artifact = try await ArtifactStore(root: directory.appending(path: "artifacts"))
            .retain(Data(summary.utf8), kind: .markdown, name: "Summary.md")
        let captured = CapturedDocument(
            title: "Retained source", sourceURL: url, coverage: .article,
            blocks: [.init(
                kind: .paragraph,
                markdown: "Retained evidence.",
                text: "Retained evidence."
            )]
        )
        let id = try await store.publishCapture(
            job,
            document: captured,
            artifacts: [artifact],
            summary: summary
        )
        let preview = DocumentPreviewModel()
        preview.selectedID = id
        await preview.load(from: store)
        #expect(preview.identity.text == "Note Summary")
        preview.showsCapturedSource = true
        #expect(preview.identity.text == "Source")
        await preview.load(from: store)
        #expect(preview.identity.text == "Source")
        #expect(preview.displayedMarkdown == captured.markdown)
        preview.showsCapturedSource = false
        #expect(preview.identity.text == "Note Summary")
        #expect(try await store.document(id: id)?.markdown == summary)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_IDENTITY_SCREENSHOTS"] != nil))
    func readingAndBrowsingIdentityFitsBothAppearancesAndPaneWidths() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let url = try #require(URL(string: "https://fixture.example/source"))
        _ = try await store.enqueueCapture(CaptureRequest.webLink(url))
        let job = try #require(await store.claimCapture())
        let sourceID = try await store.publishCapture(job, document: CapturedDocument(
            title: "Prompting practices and clear source boundaries", sourceURL: url,
            coverage: .article,
            blocks: [.init(
                kind: .paragraph,
                markdown: "Retained source evidence about clear instructions and checked references.",
                text: "Retained source evidence about clear instructions and checked references."
            )]
        ), artifacts: [])
        let source = try #require(await store.document(id: sourceID))
        let captureID = try #require(await store.captureID(for: sourceID))
        let summary = try await store.publishSummaryNote(
            "A checked synthesis of clear instructions and source boundaries.",
            for: source, captureID: captureID, engine: "Synthetic fixture"
        )
        let note = try await store.save(MarkdownDocument(
            name: "Personal working note",
            markdown: "My own observations."
        ))
        let documents = try await store.documentPage().documents
        let items = try await store.atlasSnapshot().items
        for dark in [false, true] {
            for width in [320.0, 680.0] {
                let suffix = "\(Int(width))-\(dark ? "dark" : "light")"
                for (name, id) in [
                    ("source", sourceID),
                    ("summary", summary.id),
                    ("note", note.id),
                ] {
                    let preview = DocumentPreviewModel()
                    preview.selectedID = id
                    await preview.load(from: store)
                    try await snapshot(
                        DocumentPreview(model: preview, showsLibraryDetails: true),
                        name: "\(name)-\(suffix)",
                        width: width,
                        height: 550,
                        dark: dark
                    )
                }
                try await snapshot(
                    List(documents + [filedCapture]) { document in
                        LibraryDocumentRow(document: document)
                    }
                    .listStyle(.inset),
                    name: "list-\(suffix)", width: width, height: 400, dark: dark
                )
            }
            let atlas = KnowledgeAtlasModel(snapshot: AtlasSnapshot(categories: [], items: items))
            atlas.reduceMotion = true
            try await snapshot(
                KnowledgeAtlasView(atlas: atlas, store: nil, openItem: { _ in }),
                name: "map-\(dark ? "dark" : "light")",
                width: 680,
                height: 480,
                dark: dark
            )
        }
    }

    /// A captured page with a preview and a home, which the store's fixtures don't have.
    private var filedCapture: DocumentSummary {
        let image = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        return DocumentSummary(
            id: UUID(),
            name: "A captured page with a long title that wraps onto a second line",
            sourceURL: URL(string: "https://www.fixture.example/page"),
            faviconData: nil,
            faviconChecked: true,
            kind: "source",
            filing: "20.03 Synthetic research",
            previewImage: image.tiffRepresentation
        )
    }

    private func snapshot(
        _ view: some View,
        name: String,
        width: Double,
        height: Double,
        dark: Bool
    ) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(dark ? .dark : .light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width + 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let path = try #require(ProcessInfo.processInfo
            .environment["GLEANARY_IDENTITY_SCREENSHOTS"])
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appending(path: "\(name).png"))
    }
}
