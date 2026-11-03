import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

/// Serves a small article for any synthetic page, titled after its path.
private struct ArticleFetcher: SourceFetching {
    func fetch(_ url: URL) throws -> DownloadedContent {
        let topic = url.lastPathComponent
        return DownloadedContent(
            data: Data("""
            <!doctype html><html><head><title>\(topic)</title></head><body><article>
            <p>\(String(repeating: "Synthetic notes about \(topic) for automation tests. ", count: 8))</p>
            </article></body></html>
            """.utf8),
            url: url, mime: "text/html", encoding: "utf-8"
        )
    }
}

/// Fails every fetch the same way.
private struct FailingFetcher: SourceFetching {
    let error: CaptureError

    func fetch(_: URL) throws -> DownloadedContent {
        throw error
    }
}

/// Fails the first `failures` fetches with a passing error, then serves an article.
private actor FlakyFetcher: SourceFetching {
    private var failures: Int
    private(set) var attempts = 0

    init(failures: Int) {
        self.failures = failures
    }

    func fetch(_ url: URL) throws -> DownloadedContent {
        attempts += 1
        guard failures <= 0 else {
            failures -= 1
            throw CaptureError.downloadFailed
        }
        return try ArticleFetcher().fetch(url)
    }
}

/// Files anything about papers in 51, gardens in a new home, mysteries nowhere.
private actor PaperFiler: ConversationInferring {
    func researchTitle(for _: String) throws -> String {
        throw ConversationError.invalidOutput
    }

    nonisolated let capabilities: InferenceCapabilities
    private(set) var calls = 0

    init(local: Bool = true) {
        capabilities = InferenceCapabilities(
            identifier: "fixture.paper-filer", local: local, structured: true, streaming: false
        )
    }

    func plan(request _: String, context _: ConversationPlanningContext) throws
        -> ConversationPlan
    {
        throw LinkSummaryError.unavailable
    }

    nonisolated func research(question _: String, sources _: [ResearchSource])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func reply(question _: String, role _: AgentRole, history _: [ConversationTurn])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    func classifyBookmarks(
        _ items: [BookmarkClassification.Item],
        categories _: [DecimalCategory],
        examples _: [UUID: [String]]
    ) -> [BookmarkClassification.Answer] {
        calls += 1
        return items.map { item in
            let text = item.text.lowercased()
            return BookmarkClassification.Answer(
                item: item.number,
                code: text.contains("paper") ? "51" : "",
                newCategory: text.contains("garden") ? "Gardening" : "",
                confident: true
            )
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(days: Double) {
        lock.withLock { date = date.addingTimeInterval(days * 86400) }
    }

    func advance(hours: Double) {
        advance(days: hours / 24)
    }
}

private actor FixedProbe: LinkProbing {
    var result: LinkProbe
    private(set) var probed: [URL] = []

    init(_ result: LinkProbe) {
        self.result = result
    }

    func probe(_ url: URL) -> LinkProbe {
        probed.append(url)
        return result
    }
}

private struct FixedArchive: ArchiveLookup {
    func snapshot(of _: URL) -> URL? {
        URL(string: "https://web.archive.org/web/2020/https://fixture.example/gone")
    }
}

/// Answers after a moment, noting how many checks overlap overall and per site.
private actor PacedProbe: LinkProbing {
    private var active: [String: Int] = [:]
    private(set) var mostAtOnce = 0
    private(set) var mostPerSite = 0

    func probe(_ url: URL) async -> LinkProbe {
        let site = url.host() ?? ""
        active[site, default: 0] += 1
        mostPerSite = max(mostPerSite, active[site] ?? 0)
        mostAtOnce = max(mostAtOnce, active.values.reduce(0, +))
        try? await Task.sleep(for: .milliseconds(30))
        active[site, default: 1] -= 1
        return .reachable
    }
}

/// Calls the first candidate related, with a reason.
private actor FirstRelatedJudge: LinkJudging {
    nonisolated let local: Bool
    private(set) var calls = 0

    init(local: Bool = true) {
        self.local = local
    }

    func judgeLinks(
        _: LinkJudgement.Item,
        candidates: [LinkJudgement.Item]
    ) -> [LinkJudgement.Answer] {
        calls += 1
        return candidates.map {
            LinkJudgement.Answer(
                item: $0.number, related: $0.number == 1,
                reason: $0.number == 1 ? "Both cover the same synthetic topic." : ""
            )
        }
    }
}

@Suite(.serialized) struct AutomationTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    /// A library with each page captured as full text, no summary, filed in the Inbox.
    private func library(_ pages: [String]) async throws
        -> (DocumentStore, IngestionEngine, [UUID])
    {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let ingestion = IngestionEngine(
            store: store, fetcher: ArticleFetcher(), summarizer: FixtureLinkSummarizer(),
            settings: { CaptureSettings(summarize: false, previews: false) }
        )
        for page in pages {
            _ = try await ingestion.enqueue("https://fixture.example/\(page)")
        }
        try await ingestion.run()
        var ids: [UUID] = []
        for job in try await store.captureJobs().reversed() {
            try ids.append(#require(job.noteID))
        }
        return (store, ingestion, ids)
    }

    private func engine(
        _ store: DocumentStore,
        ingestion: IngestionEngine? = nil,
        probe: any LinkProbing = FixedProbe(.reachable),
        judge: (any LinkJudging)? = nil,
        filer: (any ConversationInferring)? = nil,
        similar: [UUID] = [],
        clock: TestClock = TestClock(),
        politeness: Duration = .zero,
        summarizesFetches: Bool = false,
        summarizerIsLocal: Bool = true
    ) -> AutomationEngine {
        AutomationEngine(store: store, dependencies: .init(
            summarize: { document in
                guard let ingestion else { throw LinkSummaryError.failed }
                return try await ingestion.summarizeExisting(document)
            },
            summarizerIsLocal: { summarizerIsLocal },
            probe: probe,
            archive: FixedArchive(),
            judge: { judge },
            similar: { _, _ in similar },
            now: { clock.now },
            politeness: politeness,
            fetchBookmark: { id, summarize in
                try await ingestion?.enqueueBookmarkFetch(noteID: id, summarize: summarize)
            },
            capturesSummarize: { summarizesFetches },
            // The queue runs to the end here, so the run finds the capture finished.
            startCapture: { _ in try? await ingestion?.run() },
            capturePoll: .milliseconds(10),
            filer: { filer }
        ))
    }

    /// An empty library and a capture engine over it, fetching through `fetcher`.
    private func emptyLibrary(
        _ fetcher: any SourceFetching = ArticleFetcher(),
        summarize: Bool = false
    ) async throws -> (DocumentStore, IngestionEngine) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let ingestion = IngestionEngine(
            store: store, fetcher: fetcher, summarizer: FixtureLinkSummarizer(),
            settings: { CaptureSettings(summarize: summarize, previews: false) }
        )
        return (store, ingestion)
    }

    /// Imports unfiled bookmarks, the first one oldest; returns their notes in that order.
    private func importBookmarks(_ titles: [String], into store: DocumentStore) async throws
        -> [UUID]
    {
        let bookmarks = try titles.enumerated().map { index, title in
            try ImportedBookmark(
                url: #require(URL(string: "https://site\(index % 2).example/\(index)")),
                title: title,
                created: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86400)
            )
        }
        let original = try await ArtifactStore(root: root.appending(path: "artifacts"))
            .retain(Data("export".utf8), kind: .text, name: "export.csv")
        _ = try await store.importBookmarks(
            bookmarks,
            plan: BookmarkFolderPlan(bookmarks: bookmarks, existing: []),
            original: original
        )
        let notes = try await store.documentPage(limit: 100).documents
        return try bookmarks.map { bookmark in
            try #require(notes.first { $0.name == bookmark.title }?.id)
        }
    }

    private func config(
        _ kind: AutomationKind,
        _ change: (inout AutomationConfig) -> Void = { _ in }
    )
        -> AutomationConfig
    {
        var config = AutomationConfig(kind: kind)
        config.enabled = true
        change(&config)
        return config
    }

    // MARK: Scheduling

    @Test func dueOnceAfterAMissedSchedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var config = AutomationConfig(kind: .linkChecker)
        #expect(!config.isDue(at: now))
        config.enabled = true
        #expect(config.isDue(at: now))
        config.lastRunAt = now.addingTimeInterval(-3600)
        #expect(!config.isDue(at: now))
        // Closed for a week: due now, and after this run, not again until a day later.
        config.lastRunAt = now.addingTimeInterval(-7 * 86400)
        #expect(config.isDue(at: now))
        config.lastRunAt = now
        #expect(!config.isDue(at: now.addingTimeInterval(86399)))
        #expect(config.isDue(at: now.addingTimeInterval(86400)))
    }

    @Test @MainActor func tickRunsOnlyDueAutomationsAndRecordsTheRun() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library(["alpha"])
        var summarizer = AutomationConfig(kind: .summaryBackfill)
        summarizer.enabled = true
        try await store.saveAutomation(summarizer)
        let model = AutomationsModel(
            store: store, engine: engine(store, ingestion: ingestion), schedules: false
        )
        await model.load()
        await model.tick()
        #expect(model.runs[.summaryBackfill]?.count == 1)
        #expect(model.runs[.linkChecker]?.isEmpty == true)
        #expect(model.config(.summaryBackfill).lastRunAt != nil)
        // Ran just now, so a second tick has nothing due.
        await model.tick()
        #expect(model.runs[.summaryBackfill]?.count == 1)
    }

    @Test @MainActor func historyLeavesOutTheRunInProgress() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library(["alpha"])
        _ = try await store.beginAutomationRun(.linkChecker, at: Date())
        let model = AutomationsModel(
            store: store, engine: engine(store, ingestion: ingestion), schedules: false
        )
        await model.load()
        #expect(model.runs[.linkChecker]?.isEmpty == true)
        #expect(!model.failed.contains(.linkChecker))
    }

    @Test func historyPagesAreBoundedOrderedAndExcludeActiveRuns() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try await library([])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var ids: [UUID] = []
        for _ in 0 ..< 23 {
            let id = try await store.beginAutomationRun(.bookmarkFetcher, at: date)
            try await store.finishAutomationRun(AutomationRun(
                id: id,
                kind: .bookmarkFetcher,
                startedAt: date,
                status: .succeeded
            ))
            ids.append(id)
        }
        _ = try await store.beginAutomationRun(.bookmarkFetcher, at: date.addingTimeInterval(1))
        _ = try await store.beginAutomationRun(.linkChecker, at: date)
        var seen: [UUID] = []
        for index in 0 ..< 5 {
            let page = try await store.automationRunPage(.bookmarkFetcher, page: index)
            #expect(page.index == index)
            #expect(page.total == 23)
            #expect(page.runs.count == (index == 4 ? 3 : 5))
            #expect(page.hasNewer == (index > 0))
            #expect(page.hasOlder == (index < 4))
            seen += page.runs.map(\.id)
        }
        #expect(seen == Array(ids.reversed()))
        #expect(try await store.automationRunPage(.bookmarkFetcher, page: Int.max).index == 4)
        #expect(try await store.automationRunPage(.bookmarkFetcher, page: -1).index == 0)
        let empty = try await store.automationRunPage(.linkChecker)
        #expect(empty.total == 0 && empty.runs.isEmpty)
        #expect(!empty.hasOlder && !empty.hasNewer)
    }

    @Test @MainActor func browsingOlderHistoryKeepsLatestStatusAndRefreshesThePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library([])
        let deletedID = UUID()
        var ids: [UUID] = []
        for index in 0 ..< 23 {
            let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            let id = try await store.beginAutomationRun(.bookmarkFetcher, at: date)
            var run = AutomationRun(
                id: id,
                kind: .bookmarkFetcher,
                startedAt: date,
                status: index == 22 ? .failed : .succeeded
            )
            if index == 0 {
                run.note(.skipped, deletedID, "Deleted fixture", "No longer saved.")
            }
            try await store.finishAutomationRun(run)
            ids.append(id)
        }
        let model = AutomationsModel(
            store: store,
            engine: engine(store, ingestion: ingestion),
            schedules: false
        )
        await model.load()
        #expect(model.historyPages[.bookmarkFetcher]?.runs.count == 5)
        #expect(!model.goneItems.contains(deletedID))
        await model.showHistoryPage(4, of: .bookmarkFetcher)
        #expect(model.historyPages[.bookmarkFetcher]?.runs
            .map(\.id) == Array(ids.prefix(3).reversed()))
        #expect(model.goneItems.contains(deletedID))
        #expect(model.runs[.bookmarkFetcher]?.first?.id == ids.last)
        #expect(model.failed.contains(.bookmarkFetcher))
        await model.load()
        #expect(model.historyPages[.bookmarkFetcher]?.index == 4)
        await model.showHistoryPage(0, of: .bookmarkFetcher)
        #expect(model.historyPages[.bookmarkFetcher]?.runs.first?.id == ids.last)
        #expect(!model.goneItems.contains(deletedID))
        #expect(!model.loadingHistory)
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_AUTOMATION_SCREENSHOTS"] == "1"))
    @MainActor func paginatedHistoryHasNativeLayouts() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library([])
        for index in 0 ..< 23 {
            let date = Date().addingTimeInterval(Double(index - 23) * 1800)
            let id = try await store.beginAutomationRun(.summaryBackfill, at: date)
            try await store.finishAutomationRun(AutomationRun(
                id: id,
                kind: .summaryBackfill,
                startedAt: date,
                status: .succeeded
            ))
        }
        let model = AutomationsModel(
            store: store,
            engine: engine(store, ingestion: ingestion),
            schedules: false
        )
        await model.load()
        for dark in [false, true] {
            try await historyScreenshot(model, dark: dark, name: "recent")
        }
        await model.showHistoryPage(4, of: .summaryBackfill)
        try await historyScreenshot(model, dark: true, name: "older")
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_AUTOMATION_SCREENSHOTS"] == "1"))
    @MainActor func longReviewTitlesHaveLeadingNativeLayouts() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let titles = [
            "Synthetic review title: how a local library keeps a long source title readable when it wraps across multiple lines",
            "Synthetic tooling experiments and performance comparisons for a small native document library",
        ]
        let (store, ingestion, ids) = try await library(titles)
        let id = try await store.beginAutomationRun(.summaryBackfill, at: Date())
        var run = AutomationRun(
            id: id,
            kind: .summaryBackfill,
            startedAt: Date(),
            status: .succeeded
        )
        run.proposed = 2
        for (index, title) in titles.enumerated() {
            run.note(
                .proposed,
                ids[index],
                title,
                "Link to another synthetic item: both sources describe the same implementation tradeoff."
            )
        }
        try await store.finishAutomationRun(run)
        let model = AutomationsModel(
            store: store,
            engine: engine(store, ingestion: ingestion),
            schedules: false
        )
        await model.load()
        for dark in [false, true] {
            try await historyScreenshot(model, dark: dark, name: "leading-review", width: 900)
        }
    }

    @MainActor private func historyScreenshot(
        _ model: AutomationsModel,
        dark: Bool,
        name: String,
        width: CGFloat = 1100
    ) async throws {
        let host = NSHostingView(rootView: AutomationsView(model: model, open: { _ in })
            .frame(width: width, height: 1100)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png
            .write(
                to: URL(
                    fileURLWithPath: "/tmp/gleanary-automation-history-\(name)-\(dark ? "dark" : "light").png"
                )
            )
    }

    // MARK: Summary backfill

    @Test func summarizerAppliesWithUndoAndMovesOn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, ids) = try await library(["alpha", "beta"])
        // Filed or not, an item without its summary gets one.
        try await store.saveCategory(code: "31", name: "Computing")
        try await store.fileNote(ids[0], categoryID: #require(await store.categories().first).id)
        let automation = engine(store, ingestion: ingestion)
        let run = await automation.run(config(.summaryBackfill))
        #expect(run.status == .succeeded)
        #expect(run.changed == 2)
        for id in ids {
            #expect(try await store.document(id: id)?.markdown
                .hasPrefix("A brief synthetic summary.") == true)
        }
        // Summarized items aren't selected again.
        #expect(try await store.summaryCandidates(limit: 10, retryBefore: Date()).isEmpty)
        let undone = try await store.undoAgentChanges(store.appliedRunChanges(run.id))
        #expect(undone == 2)
        #expect(try await store.document(id: ids[0])?.markdown
            .contains("Synthetic notes about alpha") == true)
    }

    @Test func dailyBudgetStopsARunPartway() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library(["alpha", "beta"])
        let run = await engine(store, ingestion: ingestion)
            .run(config(.summaryBackfill) { $0.dailyCalls = 1 })
        #expect(run.changed == 1)
        #expect(run.status == .partial)
        #expect(run.report.contains { $0.contains("today's limit") })
    }

    @Test func onDeviceOnlySkipsACloudSummarizer() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library(["alpha"])
        let automation = AutomationEngine(store: store, dependencies: .init(
            summarize: { try await ingestion.summarizeExisting($0) },
            summarizerIsLocal: { false },
            probe: FixedProbe(.reachable), archive: FixedArchive(), judge: { nil },
            similar: { _, _ in [] }
        ))
        let run = await automation.run(config(.summaryBackfill) { $0.cloudAllowed = false })
        #expect(run.changed == 0)
        #expect(run.report.first?.contains("on-device only") == true)
    }

    // MARK: Link checker

    @Test func linkCheckerProposesArchiveOnlyAfterRepeatedFailures() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["gone"])
        let clock = TestClock()
        let automation = engine(
            store,
            probe: FixedProbe(.gone("The page returned HTTP 404")),
            clock: clock
        )
        let checker = config(.linkChecker)
        _ = await automation.run(checker)
        clock.advance(days: 1.1)
        _ = await automation.run(checker)
        clock.advance(days: 1.1)
        let early = await automation.run(checker)
        // Three failures, but within a few days: a site's bad week isn't enough yet.
        #expect(early.proposed == 0)
        #expect(try await store.itemCheck(ids[0], kind: "access")?.failures == 3)
        clock.advance(days: 5)
        let late = await automation.run(checker)
        #expect(late.proposed == 1)
        let changes = try await store.pendingAutomationChanges(.linkChecker)
        let proposal = try #require(changes.first)
        #expect(proposal.kind == .archive)
        #expect(proposal.reason.contains("web.archive.org"))
        // Proposed only: nothing is archived until it's applied.
        #expect(try await !store.isArchived(ids[0]))
        _ = try await store.applyAgentChanges([proposal.id])
        #expect(try await store.isArchived(ids[0]))
        // Not proposed twice.
        clock.advance(days: 2)
        #expect(await automation.run(checker).proposed == 0)
        _ = try await store.undoAgentChanges([proposal.id])
        #expect(try await !store.isArchived(ids[0]))
    }

    @Test func restrictedAndMovedLinksAreNeverArchived() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try await library(["private"])
        let clock = TestClock()
        let automation = engine(store, probe: FixedProbe(.restricted(403)), clock: clock)
        for _ in 0 ..< 5 {
            _ = await automation.run(config(.linkChecker))
            clock.advance(days: 31)
        }
        #expect(try await store.pendingAutomationChanges(.linkChecker).isEmpty)
        let restricted = try #require(await automation.run(config(.linkChecker)).entries.first)
        #expect(restricted.outcome == .restricted)
    }

    @Test func deadLinksArchiveThemselvesWhenAllowedWithUndo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["gone"])
        let clock = TestClock()
        let automation = engine(
            store,
            probe: FixedProbe(.gone("The page returned HTTP 404")),
            clock: clock
        )
        let checker = config(.linkChecker) { $0.archivesDeadLinks = true }
        for _ in 0 ..< 3 {
            let early = await automation.run(checker)
            #expect(early.changed == 0)
            #expect(early.entries.first?.detail.contains("before it's archived") == true)
            clock.advance(days: 1.1)
        }
        // Three failures, but within a few days: not archived until they span a week.
        #expect(try await !store.isArchived(ids[0]))
        clock.advance(days: 5)
        let late = await automation.run(checker)
        #expect(late.changed == 1)
        #expect(late.proposed == 0)
        #expect(late.entries.first?.outcome == .changed)
        #expect(late.entries.first?.detail.contains("web.archive.org") == true)
        #expect(try await store.isArchived(ids[0]))
        #expect(try await store.pendingAutomationChanges(.linkChecker).isEmpty)
        #expect(late.kind.undoable)

        let undone = try await store.undoAgentChanges(store.appliedRunChanges(late.id))
        #expect(undone == 1)
        #expect(try await !store.isArchived(ids[0]))
        // Undone is a choice: never archived on its own again.
        clock.advance(days: 2)
        #expect(await automation.run(checker).changed == 0)
        #expect(try await !store.isArchived(ids[0]))
    }

    @Test func deadLinksWaitingForReviewAreLeftThere() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["gone"])
        let clock = TestClock()
        let automation = engine(
            store,
            probe: FixedProbe(.gone("The domain no longer resolves")),
            clock: clock
        )
        for _ in 0 ..< 4 {
            _ = await automation.run(config(.linkChecker))
            clock.advance(days: 3)
        }
        #expect(try await store.pendingAutomationChanges(.linkChecker).count == 1)
        clock.advance(days: 2)
        let run = await automation.run(config(.linkChecker) { $0.archivesDeadLinks = true })
        #expect(run.changed == 0)
        #expect(try await !store.isArchived(ids[0]))
        #expect(try await store.pendingAutomationChanges(.linkChecker).count == 1)
    }

    @Test func linksGleanaryWontCheckAreNeverArchived() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["local"])
        let clock = TestClock()
        let automation = engine(store, probe: FixedProbe(.refused), clock: clock)
        let checker = config(.linkChecker) { $0.archivesDeadLinks = true }
        for _ in 0 ..< 5 {
            _ = await automation.run(checker)
            clock.advance(days: 31)
        }
        #expect(try await !store.isArchived(ids[0]))
        #expect(try await store.pendingAutomationChanges(.linkChecker).isEmpty)
        #expect(try await store.itemCheck(ids[0], kind: "access")?.failures == 0)
        let entry = try #require(await automation.run(checker).entries.first)
        #expect(entry.outcome == .restricted)
        let local = try #require(URL(string: "http://localhost/x"))
        #expect(await WebLinkProber().probe(local) == .refused)
    }

    @Test func deadLinkSettingPersistsAndStartsOff() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try await library([])
        #expect(try await store.automationConfigs().allSatisfy { !$0.archivesDeadLinks })
        var checker = AutomationConfig(kind: .linkChecker)
        checker.archivesDeadLinks = true
        try await store.saveAutomation(checker)
        let saved = try await store.automationConfigs().first { $0.kind == .linkChecker }
        #expect(saved?.archivesDeadLinks == true)
    }

    @Test func reviewSheetShowsEveryKindOfChange() {
        #expect(AgentChangesReview.kindOrder.count == AgentChange.Kind.allCases.count)
        #expect(Set(AgentChangesReview.kindOrder) == Set(AgentChange.Kind.allCases))
    }

    /// A moved link becomes a proposal to update it, which applies and undoes like any other.
    @Test func movedLinksProposeUpdatingTheLink() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["old"])
        let destination = try #require(URL(string: "https://fixture.example/new"))
        let clock = TestClock()
        let automation = engine(store, probe: FixedProbe(.moved(destination)), clock: clock)
        let run = await automation.run(config(.linkChecker))
        #expect(run.proposed == 1)
        #expect(run.entries.map(\.outcome) == [.proposed])
        #expect(run.entries.first?.itemID == ids[0])
        #expect(try await store.automationRuns(.linkChecker).first?.entries == run.entries)
        // Checked, so nothing is due until the recheck, which is yours to set.
        #expect(try await automation.backlog(config(.linkChecker)) == 0)
        try await store.saveAutomation(config(.linkChecker) { $0.recheck = 7 * 24 * 60 * 60 })
        #expect(try await store.automationConfigs().first { $0.kind == .linkChecker }?.recheck
            == 7 * 24 * 60 * 60)
        clock.advance(days: 8)
        #expect(try await automation.backlog(config(.linkChecker) {
            $0.recheck = 7 * 24 * 60 * 60
        }) == 1)
        #expect(try await automation.backlog(config(.linkChecker)) == 0)
        let proposal = try #require(try await store.pendingAutomationChanges(.linkChecker).first)
        #expect(proposal.kind == .relink)
        #expect(proposal.after == destination.absoluteString)
        // Not proposed again while it waits.
        clock.advance(days: 31)
        let again = await automation.run(config(.linkChecker))
        #expect(again.proposed == 0)
        #expect(again.entries.map(\.outcome) == [.moved])

        _ = try await store.applyAgentChanges([proposal.id])
        #expect(try await store.libraryItemDetails(for: ids[0]).sourceURL == destination)
        #expect(try await store.itemCheck(ids[0], kind: "access") == nil)
        #expect(try await store.undoAgentChanges([proposal.id]) == 1)
        #expect(try await store.libraryItemDetails(for: ids[0]).sourceURL?.absoluteString
            == "https://fixture.example/old")

        // Undo forgot the check, so the restored link is due again; a source saved since is
        // due straight away too.
        let ingestion = IngestionEngine(
            store: store, fetcher: ArticleFetcher(), summarizer: FixtureLinkSummarizer(),
            settings: { CaptureSettings(summarize: false, previews: false) }
        )
        _ = try await ingestion.enqueue("https://fixture.example/newer")
        try await ingestion.run()
        #expect(try await automation.backlog(config(.linkChecker)) == 2)
    }

    @Test func probeClassifiesResponses() throws {
        let page = try #require(URL(string: "https://fixture.example/page"))
        func response(_ status: Int, location: String? = nil) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(
                url: page, statusCode: status, httpVersion: nil,
                headerFields: location.map { ["Location": $0] }
            ))
        }
        #expect(try WebLinkProber.classify(response(200)) == .reachable)
        #expect(try WebLinkProber.classify(response(302)) == .reachable)
        #expect(try WebLinkProber.classify(response(301, location: "/moved")) ==
            .moved(URL(string: "https://fixture.example/moved")))
        #expect(try WebLinkProber.classify(response(403)) == .restricted(403))
        #expect(try WebLinkProber.classify(response(410)) == .gone("The page returned HTTP 410"))
        #expect(try WebLinkProber
            .classify(response(503)) == .transient("The site returned HTTP 503"))
    }

    // MARK: Cross-linker

    @Test func crossLinkerProposesLinksThatShowOnceApplied() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["alpha", "beta"])
        let judge = FirstRelatedJudge()
        let automation = engine(store, judge: judge, similar: ids)
        let run = await automation.run(config(.crossLinker) { $0.batchLimit = 1 })
        #expect(run.proposed == 1)
        #expect(await judge.calls == 1)
        let proposal = try #require(await store.pendingAutomationChanges(.crossLinker).first)
        #expect(proposal.kind == .link)
        #expect(Set([proposal.noteID, proposal.targetID]) == Set(ids))
        #expect(try await store.linkedItems(for: ids[0]).isEmpty)
        _ = try await store.applyAgentChanges([proposal.id])
        let linked = try await store.linkedItems(for: ids[0])
        #expect(linked.map(\.document.id) == [ids[1]])
        #expect(linked.first?.rationale == "Both cover the same synthetic topic.")
        // Linked items aren't candidates any more, so nothing is proposed again.
        #expect(await automation.run(config(.crossLinker)).proposed == 0)
        _ = try await store.undoAgentChanges([proposal.id])
        #expect(try await store.linkedItems(for: ids[0]).isEmpty)
    }

    @Test func crossLinkerNeedsAModelAndRespectsOnDeviceOnly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["alpha", "beta"])
        let none = await engine(store, similar: ids).run(config(.crossLinker))
        #expect(none.report.first?.contains("needs Apple Intelligence or ChatGPT") == true)
        let cloud = FirstRelatedJudge(local: false)
        let skipped = await engine(store, judge: cloud, similar: ids)
            .run(config(.crossLinker) { $0.cloudAllowed = false })
        #expect(skipped.proposed == 0)
        #expect(await cloud.calls == 0)
    }

    @Test func linkJudgementKeepsOnlyReasonedAnswersForListedCandidates() throws {
        let candidates = [
            LinkJudgement.Item(number: 1, title: "A", excerpt: ""),
            LinkJudgement.Item(number: 2, title: "B", excerpt: ""),
        ]
        let answers = try LinkJudgement.decode(Data("""
        {"answers": [
            {"item": 1, "related": true, "reason": "Same topic."},
            {"item": 2, "related": true, "reason": "  "},
            {"item": 1, "related": false, "reason": ""},
            {"item": 9, "related": true, "reason": "Invented."}
        ]}
        """.utf8), candidates: candidates)
        #expect(answers.map(\.item) == [1, 2])
        #expect(answers.map(\.related) == [true, false])
    }

    // MARK: Archive

    @Test func archivedItemsLeaveTheLibraryUntilUnarchived() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["alpha", "beta"])
        try await store.archive(ids[0], reason: "Archived by you")
        #expect(try await store.documentPage().documents.map(\.id) == [ids[1]])
        #expect(try await store.documentPage(scope: .archived).documents.map(\.id) == [ids[0]])
        #expect(try await !store.atlasSnapshot().items.contains { $0.id == ids[0] })
        #expect(try await !store.searchSnapshot(query: "alpha", candidateLimit: 20).passages
            .contains { $0.documentID == ids[0] })
        #expect(try await store.libraryItemDetails(for: ids[0]).archiveReason == "Archived by you")
        try await store.unarchive(ids[0])
        #expect(try await Set(store.documentPage().documents.map(\.id)) == Set(ids))
    }

    @Test func clearingTheConversationLeavesAutomationProposals() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, ids) = try await library(["alpha", "beta"])
        let run = await engine(store, judge: FirstRelatedJudge(), similar: ids)
            .run(config(.crossLinker) { $0.batchLimit = 1 })
        #expect(run.proposed == 1)
        try await store.clearConversation()
        #expect(try await store.pendingAutomationChanges(.crossLinker).count == 1)
    }
}

