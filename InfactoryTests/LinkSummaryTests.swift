import AppKit
import Foundation
import FoundationModels
import GRDB
@testable import Infactory
import SwiftUI
import Testing

struct FixtureLinkSummarizer: LinkSummarizing {
    func summarize(_: CapturedDocument) async throws -> String {
        "A brief synthetic summary.\n\n## Key takeaways\n\n- Keep the original evidence."
    }
}

private actor SummaryProbe: LinkSummarizing {
    nonisolated let engineName = "Fixture model"
    var documents: [CapturedDocument] = []
    var unavailable = false
    func setUnavailable(_ value: Bool) {
        unavailable = value
    }

    func summarize(_ document: CapturedDocument) throws -> String {
        documents.append(document)
        if unavailable {
            throw LinkSummaryError.unavailable
        }
        return "Local-first tools keep your work available offline.\n\n## Key takeaways\n\n- Store evidence locally."
    }
}

private actor WaitingSummary: LinkSummarizing {
    var started = false

    func summarize(_: CapturedDocument) async throws -> String {
        started = true
        try await Task.sleep(for: .seconds(10))
        return "A summary that must not be published after cancellation."
    }
}

private actor HeldSummary: LinkSummarizing {
    var started = false
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false

    func summarize(_: CapturedDocument) async -> String {
        started = true
        if finished {
            return "A generated summary."
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        finished = true
        continuation?.resume(returning: "A generated summary.")
        continuation = nil
    }
}

private struct SummaryGraphFixture: GraphExtracting {
    func extract(_: String) async throws -> GraphProposal {
        GraphProposal(entities: [], relations: [])
    }
}

private struct SummaryEmbeddingFixture: EmbeddingProviding {
    func profile() async throws -> EmbeddingProfile {
        EmbeddingProfile(model: "synthetic-summary-test", revision: 1, dimensions: 2)
    }

    func vector(for _: String, profile _: EmbeddingProfile) async throws -> [Float] {
        [1, 0]
    }
}

private actor SummaryFetcher: SourceFetching {
    var calls = 0
    func fetch(_ url: URL) throws -> DownloadedContent {
        calls += 1
        return DownloadedContent(
            data: Data(
                "<!doctype html><html><head><title>Local-first tools</title></head><body><article><p>Local-first tools keep documents on your device. The unique source term cobaltbeacon remains searchable with its original citation.</p></article></body></html>"
                    .utf8
            ),
            url: url, mime: "text/html", encoding: "utf-8"
        )
    }
}

@Suite(.serialized) struct LinkSummaryTests {
    @Test @MainActor func linkSummaryIsPrimaryButSourceEvidenceSurvivesReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let probe = SummaryProbe()
        let engine = IngestionEngine(store: store, fetcher: SummaryFetcher(), summarizer: probe)
        _ = try await engine.enqueue("https://example.org/article")
        try await engine.run()
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .ready)
        let id = try #require(job.noteID)
        let note = try #require(await store.document(id: id))
        #expect(note.markdown.hasPrefix("Local-first tools"))
        #expect(!note.markdown.contains("cobaltbeacon"))
        let detail = try await store.captureDetail(id: #require(await store.captureID(for: id)))
        #expect(detail.document.markdown.contains("cobaltbeacon"))
        #expect(detail.artifacts.map(\.kind) == [.html, .markdown])
        let summaryArtifact = try #require(detail.artifacts.last)
        let artifacts = ArtifactStore(root: root.appending(path: "artifacts"))
        #expect(try await artifacts.data(for: summaryArtifact) == Data(note.markdown.utf8))
        let reopened = DocumentStore(url: store.url)
        _ = try await reopened.open()
        #expect(try await reopened.document(id: id)?.markdown == note.markdown)
        let preview = DocumentPreviewModel()
        preview.selectedID = id
        await preview.load(from: reopened)
        #expect(preview.generatedSummary)
        #expect(preview.authorProvider == "Fixture model")
        #expect(preview.citation?.captureID == detail.id)
        let snapshot = try await reopened.searchSnapshot(query: "cobaltbeacon", candidateLimit: 10)
        let passage = try #require(snapshot.passages.first { $0.text.contains("cobaltbeacon") })
        #expect(passage.citation?.captureID == detail.id)
        #expect(await probe.documents.count == 1)
        _ = try await engine.enqueue("https://example.org/article")
        try await engine.run()
        #expect(await probe.documents.count == 1)
    }

    @Test @MainActor func unavailableModelSavesFullTextAndSummarizesLater() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let probe = SummaryProbe(), fetcher = SummaryFetcher()
        await probe.setUnavailable(true)
        let engine = IngestionEngine(store: store, fetcher: fetcher, summarizer: probe)
        _ = try await engine.enqueue("https://example.org/article")
        try await engine.run()
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .ready)
        #expect(job.progress.contains("without a summary"))
        #expect(job.progress.contains(LinkSummaryError.unavailable.localizedDescription))
        let id = try #require(job.noteID)
        let saved = try #require(await store.document(id: id))
        #expect(saved.markdown.contains("cobaltbeacon"))
        let preview = DocumentPreviewModel()
        preview.selectedID = id
        await preview.load(from: store)
        #expect(preview.canGenerateSummary)
        await probe.setUnavailable(false)
        let summarized = try await engine.summarizeExisting(saved)
        #expect(!summarized.markdown.contains("cobaltbeacon"))
        #expect(try await store.libraryAuthorProvider(for: id) == "Fixture model")
        // The second request is for the favicon; summarizing later never refetches the article.
        #expect(await fetcher.calls == 2)
    }

    @Test func cancellationDuringSummarizationNeverPublishesANote() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let summarizer = WaitingSummary()
        let engine = IngestionEngine(
            store: store,
            fetcher: SummaryFetcher(),
            summarizer: summarizer
        )
        let id = try await engine.enqueue("https://example.org/article")
        let worker = Task { try await engine.run() }
        for _ in 0 ..< 100 {
            if await summarizer.started {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await summarizer.started)
        try await engine.cancel(id)
        try await worker.value
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .cancelled)
        #expect(job.acquired.count == 1)
        #expect(try await store.documents().isEmpty)
    }

    @Test @MainActor func existingCaptureGetsSummaryWithoutDownloadingOrLosingEvidence(
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let original = try await Self.legacyCapture(in: store)
        let captureID = try #require(await store.captureID(for: original.id))
        let before = try await store.captureDetail(id: captureID)
        let preview = DocumentPreviewModel()
        preview.selectedID = original.id
        await preview.load(from: store)
        #expect(preview.canGenerateSummary)
        #expect(!preview.generatedSummary)
        let fetcher = SummaryFetcher(), probe = SummaryProbe()
        let engine = IngestionEngine(store: store, fetcher: fetcher, summarizer: probe)
        let saved = try await engine.summarizeExisting(original)
        #expect(saved.id == original.id)
        #expect(saved.name == original.name)
        #expect(saved.revision != original.revision)
        #expect(!saved.markdown.contains("cobaltbeacon"))
        #expect(await fetcher.calls == 0)
        #expect(await probe.documents.first?.markdown == original.markdown)
        let after = try await store.captureDetail(id: captureID)
        #expect(try after.document.fingerprint == before.document.fingerprint)
        #expect(after.artifacts.count == before.artifacts.count + 1)
        let history = try await store.history(for: original.id)
        #expect(history.count == 2)
        #expect(history.contains { $0.markdown == original.markdown })
        let reopened = DocumentStore(url: store.url)
        _ = try await reopened.open()
        #expect(try await reopened.document(id: saved.id) == saved)
        await preview.load(from: reopened)
        #expect(preview.generatedSummary)
        #expect(!preview.canGenerateSummary)
        let snapshot = try await reopened.searchSnapshot(query: "cobaltbeacon", candidateLimit: 10)
        let match = try #require(snapshot.passages.first { $0.text.contains("cobaltbeacon") })
        #expect(match.citation?.captureID == captureID)
        #expect(try await reopened.captureJobs().count == 1)
        await #expect(throws: LinkSummaryError.self) { try await engine.summarizeExisting(saved) }
        #expect(await probe.documents.count == 1)
    }

    @Test @MainActor func existingSummaryFailureIsRetryableAndCancelKeepsTheSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let original = try await Self.legacyCapture(in: store)
        let probe = SummaryProbe()
        await probe.setUnavailable(true)
        let library = LibraryModel(
            store: store,
            provider: SummaryEmbeddingFixture(),
            graphProvider: SummaryGraphFixture(),
            summarizer: probe
        )
        library.ready = true
        library.generateSummary(for: original)
        #expect(library.busy)
        #expect(library.generatingSummaryID == original.id)
        await library.summaryTask?.value
        #expect(!library.busy)
        #expect(library.canGenerateSummaries)
        #expect(library.error == LinkSummaryError.unavailable.localizedDescription)
        #expect(try await store.document(id: original.id) == original)
        #expect(try await store.history(for: original.id).count == 1)
        await probe.setUnavailable(false)
        library.generateSummary(for: original)
        await library.summaryTask?.value
        await library.indexingTask?.value
        #expect(library.error == nil)
        #expect(try await store.document(id: original.id)?.revision != original.revision)

        let other = try await Self.legacyCapture(in: store)
        let waiting = WaitingSummary()
        let cancelling = LibraryModel(store: store, summarizer: waiting)
        cancelling.ready = true
        cancelling.generateSummary(for: other)
        for _ in 0 ..< 100 {
            if await waiting.started {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waiting.started)
        cancelling.cancelSummary()
        await cancelling.summaryTask?.value
        #expect(cancelling.generatingSummaryID == nil)
        #expect(!cancelling.busy)
        #expect(cancelling.error == nil)
        #expect(try await store.document(id: other.id) == other)
    }

    @Test func generationCannotOverwriteAnEditedCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        var original = try await Self.legacyCapture(in: store)
        original.markdown = "A human-edited note."
        let edited = try await store.save(original)
        let probe = SummaryProbe()
        let engine = IngestionEngine(store: store, summarizer: probe)
        await #expect(throws: LinkSummaryError.self) { try await engine.summarizeExisting(edited) }
        #expect(await probe.documents.isEmpty)
        #expect(try await store.document(id: edited.id) == edited)
    }

    @Test func concurrentEditsRejectAStaleSummaryAndQueueUnusedArtifactCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let original = try await Self.legacyCapture(in: store)
        let held = HeldSummary()
        let engine = IngestionEngine(store: store, summarizer: held)
        let worker = Task { try await engine.summarizeExisting(original) }
        try await Self.waitForSummary(held)
        var edit = original
        edit.markdown = "A newer human edit."
        let saved = try await store.save(edit)
        await held.finish()
        await #expect(throws: InfactoryError.self) { try await worker.value }
        #expect(try await store.document(id: saved.id) == saved)
        #expect(try await store.history(for: saved.id).count == 2)
        #expect(try await store.hasPendingArtifactDeletions())
        #expect(try await store.collectDeletedArtifacts() == 0)
        let artifact = try await engine.artifacts.fileURL(ContentHash.of("A generated summary."))
        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func failedSummaryPublicationRollsBackTheNoteCaptureAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let original = try await Self.legacyCapture(in: store)
        let captureID = try #require(await store.captureID(for: original.id))
        let database = try DatabaseQueue(path: store.url.path)
        try await database.write { db in
            try db.execute(sql: """
            CREATE TRIGGER fail_summary BEFORE UPDATE ON notes BEGIN
                SELECT RAISE(ABORT, 'Synthetic summary publication failure');
            END;
            """)
        }
        let engine = IngestionEngine(store: store, summarizer: FixtureLinkSummarizer())
        await #expect(throws: DatabaseError.self) { try await engine.summarizeExisting(original) }
        #expect(try await store.document(id: original.id) == original)
        #expect(try await store.history(for: original.id).count == 1)
        #expect(try await store.captureDetail(id: captureID).artifacts.count == 1)
        #expect(try await store.summarySource(for: original).id == captureID)
        #expect(try await store.collectDeletedArtifacts() == 0)
    }

    @Test func deletionDuringGenerationDoesNotResurrectTheNote() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let original = try await Self.legacyCapture(in: store)
        let held = HeldSummary()
        let engine = IngestionEngine(store: store, summarizer: held)
        let worker = Task { try await engine.summarizeExisting(original) }
        try await Self.waitForSummary(held)
        _ = try await store.permanentlyRemove(original)
        await held.finish()
        await #expect(throws: InfactoryError.self) { try await worker.value }
        #expect(try await store.document(id: original.id) == nil)
        #expect(try await store.documents().isEmpty)
        #expect(try await store.collectDeletedArtifacts() == 0)
    }

    @Test @MainActor func previewActionGeneratesSummaryAndRefreshesReadOnlyContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let original = try await Self.legacyCapture(in: store)
        let preview = DocumentPreviewModel()
        preview.selectedID = original.id
        await preview.load(from: store)
        let library = LibraryModel(
            store: store,
            provider: SummaryEmbeddingFixture(),
            graphProvider: SummaryGraphFixture(),
            summarizer: FixtureLinkSummarizer()
        )
        library.ready = true
        _ = NSApplication.shared
        let view = DocumentPreview(
            model: preview,
            summaryEnabled: true,
            generateSummary: { library.generateSummary(for: $0) }
        )
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(preview.canGenerateSummary)
        try Self.screenshot(host, name: "infactory-generate-summary-before")
        host.rootView = DocumentPreview(model: preview, generatingSummary: true)
            .preferredColorScheme(.dark)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try Self.screenshot(host, name: "infactory-generate-summary-progress")
        window.setContentSize(NSSize(width: 320, height: 500))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try Self.screenshot(host, name: "infactory-generate-summary-progress-narrow")
        window.setContentSize(NSSize(width: 600, height: 500))
        host.rootView = view.preferredColorScheme(.dark)
        view.generateSummary(original)
        await library.summaryTask?.value
        await library.indexingTask?.value
        await preview.load(from: store)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(preview.generatedSummary)
        #expect(!preview.canGenerateSummary)
        try Self.screenshot(host, name: "infactory-generate-summary-after")
        #expect(try await store.document(id: original.id)?.markdown
            .hasPrefix("A brief synthetic summary.") == true)
    }

    @Test func pastedTextDoesNotNeedAppleIntelligence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let probe = SummaryProbe()
        await probe.setUnavailable(true)
        let engine = IngestionEngine(store: store, summarizer: probe)
        _ = try await engine.enqueue("A thought to keep verbatim.")
        try await engine.run()
        #expect(try await store.documents().first?.markdown == "A thought to keep verbatim.")
        #expect(await probe.documents.isEmpty)
    }

    @Test func chunkingPreservesTheWholeSourceAndMarkdownKeepsItsStructure() {
        let source = String(repeating: "Evidence 👩🏽‍💻.\n", count: 1500)
        let chunks = AppleLinkSummarizer.chunks(source, limit: 6000)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == source)
        #expect(chunks.allSatisfy { $0.count <= 6000 })
        #expect(MarkdownPreview
            .blocks("Main point.\n\n## Key takeaways\n\n- First.\n- Second.") == [
                "Main point.",
                "## Key takeaways",
                "- First.",
                "- Second.",
            ])
        #expect(MarkdownPreview.blocks("```swift\nlet x = 1\n\nlet y = 2\n```") == [
            "```swift\nlet x = 1\n\nlet y = 2\n```",
        ])
    }

    @Test func numberedEvidencePreservesPDFLineBreaksWithoutModelCopiedQuotes() throws {
        let source = "The method did not improve\naccuracy. Cost fell by 20%."
        let evidence = SummaryEvidence(source)
        let first = try #require(evidence.items.first)
        #expect(source.contains(first.text))
        #expect(evidence.prompt.contains("did not improve accuracy"))
        let proposal = EvidenceSummaryDraft(
            overview: .init(text: "The method did not improve accuracy.", evidenceIDs: [first.id]),
            takeaways: []
        )
        let draft = try proposal.anchored(in: evidence)
        #expect(draft.overview.quotes == [first.text])
        // A broad point may cite several excerpts, but not none and not more than three.
        let second = try #require(evidence.items.last)
        let broad = try EvidenceSummaryDraft(
            overview: .init(
                text: "Accuracy held while cost fell.",
                evidenceIDs: [first.id, second.id]
            ),
            takeaways: []
        ).anchored(in: evidence)
        #expect(broad.overview.quotes == [first.text, second.text])
        #expect(throws: LinkSummaryError.evidenceMismatch) {
            try EvidenceSummaryDraft(
                overview: .init(text: "Uncited.", evidenceIDs: []),
                takeaways: []
            ).anchored(in: evidence)
        }
        #expect(try draft.markdown(source: source) == "The method did not improve accuracy.")
        #expect(try evidence.select([]).isEmpty)
        #expect(try evidence.select([first.id, first.id]).count == 1)
        #expect(throws: LinkSummaryError.self) { try evidence.select(["unknown-id"]) }
        let repeated = "Café tests\nkeep results. Café tests keep results."
        let unique = SummaryEvidence(repeated)
        #expect(unique.items.count == 1)
        #expect(unique.items.allSatisfy { repeated.contains($0.text) })
    }

    @Test func modelErrorsHaveSafeSpecificMessagesAndContextRecoveryClassification() {
        let legacy = LanguageModelSession.GenerationError
            .exceededContextWindowSize(.init(debugDescription: "Synthetic context failure"))
        #expect(AppleLinkSummarizer.modelFailure(legacy).errorDescription == LinkSummaryError
            .contextLimit.errorDescription)
        #if compiler(>=6.4)
            if #available(macOS 27, *) {
                let modern = LanguageModelError.contextSizeExceeded(.init(
                    contextSize: 4096,
                    tokenCount: 5000,
                    debugDescription: "Synthetic context failure"
                ))
                #expect(AppleLinkSummarizer.modelFailure(modern)
                    .errorDescription == LinkSummaryError.contextLimit.errorDescription)
            }
        #endif
        #expect(LinkSummaryError.evidenceMismatch.errorDescription != LinkSummaryError.invalidOutput
            .errorDescription)
    }

    @Test func summaryDraftRequiresSourceQuotesAndBuildsConsistentMarkdown() throws {
        let source = "Local copies work offline. Device failure can lose changes."
        let draft = SummaryDraft(
            overview: .init(
                text: "Local copies keep documents readable offline.",
                quotes: ["Local copies work offline."]
            ),
            takeaways: [.init(
                text: "Device failure can lose changes.",
                quotes: ["Device failure can lose changes."]
            )]
        )
        #expect(try draft
            .markdown(source: source) ==
            "Local copies keep documents readable offline.\n\n## Key takeaways\n\n- Device failure can lose changes.")
        let invented = SummaryDraft(
            overview: .init(
                text: "Invented claim.",
                quotes: ["Local copies work offline.", "An absent quote."]
            ),
            takeaways: []
        )
        #expect(throws: LinkSummaryError.self) { try invented.markdown(source: source) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INFACTORY_SUMMARY_PDF_FIXTURE"] != nil))
    func nativeSummaryOnLocalPublicPDFFixture() async throws {
        let path = try #require(ProcessInfo.processInfo
            .environment["INFACTORY_SUMMARY_PDF_FIXTURE"])
        let data = try Data(contentsOf: URL(filePath: path))
        let document = try await PDFExtractor().extract(
            data,
            name: "Public paper fixture",
            url: nil
        )
        let summary = try await AppleLinkSummarizer().summarize(document)
        #expect(!summary.isEmpty)
        #expect(summary.split(whereSeparator: \.isWhitespace).count <= 250)
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["INFACTORY_NATIVE_SUMMARY_TESTS"] == "1"))
    func nativeExistingCaptureSummaryUsesRetainedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let original = try await Self.legacyCapture(in: store)
        let engine = IngestionEngine(store: store)
        let saved = try await engine.summarizeExisting(original)
        #expect(saved.id == original.id)
        #expect(saved.revision != original.revision)
        let detail = try await store
            .captureDetail(id: #require(await store.captureID(for: original.id)))
        #expect(detail.document.markdown == original.markdown)
        #expect(detail.artifacts.last?.hash == ContentHash.of(saved.markdown))
        #expect(try await store.history(for: original.id).count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["INFACTORY_NATIVE_SUMMARY_TESTS"] == "1"))
    func nativeSummaryCoversTheEndOfALongSyntheticSource() async throws {
        let opening = "A team tested local-first tools to see whether saved documents stayed available offline. "
        let body = String(
            repeating: "The team opened documents without a network connection. The local copy remained readable during each test. ",
            count: 85
        )
        let ending = "The final device-failure test revealed an important limitation: all unsynced changes were lost. The team recommends keeping a separate backup to protect against device failure."
        let document = CapturedDocument(
            title: "Local-first tools and device failure", coverage: .partial,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: opening + body + ending,
                text: opening + body + ending
            )]
        )
        let summary = try await AppleLinkSummarizer().summarize(document)
        #expect(summary.lowercased().contains("unsynced"))
        #expect(summary.lowercased().contains("device"))
        #expect(!summary.lowercased().contains("did not test"))
        #expect(summary.contains("## Capture limits"))
        #expect(summary.split(whereSeparator: \.isWhitespace).count <= 250)
        print("Synthetic native summary:\n" + summary)
    }

    private static func legacyCapture(in store: DocumentStore) async throws -> MarkdownDocument {
        let source = try #require(URL(string: "https://example.org/" + UUID().uuidString))
        let artifacts = ArtifactStore(root: store.url.deletingLastPathComponent()
            .appending(path: "artifacts"))
        let original = try await artifacts.retain(
            Data("Synthetic original source bytes.".utf8),
            kind: .html,
            name: "source.html",
            sourceURL: source
        )
        _ = try await store.enqueueCapture(CaptureRequest(
            url: source,
            identity: source.absoluteString,
            label: "Legacy capture"
        ))
        let job = try #require(await store.claimCapture())
        let body = "Local-first tools keep documents offline. The cobaltbeacon source evidence stays searchable."
        let id = try await store.publishCapture(
            job,
            document: CapturedDocument(
                title: "Legacy source",
                sourceURL: source,
                coverage: .article,
                blocks: [ContentBlock(
                    kind: .paragraph,
                    markdown: body,
                    text: body
                )]
            ),
            artifacts: [original]
        )
        return try #require(await store.document(id: id))
    }

    private static func waitForSummary(_ held: HeldSummary) async throws {
        for _ in 0 ..< 100 {
            if await held.started {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Summary generation did not start within one second.")
        await held.finish()
    }

    @MainActor private static func screenshot(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
    }

    @Test @MainActor func previewLoadsSelectionAndClearsDeletedDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        let notes = try await store.open(seed: [MarkdownDocument(
            name: "Fixture",
            markdown: "A summary."
        )])
        let note = try #require(notes.first)
        let preview = DocumentPreviewModel()
        preview.selectedID = note.id
        await preview.load(from: store)
        #expect(preview.document == note)
        #expect(!preview.loading)
        _ = try await store.permanentlyRemove(note)
        await preview.load(from: store)
        #expect(preview.document == nil)
        #expect(preview.selectedID == nil)
    }
}

