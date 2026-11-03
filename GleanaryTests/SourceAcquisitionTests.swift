import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
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

struct ExploreProbe: LinkProbing {
    func probe(_: URL) async -> LinkProbe {
        .reachable
    }
}

struct ExploreArchive: ArchiveLookup {
    func snapshot(of _: URL) async -> URL? {
        nil
    }
}

/// Serves the essay and a robots.txt, when given one.
struct RobotsFetcher: SourceFetching {
    let robots: String?
    var robotsStatus = 200

    func fetch(_ url: URL) async throws -> DownloadedContent {
        if url.path == "/robots.txt" {
            guard robotsStatus == 200, let robots else { throw CaptureError.http(robotsStatus) }
            return DownloadedContent(
                data: Data(robots.utf8),
                url: url,
                mime: "text/plain",
                encoding: "utf-8"
            )
        }
        return try await EssayFetcher().fetch(url)
    }
}

/// Refuses the recommended essay, as a site that blocks automated fetches does.
struct ForbiddenFetcher: SourceFetching {
    func fetch(_ url: URL) async throws -> DownloadedContent {
        throw CaptureError.http(url.absoluteString == CreatorVideoFixture.essay ? 403 : 404)
    }
}

/// Reads every link's wording as one fixed intent, or fails.
struct FixedJudge: RecommendationJudging {
    let intent: LinkIntent?
    let local = true
    func judgeIntents(_ items: [RecommendationJudgement.Item]) async throws -> [Int: LinkIntent] {
        guard let intent else { throw LinkSummaryError.unavailable }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.number, intent) })
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

    /// A library with the synthetic video and its auto-saved essay.
    private func balancedLibrary() async throws -> (URL, DocumentStore, IngestionEngine) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        try await store.seedExampleCategories()
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .balanced) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        return (root, store, engine)
    }

    @Test func probationArchivesOnlyUnusedAutomaticSaves() async throws {
        let (root, store, _) = try await balancedLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let essay = try #require(await store.documents().first { $0.name == "Swarm scaling" })
        let later = Date().addingTimeInterval(AcquisitionPolicy.probation + 60)
        // Not due yet.
        #expect(try await store.expireUnusedAcquisitions() == 0)
        // Opening it ends probation.
        try await store.recordAcquisitionOpened(essay.id)
        #expect(try await store.expireUnusedAcquisitions(now: later) == 0)
        try await store.readyDatabase().write { db in
            try db.execute(sql: "UPDATE acquisition_candidates SET openedAt = NULL")
        }
        // Filing it counts as using it.
        let home = try #require(await store.categories().first)
        try await store.fileNote(essay.id, categoryID: home.id)
        #expect(try await store.expireUnusedAcquisitions(now: later) == 0)
        try await store.readyDatabase().write { db in
            try db.execute(sql: "DELETE FROM note_categories")
        }
        #expect(try await store.expireUnusedAcquisitions(now: later) == 1)
        let reason = try await store.readyDatabase().read { db in
            try String.fetchOne(
                db, sql: "SELECT archiveReason FROM notes WHERE id = ? AND archivedAt IS NOT NULL",
                arguments: [essay.id.uuidString]
            )
        }
        #expect(reason == "Saved automatically and not opened within 30 days.")
        let digest = try await store.acquisitionDigest(
            from: .distantPast, to: later.addingTimeInterval(60)
        )
        #expect(digest.expired == 1)
        #expect(digest.saved.isEmpty)
    }

    @Test func mutingASiteFiltersItsLinks() async throws {
        let essay = try link(CreatorVideoFixture.essay, context: "I'd recommend reading this one")
        let plans = AcquisitionPlanner.plan(
            [essay], sourceURL: nil, policy: SourceAcquisitionLevel.balanced.policy,
            savedToday: 0, saved: [], muted: ["essays.example.org"]
        )
        #expect(plans.first?.state == .filtered)
        #expect(plans.first?.reason == "Muted site")

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        try await store.muteAcquisitionHost("www.essays.example.org")
        #expect(try await store.mutedAcquisitionHosts() == ["essays.example.org"])
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .balanced) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        #expect(try await store.documents().count == 1)
        try await store.unmuteAcquisitionHost("essays.example.org")
        #expect(try await store.mutedAcquisitionHosts().isEmpty)
    }

    @Test func digestListsAutomaticSavesWithWhereTheyWereFound() async throws {
        let (root, store, _) = try await balancedLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = try await store.acquisitionDigest(
            from: .distantPast, to: Date().addingTimeInterval(60)
        )
        let item = try #require(digest.saved.first)
        #expect(item.title == "Swarm scaling")
        #expect(item.originTitle.contains("Synthetic agents talk"))
        let section = DigestNote.foundForYou(digest.saved, expired: 2)
        #expect(section.contains("## Found for you"))
        #expect(section.contains(
            "- [Swarm scaling](gleanary://note/\(item.noteID.uuidString)): recommended by the creator in ["
        ))
        #expect(section.contains("Archived 2 items saved automatically but never opened."))
        #expect(DigestNote.foundForYou([], expired: 0).isEmpty)
    }

    @Test @MainActor func captureSettingsRenderTheDialOnce() throws {
        let categories = [
            DecimalCategory(id: UUID(), code: "10", name: "Inbox"),
            DecimalCategory(id: UUID(), code: "31", name: "Agent architectures"),
        ]
        for dark in [false, true] {
            let view = NSHostingView(rootView: CaptureSettingsView(categories: categories)
                .frame(width: 620, height: 520)
                .environment(\.colorScheme, dark ? .dark : .light))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 620)
            if let path = ProcessInfo.processInfo.environment["GLEANARY_SETTINGS_SCREENSHOT"] {
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path + (dark ? ".dark.png" : ".light.png")))
            }
        }
    }

    @Test func timestampedYouTubeLinksShareTheVideosIdentity() throws {
        let plain = try #require(URL(string: "https://www.youtube.com/watch?v=abcdefghijk"))
        let identity = try CaptureRequest.webLink(plain).identity
        for variant in [
            "https://youtu.be/abcdefghijk?t=42",
            "https://www.youtube.com/watch?v=abcdefghijk&t=1m30s&si=share",
            "https://m.youtube.com/watch?t=90&v=abcdefghijk",
            "https://www.youtube.com/live/abcdefghijk?t=5",
        ] {
            let url = try #require(URL(string: variant))
            let request = try CaptureRequest.webLink(url)
            #expect(request.identity == identity)
            #expect(request.url == plain)
        }
    }

    @Test func robotsRulesFollowRFC9309() throws {
        let rules = RobotsRules.parse("""
        # Synthetic robots.txt
        User-agent: OtherBot
        Disallow: /

        User-agent: *
        Disallow: /private/
        Allow: /private/open
        Disallow: /*.pdf$
        Crawl-delay: 4
        """)
        func allows(_ path: String) throws -> Bool {
            try rules.allows(#require(URL(string: "https://example.org" + path)))
        }
        #expect(try allows("/writing/essay"))
        #expect(try !allows("/private/notes"))
        #expect(try allows("/private/open-letter"))
        #expect(try !allows("/files/report.pdf"))
        #expect(try allows("/files/report.pdf?download=1"))
        #expect(rules.crawlDelay == 4)
        let named = RobotsRules
            .parse("User-agent: *\nDisallow: /\n\nUser-agent: Gleanary\nAllow: /")
        #expect(try named.allows(#require(URL(string: "https://example.org/a"))))
        #expect(RobotsRules.parse("User-agent: *\nDisallow:").rules.isEmpty)
    }

    @Test func robotsPolicyTreatsMissingFilesAsOpenAndFailuresAsClosed() async throws {
        let url = try #require(URL(string: CreatorVideoFixture.essay))
        #expect(await RobotsPolicy(fetcher: RobotsFetcher(robots: nil, robotsStatus: 404))
            .rules(for: url) == .allowAll)
        #expect(await RobotsPolicy(fetcher: RobotsFetcher(robots: nil, robotsStatus: 503))
            .rules(for: url) == .disallowAll)
    }

    @Test func automaticSavesRespectRobotsButYourOwnSavesDoNot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let engine = IngestionEngine(
            store: store, fetcher: RobotsFetcher(robots: "User-agent: *\nDisallow: /writing/"),
            youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .balanced) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        #expect(try await store.documents().count == 1)
        let blocked = try #require(await store.readyDatabase().read { db in
            try Row.fetchOne(db, sql: """
            SELECT id, state, reason FROM acquisition_candidates WHERE url = ?
            """, arguments: [CreatorVideoFixture.essay]).map {
                (
                    id: $0["id"] as String,
                    state: $0["state"] as String,
                    reason: $0["reason"] as String
                )
            }
        })
        #expect(blocked.state == "filtered")
        #expect(blocked.reason == "The site's robots.txt asks not to fetch this")
        // Choosing to save it yourself is not crawling.
        let id = try #require(UUID(uuidString: blocked.id))
        try await store.readyDatabase().write { db in
            try db.execute(sql: "UPDATE acquisition_candidates SET state = 'suggested'")
        }
        _ = try await engine.saveAcquisition(id)
        try await engine.run()
        #expect(try await store.documents().contains { $0.name == "Swarm scaling" })
    }

    @Test func aJudgedIntentOverridesCuePhrases() async throws {
        let slides = try link("https://notes.example.net/agents", context: "Slides for the talk")
        let promoted = try link(CreatorVideoFixture.essay, context: "I recommend this")
        let plans = AcquisitionPlanner.plan(
            [slides, promoted], sourceURL: nil, policy: SourceAcquisitionLevel.balanced.policy,
            savedToday: 0, saved: [],
            intents: [slides.identity: .recommendation, promoted.identity: .promotion]
        )
        #expect(plans.map(\.state) == [.approved, .filtered])
        #expect(plans.first?.intent == .recommendation)

        for judge in [FixedJudge(intent: .other), FixedJudge(intent: nil)] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DocumentStore(url: root.appending(path: "library.sqlite"))
            _ = try await store.open()
            let engine = IngestionEngine(
                store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
                settings: { CaptureSettings(
                    summarize: false,
                    previews: false,
                    acquisition: .balanced
                ) },
                recommendationJudge: judge
            )
            _ = try await engine.enqueue(
                "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
            )
            try await engine.run()
            let row = try await store.readyDatabase().read { db in
                try Row.fetchOne(db, sql: """
                SELECT state, intent FROM acquisition_candidates WHERE url = ?
                """, arguments: [CreatorVideoFixture.essay]).map {
                    (state: $0["state"] as String, intent: $0["intent"] as String?)
                }
            }
            if judge.intent == nil {
                // A failing model leaves the cue phrases to decide.
                #expect(row?.state == "queued")
                #expect(row?.intent == nil)
            } else {
                // The model read "I'd recommend reading" as not a recommendation this time.
                #expect(row?.state == "suggested")
                #expect(row?.intent == "other")
            }
        }
    }

    @Test func oneSiteCannotTakeTheWholeDay() throws {
        let links = try (1 ... 3).map {
            try link("https://essays.example.org/\($0)", context: "I recommend reading this")
        }
        let plans = AcquisitionPlanner.plan(
            links, sourceURL: nil, policy: SourceAcquisitionLevel.balanced.policy,
            savedToday: 2, saved: [], savedTodayBySite: ["essays.example.org": 2]
        )
        #expect(plans.map(\.state) == [.approved, .suggested, .suggested])
    }

    @Test func automaticFetchesFromOneSiteAreSpacedOut() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let engine = IngestionEngine(store: store, fetcher: RobotsFetcher(robots: ""))
        let url = try #require(URL(string: CreatorVideoFixture.essay))
        let clock = ContinuousClock()
        let start = clock.now
        await engine.spaceAutomaticFetch(url)
        await engine.spaceAutomaticFetch(url)
        #expect(clock.now - start >= .seconds(2))
    }

    @Test func foundViaLinksShowInTheGraph() async throws {
        let (root, store, _) = try await balancedLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try #require(await store.documents()
            .first { $0.name.contains("Synthetic agents") })
        let essay = try #require(await store.documents().first { $0.name == "Swarm scaling" })
        let edge = GraphEdge(
            source: "note:\(video.id.uuidString)", target: "note:\(essay.id.uuidString)",
            predicate: .relatedTo
        )
        let reasons = try await store.libraryGraphReasons(for: edge, request: LibraryGraphRequest())
        #expect(reasons.map(\.label) == ["Found via"])
        #expect(reasons.first?.text.hasPrefix("Recommended by the creator") == true)
    }

    @Test func suggestionsReadAsTitles() throws {
        func candidate(_ url: String, title: String, pageTitle: String? = nil) throws
            -> AcquisitionCandidate
        {
            try AcquisitionCandidate(
                id: UUID(), identity: url, url: #require(URL(string: url)), title: title,
                foundInNoteID: UUID(), context: "", provenance: .citation, hop: 1, score: 0.5,
                state: .suggested, reason: "", pageTitle: pageTitle
            )
        }
        let slug = "https://blog.example.org/blog/interviewing-ai-researchers-on-automation"
        #expect(try candidate(slug, title: slug).displayTitle
            == "Interviewing ai researchers on automation")
        #expect(try candidate(slug, title: "released", pageTitle: "Interviews on automation")
            .displayTitle == "Interviews on automation")
        #expect(try candidate(slug, title: "A study of agent swarms").displayTitle
            == "A study of agent swarms")
        let id = "https://papers.example.org/abstract=4814445"
        #expect(try candidate(id, title: id).displayTitle == "papers.example.org")

        #expect(PageTitle.read(html: """
        <html><head><title>Plain | Site</title>
        <meta property="og:title" content="  Shared   title "></head></html>
        """) == "Shared title")
        #expect(PageTitle.read(html: "<html><head><title>Only plain</title></head></html>")
            == "Only plain")
        #expect(PageTitle.read(html: "<html><body>No title</body></html>") == nil)
    }

    @Test func oneDOIIsOnePaperWhicheverPageLinksIt() {
        let document = CapturedDocument(title: "Notes", coverage: .note, blocks: [ContentBlock(
            kind: .paragraph,
            markdown: """
            [Abstract](https://www.science.example.org/doi/abs/10.1126/science.abq1158) and \
            [PDF](https://www.science.example.org/doi/pdf/10.1126/science.abq1158) and \
            [Other](https://www.science.example.org/doi/abs/10.1126/science.xyz9999)
            """,
            text: ""
        )])
        let links = document.foundLinks(excluding: "")
        #expect(links.map(\.title) == ["Abstract", "Other"])
    }

    @Test func suggestionsGetTheirPageTitlesInTheBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .suggest) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        let video = try #require(await store.documents().first)
        let essay = try #require(await store.acquisitionCandidates(foundIn: video.id)
            .first { $0.url.absoluteString == CreatorVideoFixture.essay })
        #expect(essay.state == .suggested)
        #expect(essay.pageTitle == "Swarm scaling")
        #expect(essay.displayTitle == "Swarm scaling")
        // Looked for once only.
        #expect(try await store.untitledSuggestions(limit: 10).isEmpty)
    }

    @Test func categoryOverridesPickTheLevel() {
        var settings = CaptureSettings(acquisition: .balanced)
        settings.overrides = ["31": .lazy, "40.02": .eager]
        #expect(settings.acquisition(forCategory: "31") == .lazy)
        #expect(settings.acquisition(forCategory: "31.04") == .lazy)
        #expect(settings.acquisition(forCategory: "40.02") == .eager)
        #expect(settings.acquisition(forCategory: "40") == .balanced)
        #expect(settings.acquisition(forCategory: nil) == .balanced)
    }

    @Test func filingIntoALazyCategoryHoldsBackDeferredSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        try await store.seedExampleCategories()
        let home = try #require(await store.categories().first)
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: {
                var settings = CaptureSettings(
                    summarize: false,
                    previews: false,
                    acquisition: .balanced
                )
                settings.overrides = [home.code: .lazy]
                return settings
            }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run(deferAcquisition: true)
        let video = try #require(await store.documents().first)
        #expect(try await store.approvedAcquisitions(foundIn: video.id).count == 1)
        try await store.fileNote(video.id, categoryID: home.id)
        try await engine.replanForCategory(foundIn: video.id)
        #expect(try await store.approvedAcquisitions(foundIn: video.id).isEmpty)
        #expect(try await engine.queueApprovedAcquisitions(foundIn: video.id).isEmpty)
    }

    @Test func exploreQueuesFrontierLinksThatNowQualify() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let origin = try await store.save(MarkdownDocument(name: "Origin", markdown: "Notes."))
        let posted = try link(CreatorVideoFixture.essay, context: "Slides for the talk")
        try await store.recordAcquisitions(
            AcquisitionPlanner.plan(
                [posted], sourceURL: nil, policy: SourceAcquisitionLevel.suggest.policy,
                savedToday: 0, saved: []
            ),
            foundIn: origin.id, hop: 1
        )
        for level in [SourceAcquisitionLevel.eager, .explore] {
            let engine = IngestionEngine(
                store: store, fetcher: EssayFetcher(),
                settings: { CaptureSettings(summarize: false, previews: false, acquisition: level)
                },
                relevance: FixedRelevance(value: 0.9)
            )
            let queued = try await engine.explore(limit: 5)
            if level == .eager {
                #expect(queued == nil)
                continue
            }
            #expect(queued?.map(\.url.absoluteString) == [CreatorVideoFixture.essay])
            try await engine.run()
            #expect(try await store.documents().contains { $0.name == "Swarm scaling" })
            #expect(try await engine.explore(limit: 5)?.isEmpty == true)
        }
    }

    @Test func exploreFromHereFollowsANotesLinksWhateverTheLevel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let note = try await store.save(MarkdownDocument(
            name: "Reading list",
            markdown: "I recommend [this essay](\(CreatorVideoFixture.essay)) on agents."
        ))
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .off) },
            relevance: FixedRelevance(value: 0.5)
        )
        let queued = try await engine.exploreFrom(note.id)
        #expect(queued.map(\.provenance) == [.citation])
        try await engine.run()
        let essay = try #require(await store.documents().first { $0.name == "Swarm scaling" })
        let links = try await store.linkedItems(for: note.id)
        #expect(links.map(\.document.id) == [essay.id])
    }

    @Test func sourceExplorerSaysWhenExploreIsOff() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let automation = AutomationEngine(store: store, dependencies: .init(
            summarize: { $0 }, summarizerIsLocal: { true },
            probe: ExploreProbe(), archive: ExploreArchive(), judge: { nil },
            similar: { _, _ in [] }
        ))
        let run = await automation.run(AutomationConfig(kind: .sourceExplorer))
        #expect(run.status == .succeeded)
        #expect(run.report.first?.contains("isn't set to Explore") == true)
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

    @Test func aSaveWhoseCaptureFailedSaysSoAndCanBeDismissed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let engine = IngestionEngine(
            store: store, fetcher: ForbiddenFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false, acquisition: .balanced) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        let video = try #require(await store.documents().first)
        let essay = try #require(await store.acquisitionSuggestions(foundIn: [video.id])[video.id]?
            .first { $0.url.absoluteString == CreatorVideoFixture.essay })
        #expect(essay.state == .queued)
        #expect(essay.captureError?.isEmpty == false)

        try await store.dismissAcquisition(essay.id)
        #expect(try await store.acquisitionCandidate(id: essay.id)?.state == .rejected)
    }

    @Test func youTubeSuggestionsAreTitledFromOEmbed() throws {
        let short = try #require(URL(string: "https://youtu.be/abcdefghijk?t=30"))
        let oEmbed = try #require(PageTitle.oEmbedURL(for: short))
        #expect(oEmbed.host == "www.youtube.com" && oEmbed.path == "/oembed")
        #expect(oEmbed.query?.contains("watch%3Fv%3Dabcdefghijk") == true)
        #expect(try PageTitle
            .oEmbedURL(for: #require(URL(string: "https://example.org/essay"))) == nil)
        #expect(PageTitle.read(oEmbed: Data(#"{"title":"A  synthetic\ntalk","type":"video"}"#.utf8))
            == "A synthetic talk")
        #expect(PageTitle.read(oEmbed: Data("not json".utf8)) == nil)
    }

    @Test func suggestedReadingExplainsWhatTheLevelSavesOnItsOwn() {
        #expect(SourceAcquisitionLevel.suggest.suggestionNote.hasPrefix("Suggest saves nothing"))
        #expect(SourceAcquisitionLevel.eager.suggestionNote
            .hasPrefix("Eager saves up to 10 links per source and 5 per site a day"))
        #expect(SourceAcquisitionLevel.balanced.suggestionNote.contains("Settings › Capture"))
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
