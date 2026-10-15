import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing
import WebKit

private struct PageFetcher: SourceFetching {
    /// A share card the page names, and the image served for it.
    var shareImage: (url: String, data: Data)?

    func fetch(_ url: URL) throws -> DownloadedContent {
        if let shareImage, url.absoluteString == shareImage.url {
            return DownloadedContent(
                data: shareImage.data, url: url, mime: "image/png", encoding: nil
            )
        }
        let meta = shareImage.map { "<meta property=\"og:image\" content=\"\($0.url)\">" } ?? ""
        return DownloadedContent(
            data: Data("""
            <!doctype html><html><head><title>Screenshot fixture</title>\(meta)</head>
            <body><article><h1>Screenshot fixture</h1>
            <p>\(String(repeating: "Quartzlantern pages keep a visual record next to their extracted text. ", count: 12))</p>
            <p>\(String(repeating: "The rendered image is retained beside the original HTML. ", count: 12))</p>
            </article></body></html>
            """.utf8),
            url: url,
            mime: "text/html",
            encoding: "utf-8"
        )
    }
}

private actor StubScreenshotter: PageScreenshotting {
    let result: Result<Data, CaptureError>
    let heroTop: Int?
    private(set) var requested: [URL] = []

    init(_ result: Result<Data, CaptureError>, heroTop: Int? = nil) {
        self.result = result
        self.heroTop = heroTop
    }

    func capture(_ url: URL) throws -> PageScreenshot {
        requested.append(url)
        return try PageScreenshot(image: result.get(), heroTop: heroTop)
    }
}

/// The CLI test helper cannot write WebKit's default rule store.
private struct TemporaryRuleStoreScreenshotter: PageScreenshotting {
    let root: URL

    func capture(_ url: URL) async throws -> PageScreenshot {
        let store = try #require(WKContentRuleListStore(url: root))
        return try await PageScreenshotSession(ruleStore: store).capture(url)
    }
}

/// A solid image, as a share card or logo.
@MainActor private func solidImage(width: Int, height: Int, color: NSColor) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

/// A tall synthetic page: a red masthead over a blue body.
@MainActor private func syntheticScreenshot(width: Int = 1280, height: Int = 4000) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.blue.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor.red.setFill()
    // AppKit drawing grows upward, so the masthead is the highest rows.
    NSRect(x: 0, y: height - width / 2, width: width, height: width / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.representation(using: .jpeg, properties: [:]))
}

