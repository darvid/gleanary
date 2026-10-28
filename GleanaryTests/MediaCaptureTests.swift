import AppKit
import CoreMedia
import Foundation
@testable import Gleanary
import GRDB
import Speech
import Testing
import WebKit

private actor MediaProviderFixture: YouTubeProviding {
    var missing = false
    var transcriptCalls = 0
    var audioCalls = 0
    func setMissing() {
        missing = true
    }

    func transcript(for target: MediaTarget) throws -> VideoTranscript {
        transcriptCalls += 1
        if missing {
            throw MediaError.noCaptions
        }
        return VideoTranscript(
            videoID: target.id,
            title: "Synthetic video",
            author: "Synthetic channel",
            language: "en",
            generated: true,
            method: "fixture",
            segments: [
                TimedText(text: "First local idea.", start: 0, duration: 3),
                TimedText(text: "Cobaltbeacon timestamped knowledge.", start: 65, duration: 5),
            ]
        )
    }

    func audio(for target: MediaTarget) throws -> ResolvedAudio {
        audioCalls += 1
        return try ResolvedAudio(
            url: #require(URL(string: "https://fixture.example/audio.m4a")),
            info: VideoAudioInfo(
                videoID: target.id,
                title: "Synthetic audio",
                author: "Synthetic channel",
                duration: 70
            )
        )
    }
}

private actor MediaFetchFixture: SourceFetching {
    /// A synthetic 480×360 still, the size YouTube's hqdefault thumbnails come in.
    static let still: Data = {
        let output = NSMutableData()
        guard let context = CGContext(
            data: nil, width: 480, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return Data() }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }()

    var requestedURLs: [URL] = []
    var html: String?
    func setHTML(_ text: String) {
        html = text
    }

    func fetch(_ url: URL) throws -> DownloadedContent {
        requestedURLs.append(url)
        if url.host == "i.ytimg.com" {
            // Only the always-present size exists, as for many real videos.
            guard url.lastPathComponent == "hqdefault.jpg" else { throw CaptureError.http(404) }
            return DownloadedContent(data: Self.still, url: url, mime: "image/jpeg", encoding: nil)
        }
        if url.path.hasSuffix("audio.m4a") {
            return DownloadedContent(
                data: Data("synthetic audio bytes".utf8),
                url: url,
                mime: "audio/mp4",
                encoding: nil
            )
        }
        guard let html else { throw CaptureError.http(403) }
        return DownloadedContent(
            data: Data(html.utf8),
            url: url,
            mime: "text/html",
            encoding: "utf-8"
        )
    }
}

private actor SpeechFixture: AudioTranscribing {
    var needsModel = true
    var calls = 0
    func installFixtureModel() {
        needsModel = false
    }

    func transcribe(_ file: URL, locale _: String, downloadModel _: Bool) throws -> [TimedText] {
        calls += 1
        guard !needsModel else { throw MediaError.speechModelMissing }
        guard try Data(contentsOf: file) == Data("synthetic audio bytes".utf8)
        else { throw CaptureError.missingArtifact }
        return [TimedText(
            text: "Synthetic local transcription with cobaltbeacon.",
            start: 12,
            duration: 4
        )]
    }
}

private struct MediaFixture {
    let root: URL
    let store: DocumentStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DocumentStore(url: root.appending(path: "library.sqlite"))
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized)
struct MediaCaptureTests {
    private static func target(_ url: String) throws -> MediaTarget {
        let parsed = try #require(URL(string: url))
        return try #require(try MediaTarget.parse(parsed))
    }

    private static let video = "https://www.youtube.com/watch?v=abcdefghijk"
    private static let reddit = "https://www.reddit.com/comments/abc123/"
    private static let x = "https://x.com/i/status/12345"