extension LinkSummaryTests {
    @Test func switchingSummarizersAppliesToTheNextCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let declined = SummaryProbe()
        await declined.setUnavailable(true)
        let engine = IngestionEngine(store: store, fetcher: SummaryFetcher(), summarizer: declined)
        await engine.useSummarizer(FixtureLinkSummarizer())
        _ = try await engine.enqueue("https://example.org/article")
        try await engine.run()
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .ready)
        let noteID = try #require(job.noteID)
        let note = try #require(await store.document(id: noteID))
        #expect(note.markdown.hasPrefix("A brief synthetic summary."))
        #expect(await declined.documents.isEmpty)
    }
}

extension LinkSummaryTests {
    @Test func capturesWaitForTheProvidersSummarizer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        // The default engine until the provider setting loads, which must not be used.
        let placeholder = SummaryProbe()
        let engine = IngestionEngine(
            store: store, fetcher: SummaryFetcher(), summarizer: placeholder,
            summarizerChosen: false
        )
        _ = try await engine.enqueue("https://example.org/article")
        let running = Task { try await engine.run() }
        try await Task.sleep(for: .milliseconds(300))
        await engine.useSummarizer(FixtureLinkSummarizer())
        try await running.value
        let job = try #require(await store.captureJobs().first)
        let noteID = try #require(job.noteID)
        let note = try #require(await store.document(id: noteID))
        #expect(note.markdown.hasPrefix("A brief synthetic summary."))
        #expect(await placeholder.documents.isEmpty)
    }

    @Test func summariesOffSavesTheFullTextWithoutAskingTheModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let probe = SummaryProbe()
        let engine = IngestionEngine(
            store: store, fetcher: SummaryFetcher(), summarizer: probe,
            settings: { CaptureSettings(summarize: false) }
        )
        _ = try await engine.enqueue("https://example.org/article")
        try await engine.run()
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .ready)
        #expect(!job.progress.contains("without a summary"))
        let noteID = try #require(job.noteID)
        let note = try #require(await store.document(id: noteID))
        #expect(note.markdown.contains("cobaltbeacon"))
        #expect(await probe.documents.isEmpty)
    }

    @Test func anUnusableChosenEngineFailsWithItsReason() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let engine = IngestionEngine(
            store: store, fetcher: SummaryFetcher(),
            summarizer: UnavailableSummarizer(
                engineName: "ChatGPT", error: ChatGPTError.modelDenied
            )
        )
        _ = try await engine.enqueue("https://example.org/article")
        try await engine.run()
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .ready)
        #expect(job.progress.contains("without a summary"))
        #expect(job.progress.contains(ChatGPTError.modelDenied.localizedDescription))
        #expect(!job.progress.contains("Apple Intelligence"))
    }

    @Test func summaryFailuresNameTheirEngineOnce() {
        let checked = SummaryFailure(engine: "ChatGPT", underlying: .unsupportedSummary)
        #expect(checked
            .errorDescription == "ChatGPT: " +
            (LinkSummaryError.unsupportedSummary.errorDescription ?? ""))
        // Apple's own messages already say Apple Intelligence.
        let apple = SummaryFailure(engine: "Apple Intelligence", underlying: .unavailable)
        #expect(apple.errorDescription == LinkSummaryError.unavailable.errorDescription)
        #expect(SummaryFailure(engine: "", underlying: .failed).errorDescription ==
            LinkSummaryError.failed.errorDescription)
    }
}
