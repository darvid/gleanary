import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

private struct SummaryNotesFixture {
    let root: URL
    let store: DocumentStore

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }

    func source(_ name: String = "one", local: Bool = false) async throws -> MarkdownDocument {
        let url = try #require(URL(string: "https://fixture.example/\(name)"))
        _ = try await store.enqueueCapture(CaptureRequest.webLink(url))
        let job = try #require(await store.claimCapture())
        let captured = CapturedDocument(
            title: "Synthetic source \(name)", sourceURL: local ? nil : url, coverage: .article,
            blocks: [.init(
                kind: .paragraph,
                markdown: "Retained evidence for \(name).",
                text: "Retained evidence for \(name)."
            )]
        )
        let id = try await store.publishCapture(job, document: captured, artifacts: [])
        return try #require(await store.document(id: id))
    }
}

private actor SummaryNotesProbe: LinkSummarizing {
    nonisolated let engineName = "Synthetic fixture"
    var calls = 0
    let held: Bool
    var continuation: CheckedContinuation<Void, Never>?

    init(held: Bool = false) {
        self.held = held
    }

    func summarize(_: CapturedDocument) async throws -> String {
        calls += 1
        if held {
            await withCheckedContinuation { continuation = $0 }
        }
        return "A supported synthetic summary."
    }

    func release() {
        continuation?.resume(); continuation = nil
    }
}

@Suite(.serialized)
struct SummaryNotesTests {
    @Test @MainActor func sourceNavigationDoesNotOfferTheSourceAlreadyBeingRead() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let source = try await fixture.source()
        let preview = DocumentPreviewModel()
        preview.selectedID = source.id
        await preview.load(from: fixture.store)
        #expect(preview.citation != nil)
        #expect(!preview.canViewCapturedSource)
        #expect(preview.summaries.isEmpty)

        let engine = IngestionEngine(store: fixture.store, summarizer: SummaryNotesProbe())
        let summary = try await engine.createSummaryNote(source)
        await preview.load(from: fixture.store)
        #expect(!preview.canViewCapturedSource)
        #expect(preview.summaries.map(\.id) == [summary.id])

