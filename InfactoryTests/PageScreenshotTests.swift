import AppKit
import Foundation
@testable import Infactory
import SwiftUI
import Testing
import WebKit

private struct PageFetcher: SourceFetching {
    func fetch(_ url: URL) throws -> DownloadedContent {
        DownloadedContent(
            data: Data("""
            <!doctype html><html><head><title>Screenshot fixture</title></head>
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
    private(set) var requested: [URL] = []

    init(_ result: Result<Data, CaptureError>) {
        self.result = result
    }

    func capture(_ url: URL) throws -> Data {
        requested.append(url)
        return try result.get()
    }
}

/// The CLI test helper cannot write WebKit's default rule store.
private struct TemporaryRuleStoreScreenshotter: PageScreenshotting {
    let root: URL

    func capture(_ url: URL) async throws -> Data {
        let store = try #require(WKContentRuleListStore(url: root))
        return try await PageScreenshotSession(ruleStore: store).capture(url)
    }
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

    private func capture(with screenshotter: StubScreenshotter) async throws -> CaptureDetail {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let engine = IngestionEngine(
            store: store,
            fetcher: PageFetcher(),
            summarizer: FixtureLinkSummarizer(),
            screenshotter: screenshotter
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
            forIdentifier: "infactory-page-screenshot-test",
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
            .environment["INFACTORY_LIVE_SCREENSHOT_TESTS"] == "1"))
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
        guard let directory = ProcessInfo.processInfo.environment["INFACTORY_LIBRARY_SCREENSHOTS"]
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

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["INFACTORY_LIVE_SCREENSHOT_TESTS"] == "1"))
    @MainActor func liveScreenshotRendersAPublicPage() async throws {
        _ = NSApplication.shared
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.com/"))
        let data = try await TemporaryRuleStoreScreenshotter(root: root).capture(url)
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide >= Int(PageScreenshotSession.width))
        #expect(image.pixelsHigh >= Int(PageScreenshotSession.viewportHeight))
    }
}