// MARK: Large libraries

extension AutomationTests {
    @Test func batchesGrowToCoverALibraryWithinAMonth() {
        var checker = AutomationConfig(kind: .linkChecker)
        // Daily: 30 runs a cycle, so 7,400 due links need 247 a run.
        #expect(AutomationEngine.plannedBatch(checker, backlog: 7400) == 247)
        // Never fewer than the batch you set.
        #expect(AutomationEngine.plannedBatch(checker, backlog: 10) == checker.batchLimit)
        // Never more than the cap, however much is due.
        #expect(AutomationEngine.plannedBatch(checker, backlog: 1_000_000)
            == AutomationEngine.largestBatch)
        // More runs a cycle, smaller runs.
        checker.interval = 6 * 60 * 60
        #expect(AutomationEngine.plannedBatch(checker, backlog: 7400) == 62)
        // Rechecking weekly needs bigger runs to get round in time.
        checker.interval = 24 * 60 * 60
        checker.recheck = 7 * 24 * 60 * 60
        #expect(AutomationEngine.plannedBatch(checker, backlog: 7400) == 1000)
        checker.recheck = 91 * 24 * 60 * 60
        #expect(AutomationEngine.plannedBatch(checker, backlog: 7400) == 82)
        // Summaries keep to the batch; the daily model budget limits them.
        let summarizer = AutomationConfig(kind: .summaryBackfill)
        #expect(AutomationEngine.plannedBatch(summarizer, backlog: 7400) == summarizer.batchLimit)
    }

    @Test func newestUncheckedItemsComeFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try await library(["first", "second", "third"])
        let probe = FixedProbe(.reachable)
        let run = await engine(store, probe: probe).run(config(.linkChecker) { $0.batchLimit = 1 })
        #expect(run.examined == 1)
        #expect(await probe.probed.map(\.lastPathComponent) == ["third"])
        #expect(try await store.linkCheckBacklog(
            checkedBefore: Date.distantPast,
            retryBefore: Date.distantPast
        ) == 2)
    }

    @Test func sitesAreCheckedTogetherButEachOneAtATime() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let ingestion = IngestionEngine(
            store: store, fetcher: ArticleFetcher(), summarizer: FixtureLinkSummarizer(),
            settings: { CaptureSettings(summarize: false, previews: false) }
        )
        for site in ["one", "two", "three"] {
            for page in ["a", "b"] {
                _ = try await ingestion.enqueue("https://\(site).example/\(page)")
            }
        }
        try await ingestion.run()
        let probe = PacedProbe()
        let run = await engine(store, probe: probe, politeness: .milliseconds(10))
            .run(config(.linkChecker))
        #expect(run.examined == 6)
        #expect(run.fine == 6)
        #expect(await probe.mostPerSite == 1)
        #expect(await probe.mostAtOnce > 1)
    }

    @Test @MainActor func newSavesRunTheAutomationsThatFollowThem() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library(["alpha"])
        for kind in [AutomationKind.summaryBackfill, .linkChecker] {
            var automation = AutomationConfig(kind: kind)
            automation.enabled = true
            // Not due on its schedule.
            automation.lastRunAt = Date()
            try await store.saveAutomation(automation)
        }
        let model = AutomationsModel(
            store: store, engine: engine(store, ingestion: ingestion), schedules: false
        )
        await model.load()
        await model.runForNewItems()
        #expect(model.runs[.summaryBackfill]?.count == 1)
        // A link just fetched needs no check.
        #expect(model.runs[.linkChecker]?.isEmpty == true)
    }
}