        var edited = source
        edited.markdown += "\n\nA personal annotation."
        _ = try await fixture.store.save(edited)
        await preview.load(from: fixture.store)
        #expect(preview.canViewCapturedSource)
        preview.showsCapturedSource = true
        await preview.load(from: fixture.store)
        #expect(!preview.canViewCapturedSource)
        #expect(preview.displayedMarkdown == source.markdown)
    }

    @Test @MainActor func generationCreatesAnEditableSummaryWithoutReplacingTheSource(
    ) async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let original = try await fixture.source()
        let captureID = try #require(await fixture.store.captureID(for: original.id))
        let capture = try await fixture.store.captureDetail(id: captureID)
        let probe = SummaryNotesProbe()
        let engine = IngestionEngine(store: fixture.store, summarizer: probe)
        let summary = try await engine.createSummaryNote(original)
        #expect(summary.id != original.id)
        #expect(summary.markdown == "A supported synthetic summary.")
        #expect(try await fixture.store.document(id: original.id) == original)
        #expect(try await fixture.store.history(for: original.id).count == 1)
        #expect(try await fixture.store.captureDetail(id: captureID).artifacts == capture.artifacts)
        #expect(try await fixture.store.libraryItemDetails(for: summary.id).kind == "summary")
        #expect(try await fixture.store.libraryAuthorProvider(for: summary.id) == probe.engineName)
        #expect(try await fixture.store.librarySources(for: summary.id).map(\.id) == [original.id])
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open()
        #expect(try await reopened.librarySummaries(for: original.id).map(\.id) == [summary.id])
        let preview = DocumentPreviewModel()
        preview.selectedID = original.id
        await preview.load(from: reopened)
        #expect(!preview.canGenerateSummary)
        #expect(preview.summaries.map(\.id) == [summary.id])
        #expect(preview.displayedMarkdown == original.markdown)
        await #expect(throws: LinkSummaryError.alreadySummarized) {
            try await engine.createSummaryNote(original)
        }
        await #expect(throws: LinkSummaryError.alreadySummarized) {
            try await engine.summarizeExisting(original)
        }
        #expect(await probe.calls == 1)
        var edit = summary
        edit.markdown += "\n\nA human annotation."
        let edited = try await reopened.save(edit)
        #expect(try await reopened.librarySummaries(for: original.id).map(\.id) == [edited.id])
        #expect(try await reopened.document(id: original.id) == original)
    }

    @Test func verifiedSummaryFirstCapturesKeepTheirTypeAcrossMigrationAndEdits() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let url = try #require(URL(string: "https://fixture.example/legacy"))
        _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(url))
        let job = try #require(await fixture.store.claimCapture())
        let summary = "An existing generated summary."
        let artifactStore = ArtifactStore(root: fixture.root.appending(path: "artifacts"))
        let artifact = try await artifactStore.retain(
            Data(summary.utf8),
            kind: .markdown,
            name: "Summary.md"
        )
        let captured = CapturedDocument(
            title: "Historical source", sourceURL: url, coverage: .article,
            blocks: [.init(
                kind: .paragraph,
                markdown: "Retained original text.",
                text: "Retained original text."
            )]
        )
        let id = try await fixture.store.publishCapture(
            job,
            document: captured,
            artifacts: [artifact],
            summary: summary
        )
        // Recreate the previous schema in this disposable fixture, retaining the legacy data.
        try await DatabaseQueue(path: fixture.store.url.path).write { db in
            try db.execute(sql: """
            DROP INDEX note_sources_summaries;
            ALTER TABLE note_sources DROP COLUMN summaryRole;
            DELETE FROM grdb_migrations WHERE identifier = 'explicit-summary-role-v1';
            UPDATE notes SET summaryEngine = NULL WHERE id = ?;
            """, arguments: [id.uuidString])
        }
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open()
        #expect(try await reopened.explicitSummaryIDs(for: id) == [id])
        var edited = try #require(await reopened.document(id: id))
        edited.markdown = "A human-edited summary."
        edited = try await reopened.save(edited)
        #expect(try await reopened.libraryItemDetails(for: id).kind == "summary")
        #expect(try await reopened.librarySummaries(for: id).map(\.id) == [id])
        #expect(try await reopened.summaryNoteInput(for: edited, createAnother: true).document
            .markdown == captured.markdown)
        let probe = SummaryNotesProbe()
        let engine = IngestionEngine(store: reopened, summarizer: probe)
        await #expect(throws: LinkSummaryError.alreadySummarized) {
            try await engine.createSummaryNote(edited)
        }
        #expect(await probe.calls == 0)
        _ = try await engine.createSummaryNote(edited, createAnother: true)
        #expect(try await reopened.document(id: id) == edited)
    }

    @Test func anotherSummaryRequiresAnExplicitOptIn() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let source = try await fixture.source()
        let probe = SummaryNotesProbe()
        let engine = IngestionEngine(store: fixture.store, summarizer: probe)
        let first = try await engine.createSummaryNote(source)
        await #expect(throws: LinkSummaryError.alreadySummarized) {
            try await engine.createSummaryNote(source)
        }
        let second = try await engine.createSummaryNote(source, createAnother: true)
        #expect(first.id != second.id)
        #expect(first.name != second.name)
        #expect(try await fixture.store.document(id: first.id) == first)
        #expect(try await fixture.store.document(id: source.id) == source)
        #expect(try await fixture.store.librarySummaries(for: source.id).count == 2)
        #expect(await probe.calls == 2)
    }

    @Test func summaryRolesArePerSourceAndReversibleWithoutRewritingTheNote() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let first = try await fixture.source("first")
        let second = try await fixture.source("second")
        let note = try await fixture.store.save(MarkdownDocument(
            name: "Existing note",
            markdown: "User-written synthesis."
        ))
        // A plain provenance link to another source is not a summary association.
        let secondSource = try #require(await fixture.store.researchSource(noteID: second.id)
            .sourceIDs.first)
        try await DatabaseQueue(path: fixture.store.url.path).write { db in
            try db.execute(
                sql: "INSERT INTO note_sources(noteID, sourceID) VALUES (?, ?)",
                arguments: [note.id.uuidString, secondSource.uuidString]
            )
        }
        try await fixture.store.associateSummary(note.id, with: first.id)
        #expect(try await fixture.store.librarySummaries(for: first.id).map(\.id) == [note.id])
        #expect(try await fixture.store.librarySummaries(for: second.id).isEmpty)
        #expect(try await fixture.store.document(id: note.id) == note)
        #expect(try await fixture.store.history(for: note.id).count == 1)
        #expect(try await fixture.store.libraryItemDetails(for: note.id).kind == "summary")
        #expect(try await fixture.store.libraryAuthorProvider(for: note.id) == "user")
        try await fixture.store.associateSummary(note.id, with: second.id)
        try await fixture.store.associateSummary(note.id, with: first.id, enabled: false)
        #expect(try await fixture.store.librarySummaries(for: first.id).isEmpty)
        #expect(try await fixture.store.librarySummaries(for: second.id).map(\.id) == [note.id])
        try await fixture.store.associateSummary(note.id, with: second.id, enabled: false)
        #expect(try await fixture.store.libraryItemDetails(for: note.id).kind == "note")
        #expect(try await fixture.store.librarySources(for: note.id).count == 2)
        #expect(try await fixture.store.document(id: note.id) == note)
        await #expect(throws: LinkSummaryError.editedCapture) {
            try await fixture.store.associateSummary(first.id, with: first.id)
        }
        await #expect(throws: LinkSummaryError.editedCapture) {
            try await fixture.store.associateSummary(first.id, with: second.id)
        }
    }

    @Test func archivedSummariesBlockDuplicatesButDeletedSummariesDoNot() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let source = try await fixture.source()
        let probe = SummaryNotesProbe()
        let engine = IngestionEngine(store: fixture.store, summarizer: probe)
        let summary = try await engine.createSummaryNote(source)
        try await fixture.store.archive(summary.id, reason: "Synthetic archive")
        await #expect(throws: LinkSummaryError.alreadySummarized) {
            try await engine.createSummaryNote(source)
        }
        #expect(await probe.calls == 1)
        try await fixture.store.remove(summary)
        _ = try await engine.createSummaryNote(source)
        #expect(await probe.calls == 2)
        #expect(try await fixture.store.librarySummaries(for: source.id).count == 1)
    }

    @Test func anAssociationMadeDuringGenerationPreventsDuplicatePublication() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let source = try await fixture.source()
        let note = try await fixture.store.save(MarkdownDocument(
            name: "Existing summary",
            markdown: "Saved synthesis."
        ))
        let probe = SummaryNotesProbe(held: true)
        let engine = IngestionEngine(store: fixture.store, summarizer: probe)
        let worker = Task { try await engine.createSummaryNote(source) }
        try await waitForSummary(probe)
        try await fixture.store.associateSummary(note.id, with: source.id)
        await probe.release()
        await #expect(throws: LinkSummaryError.alreadySummarized) { try await worker.value }
        #expect(try await fixture.store.librarySummaries(for: source.id).map(\.id) == [note.id])
        #expect(try await fixture.store.documents().count == 2)
        #expect(try await fixture.store.document(id: source.id) == source)
    }

    @Test func cancellationAndStaleSourcesCannotPublishANewSummary() async throws {
        for cancelled in [true, false] {
            let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
            let source = try await fixture.source()
            let probe = SummaryNotesProbe(held: true)
            let engine = IngestionEngine(store: fixture.store, summarizer: probe)
            let worker = Task { try await engine.createSummaryNote(source) }
            try await waitForSummary(probe)
            if cancelled {
                worker.cancel()
            } else {
                var edit = source
                edit.markdown = "A newer human edit."
                _ = try await fixture.store.save(edit)
            }
            await probe.release()
            if cancelled {
                await #expect(throws: CancellationError.self) { try await worker.value }
            } else {
                await #expect(throws: GleanaryError.self) { try await worker.value }
            }
            #expect(try await fixture.store.librarySummaries(for: source.id).isEmpty)
            #expect(try await fixture.store.documents().count == 1)
        }
    }

    @Test @MainActor func localCapturesAlsoSupportSummaryNotes() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let source = try await fixture.source("local", local: true)
        let preview = DocumentPreviewModel()
        preview.selectedID = source.id
        await preview.load(from: fixture.store)
        #expect(preview.canGenerateSummary)
        let engine = IngestionEngine(store: fixture.store, summarizer: SummaryNotesProbe())
        let summary = try await engine.createSummaryNote(source)
        #expect(try await fixture.store.librarySummaries(for: source.id).map(\.id) == [summary.id])
        #expect(try await fixture.store.document(id: source.id) == source)
    }

    @Test func removingAnExplicitRoleDoesNotReclassifyOtherSourcesAsSummaries() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let first = try await fixture.source("first")
        let second = try await fixture.source("second")
        let source = try await fixture.store.researchSource(noteID: first.id)
        let task = try await fixture.store.beginConversation(
            "Synthetic summary",
            owner: .researcher
        )
        let summary = try await fixture.store.saveResearch(
            "A verified synthetic summary.", name: "Original summary", sources: [source],
            taskID: task, provider: "fixture"
        )
        try await fixture.store.associateSummary(summary.id, with: second.id)
        #expect(try await fixture.store.librarySummaries(for: second.id).map(\.id) == [summary.id])
        try await fixture.store.associateSummary(summary.id, with: second.id, enabled: false)
        #expect(try await fixture.store.librarySummaries(for: second.id).isEmpty)
        #expect(try await fixture.store.librarySummaries(for: first.id).map(\.id) == [summary.id])
        #expect(try await fixture.store.libraryItemDetails(for: summary.id).kind == "summary")
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_SUMMARY_NAVIGATION_SCREENSHOTS"] != nil))
    @MainActor func summaryNavigationLayouts() async throws {
        let fixture = try await SummaryNotesFixture(); defer { fixture.clean() }
        let source = try await fixture.source()
        let reference = try await fixture.store.save(MarkdownDocument(
            name: "Synthetic knowledge note",
            markdown: "[Source documentation](https://fixture.example/one)"
        ))
        let engine = IngestionEngine(store: fixture.store, summarizer: SummaryNotesProbe())
        _ = try await engine.createSummaryNote(source)
        let preview = DocumentPreviewModel()
        preview.selectedID = source.id
        await preview.load(from: fixture.store)
        let model = LinkedSourcesModel()
        await model.load(reference, from: fixture.store)
        #expect(model.sources.first?.noteID == source.id)
        #expect(model.sources.first?.summaries.count == 1)
        let library = LibraryModel(store: fixture.store)
        library.ready = true
        for dark in [false, true] {
            for width in [320.0, 680.0] {
                let suffix = "\(Int(width))-\(dark ? "dark" : "light")"
                try await snapshot(DocumentPreview(
                    model: preview, summaryEnabled: true,
                    createAnotherSummary: { library.generateSummary(for: $0, createAnother: true) },
                    showsLibraryDetails: true
                ), name: "source-\(suffix)", size: NSSize(width: width, height: 800), dark: dark)
                try await snapshot(
                    LinkedSourcesView(document: reference, context: LinkedSourceContext(
                        store: fixture.store, revision: "fixture", canAdd: true,
                        add: { _, _, _ in throw CaptureError.downloadFailed }
                    ), openDocument: { _ in }, model: model),
                    name: "linked-\(suffix)",
                    size: NSSize(width: width, height: 250),
                    dark: dark
                )
            }
            try await snapshot(
                SummaryAssociationView(store: fixture.store, sourceID: source.id),
                name: "associate-\(dark ? "dark" : "light")",
                size: NSSize(width: 560, height: 520),
                dark: dark
            )
        }
    }

    @MainActor private func snapshot(
        _ view: some View, name: String, size: NSSize, dark: Bool
    ) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
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
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory =
            try URL(fileURLWithPath: #require(ProcessInfo.processInfo
                    .environment["GLEANARY_SUMMARY_NAVIGATION_SCREENSHOTS"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).png"))
    }

    private func waitForSummary(_ probe: SummaryNotesProbe) async throws {
        for _ in 0 ..< 100 {
            if await probe.calls > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Synthetic summary did not start")
        throw LinkSummaryError.failed
    }
}
