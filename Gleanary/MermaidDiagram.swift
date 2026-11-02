import AppKit
import SwiftUI
import WebKit

/// Mermaid diagrams in Markdown, written as a `mermaid` code fence.
enum MermaidDiagram {
    /// The diagram source when a Markdown block is a `mermaid` fence.
    nonisolated static func source(_ block: String) -> String? {
        let lines = block.components(separatedBy: "\n")
        guard lines.count > 2, lines[0].hasPrefix("```"),
              lines[0].dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "mermaid",
              lines[lines.count - 1].hasPrefix("```")
        else { return nil }
        let source = lines.dropFirst().dropLast().joined(separator: "\n")
        return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : source
    }

    @MainActor static let renderer = MermaidRenderer()
}

enum MermaidError: Error {
    case unavailable
    case invalid
}

/// Draws diagrams with the bundled Mermaid library in one hidden web view, one at a time. The
/// page can't load anything (its content security policy allows only inline styles and the
/// injected script), Mermaid runs at its strict security level, and nothing but the empty page
/// may load in it. Results are kept in memory by source and appearance.
@MainActor final class MermaidRenderer: NSObject, WKNavigationDelegate {
    struct Style: Hashable {
        let dark: Bool
        let background: String
    }

    private static let maximumSide: CGFloat = 6000
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loaded: Task<Void, any Error>?
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    private var queue: Task<Void, Never>?
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ source: String, style: Style) -> NSImage? {
        cache.object(forKey: Self.key(source, style))
    }

    func render(_ source: String, style: Style) async throws -> NSImage {
        if let image = cached(source, style: style) {
            return image
        }
        // Serialized, since every diagram is drawn in the same page.
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return try await draw(source, style: style)
        }
        queue = Task { _ = try? await task.value }
        let image = try await task.value
        cache.setObject(image, forKey: Self.key(source, style))
        return image
    }

    private static func key(_ source: String, _ style: Style) -> NSString {
        "\(style.dark ? 1 : 0)\(style.background)\n\(source)" as NSString
    }

    private func draw(_ source: String, style: Style) async throws -> NSImage {
        let view = try await page()
        let size = try await view.callAsyncJavaScript(
            "return await window.gleanaryMermaid(source, dark, background);",
            arguments: ["source": source, "dark": style.dark, "background": style.background],
            contentWorld: .page
        ) as? [Double]
        guard let size, size.count == 2, size[0] >= 1, size[1] >= 1
        else { throw MermaidError.invalid }
        let rect = CGRect(
            x: 0, y: 0,
            width: min(Self.maximumSide, size[0]), height: min(Self.maximumSide, size[1])
        )
        view.setFrameSize(NSSize(
            width: max(rect.width, 400), height: max(rect.height, 300)
        ))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        image.size = rect.size
        return image
    }

    private func page() async throws -> WKWebView {
        if let loaded {
            try await loaded.value
            if let webView {
                return webView
            }
        }
        let task = Task { @MainActor in try await load() }
        loaded = task
        do {
            try await task.value
        } catch {
            loaded = nil
            throw error
        }
        guard let webView else { throw MermaidError.unavailable }
        return webView
    }

    private func load() async throws {
        let script = try CaptureResources.script("Mermaid") + Self.bridge
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let view = WKWebView(frame: frame, configuration: configuration)
        view.navigationDelegate = self
        // WebKit only lays out and paints reliably inside a window; this one is never shown.
        let window = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        self.window = window
        webView = view
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
            view.loadHTMLString(Self.html, baseURL: nil)
        }
    }

    private func finishLoad(_ result: Result<Void, any Error>) {
        pendingLoad?.resume(with: result)
        pendingLoad = nil
    }

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        finishLoad(.failure(error))
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: any Error
    ) {
        finishLoad(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        webView = nil
        window = nil
        loaded = nil
        finishLoad(.failure(MermaidError.unavailable))
    }

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
    <style>html,body{margin:0;padding:0;background:transparent}#diagram{display:inline-block;padding:12px}</style>
    </head><body><div id="diagram"></div></body></html>
    """

    /// Draws one diagram at its natural size and returns that size in points.
    private static let bridge = """
    ;(() => {
      let count = 0;
      window.gleanaryMermaid = async (source, dark, background) => {
        document.body.style.background = background;
        const host = document.getElementById('diagram');
        host.innerHTML = '';
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'strict',
          theme: dark ? 'dark' : 'neutral',
          fontFamily: '-apple-system, "SF Pro Text", "Helvetica Neue", sans-serif',
          themeVariables: { fontSize: '14px', background: background, edgeLabelBackground: background }
        });
        const id = 'gleanary-diagram-' + (++count);
        try {
          const { svg } = await mermaid.render(id, source);
          host.innerHTML = svg;
        } finally {
          for (const leftover of document.querySelectorAll('[id^="dgleanary-diagram-"]')) {
            leftover.remove();
          }
        }
        const svg = host.querySelector('svg');
        if (!svg) { return null; }
        const box = svg.viewBox && svg.viewBox.baseVal;
        if (box && box.width > 0 && box.height > 0) {
          svg.removeAttribute('style');
          svg.setAttribute('width', box.width);
          svg.setAttribute('height', box.height);
        }
        const rect = host.getBoundingClientRect();
        return [Math.ceil(rect.width), Math.ceil(rect.height)];
      };
    })();
    """
}

/// A diagram drawn in place of its `mermaid` fence. Until it's drawn, or if Mermaid can't read
/// it, the source shows as code.
struct MermaidBlock<Fallback: View>: View {
    let source: String
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var failed = false

    private struct Request: Hashable {
        let source: String
        let style: MermaidRenderer.Style
    }

    private var style: MermaidRenderer.Style {
        let dark = colorScheme == .dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var hex = dark ? "#1e1e1e" : "#ffffff"
        appearance?.performAsCurrentDrawingAppearance {
            if let color = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) {
                hex = String(
                    format: "#%02x%02x%02x",
                    Int(color.redComponent * 255),
                    Int(color.greenComponent * 255),
                    Int(color.blueComponent * 255)
                )
            }
        }
        return MermaidRenderer.Style(dark: dark, background: hex)
    }

    var body: some View {
        let style = style
        let shown = image ?? MermaidDiagram.renderer.cached(source, style: style)
        Group {
            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: shown.size.width)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .accessibilityLabel("Diagram")
                    .accessibilityValue(source)
                    .contextMenu {
                        Button("Copy Mermaid Source") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(source, forType: .string)
                        }
                    }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    fallback()
                    if failed {
                        Label(
                            "Mermaid couldn't draw this diagram.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: Request(source: source, style: style)) {
            image = nil
            failed = false
            do {
                image = try await MermaidDiagram.renderer.render(source, style: style)
            } catch {
                failed = !(error is CancellationError)
            }
        }
    }
}