// MARK: Bookmark fetcher

extension AutomationTests {
    @Test func upkeepDefaultsFinishYourWorkButOnlyProposeOrWriteWhenAsked() {
        #expect(AutomationConfig(kind: .bookmarkFetcher).enabled)
        #expect(AutomationConfig(kind: .captureRetry).enabled)
        #expect(!AutomationConfig(kind: .unfiledFiler).enabled)
        #expect(!AutomationConfig(kind: .weeklyDigest).enabled)
        #expect(AutomationKind.weeklyDigest.intervals == [7 * 24 * 60 * 60])
        // Only the filer revisits items, so only its batch grows with the backlog.
        #expect(AutomationEngine.plannedBatch(
            AutomationConfig(kind: .bookmarkFetcher), backlog: 7400
        ) == 5)
        #expect(AutomationEngine.plannedBatch(
            AutomationConfig(kind: .unfiledFiler), backlog: 7400
        ) == 247)
    }

    @Test func bookmarkFetcherFetchesNewestFirstWithUndo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion) = try await emptyLibrary()
        let ids = try await importBookmarks(["oldest", "middle", "newest"], into: store)
        let original = try #require(await store.document(id: ids[1]))
        let automation = engine(store, ingestion: ingestion)
        #expect(try await automation.backlog(config(.bookmarkFetcher)) == 3)
        let steps = StepLog()
        let run = await automation.run(config(.bookmarkFetcher) { $0.batchLimit = 2 }) {
            await steps.add($0)
        }
        #expect(run.status == .succeeded)
        #expect(run.changed == 2)
        // Says which page it's on, so a slow fetch doesn't look stuck.
        let said = await steps.lines
        #expect(said.count == 2)
        #expect(said.first?.hasPrefix("Fetching 1 of 2: ") == true)
        #expect(run.entries.map(\.itemID) == [ids[2], ids[1]])
        #expect(run.entries.allSatisfy { $0.outcome == .changed })
        // Upgraded in place, through the same capture path as opening the bookmark.
        #expect(try await store.document(id: ids[1])?.markdown
            .contains("Synthetic notes about 1") == true)
        #expect(try await store.unfetchedBookmarkURL(noteID: ids[1]) == nil)
        #expect(try await automation.backlog(config(.bookmarkFetcher)) == 1)
        // Successful background fetches aren't announced or listed as failures.
        #expect(try await store.captureJobs().allSatisfy { $0.state == .ready })

        #expect(try await store.undoAgentChanges(store.appliedRunChanges(run.id)) == 2)
        #expect(try await store.document(id: ids[1])?.markdown == original.markdown)
        // Undone bookmarks aren't fetched again unasked; the oldest is next.
        let next = await automation.run(config(.bookmarkFetcher))
        #expect(next.entries.map(\.itemID) == [ids[0]])
    }

    @Test func bookmarkFetcherReportsFailuresOnceAndLeavesThemToTheRetry() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion) = try await emptyLibrary(FailingFetcher(error: .http(503)))
        let ids = try await importBookmarks(["flaky"], into: store)
        let automation = engine(store, ingestion: ingestion)
        let run = await automation.run(config(.bookmarkFetcher))
        #expect(run.changed == 0)
        #expect(run.skipped == 1)
        let entry = try #require(run.entries.first)
        #expect(entry.itemID == ids[0])
        // The retry is on by default, and a server error may pass.
        #expect(entry.outcome == .retry)
        #expect(entry.detail.contains("HTTP 503"))
        // Not fetched again on the next run; the failed capture is the retry's to try.
        #expect(try await automation.backlog(config(.bookmarkFetcher)) == 0)
        #expect(await automation.run(config(.bookmarkFetcher)).examined == 0)
        let failed = try #require(await store.captureJobs().first)
        #expect(failed.state == .failed)
        #expect(failed.retryable)
    }

    @Test func bookmarkFetcherSummariesCountTowardTheBudgetAndStayOnDevice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion) = try await emptyLibrary(summarize: true)
        let ids = try await importBookmarks(["first", "second"], into: store)
        let budgeted = await engine(store, ingestion: ingestion, summarizesFetches: true)
            .run(config(.bookmarkFetcher) { $0.dailyCalls = 1 })
        #expect(budgeted.changed == 1)
        #expect(budgeted.calls == 1)
        #expect(budgeted.status == .partial)
        #expect(budgeted.report.contains { $0.contains("today's limit") })
        #expect(try await store.document(id: ids[1])?.markdown
            .hasPrefix("A brief synthetic summary.") == true)
        // On-device only with ChatGPT writing summaries: fetched, but not summarized.
        let local = await engine(
            store, ingestion: ingestion, summarizesFetches: true, summarizerIsLocal: false
        ).run(config(.bookmarkFetcher) { $0.cloudAllowed = false; $0.dailyCalls = 0 })
        #expect(local.changed == 1)
        #expect(local.calls == 0)
        #expect(try await store.document(id: ids[0])?.markdown
            .contains("Synthetic notes about 0") == true)
    }
}

