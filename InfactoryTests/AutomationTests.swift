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
        clock: TestClock = TestClock()
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
            politeness: .zero
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
        let moved = await engine(
            store, probe: FixedProbe(.moved(URL(string: "https://fixture.example/new"))),
            clock: clock
        ).run(config(.linkChecker))
        #expect(moved.report.contains { $0.contains("moved to https://fixture.example/new") })
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
