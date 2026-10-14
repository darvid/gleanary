import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

protocol PageScreenshotting: Sendable {
    /// JPEG bytes of the rendered page, top-aligned and capped in height.
    func capture(_ url: URL) async throws -> Data
}

struct WebPageScreenshotter: PageScreenshotting {
    func capture(_ url: URL) async throws -> Data {
        try await PageScreenshotSession().capture(url)
    }
}

/// A live, script-enabled render of a public page, used only for a visual record.
/// Main-frame and subframe navigations get full URLPolicy DNS validation. Subresources can only
/// be filtered by URL pattern, so a public hostname that resolves to a private address is not
/// caught for images, styles, scripts or fetches; the session holds no cookies or credentials.
@MainActor final class PageScreenshotSession: NSObject, WKNavigationDelegate {
    static let width: CGFloat = 1280
    static let viewportHeight: CGFloat = 800
    static let maximumHeight: CGFloat = 6000

    private var webView: WKWebView?
    private var window: NSWindow?
    private var pending: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?
    private let policy = URLPolicy()
    private let ruleStore: WKContentRuleListStore

    init(ruleStore: WKContentRuleListStore = .default()) {
        self.ruleStore = ruleStore
    }

    func capture(_ url: URL) async throws -> Data {
        guard url.scheme == "https" || url.scheme == "http" else { throw CaptureError.unsafeURL }
        try await policy.validate(url)
        let view = try await makeWebView()
        defer { tearDown() }
        try await load(url, in: view)
        // Let script-rendered content and late layout settle before measuring.
        try await Task.sleep(for: .seconds(1.5))
        let measured = try await view.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
        ) as? Double
        let height = min(Self.maximumHeight, max(Self.viewportHeight, measured ?? 0))
        view.setFrameSize(NSSize(width: Self.width, height: height))
        try await Task.sleep(for: .milliseconds(300))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: Self.width, height: height)
        configuration.snapshotWidth = NSNumber(value: Double(Self.width))
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        return try Self.jpeg(image)
    }

    private func makeWebView() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let rules = try await ruleStore.compileContentRuleList(
            forIdentifier: "infactory-page-screenshot-v1",
            encodedContentRuleList: Self.networkRules()
        )
        if let rules {
            configuration.userContentController.add(rules)
        }
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        // A fixed appearance keeps records consistent regardless of the system theme.
        view.appearance = NSAppearance(named: .aqua)
        // WebKit only lays out and paints reliably inside a window; this one is never shown.
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window
        webView = view
        return view
    }

    private func load(_ url: URL, in view: WKWebView) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    self?.finish(.failure(CaptureError.extractionFailed))
                }
                view.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.absoluteString == "about:blank" || url.scheme == "about" {
            return .allow
        }
        guard url.scheme == "https" || url.scheme == "http" else { return .cancel }
        do { try await policy.validate(url); return .allow }
        catch { return .cancel }
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: any Error) {
        finish(.failure(CaptureError.extractionFailed))
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError _: any Error
    ) {
        finish(.failure(CaptureError.extractionFailed))
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        finish(.failure(CaptureError.extractionFailed))
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let pending else { return }
        self.pending = nil
        timeout?.cancel()
        timeout = nil
        pending.resume(with: result)
    }

    private func tearDown() {
        finish(.failure(CancellationError()))
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        let dataStore = webView.configuration.websiteDataStore
        Task { await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) }
        window?.contentView = nil
        window = nil
        self.webView = nil
    }

    private static func jpeg(_ image: NSImage) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage)
              .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw CaptureError.extractionFailed }
        guard data.count <= CaptureLimits.artifactBytes else { throw CaptureError.tooLarge }
        return data
    }

    /// Block everything except public-looking http(s) and inline data. WebKit's rule compiler
    /// has no alternation, so each private range is its own rule; later rules win.
    static func networkRules() throws -> String {
        var rules: [[String: [String: String]]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
        ]
        for allowed in ["^https?://", "^data:", "^blob:"] {
            rules.append([
                "trigger": ["url-filter": allowed],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let privateHosts = [
            "localhost[:/]", "[^/]*\\.localhost[:/]", "[^/]*\\.local[:/]", "[^/]*\\.internal[:/]",
            "\\[", "[^/]*@", "[^/]*:[0-9]",
            "0\\.", "10\\.", "127\\.", "169\\.254\\.", "192\\.168\\.",
            "172\\.1[6-9]\\.", "172\\.2[0-9]\\.", "172\\.3[01]\\.",
            "100\\.6[4-9]\\.", "100\\.[7-9][0-9]\\.", "100\\.1[01][0-9]\\.", "100\\.12[0-7]\\.",
        ]
        for host in privateHosts {
            rules.append([
                "trigger": ["url-filter": "^https?://" + host],
                "action": ["type": "block"],
            ])
        }
        return try String(decoding: JSONEncoder().encode(rules), as: UTF8.self)
    }
}

/// The Library row header: the top of the page (masthead and hero), not a shrunken full page.
enum PagePreview {
    /// Width to height. Rows clip further from the top, so this only bounds what is stored.
    static let aspectRatio: CGFloat = 2
    static let pixelWidth = 640

    /// Pages keep their top (masthead and hero); video stills crop around the centre, which also
    /// trims YouTube's letterbox bars.
    static func thumbnail(_ screenshot: Data, centered: Bool = false) -> Data? {
        guard let source = CGImageSourceCreateWithData(screenshot as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0 else { return nil }
        let cropHeight = min(image.height, Int(CGFloat(image.width) / aspectRatio))
        guard let top = image.cropping(to: CGRect(
            x: 0, y: centered ? (image.height - cropHeight) / 2 : 0,
            width: image.width, height: cropHeight
        )) else { return nil }
        let width = min(pixelWidth, top.width)
        let height = max(1, Int(CGFloat(top.height) * CGFloat(width) / CGFloat(top.width)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(top, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