// MARK: Failed-capture retry

extension AutomationTests {
    @Test func captureRetryBacksOffThenLeavesItForYou() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = FlakyFetcher(failures: .max)
        let (store, ingestion) = try await emptyLibrary(fetcher)
        _ = try await ingestion.enqueue("https://flaky.example/page")
        try await ingestion.run()
        #expect(await fetcher.attempts == 1)
        let clock = TestClock(Date())
        let automation = engine(store, ingestion: ingestion, clock: clock)
        let retry = config(.captureRetry)
        // The first try waits an hour after the failure.
        #expect(await automation.run(retry).examined == 0)
        var expected = 1
        for (wait, next) in [(1.1, "a day"), (24.1, "a week")] {
            clock.advance(hours: wait)
            let run = await automation.run(retry)
            expected += 1
            #expect(await fetcher.attempts == expected)
            #expect(run.entries.map(\.outcome) == [.retry])
            #expect(run.entries.first?.detail.contains("trying again in \(next)") == true)
            // Not again until that wait is over.
            #expect(await automation.run(retry).examined == 0)
        }
        clock.advance(days: 7.1)
        let last = await automation.run(retry)
        #expect(await fetcher.attempts == 4)
        #expect(last.entries.first?.outcome == .skipped)
        #expect(last.entries.first?.detail.contains("left in Activity") == true)
        clock.advance(days: 60)
        #expect(await automation.run(retry).examined == 0)
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .failed)
        #expect(job.autoRetries == 3)
    }

    @Test func captureRetrySavesWhatWorksSecondTime() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion) = try await emptyLibrary(FlakyFetcher(failures: 1))
        _ = try await ingestion.enqueue("https://flaky.example/second")
        try await ingestion.run()
        let clock = TestClock(Date())
        clock.advance(hours: 2)
        let run = await engine(store, ingestion: ingestion, clock: clock).run(config(.captureRetry))
        #expect(run.changed == 1)
        let entry = try #require(run.entries.first)
        #expect(entry.outcome == .changed)
        let job = try #require(await store.captureJobs().first)
        #expect(job.state == .ready)
        #expect(entry.itemID == job.noteID)
    }

    @Test func captureRetryNeverRetriesWhatNeedsYou() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion) = try await emptyLibrary(FailingFetcher(error: .http(404)))
        _ = try await ingestion.enqueue("https://gone.example/page")
        try await ingestion.run()
        // A post that needs the capture browser, even with a reason that would otherwise pass.
        _ = try await ingestion.enqueue("https://browser.example/post")
        let claimed = try #require(await store.claimCapture())
        try await store.failCapture(
            claimed, error: "Needs a browser.", recovery: .browser, retryable: true
        )
        let clock = TestClock(Date())
        clock.advance(days: 30)
        let automation = engine(store, ingestion: ingestion, clock: clock)
        #expect(try await automation.backlog(config(.captureRetry)) == 0)
        #expect(await automation.run(config(.captureRetry)).examined == 0)
        #expect(try await store.captureJobs().allSatisfy { !$0.retryable && $0.autoRetries == 0 })
    }

    @Test func olderFailuresAreJudgedByTheirMessage() {
        #expect(CaptureFailure.retryable(message: CaptureError.http(503).localizedDescription))
        #expect(CaptureFailure.retryable(message: CaptureError.http(429).localizedDescription))
        #expect(CaptureFailure.retryable(message: CaptureError.downloadFailed.localizedDescription))
        #expect(!CaptureFailure.retryable(message: CaptureError.http(404).localizedDescription))
        #expect(!CaptureFailure.retryable(message: CaptureError.needsBrowser.localizedDescription))
        #expect(!CaptureFailure.retryable(MediaError.browserRequired))
        #expect(CaptureFailure.retryable(MediaError.blocked))
    }
}

