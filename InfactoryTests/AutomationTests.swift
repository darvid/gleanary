import Foundation
@testable import Infactory
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.withLock { date }
    }

    func advance(days: Double) {
        lock.withLock { date = date.addingTimeInterval(days * 86400) }
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
        let inbox = try #require(await store.categories().first(where: \.isInbox))
        var ids: [UUID] = []
        for job in try await store.captureJobs().reversed() {
            let id = try #require(job.noteID)
            try await store.fileNote(id, categoryID: inbox.id)
            ids.append(id)
        }
        return (store, ingestion, ids)
    }

    private func engine(
        _ store: DocumentStore,
        ingestion: IngestionEngine? = nil,
        probe: any LinkProbing = FixedProbe(.reachable),
        judge: (any LinkJudging)? = nil,
        similar: [UUID] = [],
        clock: TestClock = TestClock(),
        politeness: Duration = .zero
    ) -> AutomationEngine {
        AutomationEngine(store: store, dependencies: .init(
            summarize: { document in
                guard let ingestion else { throw LinkSummaryError.failed }
                return try await ingestion.summarizeExisting(document)
            },
            summarizerIsLocal: { true },
            probe: probe,
            archive: FixedArchive(),
            judge: { judge },
            similar: { _, _ in similar },
            now: { clock.now },
            politeness: politeness
        ))
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
        var summarizer = AutomationConfig(kind: .inboxSummarizer)
        summarizer.enabled = true
        try await store.saveAutomation(summarizer)
        let model = AutomationsModel(
            store: store, engine: engine(store, ingestion: ingestion), schedules: false
        )
        await model.load()
        await model.tick()
        #expect(model.runs[.inboxSummarizer]?.count == 1)
        #expect(model.runs[.linkChecker]?.isEmpty == true)
        #expect(model.config(.inboxSummarizer).lastRunAt != nil)
        // Ran just now, so a second tick has nothing due.
        await model.tick()
        #expect(model.runs[.inboxSummarizer]?.count == 1)
    }

    // MARK: Inbox summarizer

    @Test func summarizerAppliesWithUndoAndMovesOn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, ids) = try await library(["alpha", "beta"])
        let automation = engine(store, ingestion: ingestion)
        let run = await automation.run(config(.inboxSummarizer))
        #expect(run.status == .succeeded)
        #expect(run.changed == 2)
        for id in ids {
            #expect(try await store.document(id: id)?.markdown
                .hasPrefix("A brief synthetic summary.") == true)
        }
        // Summarized items aren't selected again.
        #expect(try await store.inboxSummaryCandidates(limit: 10, retryBefore: Date()).isEmpty)
        let undone = try await store.undoAgentChanges(store.appliedRunChanges(run.id))
        #expect(undone == 2)
        #expect(try await store.document(id: ids[0])?.markdown
            .contains("Synthetic notes about alpha") == true)
    }

    @Test func dailyBudgetStopsARunPartway() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, ingestion, _) = try await library(["alpha", "beta"])
        let run = await engine(store, ingestion: ingestion)
            .run(config(.inboxSummarizer) { $0.dailyCalls = 1 })
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
        let run = await automation.run(config(.inboxSummarizer) { $0.cloudAllowed = false })
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
        let summarizer = AutomationConfig(kind: .inboxSummarizer)
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
        for kind in [AutomationKind.inboxSummarizer, .linkChecker] {
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
        #expect(model.runs[.inboxSummarizer]?.count == 1)
        // A link just fetched needs no check.
        #expect(model.runs[.linkChecker]?.isEmpty == true)
    }
}
