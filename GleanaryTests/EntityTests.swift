import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

@Suite(.serialized) struct EntityTests {
    private func store() async throws -> (URL, DocumentStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        return (root, store)
    }

    /// Records that a note mentions an entity, as extraction would.
    private func mention(
        _ name: String, kind: GraphNode.Kind, quote: String, in note: MarkdownDocument,
        store: DocumentStore
    ) async throws {
        let revision = try #require(note.revision)
        let job = GraphJob(
            noteID: note.id, revision: revision, token: UUID(), name: note.name,
            state: "running", completed: 0, total: 1, error: nil
        )
        let claim = GraphClaim(
            source: GraphNode(
                id: GraphNode.documentID(note.id), kind: .document, label: note.name,
                noteID: note.id
            ),
            target: GraphNode.entity(name, kind: kind, noteID: note.id),
            predicate: .mentions, quote: quote, citation: nil, offset: 0, origin: "model"
        )
        try await store.readyDatabase().write { db in
            try DocumentStore.insertGraphClaim(claim, job: job, chunk: 0, in: db)
        }
    }

    @Test func entitiesListByMentionsWithTheirWrittenNames() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.save(MarkdownDocument(name: "Swarms", markdown: "Notes."))
        let second = try await store.save(MarkdownDocument(name: "Scaling", markdown: "Notes."))
        let archived = try await store.save(MarkdownDocument(name: "Old", markdown: "Notes."))
        try await mention(
            "Toby Ord",
            kind: .person,
            quote: "Toby Ord wrote about swarms.",
            in: first,
            store: store
        )
        try await mention(
            "Toby Ord",
            kind: .person,
            quote: "As Toby Ord argues, it scales.",
            in: second,
            store: store
        )
        try await mention(
            "Synthetic Labs",
            kind: .organization,
            quote: "Synthetic Labs built it.",
            in: first,
            store: store
        )
        try await mention(
            "Ghost",
            kind: .person,
            quote: "Ghost was here.",
            in: archived,
            store: store
        )
        try await store.archive(archived.id, reason: "Synthetic")

        let all = try await store.entities()
        #expect(all.map(\.name) == ["Toby Ord", "Synthetic Labs"])
        #expect(all.map(\.noteCount) == [2, 1])
        #expect(try await store.entities(kind: .organization).map(\.name) == ["Synthetic Labs"])
        #expect(try await store.entities(matching: "ORD").map(\.name) == ["Toby Ord"])

        let top = try #require(all.first)
        let mentions = try await store.entityMentions(top.id)
        #expect(Set(mentions.map(\.noteID)) == [first.id, second.id])
        #expect(mentions.allSatisfy { $0.predicate == .mentions && $0.other == nil })
        #expect(EntitiesView.byNote(mentions).count == 2)
        #expect(DocumentStore.entityName("toby ord", in: []) == "Toby Ord")
    }

    @Test func capturedAuthorsSurviveTheNoteChangingAndCreatorTextIsNotExtracted() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        var video = try #require(await store.documents().first)
        let work = try #require(await store.nextGraphWork())
        #expect(!work.chunk.extractionText.contains("next cohort"))
        #expect(work.chunk.extractionText.contains("shared plans"))
        #expect(try await store.entities(kind: .person).map(\.name) == ["Synthetic channel"])

        // Replaced text, as when a saved link becomes its summary, keeps its author.
        video.markdown = "A short synthetic summary."
        _ = try await store.save(video)
        while try await store.nextGraphWork() != nil {}
        let authors = try await store.entities(kind: .person)
        #expect(authors.map(\.name) == ["Synthetic channel"])
        let author = try #require(authors.first)
        let mention = try #require(await store.entityMentions(author.id).first)
        #expect(mention.predicate == .authoredBy)
        #expect(EntitiesView.relation(mention) == "Author")
    }

    @Test @MainActor func entitiesPageRenders() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(name: "Swarm notes", markdown: "Notes."))
        try await mention(
            "Toby Ord",
            kind: .person,
            quote: "Toby Ord wrote about swarm scaling.",
            in: note,
            store: store
        )
        try await mention(
            "Synthetic Labs",
            kind: .organization,
            quote: "Synthetic Labs built the benchmark.",
            in: note,
            store: store
        )
        for dark in [false, true] {
            let view = NSHostingView(rootView: EntitiesView(store: store, open: { _ in })
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
            let window = NSWindow(
                contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 900)
            if let path = ProcessInfo.processInfo.environment["GLEANARY_ENTITIES_SCREENSHOT"] {
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path + (dark ? ".dark.png" : ".light.png")))
            }
        }
    }
}