// MARK: Unfiled filer

extension AutomationTests {
    private func unfiledLibrary(_ titles: [String]) async throws -> (DocumentStore, [UUID]) {
        let (store, _) = try await emptyLibrary()
        try await store.saveCategory(code: "51", name: "Papers")
        return try await (store, importBookmarks(titles, into: store))
    }

    @Test func unfiledFilerProposesExistingHomesAndFilesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ids) = try await unfiledLibrary(["A paper", "Garden notes", "Mystery"])
        let filer = PaperFiler()
        let clock = TestClock()
        let automation = engine(store, filer: filer, clock: clock)
        let run = await automation.run(config(.unfiledFiler))
        #expect(run.examined == 3)
        #expect(run.proposed == 1)
        #expect(run.calls == 1)
        #expect(await filer.calls == 1)
        #expect(run.fine == 1)
        #expect(run.entries.first { $0.outcome == .skipped }?.detail.contains("Gardening") == true)
        // Proposed only: nothing is filed until it's applied.
        #expect(try await store.categories(for: ids[0]).isEmpty)
        let proposal = try #require(await store.pendingAutomationChanges(.unfiledFiler).first)
        #expect(proposal.kind == .filing)
        #expect(proposal.noteID == ids[0])
        #expect(proposal.after == "51 Papers")
        // Waiting for review, so not proposed twice.
        #expect(try await automation.backlog(config(.unfiledFiler)) == 0)
        _ = try await store.applyAgentChanges([proposal.id])
        #expect(try await store.categories(for: ids[0]).map(\.code) == ["51"])
        _ = try await store.undoAgentChanges([proposal.id])
        #expect(try await store.categories(for: ids[0]).isEmpty)
        // A month on the items are looked at again from saved answers, and a filing that was
        // undone isn't proposed again.
        clock.advance(days: 31)
        let again = await automation.run(config(.unfiledFiler))
        #expect(again.examined == 3)
        #expect(again.proposed == 0)
        #expect(await filer.calls == 1)
    }

    @Test func unfiledFilerKeepsToItsBudgetAndOnDeviceSetting() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try await unfiledLibrary((1 ... 12).map { "Paper \($0)" })
        let cloud = PaperFiler(local: false)
        let skipped = await engine(store, filer: cloud)
            .run(config(.unfiledFiler) { $0.cloudAllowed = false })
        #expect(skipped.report.first?.contains("on-device only") == true)
        #expect(await cloud.calls == 0)
        // On-device batches hold 10, so a budget of one call covers 10 of the 12.
        let filer = PaperFiler()
        let run = await engine(store, filer: filer).run(config(.unfiledFiler) { $0.dailyCalls = 1 })
        #expect(run.status == .partial)
        #expect(run.calls == 1)
        #expect(run.proposed == 10)
        #expect(run.report.contains { $0.contains("today's limit") })
        let none = await engine(store).run(config(.unfiledFiler))
        #expect(none.report.first?.contains("needs Apple Intelligence or ChatGPT") == true)
    }
}

