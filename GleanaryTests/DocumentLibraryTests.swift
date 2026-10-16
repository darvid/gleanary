import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

private struct LibraryFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store: DocumentStore

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DocumentStore(url: root.appending(path: "library.sqlite"))
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor IconFixtureFetcher: SourceFetching {
    var responses: [URL: Data] = [:]
    var calls: [URL] = []
    func set(_ url: URL, data: Data) {
        responses[url] = data
    }

    func fetch(_ url: URL) throws -> DownloadedContent {
        calls.append(url)
        guard let data = responses[url] else { throw CaptureError.http(404) }
        return DownloadedContent(data: data, url: url, mime: "image/png", encoding: nil)
    }
}

private struct DeletionFixtureEmbedder: EmbeddingProviding {
    func profile() async throws -> EmbeddingProfile {
        EmbeddingProfile(revision: 1, dimensions: 2)
    }

    func vector(for _: String, profile _: EmbeddingProfile) async throws -> [Float] {
        [1, 0]
    }
}

@Suite(.serialized)
struct DocumentLibraryTests {
    @Test @MainActor func chatSidebarDimsEmptyHomesOnColdLaunchAndRefreshesAfterFiling(
    ) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [])
        _ = try await fixture.store.addCategories([
            (code: "11", name: "Empty filing"), (code: "12", name: "Filed evidence"),
        ])
        let categories = try await fixture.store.categories()
        let empty = try #require(categories.first { $0.code == "11" })
        let filed = try #require(categories.first { $0.code == "12" })
        let note = try await fixture.store.save(MarkdownDocument(
            name: "Synthetic evidence",
            markdown: "Saved evidence."
        ))
        try await fixture.store.fileNote(note.id, categoryID: filed.id)
        let suite = "gleanary-chat-filing-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "atlasHidesEmptyCategories")
        defaults.set(LibraryPresentation.map.rawValue, forKey: "libraryPresentation")
        defaults.set(true, forKey: "starterCategoriesOffered")
        let library = LibraryModel(store: fixture.store)
        await library.load()
        let conversation = ConversationModel(
            store: fixture.store,
            coordinator: AgentCoordinator(store: fixture.store)
        )
        await conversation.load()
        for dark in [false, true] {
            let atlas = KnowledgeAtlasModel()
            #expect(atlas.emptyCategoryIDs.isEmpty)
            let host = NSHostingView(rootView: ContentView(
                library: library, conversation: conversation, atlasModel: atlas
            ).defaultAppStorage(defaults).preferredColorScheme(dark ? .dark : .light))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            for _ in 0 ..< 100 {
                if atlas.emptyCategoryIDs.contains(empty.id) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(atlas.emptyCategoryIDs.contains(empty.id))
            #expect(!atlas.emptyCategoryIDs.contains(filed.id))
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.display()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory.appending(
                path: "gleanary-chat-empty-filing-\(dark ? "dark" : "light").png"
            ))
            try await fixture.store.fileNote(note.id, categoryID: empty.id)
            await library.refreshConversationChanges()
            for _ in 0 ..< 100 {
                if atlas.emptyCategoryIDs.contains(filed.id) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!atlas.emptyCategoryIDs.contains(empty.id))
            #expect(atlas.emptyCategoryIDs.contains(filed.id))
            try await fixture.store.fileNote(note.id, categoryID: filed.id)
            await library.refreshConversationChanges()
        }
        await library.indexingTask?.value
    }

    @Test @MainActor func filingChipsAndActionsShareTextBaselinesWhenWrapping() async throws {
        for width in [260.0, 400.0] {
            for dark in [false, true] {
                let measurements = FilingBaselineMeasurements()
                let host = NSHostingView(rootView: FilingBaselineProbe(measurements: measurements)
                    .preferredColorScheme(dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 140),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let label = try #require(measurements.values["label"])
                let chip = try #require(measurements.values["chip"])
                let change = try #require(measurements.values["change"])
                let suggest = try #require(measurements.values["suggest"])
                #expect(abs(label - chip) < 1)
                #expect(abs(change - suggest) < 1)
                if width == 400 {
                    #expect(abs(chip - change) < 1)
                } else {
                    #expect(change > chip + 8)
                }
                window.displayIfNeeded()
                host.needsDisplay = true
                host.display()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: FileManager.default.temporaryDirectory.appending(
                    path: "gleanary-filing-baseline-\(Int(width))-\(dark ? "dark" : "light").png"
                ))
            }
        }
    }

    @Test @MainActor func savedDocumentPreviewFitsNarrowPanes() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let request = try CaptureRequest(
            url: #require(URL(string: "https://fixture.example/testing")),
            identity: "fixture:narrow-preview", label: "Testing"
        )
        _ = try await fixture.store.enqueueCapture(request)
        let job = try #require(await fixture.store.claimCapture())
        let image = NSImage(size: NSSize(width: 1200, height: 630), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let id = try await fixture.store.publishCapture(
            job,
            document: CapturedDocument(
                title: "Testing: A saved source with a long document title",
                sourceURL: request.url, coverage: .partial,
                blocks: [ContentBlock(
                    kind: .paragraph,
                    markdown: "Synthetic saved text.",
                    text: "Synthetic saved text."
                )]
            ), artifacts: [], previewImage: data
        )
        _ = try await fixture.store.addCategories([(code: "15", name: "Tools & software")])
        let category = try #require(await fixture.store.categories().first { $0.code == "15" })
        try await fixture.store.fileNote(id, categoryID: category.id)
        let preview = DocumentPreviewModel()
        preview.selectedID = id
        await preview.load(from: fixture.store)
        let model = ConversationModel(
            store: fixture.store,
            coordinator: AgentCoordinator(store: fixture.store)
        )
        await model.load()
        for width in [320.0, 400.0, 520.0] {
            let host = NSHostingView(rootView: DocumentPreview(
                model: preview,
                suggestHome: HomeSuggester(
                    suggest: { try await model.suggestHome(for: $0) },
                    file: { try await model.fileAsSuggested($0, $1) },
                    undo: { try await model.undoSuggestedFiling($0) },
                    addHome: { try await model.addSuggestedHome($0, $1) },
                    removeHome: { try await model.removeSuggestedHome($0, $1) }
                )
            ).preferredColorScheme(.dark))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            host.appearance = window.appearance
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            #expect(abs(host.bounds.width - width) < 1)
            let scroll = try #require(Self.descendant(NSScrollView.self, in: host))
            let document = try #require(scroll.documentView)
            #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
            #expect(scroll.contentView.bounds.minX == 0)
            try Self.screenshot(host, name: "gleanary-preview-\(Int(width))")
        }
        for width in [560.0, 680.0, 960.0] {
            let library = LibraryModel(store: fixture.store)
            library.ready = true
            let host = NSHostingView(rootView: ConversationView(
                model: model, library: library, previewModel: preview
            ).preferredColorScheme(.dark))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            #expect(abs(host.bounds.width - width) < 1)
            let split = try #require(Self.descendant(NSSplitView.self, in: host))
            #expect(split.arrangedSubviews.count == 2)
            for pane in split.arrangedSubviews {
                let frame = pane.convert(pane.bounds, to: host)
                #expect(frame.minX >= -1)
                #expect(frame.maxX <= host.bounds.maxX + 1)
            }
            try Self.screenshot(host, name: "gleanary-chat-preview-\(Int(width))")
        }
    }

    @Test @MainActor func hostedListUpdatesUncachedSecondPageWithoutAnotherInteraction(
    ) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: (0 ..< 85).map {
            MarkdownDocument(name: "Page fixture \($0)", markdown: "Saved fixture text.")
        })
        let grid = DocumentGridModel(store: fixture.store)
        await grid.reload()
        #expect(grid.document(at: 80) == nil)
        var arrived: Set<UUID> = []
        let host = NSHostingView(rootView: LibraryCachePageProbe(grid: grid) { arrived.insert($0) })
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(arrived.isEmpty)
        grid.show(indices: Array(80 ..< 85))
        await grid.waitForPages()
        // Let SwiftUI consume the observed cache arrival, without a query, selection or reload.
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(arrived == Set((80 ..< 85).compactMap { grid.document(at: $0)?.id }))
        #expect(arrived.count == 5)
        grid.pause()
    }

    @Test @MainActor func legacySummaryClassificationUsesArtifactEvidenceAndKeepsOriginals(
    ) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [])
        let artifacts = ArtifactStore(root: fixture.root.appending(path: "artifacts"))
        let url = try #require(URL(string: "https://fixture.example/legacy"))
        let request = CaptureRequest(
            url: url,
            identity: "fixture:legacy-summary",
            label: "Legacy source"
        )
        _ = try await fixture.store.enqueueCapture(request)
        let job = try #require(await fixture.store.claimCapture())
        let original = try await artifacts.retain(
            Data("Retained original cobaltbeacon prose.".utf8),
            kind: .text,
            name: "Original.txt",
            sourceURL: url
        )
        let summary = "# Summary\n\nA generated overview."
        let summaryArtifact = try await artifacts.retain(
            Data(summary.utf8),
            kind: .markdown,
            name: "Summary.md"
        )
        let captured = CapturedDocument(
            title: "Legacy summary",
            sourceURL: url,
            coverage: .article,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Retained original cobaltbeacon prose.",
                text: "Retained original cobaltbeacon prose."
            )]
        )
        let id = try await fixture.store.publishCapture(
            job,
            document: captured,
            artifacts: [original, summaryArtifact],
            summary: summary
        )
        #expect(try await fixture.store.documentPage(scope: .sources).total == 0)
        let notes = try await fixture.store.documentPage(scope: .notes)
        #expect(notes.documents.first?.id == id)
        #expect(notes.documents.first?.kindLabel == "Summary")
        #expect(try await fixture.store.libraryAuthorProvider(for: id) == "Apple Intelligence")
        let preview = DocumentPreviewModel()
        preview.selectedID = id
        await preview.load(from: fixture.store)
        #expect(preview.generatedSummary)
        #expect(preview.details.kind == "summary")
        #expect(ReadingKind(libraryKind: preview.details.kind) == .notes)
        let citation = try #require(preview.citation)
        let detail = try await fixture.store.captureDetail(id: citation.captureID)
        #expect(detail.document.markdown == captured.markdown)
        #expect(detail.artifacts.contains { $0.hash == original.hash })
        #expect(try await artifacts
            .data(for: original) == Data("Retained original cobaltbeacon prose.".utf8))
        let researchSource = try await fixture.store.researchSource(noteID: id)
        let task = try await fixture.store.beginConversation(
            "Summarize this source",
            owner: .researcher
        )
        let research = try await fixture.store.saveResearch(
            "# Research summary\n\nA separate generated note.", name: "Research: saved source",
            sources: [researchSource], taskID: task, provider: "synthetic-fixture", kind: "summary"
        )
        let home = try #require(await fixture.store.categories().first)
        for noteID in [id, research.id] {
            try await fixture.store.fileNote(noteID, categoryID: home.id, includeSources: false)
        }
        let atlasSnapshot = try await fixture.store.atlasSnapshot()
        #expect(atlasSnapshot.items.allSatisfy { $0.kind == "summary" })
        let atlas = KnowledgeAtlasModel(snapshot: atlasSnapshot)
        #expect(atlas.layout.tiles.filter { $0.node.kind == .item }.count == 1)
        let card = try #require(atlas.layout.tile(.item(id))?.node.item)
        #expect(card.captureID == citation.captureID)
        #expect(card.cardKindLabel == "Source")
        #expect(card.summaryLabel == "2 summaries")
        #expect(Set(card.summaryDocuments.map(\.id)) == [id, research.id])
        #expect(atlas.layout.tile(.item(research.id))?.id == .item(id))
        #expect(atlas.root.itemCount == 2)
        atlas.kindFilter = .notes
        #expect(atlas.layout.tiles.filter { $0.node.kind == .item }.count == 2)
        #expect(atlas.layout.tile(.item(id))?.node.item?.cardKindLabel == "Summary")
        var edited = try #require(await fixture.store.document(id: id))
        edited.markdown = "My own revised annotation."
        _ = try await fixture.store.save(edited)
        #expect(try await fixture.store.documentPage().documents.first?.kindLabel == "Source")
        // A historical summary descriptor does not mislabel unrelated current text.
        #expect(try await fixture.store.documentPage(scope: .sources).total == 1)
    }

    @Test @MainActor func libraryScopesCombineSearchFilingAndRealSourceAssociations() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let personal = MarkdownDocument(
            name: "Personal note",
            markdown: "A cobaltbeacon observation."
        )
        _ = try await fixture.store.open(seed: [personal])
        let request = try CaptureRequest(
            url: #require(URL(string: "https://fixture.example/evidence")),
            identity: "fixture:library-source",
            label: "Evidence"
        )
        _ = try await fixture.store.enqueueCapture(request)
        let job = try #require(await fixture.store.claimCapture())
        let captured = CapturedDocument(
            title: "Saved source",
            sourceURL: request.url,
            coverage: .partial,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Source text with cobaltbeacon evidence.",
                text: "Source text with cobaltbeacon evidence."
            )]
        )
        let sourceID = try await fixture.store.publishCapture(
            job,
            document: captured,
            artifacts: []
        )
        let source = try await fixture.store.researchSource(noteID: sourceID)
        let task = try await fixture.store.beginConversation(
            "summarize this source",
            owner: .researcher
        )
        let summary = try await fixture.store.saveResearch(
            "# Summary\n\nCobaltbeacon evidence.",
            name: "Source summary",
            sources: [source],
            taskID: task,
            provider: "synthetic-fixture",
            kind: "summary"
        )
        try await fixture.store.seedExampleCategories()
        let category = try #require(await fixture.store.categories().first { $0.code == "31.04" })
        try await fixture.store.fileNote(sourceID, categoryID: category.id, includeSources: true)
        let sources = try await fixture.store.documentPage(scope: .sources)
        #expect(sources.documents.map(\.id) == [sourceID])
        #expect(sources.documents.first?.kindLabel == "Source")
        #expect(sources.documents.first?.coverage == "partial")
        #expect(sources.documents.first?.filing == category.label)
        #expect(try await fixture.store.documentPage(scope: .notes).total == 2)
        #expect(try await fixture.store.documentPage(scope: .unfiled).total == 2)
        #expect(try await fixture.store.documentPage(query: "cobalt", scope: .category(category.id))
            .documents.map(\.id) == [sourceID])
        #expect(try await fixture.store.documentPage(query: "Personal", scope: .sources).total == 0)
        let related = try await fixture.store.relatedLibraryDocuments(to: sourceID)
        #expect(related.map(\.id) == [summary.id])
        #expect(related.first?.kindLabel == "Summary")
        #expect(try await fixture.store.relatedLibraryDocuments(to: summary.id)
            .map(\.id) == [sourceID])
        #expect(try await fixture.store.relatedLibraryDocuments(to: personal.id).isEmpty)
        let preview = DocumentPreviewModel()
        preview.selectedID = sourceID
        await preview.load(from: fixture.store)
        #expect(preview.coverage == .partial)
        #expect(preview.details.kind == "source")
        #expect(ReadingKind(libraryKind: preview.details.kind) == .sources)
        #expect(preview.categories.first?.id == category.id)
        #expect(preview.related.first?.id == summary.id)
        let cancelledRefresh = Task { await preview.load(from: fixture.store) }
        cancelledRefresh.cancel()
        await cancelledRefresh.value
        #expect(preview.document?.id == sourceID)
        #expect(!preview.loading)
        let library = LibraryModel(store: fixture.store)
        library.ready = true
        await library.documentGrid.reload()
        try await Self.renderLibrary(library, selected: sourceID, name: "gleanary-library-source")
        try await Self.renderLibrary(
            library,
            selected: summary.id,
            name: "gleanary-library-summary"
        )
        try await fixture.store.fileNote(summary.id, categoryID: category.id, includeSources: false)
        let atlasSnapshot = try await fixture.store.atlasSnapshot()
        let atlasLayout = AtlasLayout(root: AtlasHierarchy.project(atlasSnapshot), bounds: .zero)
        let card = try #require(atlasLayout.tile(.item(sourceID)))
        #expect(card.node.item?.summaries.map(\.id) == [summary.id])
        #expect(card.node.itemCount == 2)
        #expect(atlasLayout.tile(.item(summary.id))?.id == card.id)
        try await fixture.store.remove(summary)
        let refreshedAtlas = try await AtlasLayout(
            root: AtlasHierarchy.project(fixture.store.atlasSnapshot()),
            bounds: .zero
        )
        #expect(refreshedAtlas.tile(.item(sourceID))?.node.item?.summaries.isEmpty == true)
        #expect(try await fixture.store.relatedLibraryDocuments(to: sourceID).isEmpty)
        #expect(try await fixture.store.documentPage(scope: .notes).total == 1)
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open(loadDocuments: false)
        #expect(try await reopened.documentPage(scope: .category(category.id)).total == 1)
    }

    @Test @MainActor func libraryScopeReloadInvalidatesCachedPagesAndKeepsSearch() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let notes = (0 ..< 100).map { MarkdownDocument(
            name: "Fixture \($0)",
            markdown: "Saved searchable evidence."
        ) }
        _ = try await fixture.store.open(seed: notes)
        let category = try #require(await fixture.store.categories().first)
        try await fixture.store.fileNote(notes[0].id, categoryID: category.id)
        let grid = DocumentGridModel(store: fixture.store)
        await grid.reload()
        #expect(grid.total == 100)
        grid.scope = .category(category.id)
        await grid.reload()
        #expect(grid.total == 1)
        #expect(grid.document(at: 0)?.id == notes[0].id)
        grid.query = "absent"
        await grid.reload()
        #expect(grid.total == 0)
        grid.scope = .all
        await grid.reload()
        #expect(grid.total == 0)
        #expect(grid.query == "absent")
    }

    @Test func nativeMarkdownRecognizesListsTablesAndEscapedPipes() {
        let quoted = MarkdownPreview
            .blocks(
                "- Finding [S1P1]\n\n  > First evidence line.\n  > Second evidence line.\n\n  > > Nested quote."
            )
        #expect(quoted == [
            "- Finding [S1P1]",
            "> First evidence line.\n> Second evidence line.",
            "> > Nested quote.",
        ])
        #expect(MarkdownPreview
            .quoteText(quoted[1]) == "First evidence line.\nSecond evidence line.")
        #expect(MarkdownPreview.quoteText(quoted[2]) == "Nested quote.")
        #expect(MarkdownPreview.blocks("Paragraph\n  > Evidence").count == 2)
        #expect(MarkdownPreview
            .blocks("```text\n  > literal quote\n```") == ["```text\n  > literal quote\n```"])
        #expect(MarkdownPreview.blocks("1. First\n2. Second\n\n+ Third") == [
            "1. First",
            "2. Second",
            "+ Third",
        ])
        #expect(MarkdownPreview
            .tableRows("| Name | Value |\n| --- | --- |\n| A\\|B | **42** |") == [
                ["Name", "Value"],
                ["A\\|B", "**42**"],
            ])
        #expect(MarkdownPreview.tableRows("Not a table | just prose") == nil)
        #expect(MarkdownPreview.blocks("```swift\nlet x = 1\n```").count == 1)
    }

    @Test @MainActor func libraryOpeningReusesLoadedRowsAndSearchOnlyReloadsWhenChanged(
    ) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [MarkdownDocument(
            name: "Opening fixture",
            markdown: "Evidence"
        )])
        let grid = DocumentGridModel(store: fixture.store)
        await grid.reloadIfNeeded()
        let generation = grid.generation
        let first = grid.document(at: 0)
        await grid.reloadIfNeeded()
        await grid.reloadIfNeeded()
        #expect(grid.generation == generation)
        #expect(grid.document(at: 0) == first)
        #expect(grid.total == 1)
        grid.query = "absent"
        await grid.reloadIfNeeded()
        #expect(grid.generation == generation + 1)
        #expect(grid.total == 0)
        await grid.reloadIfNeeded()
        #expect(grid.generation == generation + 1)
    }

    @Test func pagesAreBoundedOrderedSearchableAndExcludeDeletedNotes() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let notes = (0 ..< 185).map { index in
            MarkdownDocument(
                name: "Title \(index)",
                markdown: index == 0
                    ? "Unique cobaltbeacon paragraph.\n\nUnique cobaltbeacon paragraph."
                    : "Synthetic content \(index)."
            )
        }
        _ = try await fixture.store.open(seed: notes)
        let first = try await fixture.store.documentPage(limit: 10000)
        #expect(first.documents.count == 80)
        #expect(first.total == 185)
        let second = try await fixture.store.documentPage(offset: 80)
        let last = try await fixture.store.documentPage(offset: 160)
        #expect(last.documents.count == 25)
        let all = first.documents + second.documents + last.documents
        #expect(Set(all.map(\.id)).count == 185)
        #expect(all.first?.id == notes.last?.id)
        let search = try await fixture.store.documentPage(query: "cobalt")
        #expect(search.total == 1)
        #expect(search.documents.first?.id == notes.first?.id)
        #expect(try await fixture.store.documentPage(query: "Title 184").total == 1)
        #expect(try await fixture.store.documentPage(query: "\" OR * --").total == 0)
        let note = try #require(await fixture.store.document(id: notes[0].id))
        try await fixture.store.remove(note)
        #expect(try await fixture.store.documentPage().total == 184)
        #expect(try await fixture.store.documentPage(query: "cobalt").total == 0)
        #expect(try await fixture.store.document(id: note.id) == nil)
    }

    @Test @MainActor func cacheStaysBoundedAndCanScrollBackAndSearch() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: (0 ..< 1200).map {
            MarkdownDocument(name: "Bookmark \($0)", markdown: "Fixture searchable body \($0).")
        }, loadDocuments: false)
        let model = DocumentGridModel(store: fixture.store)
        await model.reload()
        #expect(model.total == 1200)
        for page in 0 ..< 15 {
            model.show(indices: [page * 80])
            await model.waitForPages()
            #expect(model.document(at: page * 80) != nil)
            #expect(model.cachedDocumentCount <= 480)
        }
        #expect(model.document(at: 0) == nil)
        model.show(indices: [0])
        await model.waitForPages()
        #expect(model.document(at: 0)?.name == "Bookmark 1199")
        model.query = "Bookmark 734"
        await model.reload()
        #expect(model.total == 1)
        #expect(model.cachedDocumentCount == 1)
        #expect(model.document(at: 0)?.name == "Bookmark 734")
        model.query = "no-such-document"
        await model.reload()
        #expect(model.total == 0)
        #expect(model.cachedDocumentCount == 0)
    }

    @Test @MainActor func concurrentMutationsInvalidateOffsetPages() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: (0 ..< 100).map {
            MarkdownDocument(name: "Bookmark \($0)", markdown: "Fixture body.")
        })
        let model = DocumentGridModel(store: fixture.store)
        await model.reload()
        let generation = model.generation
        _ = try await fixture.store.save(MarkdownDocument(name: "Newest", markdown: "Fresh body."))
        model.requestPage(1)
        await model.waitForPages()
        #expect(model.generation > generation)
        #expect(model.total == 101)
        #expect(model.document(at: 0)?.name == "Newest")
    }

    @Test func findsDeclaredIconBeforeSanitizingHTML() throws {
        let analysis = try HTMLExtractor.analyze("""
        <html><head><title>Fixture</title><link rel="shortcut icon" href="/assets/icon.png"></head>
        <body><p>Fixture content.</p></body></html>
        """, url: URL(string: "https://example.org/articles/fixture"))
        #expect(analysis.faviconURL?.absoluteString == "https://example.org/assets/icon.png")
        #expect(!analysis.sanitizedHTML.contains("/assets/icon.png"))
    }

    @Test @MainActor func iconsAreValidatedPersistedAndIndependentOfCaptureIdentity() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let source = try #require(URL(string: "https://example.org/article"))
        let iconURL = try #require(URL(string: "https://example.org/site.png"))
        let png = try Self.iconPNG()
        let fetcher = IconFixtureFetcher()
        await fetcher.set(iconURL, data: png)
        let icon = try #require(await FaviconLoader(fetcher: fetcher).load(
            source: source,
            preferred: iconURL
        ))
        #expect(icon.data.count <= 16384)
        #expect(FaviconLoader.thumbnail(Data("not an image".utf8)) == nil)
        #expect(FaviconLoader
            .thumbnail(Data(repeating: 0, count: FaviconLoader.maximumBytes + 1)) == nil)
        let request = CaptureRequest(url: source, identity: "url:fixture-icon", label: "Fixture")
        _ = try await fixture.store.enqueueCapture(request)
        let job = try #require(await fixture.store.claimCapture())
        let document = CapturedDocument(
            title: "Stored icon",
            sourceURL: source,
            coverage: .article,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Retained synthetic article.",
                text: "Retained synthetic article."
            )]
        )
        let noteID = try await fixture.store.publishCapture(
            job,
            document: document,
            artifacts: [],
            favicon: icon
        )
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open(loadDocuments: false)
        let summary = try #require(await reopened.documentPage().documents.first)
        #expect(summary.id == noteID)
        #expect(summary.sourceURL == source)
        #expect(summary.faviconData == icon.data)
        #expect(summary.faviconChecked)
        _ = try await fixture.store.enqueueCapture(request, deduplicate: false)
        let duplicate = try #require(await fixture.store.claimCapture())
        #expect(try await fixture.store.publishCapture(
            duplicate,
            document: document,
            artifacts: []
        ) == noteID)
        #expect(try await fixture.store.documentPage().total == 1)
        #expect(try await fixture.store.documentPage().documents.first?.faviconData == icon.data)
    }

    @Test @MainActor func failedIconFetchFallsBackAndIsNotRetriedAfterReopen() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let source = try #require(URL(string: "https://example.org/article"))
        let fetcher = IconFixtureFetcher()
        _ = try await fixture.store.enqueueCapture(CaptureRequest(
            url: source,
            identity: "fixture:no-icon",
            label: "No icon"
        ))
        let job = try #require(await fixture.store.claimCapture())
        _ = try await fixture.store.publishCapture(job, document: CapturedDocument(
            title: "No icon", sourceURL: source, coverage: .article,
            blocks: [ContentBlock(kind: .paragraph, markdown: "Local body.", text: "Local body.")]
        ), artifacts: [])
        let model = DocumentGridModel(
            store: fixture.store,
            favicons: FaviconLoader(fetcher: fetcher)
        )
        await model.reload()
        model.show(indices: [0])
        await model.faviconTask?.value
        #expect(await fetcher.calls.count == 1)
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open(loadDocuments: false)
        let summary = try #require(await reopened.documentPage().documents.first)
        #expect(summary.faviconChecked)
        #expect(summary.faviconData == nil)
        let restored = DocumentGridModel(store: reopened, favicons: FaviconLoader(fetcher: fetcher))
        await restored.reload()
        restored.show(indices: [0])
        await restored.faviconTask?.value
        #expect(await fetcher.calls.count == 1)
    }

    @Test func migrationRecoversExistingSourceWithoutChangingNotes() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let source = try #require(URL(string: "https://example.org/legacy"))
        _ = try await fixture.store.enqueueCapture(CaptureRequest(
            url: source,
            identity: "fixture:legacy",
            label: "Legacy"
        ))
        let job = try #require(await fixture.store.claimCapture())
        let id = try await fixture.store.publishCapture(job, document: CapturedDocument(
            title: "Legacy article", sourceURL: source, coverage: .article,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Legacy synthetic body.",
                text: "Legacy synthetic body."
            )]
        ), artifacts: [])
        let original = try await fixture.store.document(id: id)
        let database = try DatabaseQueue(path: fixture.store.url.path)
        try await database.write { db in
            // Recreate the older schema, before activity triggers referenced sourceURL.
            try ActivityTestSchema.removeTracking(in: db)
            try db.execute(sql: """
            ALTER TABLE notes DROP COLUMN sourceURL;
            ALTER TABLE notes DROP COLUMN faviconURL;
            ALTER TABLE notes DROP COLUMN faviconData;
            ALTER TABLE notes DROP COLUMN faviconCheckedAt;
            DROP INDEX notes_library_order;
            DELETE FROM grdb_migrations WHERE identifier = 'document-library-v1';
            """)
        }
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open(loadDocuments: false)
        #expect(try await reopened.document(id: id) == original)
        let summary = try #require(await reopened.documentPage().documents.first)
        #expect(summary.sourceURL == source)
        #expect(!summary.faviconChecked)
        #expect(try await reopened.history(for: id).count == 1)
    }

    @Test @MainActor func nativeGridReusesCellsRespondsToWidthAndOpensDocuments() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: (0 ..< 300).map {
            MarkdownDocument(
                name: "A long synthetic bookmark title that should truncate in one line · \($0)",
                markdown: "Fixture body."
            )
        })
        let model = DocumentGridModel(store: fixture.store)
        await model.reload()
        var opened: UUID?
        var deleted: UUID?
        _ = NSApplication.shared
        let host = NSHostingView(rootView: DocumentGridView(
            model: model,
            openNote: { opened = $0 },
            deleteNote: { deleted = $0 },
            canDeleteNotes: true
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let collection = try #require(Self.descendant(NSCollectionView.self, in: host))
        let flow = try #require(collection.collectionViewLayout as? NSCollectionViewFlowLayout)
        #expect(collection.numberOfItems(inSection: 0) == 300)
        #expect(collection.visibleItems().count < 200)
        #expect(flow.itemSize.height == 40)
        #expect(flow.itemSize.width < 200)
        let item = try #require(collection.item(at: IndexPath(item: 0, section: 0)))
        let button = try #require(Self.descendant(NSButton.self, in: item.view))
        button.performClick(nil)
        #expect(opened == model.document(at: 0)?.id)
        opened = nil
        let trash = try #require(Self.button("delete-document", in: item.view))
        let hover = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        item.view.mouseExited(with: hover)
        #expect(trash.isHidden)
        let title = try #require(Self.descendant(NSTextField.self, in: item.view))
        let titleFrame = title.frame
        item.view.mouseEntered(with: hover)
        #expect(!trash.isHidden)
        #expect(trash.isEnabled)
        try await Task.sleep(for: .milliseconds(180))
        #expect(trash.alphaValue == 1)
        #expect(title.frame == titleFrame)
        trash.performClick(nil)
        #expect(deleted == model.document(at: 0)?.id)
        #expect(opened == nil)
        try Self.screenshot(host, name: "gleanary-grid-wide")
        item.view.mouseExited(with: hover)
        #expect(!trash.isEnabled)
        // A new hover must invalidate the previous fade-out completion.
        item.view.mouseEntered(with: hover)
        try await Task.sleep(for: .milliseconds(180))
        #expect(!trash.isHidden)
        #expect(trash.alphaValue == 1)
        item.view.mouseExited(with: hover)
        try await Task.sleep(for: .milliseconds(180))
        #expect(trash.isHidden)
        #expect(trash.alphaValue == 0)
        window.setContentSize(NSSize(width: 900, height: 600))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(flow.itemSize.width > 200)
        #expect(flow.itemSize.height == 40)
        try Self.screenshot(host, name: "gleanary-grid-narrow")
        collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        let shortcut = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false,
            keyCode: 51
        ))
        deleted = nil
        collection.keyDown(with: shortcut)
        #expect(deleted == model.document(at: 0)?.id)
        host.rootView = DocumentGridView(
            model: model,
            openNote: { opened = $0 },
            deleteNote: { deleted = $0 },
            canDeleteNotes: false
        )
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!trash.isEnabled)
        deleted = nil
        trash.performClick(nil)
        collection.keyDown(with: shortcut)
        #expect(deleted == nil)
        let destination = IndexPath(item: 240, section: 0)
        collection.scrollToItems(at: [destination], scrollPosition: .top)
        try await Task.sleep(for: .milliseconds(100))
        await model.waitForPages()
        #expect(model.document(at: 240) != nil)
        #expect(model.cachedDocumentCount <= 480)
        #expect(collection.visibleItems().count < 200)
    }

    @Test @MainActor func libraryBrowserRendersNativeNavigationListAndMarkdownDetail() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let titles = [
            "A practical guide to local-first software",
            "Swift collection view performance",
            "Designing durable document libraries",
            "Notes from the reading group",
            "SQLite full-text search",
            "Typography and information density",
            "Building tools that work offline",
            "The collected papers",
        ]
        let notes = (0 ..< 150).map {
            MarkdownDocument(name: titles[$0 % titles.count], markdown: """
            Local-first tools keep your work available offline.

            ## Key takeaways

            - Keep a local copy of your sources.
            - Use **plain language** to make saved knowledge easy to recall.
            """)
        }
        _ = try await fixture.store.open(seed: notes, loadDocuments: false)
        let latest = try #require(notes.last)
        try await fixture.store.seedExampleCategories()
        let home = try #require(await fixture.store.categories().first { $0.code == "31.04" })
        try await fixture.store.fileNote(latest.id, categoryID: home.id)
        let library = LibraryModel(store: fixture.store)
        library.ready = true
        await library.documentGrid.reload()
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ContentView(
            library: library,
            initialSelection: notes.last?.id
        )
        .preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        // The shell draws its own sidebar beside the content; the sidebar is a native list.
        #expect(Self.descendant(NSTableView.self, in: host) != nil)
        #expect(Self.descendant(NSCollectionView.self, in: host) == nil)
        try Self.screenshot(host, name: "gleanary-library-wide")
        window.setContentSize(NSSize(width: 900, height: 600))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try Self.screenshot(host, name: "gleanary-library-narrow")
        host.rootView = ContentView(library: library, initialSelection: notes.last?.id)
            .preferredColorScheme(.light)
        host.appearance = NSAppearance(named: .aqua)
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1180, height: 780))
        try await Task.sleep(for: .milliseconds(650))
        host.layoutSubtreeIfNeeded()
        try Self.screenshot(host, name: "gleanary-library-light")
    }

    @Test @MainActor func deletingDocumentPurgesPayloadsFilesAndCachedNotices() async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let artifacts = ArtifactStore(root: fixture.root.appending(path: "artifacts"))
        let original = try await artifacts.retain(
            Data("Synthetic original bytes".utf8),
            kind: .html,
            name: "original.html"
        )
        let source = try #require(URL(string: "https://example.org/deletion-fixture"))
        let request = CaptureRequest(
            url: source,
            artifact: original,
            identity: "fixture:purge",
            label: "Delete fixture"
        )
        _ = try await fixture.store.enqueueCapture(request)
        let job = try #require(await fixture.store.claimCapture())
        let icon = try StoredFavicon(url: source, data: Self.iconPNG())
        let id = try await fixture.store.publishCapture(job, document: CapturedDocument(
            title: "Delete fixture", sourceURL: source, coverage: .article,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Synthetic cobaltbeacon body.",
                text: "Synthetic cobaltbeacon body."
            )]
        ), artifacts: [original], favicon: icon)
        let note = try #require(await fixture.store.document(id: id))
        let revision = try #require(note.revision)
        let database = try DatabaseQueue(path: fixture.store.url.path)
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO mind_maps(noteID, revision, version, rootID, generatedAt) VALUES (?, ?, 'fixture', 'fixture-root', 1)",
                arguments: [id.uuidString, revision.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO mind_map_nodes(id, noteID, title, summary, role, ordinal, depth) VALUES ('fixture-root', ?, 'Fixture', 'Synthetic summary', 'root', 0, 0)",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO mind_map_evidence(id, nodeID, noteID, quote, offset) VALUES ('fixture-evidence', 'fixture-root', ?, 'Synthetic quote', 0)",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO mind_map_state(nodeID, noteID, collapsed) VALUES ('fixture-root', ?, 1)",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO graph_layout(nodeID, x, y, pinned) VALUES (?, 1, 2, 0)",
                arguments: [GraphNode.documentID(id)]
            )
        }
        let library = LibraryModel(store: fixture.store, provider: DeletionFixtureEmbedder())
        library.ready = true
        await library.refreshCaptures()
        await library.indexingTask?.value
        #expect(library.documentGrid.document(at: 0)?.faviconData == icon.data)
        _ = try await fixture.store.enqueueCapture(request, deduplicate: false)
        let pending = try #require(await fixture.store.claimCapture())
        try await fixture.store.failCapture(
            pending,
            error: "Synthetic recovery",
            recovery: .browser
        )
        let recovery = try #require(await fixture.store.captureJobs().first { $0.id == pending.id })
        library.browserJob = recovery
        library.audioJob = recovery
        #expect(await library.remove(id))
        await library.indexingTask?.value
        #expect(library.documentCount == 0)
        #expect(library.documentGrid.cachedDocumentCount == 0)
        #expect(library.captureNotice == nil)
        #expect(library.browserJob == nil)
        #expect(library.audioJob == nil)
        #expect(library.captureJobs.isEmpty)
        await #expect(throws: CaptureError.self) { try await artifacts.data(for: original) }
        try await database.read { db in
            for table in ["notes", "note_revisions", "local_changes", "captures", "content_blocks",
                          "sources", "artifacts", "artifact_deletions", "ingestion_jobs",
                          "passages",
                          "index_jobs", "embeddings", "graph_nodes", "graph_node_fts",
                          "graph_edges",
                          "graph_evidence", "graph_jobs", "graph_links", "graph_layout",
                          "graph_passage_cache", "graph_decisions", "mind_maps", "mind_map_nodes",
                          "mind_map_evidence", "mind_map_state"]
            {
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")
                #expect(count == 0)
            }
            let markers = try Int.fetchOne(db, sql: "SELECT count(*) FROM purged_notes")
            #expect(markers == 1)
        }
        #expect(try await fixture.store.documentPage(query: "cobaltbeacon").total == 0)
        await #expect(throws: GleanaryError.self) { try await fixture.store.save(note) }
    }

    @Test @MainActor func deletingAnOlderNoteInvalidatesOffsetPagesEvenWhenMaxSequenceIsUnchanged(
    ) async throws {
        let fixture = try LibraryFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: (0 ..< 100).map {
            MarkdownDocument(name: "Fixture \($0)", markdown: "Synthetic body.")
        })
        let model = DocumentGridModel(store: fixture.store)
        await model.reload()
        let generation = model.generation
        let sequence = try await fixture.store.libraryChangeSequence()
        let oldest = try #require(notes.first { $0.name == "Fixture 0" })
        _ = try await fixture.store.permanentlyRemove(oldest)
        #expect(try await fixture.store.libraryChangeSequence() == sequence)
        model.requestPage(1)
        await model.waitForPages()
        #expect(model.generation > generation)
        #expect(model.total == 99)
    }

    @MainActor private static func expectMultipleColumns(in collection: NSCollectionView) throws {
        let layout = try #require(collection.collectionViewLayout)
        let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let second = try #require(layout.layoutAttributesForItem(at: IndexPath(
            item: 1,
            section: 0
        )))
        #expect(first.frame.minY == second.frame.minY)
        #expect(second.frame.minX > first.frame.minX)
    }

    @MainActor private static func button(_ identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           button.accessibilityIdentifier() == identifier
        {
            return button
        }
        return view.subviews.lazy.compactMap { button(identifier, in: $0) }.first
    }

    @MainActor private static func iconPNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for x in 0 ..< 32 {
            for y in 0 ..< 32 {
                bitmap.setColor(
                    NSColor(calibratedRed: 1, green: 0.5, blue: 0.1, alpha: 1),
                    atX: x,
                    y: y
                )
            }
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    @MainActor private static func screenshot(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = ProcessInfo.processInfo.environment["GLEANARY_LIBRARY_SCREENSHOTS"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appending(path: "\(name).png"))
    }

    @MainActor private static func renderLibrary(
        _ library: LibraryModel,
        selected: UUID,
        name: String
    ) async throws {
        guard ProcessInfo.processInfo.environment["GLEANARY_LIBRARY_SCREENSHOTS"] != nil
        else { return }
        let preview = DocumentPreviewModel()
        preview.selectedID = selected
        await preview.load(from: library.store)
        #expect(preview.document?.id == selected)
        let host = NSHostingView(rootView: ContentView(
            library: library,
            initialSelection: selected,
            previewModel: preview
        )
        .preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(650))
        host.layoutSubtreeIfNeeded()
        try screenshot(host, name: name)
    }
}

