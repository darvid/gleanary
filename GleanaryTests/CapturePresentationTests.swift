import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

struct CapturePresentationTests {
    private func job(
        _ url: URL? = nil,
        label: String? = nil,
        title: String? = nil,
        submittedURL: URL? = nil
    ) -> CaptureJob {
        CaptureJob(
            id: UUID(), token: UUID(),
            request: CaptureRequest(
                url: url,
                identity: "synthetic",
                label: label ?? url?.absoluteString ?? "",
                submittedURL: submittedURL
            ),
            state: .ready, acquired: [], progress: "Saved locally", error: nil, noteID: UUID(),
            savedTitle: title
        )
    }

    @Test func savedTitlesAndHostnamesReplaceRawAddressesWithoutChangingTheRequest() throws {
        let url =
            try #require(
                URL(string: "https://www.example.test/docs/en/guide?tracking=synthetic#section")
            )
        let capture = job(url, title: "  Synthetic guide to a local library  ")
        let display = CaptureRowPresentation(capture)
        #expect(display.title == "Synthetic guide to a local library")
        #expect(display.hostname == "example.test")
        #expect(display.url == url)
        #expect(capture.request.label == url.absoluteString)
        #expect(capture.request.identity == "synthetic")
    }

    @Test func fallbacksKeepPagesDistinctAndHideQueriesAndSchemes() throws {
        for page in ["first-guide", "second-guide"] {
            let url =
                try #require(
                    URL(
                        string: "https://example.test/docs/en/reference/\(page)?tracking=synthetic#anchor"
                    )
                )
            let display = CaptureRowPresentation(job(url, title: url.absoluteString))
            #expect(display.title == "example.test/docs/…/" + page)
            #expect(display.hostname == nil)
            #expect(display.url?.absoluteString == url.absoluteString)
        }
        let root = try #require(URL(string: "https://example.test/?tracking=synthetic"))
        #expect(CaptureRowPresentation(job(root)).title == "example.test")
    }

    @Test func longPathsAreBoundedWithoutBreakingUnicodeOrLosingTheFilename() throws {
        let url = try #require(URL(string: "https://example.test/" + String(
            repeating: "界",
            count: 300
        ) + "/guide.html"))
        let display = CaptureRowPresentation(job(url))
        #expect(display.title.count <= "example.test".count + 72)
        #expect(display.title.hasSuffix("/guide.html"))
        #expect(display.url == url)
    }

    @Test func submittedURLsRemainAvailableAndLocalCapturesKeepTheirNames() throws {
        let canonical = try #require(URL(string: "https://example.test/paper"))
        let original =
            try #require(URL(string: "https://example.test/paper?source=synthetic#section"))
        let capture = job(canonical, title: "Synthetic paper", submittedURL: original)
        #expect(CaptureRowPresentation(capture).url == original)
        #expect(CaptureRowPresentation(job(label: "Synthetic report.pdf"))
            .title == "Synthetic report.pdf")
        #expect(CaptureRowPresentation(job(label: "Synthetic report.pdf")).hostname == nil)
        #expect(CaptureRowPresentation(job()).title == "Untitled capture")
        #expect(CaptureRowPresentation(job(canonical, label: "Synthetic link title"))
            .title == "Synthetic link title")
    }

    @Test @MainActor func headingsFitNarrowAndWideRowsInBothAppearances() throws {
        let url = try #require(URL(string: "https://www.example.test/docs/en/guide/" + String(
            repeating: "long-path-",
            count: 25
        ) + "?tracking=synthetic"))
        let samples = [
            job(
                url,
                title: "A synthetic guide to preserving readable source titles across narrow Library capture rows"
            ),
            job(url),
            job(label: "Synthetic imported report.pdf"),
        ]
        for width in [CGFloat(240), 420] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        CaptureRowHeading(presentation: CaptureRowPresentation(sample))
                    }
                }.padding(16).frame(width: width, height: 300, alignment: .topLeading)
                    .preferredColorScheme(dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width <= width)
                #expect(host.fittingSize.height <= 300)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if ProcessInfo.processInfo
                    .environment["GLEANARY_CAPTURE_HEADING_SCREENSHOTS"] == "1"
                {
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png
                        .write(
                            to: URL(
                                fileURLWithPath: "/tmp/gleanary-capture-heading-\(Int(width))-\(dark ? "dark" : "light").png"
                            )
                        )
                }
            }
        }
    }
}