// MARK: Weekly digest

extension AutomationTests {
    @Test func weeklyDigestWritesOneNewNoteThatUndoRemoves() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, ids) = try await library(["alpha", "beta"])
        _ = try await ingestion.enqueue("https://fixture.example/gamma")
        try await ingestion.run()
        try await store.saveCategory(code: "10", name: "General")
        let general = try #require(await store.categories().first)
        try await store.fileNote(ids[0], categoryID: general.id)
        let before = try await ids.asyncMap { try #require(await store.document(id: $0)) }
        let clock = TestClock(Date().addingTimeInterval(60))
        let automation = engine(store, clock: clock)
        #expect(try await automation.backlog(config(.weeklyDigest)) == 3)
        let run = await automation.run(config(.weeklyDigest))
        #expect(run.status == .succeeded)
        #expect(run.changed == 1)
        #expect(run.examined == 3)
        #expect(run.headline == "Wrote a digest of 3 items")
        let digestID = try #require(run.entries.first?.itemID)
        let digest = try #require(await store.document(id: digestID))
        #expect(digest.name.hasPrefix("Weekly digest: "))
        for id in ids {
            #expect(digest.markdown.contains("(gleanary://note/\(id.uuidString))"))
        }
        // Grouped by category, unfiled last.
        let inbox = try #require(digest.markdown.range(of: "## 10 "))
        let unfiled = try #require(digest.markdown.range(of: "## Unfiled"))
        #expect(inbox.lowerBound < unfiled.lowerBound)
        // Never edits the items it lists.
        for note in before {
            #expect(try await store.document(id: note.id)?.revision == note.revision)
        }
        // Nothing new since: no second digest, and the digest isn't an item to file or link.
        let repeated = await automation.run(config(.weeklyDigest))
        #expect(repeated.changed == 0)
        #expect(repeated.report.first?.contains("Nothing saved since the last digest") == true)
        #expect(try await !store.crossLinkCandidates(limit: 50, checkedBefore: Date.distantFuture)
            .contains(digestID))

        #expect(try await store.runUndoState([run.id]).applied == [run.id])
        #expect(try await store.undoAgentChanges(store.appliedRunChanges(run.id)) == 1)
        #expect(try await store.document(id: digestID) == nil)
        // History then shows the run as undone, with no Undo left to offer.
        let state = try await store.runUndoState([run.id])
        #expect(state.applied.isEmpty && state.undone == [run.id])
        // Its link in History is shown as gone; the items it listed are still there.
        #expect(try await store.missingNotes([digestID] + ids) == [digestID])
        // Undone, so the week is covered again.
        #expect(await automation.run(config(.weeklyDigest)).changed == 1)
    }

    @Test func emptyWeekWritesNoDigest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, _) = try await library(["alpha"])
        let clock = TestClock(Date())
        clock.advance(days: 8)
        let automation = engine(store, clock: clock)
        let run = await automation.run(config(.weeklyDigest))
        #expect(run.status == .succeeded)
        #expect(run.changed == 0)
        #expect(run.entries.isEmpty)
        #expect(run.report == ["Nothing saved in the last 7 days, so no digest."])
        #expect(run.headline == "Nothing to change")
        #expect(try await store.documentPage().total == 1)
    }

    @Test func digestListsTheNewestWhenTheWeekIsLong() {
        let items = (0 ..< 3).map {
            DigestItem(
                id: UUID(), title: "Item [\($0)]", host: "example.com",
                code: $0 == 0 ? nil : "11", category: $0 == 0 ? nil : "Reading"
            )
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let note = DigestNote.document(
            items, total: 40, from: start, to: start.addingTimeInterval(7 * 86400)
        )
        #expect(note.markdown.contains(": 40 items, grouped by category. The newest 3 are listed."))
        #expect(note.markdown.contains("- [Item \\[1\\]](gleanary://note/"))
        #expect(note.markdown.contains(" (example.com)"))
        #expect(note.markdown.components(separatedBy: "## ").count == 3)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self {
            try await results.append(transform(element))
        }
        return results
    }
}

/// Progress lines an automation run reported, in order.
private actor StepLog {
    private(set) var lines: [String] = []

    func add(_ line: String) {
        lines.append(line)
    }
}
