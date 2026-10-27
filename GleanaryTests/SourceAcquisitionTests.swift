import Foundation
@testable import Gleanary
import GRDB
import Testing

/// A synthetic video whose creator recommends an essay beside self-promotion.
actor CreatorVideoFixture: YouTubeProviding {
    static let essay = "https://essays.example.org/writing/swarm-scaling"
    private(set) var creatorCalls = 0

    func transcript(for target: MediaTarget) throws -> VideoTranscript {
        VideoTranscript(
            videoID: target.id, title: "Synthetic agents talk", author: "Synthetic channel",
            language: "en", generated: true, method: "fixture",
            segments: [
                TimedText(text: "Agents coordinate through shared plans.", start: 0, duration: 4),
                TimedText(text: "Swarms scale when tasks split cleanly.", start: 40, duration: 4),
            ]
        )
    }

    func audio(for _: MediaTarget) throws -> ResolvedAudio {
        throw MediaError.blocked
    }

    func creatorText(for _: MediaTarget) async -> CreatorText? {
        creatorCalls += 1
        return CreatorText(
            description: """
            Join the next cohort: https://school.example.com/cohort

            Chapters and notes for this talk.
            """,
            pinnedComment: """
            I'd recommend reading this one too: \(Self.essay) Super interesting.

            Also my X for those who want to follow: https://x.com/syntheticcreator
            """,
            author: "Synthetic channel"
        )
    }
}

/// Serves the recommended essay; everything else is missing.
struct EssayFetcher: SourceFetching {
    func fetch(_ url: URL) async throws -> DownloadedContent {
        guard url.absoluteString == CreatorVideoFixture.essay else { throw CaptureError.http(404) }
        return DownloadedContent(data: Data("""
        <html><head><title>Swarm scaling</title></head><body><article>
        <p>Swarm scaling describes how many small agents can outperform one large agent when work divides cleanly. This is a synthetic essay used only in tests.</p>
        <p>For more, I recommend this companion piece: <a href="https://essays.example.org/writing/companion">companion</a>.</p>
        </article></body></html>
        """.utf8), url: url, mime: "text/html", encoding: "utf-8")
    }
}

/// A constant closeness, so tests do not depend on the embedding model.
struct FixedRelevance: LinkRelevanceScoring {
    let value: Double
    func relevance(of _: FoundLink, excluding _: UUID) async -> Double? {
        value
    }
}

@Suite(.serialized) struct SourceAcquisitionTests {
    private func link(
        _ url: String, context: String, creator: Bool = true
    ) throws -> FoundLink {
        let url = try #require(URL(string: url))
        return try FoundLink(
            identity: CaptureRequest.webLink(url).identity, url: url, title: url.absoluteString,
            context: context, fromCreator: creator
        )
    }

    @Test func creatorRecommendationsScoreHighAndPromotionIsFiltered() throws {
        let essay = try link(CreatorVideoFixture.essay, context: "I'd recommend reading this one")
        let cohort = try link("https://school.example.com/cohort", context: "Join the next cohort")
        let social = try link("https://linkedin.com/in/someone", context: "Read my thoughts")
        let affiliate = try link(
            "https://shop.example.com/item?tag=creator-20", context: "Gear I use"
        )
        let landing = try link("https://essays.example.org/", context: "I recommend this site")
        let plain = try link("https://notes.example.net/post", context: "Chapters", creator: false)
        let cited = try link(
            "https://papers.example.net/agents", context: "The paper behind this", creator: false
        )
        let source = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")
        let essayScore = AcquisitionScorer.score(essay, sourceURL: source)
        #expect(essayScore.provenance == .creatorRecommendation)
        #expect(essayScore.value == 1)
        #expect(AcquisitionScorer.score(cohort, sourceURL: source).filtered == "Self-promotion")
        #expect(AcquisitionScorer.score(social, sourceURL: source).filtered == "Social profile")
        #expect(AcquisitionScorer.score(affiliate, sourceURL: source).filtered == "Affiliate link")
        #expect(AcquisitionScorer.score(landing, sourceURL: source).value == 0.5)
        #expect(AcquisitionScorer.score(plain, sourceURL: source).value == 0.3)
        let citation = AcquisitionScorer.score(cited, sourceURL: source)
        #expect(citation.provenance == .citation)
        #expect(citation.value == 0.5)
    }