@Suite(.serialized)
struct PageScreenshotTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func capture(
        with screenshotter: StubScreenshotter,
        fetcher: PageFetcher = PageFetcher(),
        settings: CaptureSettings = CaptureSettings()
    ) async throws -> CaptureDetail {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let engine = IngestionEngine(
            store: store,
            fetcher: fetcher,
            summarizer: FixtureLinkSummarizer(),
            screenshotter: screenshotter,
            settings: { settings }
        )
        _ = try await engine.enqueue("https://fixture.example/page")
        try await engine.run()
        let note = try #require(await store.documents().first)
        let captureID = try #require(await store.captureID(for: note.id))
        return try await store.captureDetail(id: captureID)
    }

    @Test @MainActor func webCapturesRetainAScreenshot() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Data("synthetic jpeg bytes".utf8)
        let screenshotter = StubScreenshotter(.success(image))
        let detail = try await capture(with: screenshotter)
        let screenshot = try #require(detail.artifacts.first { $0.kind == .image })
        #expect(screenshot.name == "Screenshot.jpg")
        #expect(screenshot.sourceURL?.absoluteString == "https://fixture.example/page")
        #expect(await screenshotter.requested.map(\.absoluteString) == [
            "https://fixture.example/page",
        ])
        let artifacts = ArtifactStore(root: root.appending(path: "artifacts"))
        #expect(try await artifacts.data(for: screenshot) == image)
    }

    @Test @MainActor func screenshotFailureStillCapturesText() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try await capture(with: StubScreenshotter(.failure(.extractionFailed)))
        #expect(!detail.artifacts.contains { $0.kind == .image })
        #expect(detail.document.markdown.contains("Quartzlantern"))
    }

    @Test @MainActor func networkRulesCompile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try #require(WKContentRuleListStore(url: root))
        let rules = try await store.compileContentRuleList(
            forIdentifier: "gleanary-page-screenshot-test",
            encodedContentRuleList: PageScreenshotSession.networkRules()
        )
        #expect(rules != nil)
    }

    @Test @MainActor func previewKeepsOnlyTheTopOfThePage() throws {
        let preview = try #require(PagePreview.thumbnail(syntheticScreenshot()))
        let image = try #require(NSBitmapImageRep(data: preview))
        #expect(image.pixelsWide == PagePreview.pixelWidth)
        #expect(image.pixelsHigh == PagePreview.pixelWidth / 2)
        for y in [2, image.pixelsHigh / 2, image.pixelsHigh - 3] {
            let color = try #require(image.colorAt(x: image.pixelsWide / 2, y: y))
            #expect(color.redComponent > 0.8 && color.blueComponent < 0.2)
        }
        #expect(PagePreview.thumbnail(Data("not an image".utf8)) == nil)
    }

    @Test func heroPlacementFollowsTheHeadingAndLeadImage() {
        let height = 6000
        // A hero already at the top keeps the masthead.
        #expect(PagePreview.heroTop(PageLandmarks(heading: 180), pageHeight: height) == nil)
        #expect(PagePreview.heroTop(PageLandmarks(heading: 900), pageHeight: height) == 804)
        // A lead image just above the heading is pulled in.
        #expect(PagePreview.heroTop(
            PageLandmarks(heading: 1200, mediaTop: 700, mediaHeight: 400), pageHeight: height
        ) == 676)
        // One far above it belongs to something else.
        #expect(PagePreview.heroTop(
            PageLandmarks(heading: 1500, mediaTop: 300, mediaHeight: 400), pageHeight: height
        ) == 1404)
        #expect(PagePreview.heroTop(
            PageLandmarks(mediaTop: 1000, mediaHeight: 500), pageHeight: height
        ) == 976)
        #expect(PagePreview.heroTop(PageLandmarks(), pageHeight: height) == nil)
        // Never past the last full band.
        #expect(PagePreview.heroTop(PageLandmarks(heading: 5900), pageHeight: height) == 5360)
    }

    @Test @MainActor func heroCropBecomesThePreview() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        // The red masthead fills the top 640 rows; a hero further down is blue.
        let detail = try await capture(
            with: StubScreenshotter(.success(syntheticScreenshot()), heroTop: 1600)
        )
        let names = detail.artifacts.filter { $0.kind == .image }.map(\.name)
        #expect(names == [IngestionEngine.screenshotName, IngestionEngine.heroName])
        let preview = try #require(await previewImage())
        let color = try #require(preview.colorAt(x: preview.pixelsWide / 2, y: 4))
        #expect(color.blueComponent > 0.8 && color.redComponent < 0.2)
    }

    @Test @MainActor func aWideShareImageWinsOverTheScreenshot() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try solidImage(width: 1200, height: 630, color: .green)
        let detail = try await capture(
            with: StubScreenshotter(.success(syntheticScreenshot())),
            fetcher: PageFetcher(shareImage: ("https://fixture.example/card.png", card))
        )
        let share = try #require(detail.artifacts.first {
            $0.name == IngestionEngine.shareImageName
        })
        #expect(share.sourceURL?.absoluteString == "https://fixture.example/card.png")
        let preview = try #require(await previewImage())
        let color = try #require(preview.colorAt(x: preview.pixelsWide / 2, y: 4))
        #expect(color.greenComponent > 0.8 && color.redComponent < 0.2)
    }

    @Test @MainActor func previewsOffFetchesNoStills() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try solidImage(width: 1200, height: 630, color: .green)
        let screenshotter = try StubScreenshotter(.success(syntheticScreenshot()))
        let detail = try await capture(
            with: screenshotter,
            fetcher: PageFetcher(shareImage: ("https://fixture.example/card.png", card)),
            settings: CaptureSettings(previews: false)
        )
        #expect(await screenshotter.requested.isEmpty)
        #expect(!detail.artifacts.contains { $0.kind == .image })
        #expect(try await previewImage() == nil)
    }

    @Test @MainActor func aSquareLogoIsNotAShareImage() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let logo = try solidImage(width: 800, height: 800, color: .green)
        let detail = try await capture(
            with: StubScreenshotter(.success(syntheticScreenshot())),
            fetcher: PageFetcher(shareImage: ("https://fixture.example/logo.png", logo))
        )
        #expect(!detail.artifacts.contains { $0.name == IngestionEngine.shareImageName })
        let preview = try #require(await previewImage())
        let color = try #require(preview.colorAt(x: preview.pixelsWide / 2, y: 4))
        #expect(color.redComponent > 0.8)
    }

    private func previewImage() async throws -> NSBitmapImageRep? {
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        return try await store.documentPage().documents.first?.previewImage
            .flatMap(NSBitmapImageRep.init(data:))
    }

    @Test @MainActor func libraryRowsCarryThePagePreview() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await capture(with: StubScreenshotter(.success(syntheticScreenshot())))
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let row = try #require(await store.documentPage().documents.first)
        let preview = try #require(row.previewImage)
        #expect(NSBitmapImageRep(data: preview)?.pixelsWide == PagePreview.pixelWidth)
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LIVE_SCREENSHOT_TESTS"] == "1"))
    @MainActor func liveLibraryListShowsPagePreviews() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let engine = IngestionEngine(
            store: store,
            summarizer: FixtureLinkSummarizer(),
            screenshotter: TemporaryRuleStoreScreenshotter(root: root)
        )
        for page in [
            "https://en.wikipedia.org/wiki/Zettelkasten",
            "https://www.apple.com/newsroom/",
            "https://www.swift.org/blog/",
        ] {
            _ = try await engine.enqueue(page)
        }
        _ = try await engine.enqueue("# Reading plan\n\nCompare the three saved sources.")
        try await engine.run()
        #expect(try await store.documentPage().documents.contains { $0.previewImage != nil })
        guard let directory = ProcessInfo.processInfo.environment["GLEANARY_LIBRARY_SCREENSHOTS"]
        else { return }
        UserDefaults.standard.set(LibraryPresentation.list.rawValue, forKey: "libraryPresentation")
        defer { UserDefaults.standard.removeObject(forKey: "libraryPresentation") }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: ContentView(library: LibraryModel(store: store)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            for _ in 0 ..< 8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appending(path: "library-previews-\(name).png"))
        }
    }

    /// Writes each page's chosen preview and its source next to the screenshots for review.
    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LIBRARY_SCREENSHOTS"] != nil))
    @MainActor func liveHeroPreviews() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try URL(fileURLWithPath: #require(
            ProcessInfo.processInfo.environment["GLEANARY_LIBRARY_SCREENSHOTS"]
        ))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let engine = IngestionEngine(
            store: store,
            summarizer: FixtureLinkSummarizer(),
            screenshotter: TemporaryRuleStoreScreenshotter(root: root)
        )
        let pages = (ProcessInfo.processInfo.environment["GLEANARY_HERO_PAGES"] ?? "")
            .split(separator: " ").map(String.init)
        for page in pages {
            _ = try await engine.enqueue(page)
        }
        try await engine.run()
        for job in try await store.captureJobs() where job.state != .ready {
            print("hero failed \(job.request.identity): \(job.state) \(job.error ?? "")")
        }
        for document in try await store.documentPage().documents {
            guard let preview = document.previewImage,
                  let captureID = try await store.captureID(for: document.id) else { continue }
            let stills = try await store.captureDetail(id: captureID).artifacts
                .filter { $0.kind == .image }.map(\.name)
            let host = document.sourceURL?.host() ?? document.id.uuidString
            try preview.write(to: directory.appending(path: "hero-\(host).jpg"))
            print("hero \(host): \(stills.joined(separator: ", "))")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LIVE_SCREENSHOT_TESTS"] == "1"))
    @MainActor func liveScreenshotRendersAPublicPage() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.com/"))
        let data = try await TemporaryRuleStoreScreenshotter(root: root).capture(url).image
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide >= Int(PageScreenshotSession.width))
        #expect(image.pixelsHigh >= Int(PageScreenshotSession.viewportHeight))
    }
}