    @Test func canonicalTargetsDoNotTrustLookalikeHostsOrCredentials() throws {
        let canonical = try Self.target(Self.video)
        for link in [
            "https://youtu.be/abcdefghijk?t=65",
            "https://www.youtube.com/shorts/abcdefghijk",
            "https://m.youtube.com/watch?v=abcdefghijk&list=ignored",
        ] {
            #expect(try Self.target(link) == canonical)
        }
        #expect(try Self.target("https://twitter.com/synthetic/status/12345?s=20").identity == Self
            .target(Self.x).identity)
        #expect(try Self.target("https://old.reddit.com/r/swift/comments/abc123/title/comment/")
            .identity == "reddit:abc123")
        #expect(try MediaTarget
            .parse(#require(URL(string: "https://youtube.com.evil.example/watch?v=abcdefghijk"))) ==
            nil)
        #expect(throws: CaptureError.self) {
            try Self.target("https://username:secret@youtube.com/watch?v=abcdefghijk")
        }
        #expect(throws: MediaError.self) { try Self.target("https://youtube.com/@channel") }
    }

    @Test func captionsPublishTimingAndReuseVideoIdentity() async throws {
        let fixture = try MediaFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [])
        let provider = MediaProviderFixture(), fetcher = MediaFetchFixture()
        let engine = IngestionEngine(
            store: fixture.store,
            fetcher: fetcher,
            youtube: provider,
            summarizer: FixtureLinkSummarizer()
        )
        _ = try await engine.enqueue(Self.video); try await engine.run()
        let snapshot = try await fixture.store.searchSnapshot(
            query: "cobaltbeacon",
            candidateLimit: 10
        )
        let match = try #require(snapshot.passages.first { $0.text.contains("Cobaltbeacon") })
        #expect(match.citation?.startTime == 65)
        #expect(match.citation?.endTime == 70)
        #expect(match.citation?.url?.query?.contains("t=65") == true)
        let detail = try await fixture.store.captureDetail(id: #require(match.citation?.captureID))
        #expect(detail.document.coverage == .transcript)
        #expect(detail.artifacts.map(\.kind) == [.capture, .json, .image, .markdown])
        let videoID = try #require(await fixture.store.documents().first?.id)
        #expect(try await fixture.store.libraryItemDetails(for: videoID).previewImage != nil)
        #expect(detail.document.markdown.contains("1:05"))
        _ = try await engine.enqueue("https://youtu.be/abcdefghijk?t=65"); try await engine.run()
        #expect(try await fixture.store.documents().count == 1)
        #expect(await provider.audioCalls == 0)
        #expect(await fetcher.requestedURLs == [
            URL(string: "https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg"),
            URL(string: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"),
            URL(string: "https://www.youtube.com/favicon.ico"),
        ])
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open(seed: [])
        #expect(try await reopened.searchSnapshot(query: "cobaltbeacon", candidateLimit: 10)
            .passages.contains { $0.citation?.startTime == 65 })
    }

    @Test func audioRequiresOptInAndRetryReusesRetainedBytes() async throws {
        let fixture = try MediaFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [])
        let provider = MediaProviderFixture(), fetcher = MediaFetchFixture(),
            speech = SpeechFixture()
        await provider.setMissing()
        let engine = IngestionEngine(
            store: fixture.store,
            fetcher: fetcher,
            youtube: provider,
            transcriber: speech,
            summarizer: FixtureLinkSummarizer()
        )
        _ = try await engine.enqueue(Self.video); try await engine.run()
        var job = try #require(await fixture.store.captureJobs().first)
        #expect(job.recovery == .audio)
        #expect(await provider.audioCalls == 0)
        try await fixture.store.resumeMedia(job, audioLocale: "en-US", downloadModel: false)
        try await engine.run()
        job = try #require(await fixture.store.captureJobs().first)
        #expect(job.state == .failed && job.recovery == .audio)
        #expect(job.acquired.first?.kind == .audio)
        #expect(await provider.audioCalls == 1)
        await speech.installFixtureModel()
        try await fixture.store.resumeMedia(job, audioLocale: "en-US", downloadModel: false)
        try await engine.run()
        #expect(try await fixture.store.captureJobs().first?.state == .ready)
        #expect(await provider.audioCalls == 1)
        #expect(await fetcher.requestedURLs == [
            URL(string: "https://fixture.example/audio.m4a"),
            URL(string: "https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg"),
            URL(string: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"),
            URL(string: "https://www.youtube.com/favicon.ico"),
        ])
        #expect(await speech.calls == 2)
    }

    @Test @MainActor func redditDOMPreservesNestedRepliesAndOmitsUnrelatedPosts() async throws {
        _ = NSApplication.shared
        let target = try Self.target(Self.reddit)
        let html = """
        <html><title>Synthetic Reddit</title><body>
        <shreddit-post id="t3_abc123" post-title="Synthetic root" author="fictional_author" permalink="/comments/abc123/" content-href="https://example.org/knowledge">
          <div slot="text-body"><p>A local knowledge discussion.</p></div>
        </shreddit-post>
        <shreddit-comment thingid="t1_first" author="fictional_reply" parentid="t3_abc123" permalink="/comments/abc123/_/first/">
          <div slot="comment">First reply with cobaltbeacon.</div>
          <shreddit-comment thingid="t1_child" author="fictional_child" parentid="t1_first" permalink="/comments/abc123/_/child/">
            <div slot="comment">Nested reply.</div>
          </shreddit-comment>
        </shreddit-comment>
        <input type="text" value="PRIVATE-FORM-VALUE"><script>document.body.textContent='scripts must not run';</script>
        </body></html>
        """
        let snapshot = try await SocialCapture.extractHTML(html, target: target)
        let document = try SocialCapture.document(snapshot, target: target)
        #expect(document.blocks.count == 3)
        #expect(document.blocks.first?.text.contains("https://example.org/knowledge") == true)
        #expect(document.blocks.first(where: { $0.externalID == "t1_child" })?
            .parentID == "t1_first")
        #expect(document.blocks.first(where: { $0.externalID == "t1_first" })?
            .text == "First reply with cobaltbeacon.")
        #expect(!document.markdown.contains("PRIVATE-FORM-VALUE"))
        #expect(!document.markdown.contains("scripts must not run"))
        #expect(document.coverage == .visibleThread)
    }

    @Test @MainActor func xDOMSeparatesQuotesWithoutGuessingReplyEdges() async throws {
        _ = NSApplication.shared
        let target = try Self.target(Self.x)
        let html = """
        <html><body>
        <article data-testid="tweet"><div data-testid="User-Name">Fictional author</div>
          <a href="https://x.com/fictional/status/12345"><time datetime="2026-01-01T00:00:00Z">Today</time></a>
          <div data-testid="tweetText">Root statement.</div>
          <div data-testid="quoteTweet"><div data-testid="User-Name">Quoted author</div>
            <a href="https://x.com/quoted/status/67890"><time datetime="2026-01-01T00:00:00Z">Today</time></a>
            <div data-testid="tweetText">A quoted statement.</div>
          </div>
        </article>
        <article data-testid="tweet"><a href="https://x.com/other/status/99999"><time>Today</time></a><div data-testid="tweetText">Unrelated recommendation.</div></article>
        </body></html>
        """
        let snapshot = try await SocialCapture.extractHTML(html, target: target)
        let document = try SocialCapture.document(snapshot, target: target)
        #expect(document.blocks.count == 2)
        #expect(document.blocks.first?.text == "Root statement.")
        #expect(document.blocks.last?.kind == .quote)
        #expect(!document.markdown.contains("Unrelated recommendation"))
        #expect(document.warnings.contains { $0.contains("parent references") })
    }

    @Test func browserRecoveryIsDurableAndRejectsWrongOrStalePages() async throws {
        let fixture = try MediaFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open(seed: [])
        let engine = IngestionEngine(
            store: fixture.store,
            fetcher: MediaFetchFixture(),
            youtube: MediaProviderFixture(),
            summarizer: FixtureLinkSummarizer()
        )
        _ = try await engine.enqueue(Self.reddit); try await engine.run()
        let job = try #require(await fixture.store.captureJobs().first)
        #expect(job.recovery == .browser)
        let target = try Self.target(Self.reddit)
        let post = SocialPost(
            id: "t3_abc123",
            url: target.url,
            text: "Synthetic root post.",
            author: "Fictional",
            published: nil,
            parentID: nil,
            quoteID: nil
        )
        let wrong = try SocialSnapshot(
            pageURL: #require(URL(string: "https://reddit.com/comments/other/")),
            title: "Wrong",
            posts: [post],
            truncated: false
        )
        await #expect(throws: MediaError.self) { try await engine.submitBrowserCapture(
            wrong,
            job: job
        ) }
        let snapshot = SocialSnapshot(
            pageURL: target.url,
            title: "Synthetic",
            posts: [post],
            truncated: false
        )
        try await engine.submitBrowserCapture(snapshot, job: job)
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open(seed: [])
        let resumed = IngestionEngine(
            store: reopened,
            fetcher: MediaFetchFixture(),
            summarizer: FixtureLinkSummarizer()
        )
        try await resumed.run()
        #expect(try await reopened.documents().count == 1)
        await #expect(throws: CaptureError.self) { try await engine.submitBrowserCapture(
            snapshot,
            job: job
        ) }
    }

    @Test func publicPlayabilityPreflightRejectsRestrictedOrWrongVideos() throws {
        let target = try Self.target(Self.video)
        let healthy = #"<script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"abcdefghijk","title":"A } quoted title","author":"Fictional","lengthSeconds":"70"}}; other();</script>"#
        #expect(try NativeYouTubeProvider.publicVideoInfo(html: healthy, target: target)
            .duration == 70)
        #expect(throws: MediaError.self) { try NativeYouTubeProvider.publicVideoInfo(
            html: healthy.replacingOccurrences(of: "OK", with: "LOGIN_REQUIRED"),
            target: target
        ) }
        #expect(throws: MediaError.self) { try NativeYouTubeProvider.publicVideoInfo(
            html: healthy.replacingOccurrences(of: "abcdefghijk", with: "differentID"),
            target: target
        ) }
        #expect(JSONAssignment
            .object(in: #"{"text":"escaped \" } brace"}; trailing"#[...]) ==
            #"{"text":"escaped \" } brace"}"#)
    }

    @Test @MainActor func browserRulesCompileAndSessionIsPrivate() async throws {
        _ = NSApplication.shared
        let session = try SocialBrowserSession(target: Self.target(Self.reddit))
        #expect(!session.webView.configuration.websiteDataStore.isPersistent)
        let identifier = "gleanary-fixture-" + UUID().uuidString
        let rules = try SocialBrowserSession.networkRules()
        let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: rules
        )
        #expect(compiled != nil)
        let decoded = try JSONDecoder().decode(
            [[String: [String: String]]].self,
            from: Data(rules.utf8)
        )
        let patterns = decoded.dropFirst().compactMap { $0["trigger"]?["url-filter"] }
        for address in [
            "https://reddit.com.evil.example/",
            "http://reddit.com/",
            "https://127.0.0.1/",
        ] {
            #expect(!patterns
                .contains { address.range(of: $0, options: .regularExpression) != nil })
        }
        #expect(patterns.contains { "https://www.reddit.com/comments/abc123/".range(
            of: $0,
            options: .regularExpression
        ) != nil })
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
        session.close()
    }

    @Test func speechWordTimingPreservesUntimedPunctuation() {
        var first = AttributedString("First")
        first.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 2, preferredTimescale: 1000),
            duration: CMTime(seconds: 1, preferredTimescale: 1000)
        )
        var second = AttributedString("second")
        second.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: 40, preferredTimescale: 1000),
            duration: CMTime(seconds: 2, preferredTimescale: 1000)
        )
        let text = AttributedString("(") + first + AttributedString(", ") + second +
            AttributedString(").")
        let result = LocalTranscriber.timedSegments(
            text,
            fallback: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 50, preferredTimescale: 1000)
            )
        )
        #expect(result.map(\.text) == ["(First, ", "second)."])
        #expect(result.map(\.start) == [2, 40])
        #expect(result.map(\.duration) == [1, 2])
    }

    @Test func overlappingCaptionCuesKeepTheirOrder() throws {
        let transcript = VideoTranscript(
            videoID: "abcdefghijk",
            title: "Overlapping",
            author: "",
            language: "en",
            generated: false,
            method: "fixture",
            segments: [
                TimedText(text: "how your product is in terms", start: 333.7, duration: 2),
                TimedText(text: "of primitives.", start: 329.9, duration: 4),
            ]
        )
        let document = try transcript.document(for: Self.target(Self.video))
        #expect(document.blocks.map(\.text) == ["how your product is in terms of primitives."])
    }

    @Test func transcriptBoundsAndBrowserNavigationFailClosed() throws {
        let bad = VideoTranscript(
            videoID: "abcdefghijk",
            title: "Bad",
            author: "",
            language: "en",
            generated: true,
            method: "fixture",
            segments: [TimedText(text: "Text", start: -.infinity, duration: 1)]
        )
        #expect(throws: CaptureError.self) { try bad.document(for: Self.target(Self.video)) }
        #expect(try SocialBrowserSession.allowedNavigation(
            #require(URL(string: "https://www.reddit.com/login/")),
            site: .reddit,
            mainFrame: true
        ))
        for url in [
            "file:///etc/passwd",
            "http://reddit.com/",
            "https://reddit.com.evil.example/",
            "https://127.0.0.1/",
            "https://reddit.com:8080/",
        ] {
            #expect(try !SocialBrowserSession.allowedNavigation(
                #require(URL(string: url)),
                site: .reddit,
                mainFrame: true
            ))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_NATIVE_SPEECH_TESTS"] == "1"))
    func nativeSpeechOnSyntheticAudio() async throws {
        let fixture = try MediaFixture(); defer { fixture.clean() }
        let audio = fixture.root.appending(path: "synthetic.aiff")
        let voice = Process()
        voice.executableURL = URL(filePath: "/usr/bin/say")
        voice.arguments = [
            "-v",
            "Samantha",
            "-o",
            audio.path,
            "The bright blue bird is singing. This is a synthetic recording for a local speech recognition test.",
        ]
        try voice.run(); voice.waitUntilExit()
        #expect(voice.terminationStatus == 0)
        let segments = try await LocalTranscriber().transcribe(
            audio,
            locale: "en-US",
            downloadModel: false
        )
        #expect(segments.map(\.text).joined(separator: " ").lowercased().contains("bird"))
        #expect(segments.allSatisfy { $0.start.isFinite && $0.duration > 0 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_AUDIO_TESTS"] == "1"))
    func liveLocalAudioResolution() async throws {
        let target = try Self.target("https://www.youtube.com/watch?v=jNQXAC9IVRw")
        let result = try await NativeYouTubeProvider().audio(for: target)
        #expect(result.info.duration > 0)
        #expect(result.url.host?.hasSuffix(".googlevideo.com") == true)
        let downloaded = try await SourceFetcher().fetch(result.url)
        #expect(!downloaded.data.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_MEDIA_TESTS"] == "1"))
    func liveNativeCaptions() async throws {
        let target = try Self.target("https://www.youtube.com/watch?v=jNQXAC9IVRw")
        let result = try await NativeYouTubeProvider().transcript(for: target)
        #expect(!result.segments.isEmpty)
        var document = try result.document(for: target)
        try document.validate()
        #expect(document.blocks.first?.startTime != nil)
    }
}
