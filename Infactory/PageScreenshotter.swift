import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import WebKit

struct PageScreenshot: Sendable, Equatable {
    /// JPEG bytes of the rendered page, top-aligned and capped in height.
    var image: Data
    /// Where the page's hero (title and lead image) starts, in screenshot pixels; nil when the
    /// layout gave no clear answer.
    var heroTop: Int?
}

protocol PageScreenshotting: Sendable {
    func capture(_ url: URL) async throws -> PageScreenshot
}

struct WebPageScreenshotter: PageScreenshotting {
    func capture(_ url: URL) async throws -> PageScreenshot {
        try await PageScreenshotSession().capture(url)
    }
}

/// A live, script-enabled render of a public page, used only for a visual record.
/// Main-frame and subframe navigations get full URLPolicy DNS validation. Subresources can only
/// be filtered by URL pattern, so a public hostname that resolves to a private address is not
/// caught for images, styles, scripts or fetches; the session holds no cookies or credentials.
@MainActor final class PageScreenshotSession: NSObject, WKNavigationDelegate {
    nonisolated static let width: CGFloat = 1280
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

    func capture(_ url: URL) async throws -> PageScreenshot {
        guard url.scheme == "https" || url.scheme == "http" else { throw CaptureError.unsafeURL }
        try await policy.validate(url)
        let view = try await makeWebView()
        defer { tearDown() }
        try await load(url, in: view)
        // Let script-rendered content and late layout settle before measuring.
        try await Task.sleep(for: .seconds(1.5))
        _ = try? await view.evaluateJavaScript(Self.hideOverlays)
        let measured = try await view.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
        ) as? Double
        let height = min(Self.maximumHeight, max(Self.viewportHeight, measured ?? 0))
        view.setFrameSize(NSSize(width: Self.width, height: height))
        try await Task.sleep(for: .milliseconds(300))
        // Measured after the resize, since viewport-relative heroes change height with it.
        let landmarks = await (try? view.evaluateJavaScript(Self.findLandmarks) as? String)
            .flatMap { try? JSONDecoder().decode(PageLandmarks.self, from: Data($0.utf8)) }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: Self.width, height: height)
        configuration.snapshotWidth = NSNumber(value: Double(Self.width))
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        let (jpeg, pixelHeight) = try Self.jpeg(image)
        // Landmarks are in page points; the snapshot may be at a higher pixel scale.
        let scale = Double(pixelHeight) / height
        return PageScreenshot(
            image: jpeg,
            heroTop: landmarks.flatMap { PagePreview.heroTop($0, pageHeight: Int(height)) }
                .map { Int(Double($0) * scale) }
        )
    }

    /// Cookie banners, newsletter prompts and sticky navigation would otherwise cover the page
    /// or repeat over it. Fixed backgrounds behind the content (negative z-index) stay. Modal
    /// prompts often lock scrolling, so that's undone too.
    static let hideOverlays = """
    (() => {
      const all = document.body ? document.body.querySelectorAll('*') : [];
      for (let i = 0; i < Math.min(all.length, 8000); i++) {
        const el = all[i], style = getComputedStyle(el);
        if ((style.position === 'fixed' || style.position === 'sticky')
            && !(parseInt(style.zIndex, 10) < 0)) {
          el.style.setProperty('display', 'none', 'important');
        }
      }
      for (const el of [document.documentElement, document.body]) {
        if (el) { el.style.setProperty('overflow', 'visible', 'important'); }
      }
      return true;
    })()
    """

    /// The page's first visible heading and its largest image near the top, in page pixels.
    static let findLandmarks = """
    (() => {
      const box = el => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 ? { top: r.top + window.scrollY, height: r.height, width: r.width } : null;
      };
      let heading = null;
      for (const el of document.querySelectorAll('h1')) {
        const b = box(el);
        if (b && b.height >= 12 && b.width >= 100) { heading = b; break; }
      }
      let media = null, area = 0;
      for (const el of document.querySelectorAll('img, picture, video, canvas, svg')) {
        const b = box(el);
        if (!b || b.width < 320 || b.height < 160 || b.top > 2400) { continue; }
        if (b.width * b.height > area) { area = b.width * b.height; media = b; }
      }
      return JSON.stringify({
        heading: heading ? heading.top : null,
        mediaTop: media ? media.top : null,
        mediaHeight: media ? media.height : null
      });
    })()
    """

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

    private static func jpeg(_ image: NSImage) throws -> (Data, Int) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage)
              .representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw CaptureError.extractionFailed }
        guard data.count <= CaptureLimits.artifactBytes else { throw CaptureError.tooLarge }
        return (data, cgImage.height)
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

struct PageLandmarks: Decodable, Equatable {
    var heading: Double?
    var mediaTop: Double?
    var mediaHeight: Double?
}

/// The Library row header: the page's hero (title and lead image), not a shrunken full page.
enum PagePreview {
    /// Width to height. Rows clip further from the top, so this only bounds what is stored.
    static let aspectRatio: CGFloat = 2
    static let pixelWidth = 640
    /// A hero this close to the top keeps the masthead above it instead.
    static let mastheadAllowance = 240

    /// Where a 2:1 band showing the hero starts, from the page's landmarks: a little above its
    /// first heading, pulled up to include a lead image just above that heading. Nil when the
    /// page has no heading or lead image, or when the hero already sits at the top.
    static func heroTop(_ landmarks: PageLandmarks, pageHeight: Int) -> Int? {
        let band = Double(PageScreenshotSession.width) / aspectRatio
        var top: Double
        if let heading = landmarks.heading {
            top = heading - 96
            if let media = landmarks.mediaTop, media < heading, media > heading - band {
                top = min(top, media - 24)
            }
        } else if let media = landmarks.mediaTop {
            top = media - 24
        } else {
            return nil
        }
        let latest = Double(max(0, pageHeight - Int(band)))
        let clamped = Int(min(max(0, top), latest))
        return clamped <= mastheadAllowance ? nil : clamped
    }

    /// Where the most eye-catching part of a page's first screens is, for pages whose layout
    /// gave no hero. Nil when it is already at the top or Vision finds nothing.
    static func salientTop(_ screenshot: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(screenshot as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0,
              let window = image.cropping(to: CGRect(
                  x: 0, y: 0, width: image.width, height: min(image.height, image.width * 2)
              )) else { return nil }
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: window).perform([request])
        guard let salient = request.results?.first?.salientObjects?
            .max(by: { $0.confidence < $1.confidence }) else { return nil }
        let band = Int(CGFloat(image.width) / aspectRatio)
        // Vision's origin is bottom-left.
        let center = Int((1 - salient.boundingBox.midY) * CGFloat(window.height))
        let top = min(max(0, center - band / 2), max(0, image.height - band))
        return top <= mastheadAllowance ? nil : top
    }

    /// Pages keep their top or start at `top`; share images and video stills crop around the
    /// centre, which also trims YouTube's letterbox bars.
    static func thumbnail(_ screenshot: Data, centered: Bool = false, top: Int = 0) -> Data? {
        guard let source = CGImageSourceCreateWithData(screenshot as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0 else { return nil }
        let cropHeight = min(image.height, Int(CGFloat(image.width) / aspectRatio))
        let origin = centered ? (image.height - cropHeight) / 2
            : min(max(0, top), image.height - cropHeight)
        guard let top = image.cropping(to: CGRect(
            x: 0, y: origin, width: image.width, height: cropHeight
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