    @Test func planningRespectsEachLevelAndItsBudgets() throws {
        let recommendations = try (1 ... 5).map {
            try link("https://essays.example.org/\($0)", context: "I recommend reading this")
        }
        let balanced = AcquisitionPlanner.plan(
            recommendations, sourceURL: nil, policy: SourceAcquisitionLevel.balanced.policy,
            savedToday: 0, saved: []
        )
        #expect(balanced.map(\.state) == [.approved, .approved, .approved, .suggested, .suggested])
        let nearDailyLimit = AcquisitionPlanner.plan(
            recommendations, sourceURL: nil, policy: SourceAcquisitionLevel.balanced.policy,
            savedToday: 19, saved: [recommendations[0].identity]
        )
        #expect(nearDailyLimit.map(\.state) == [
            .noticed,
            .approved,
            .suggested,
            .suggested,
            .suggested,
        ])
        #expect(nearDailyLimit[0].reason == "Already in your library")
        let suggest = AcquisitionPlanner.plan(
            recommendations, sourceURL: nil, policy: SourceAcquisitionLevel.suggest.policy,
            savedToday: 0, saved: []
        )
        #expect(!suggest.contains { $0.state == .approved })
        let lazy = AcquisitionPlanner.plan(
            recommendations, sourceURL: nil, policy: SourceAcquisitionLevel.lazy.policy,
            savedToday: 0, saved: []
        )
        #expect(lazy.allSatisfy { $0.state == .noticed })
    }

    @Test func eagerWeighsRelevanceAndDecaysWithHops() throws {
        let posted = try link("https://notes.example.net/agents", context: "Slides for the talk")
        let cited = try link(
            "https://papers.example.net/swarms", context: "The paper behind this", creator: false
        )
        let policy = SourceAcquisitionLevel.eager.policy
        let close = AcquisitionPlanner.plan(
            [posted, cited], sourceURL: nil, policy: policy,
            relevance: [posted.identity: 0.8, cited.identity: 0.8], savedToday: 0, saved: []
        )
        #expect(close.map(\.state) == [.approved, .approved])
        #expect(close.map(\.score.value) == [0.6, 0.6])
        let far = AcquisitionPlanner.plan(
            [posted, cited], sourceURL: nil, policy: policy,
            relevance: [posted.identity: 0.1, cited.identity: 0.1], savedToday: 0, saved: []
        )
        #expect(far.map(\.state) == [.noticed, .noticed])
        // Balanced ignores relevance and only saves creator recommendations.
        let balanced = AcquisitionPlanner.plan(
            [posted, cited], sourceURL: nil, policy: SourceAcquisitionLevel.balanced.policy,
            relevance: [posted.identity: 0.8, cited.identity: 0.8], savedToday: 0, saved: []
        )
        #expect(!balanced.contains { $0.state == .approved })
        let recommended = try link("https://essays.example.org/x", context: "I recommend this")
        let secondHop = AcquisitionPlanner.plan(
            [recommended], sourceURL: nil, policy: policy, hop: 2, savedToday: 0, saved: []
        )
        #expect(secondHop.first?.score.value == 0.6)
        #expect(secondHop.first?.state == .approved)
        let thirdHop = AcquisitionPlanner.plan(
            [recommended], sourceURL: nil, policy: policy, hop: 3, savedToday: 0, saved: []
        )
        #expect(thirdHop.first?.state == .suggested)
    }

    @Test func eagerFollowsASecondHopFromAutoSavedSources() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .eager) },
            relevance: FixedRelevance(value: 0.5)
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        let companion = try await store.readyDatabase().read { db in
            try Row.fetchOne(db, sql: """
            SELECT state, hop, score FROM acquisition_candidates WHERE url LIKE '%companion'
            """).map { (
                state: $0["state"] as String,
                hop: $0["hop"] as Int,
                score: $0["score"] as Double
            ) }
        }
        // The essay's own recommendation is found two hops out. Being on the essay's own site
        // and a hop further, it scores 0.7 × 0.5 × 0.9 × 0.6 and is only noted.
        #expect(companion?.hop == 2)
        #expect(companion?.state == "noticed")
        #expect(companion?.score == 0.19)
    }

    @Test func creatorTextIsASeparateSectionThatSummariesSkip() async throws {
        let url = try #require(URL(string: "https://www.youtube.com/watch?v=abcdefghijk"))
        let target = try #require(try MediaTarget.parse(url))
        let fixture = CreatorVideoFixture()
        var document = try await fixture.transcript(for: target).document(for: target)
        let transcript = document.blocks
        document.blocks += try #require(await fixture.creatorText(for: target)).blocks
        #expect(document.markdown.contains("## From the creator"))
        #expect(document.markdown.contains("<\(CreatorVideoFixture.essay)>"))
        #expect(document.evidenceBlocks == transcript)
        let links = document.foundLinks(excluding: "youtube:abcdefghijk")
        let essay = try #require(links.first { $0.url.absoluteString == CreatorVideoFixture.essay })
        #expect(essay.fromCreator)
        #expect(essay.context.contains("recommend"))
        // Timestamp links back to the video itself are not candidates.
        #expect(!links.contains { $0.url.host()?.contains("youtube") == true })
    }

    @Test func balancedCaptureSavesTheRecommendationAndLinksItBack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .balanced) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        let documents = try await store.documents()
        #expect(documents.count == 2)
        let video = try #require(documents.first { $0.name.contains("Synthetic agents talk") })
        let essay = try #require(documents.first { $0.name.contains("Swarm scaling") })
        let candidates = try await store.readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT url, state, foundInNoteID FROM acquisition_candidates ORDER BY url
            """).map { (
                url: $0["url"] as String,
                state: $0["state"] as String,
                foundIn: $0["foundInNoteID"] as String
            ) }
        }
        let states = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url, $0.state) })
        #expect(states[CreatorVideoFixture.essay] == "queued")
        #expect(states["https://school.example.com/cohort"] == "filtered")
        // Profile links on social sites are not capturable sources at all.
        #expect(states["https://x.com/syntheticcreator"] == nil)
        // The essay is one hop out, so its own recommendation is not followed at Balanced.
        #expect(!states.keys.contains("https://essays.example.org/writing/companion"))
        #expect(candidates.allSatisfy { $0.foundIn == video.id.uuidString })
        let linked = try await store.readyDatabase().read { db in
            try String.fetchOne(db, sql: """
            SELECT rationale FROM note_links WHERE leftID = ? AND rightID = ?
            """, arguments: StatementArguments([video.id.uuidString, essay.id.uuidString].sorted()))
        }
        #expect(linked?.hasPrefix("Recommended by the creator") == true)
    }

    @Test func offRecordsNothingAndDeferredSavesWaitForTheCaller() async throws {
        for level in [SourceAcquisitionLevel.off, .balanced] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DocumentStore(url: root.appending(path: "library.sqlite"))
            _ = try await store.open()
            let engine = IngestionEngine(
                store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
                settings: { CaptureSettings(summarize: false, previews: false, acquisition: level) }
            )
            _ = try await engine.enqueue(
                "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
            )
            try await engine.run(deferAcquisition: true)
            #expect(try await store.documents().count == 1)
            let approved = try await store.approvedAcquisitions(foundIn: nil)
            #expect(approved.count == (level == .off ? 0 : 1))
            if level == .balanced {
                let queued = try await engine.queueApprovedAcquisitions(foundIn: nil)
                #expect(queued.map(\.url.absoluteString) == [CreatorVideoFixture.essay])
                try await engine.run()
                #expect(try await store.documents().count == 2)
            }
        }
    }
}