@MainActor private final class FilingBaselineMeasurements {
    var values: [String: CGFloat] = [:]
}

private struct FilingBaselineProbe: View {
    let measurements: FilingBaselineMeasurements
    private let baseline = Alignment(horizontal: .leading, vertical: .firstTextBaseline)

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Filed in").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    .overlay(alignment: baseline) { marker("label") }
                VStack(alignment: .leading, spacing: 8) {
                    ChipFlow(spacing: 8) {
                        CategoryChip(category: DecimalCategory(
                            id: UUID(), code: "15", name: "Tools & software"
                        ))
                        .overlay(alignment: baseline) { marker("chip") }
                        Button("Change…") {}.buttonStyle(.link)
                            .overlay(alignment: baseline) { marker("change") }
                        Button {} label: { Label("Suggest", systemImage: "sparkles") }
                            .buttonStyle(.link)
                            .overlay(alignment: baseline) { marker("suggest") }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout).padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "filing-baselines")
    }

    private func marker(_ name: String) -> some View {
        Color.clear.frame(width: 1, height: 1)
            .alignmentGuide(.firstTextBaseline) { _ in 0 }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("filing-baselines")).minY
            } action: { measurements.values[name] = $0 }
    }
}

private struct LibraryCachePageProbe: View {
    let grid: DocumentGridModel
    let arrived: (UUID) -> Void
    @State private var selection: Set<UUID> = []

    var body: some View {
        List(selection: $selection) {
            ForEach(80 ..< 85, id: \.self) { index in
                let document = grid.document(at: index)
                Text(document?.name ?? "Loading…").tag(document?.id)
                    .onChange(of: document?.id) { _, id in
                        if let id {
                            arrived(id)
                        }
                    }
            }
        }
    }
}
