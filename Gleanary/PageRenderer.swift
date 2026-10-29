import Foundation
import SwiftUI
import WebKit

/// A page as a browser shows it, for sites that refuse plain requests.
struct RenderedPage: Sendable {
    let html: String
    let url: URL
}

/// Loads a page in a browser engine, for a capture you asked for that a site refused, such as
/// one behind a bot check that a browser passes by running its script.
protocol PageRendering: Sendable {
    /// The page once it has loaded past any check, or nil when the check needs a person.
    func render(_ url: URL) async throws -> RenderedPage?
}

/// A private, unseen WebKit view, cleared after each page. Only main-frame navigations to
/// public HTTPS or HTTP addresses are followed.
struct WebKitPageRenderer: PageRendering {
    var timeout: Duration = .seconds(20)

    @MainActor func render(_ url: URL) async throws -> RenderedPage? {
        try await URLPolicy().validate(url)
        let session = PageBrowserSession(url: url)
        defer { session.close() }
        session.start()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if let page = try await session.loadedPage() {
                return page
            }
        }
        return nil
    }
}

/// A private browser for one page: the unseen renderer and the window you can use when a site
/// asks a person to confirm. Its data is cleared when it closes.
@MainActor @Observable final class PageBrowserSession: NSObject, WKNavigationDelegate {
    let url: URL
    @ObservationIgnored let webView: WKWebView
    var loading = true
    var error: String?
    var currentURL = ""
    private var closed = false

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // A live page in its own session, never the restricted DOM extraction runs in.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        webView.load(URLRequest(url: url))
    }

    /// The page's HTML once it has finished loading and isn't a bot check.
    func loadedPage() async throws -> RenderedPage? {
        guard !closed, !loading, let current = webView.url else { return nil }
        let state = try await webView.callAsyncJavaScript(
            """
            const check = /^(just a moment|attention required|verify you are human)/i
              .test(document.title.trim())
              || !!document.querySelector('#challenge-form, #challenge-stage, .cf-turnstile');
            return JSON.stringify({ check, ready: document.readyState === 'complete',
              html: document.documentElement.outerHTML });
            """,
            contentWorld: .defaultClient
        )
        struct State: Decodable {
            let check: Bool
            let ready: Bool
            let html: String
        }
        guard !closed, let json = state as? String,
              let page = try? JSONDecoder().decode(State.self, from: Data(json.utf8)),
              page.ready, !page.check
        else { return nil }
        guard page.html.utf8.count <= CaptureLimits.markdownBytes else {
            throw CaptureError.tooLarge
        }
        return RenderedPage(html: page.html, url: current)
    }

    func close() {
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        let dataStore = webView.configuration.websiteDataStore
        Task {
            await dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
            )
        }
    }

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard !closed, let url = action.request.url else { return .cancel }
        // Subframes, such as a check's own widget, load as the page asks.
        guard action.targetFrame?.isMainFrame == true else { return .allow }
        do {
            try await URLPolicy().validate(url)
            return .allow
        } catch {
            self.error = "The browser could not open this address."
            return .cancel
        }
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        loading = true; error = nil
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        loading = false; currentURL = webView.url?.absoluteString ?? ""
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: any Error) {
        loading = false; error = "The page did not load. Reload to try again."
    }

    func webView(
        _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: any Error
    ) {
        loading = false; error = "The page did not load. Reload to try again."
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        loading = false; error = "The browser process stopped. Reload to continue."
    }
}

/// The private browser window for a page that refused Gleanary: you complete the site's check
/// or sign in, then capture the page as it now shows.
struct PageBrowserView: View {
    let job: CaptureJob
    let library: LibraryModel
    @State private var session: PageBrowserSession
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(job: CaptureJob, url: URL, library: LibraryModel) {
        self.job = job
        self.library = library
        _session = State(initialValue: PageBrowserSession(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Capture Page").font(.title2)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            Text(
                "Complete the site’s check or sign in if it asks, then capture the page. Gleanary saves the page’s content, not passwords or cookies, and clears this private session when you close it."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Return to Page") { session.start() }
                Text(session.currentURL.isEmpty ? session.url.absoluteString : session.currentURL)
                    .lineLimit(1).textSelection(.enabled)
                Spacer()
                if session.loading {
                    WorkingProgress()
                }
            }
            PageWebView(webView: session.webView)
            if let error = session.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(saving ? "Saving…" : "Capture Page") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            guard let page = try await session.loadedPage() else {
                                session.error = "The page is still loading or checking. Try again in a moment."
                                return
                            }
                            try await library.saveRenderedPage(page, job: job)
                            dismiss()
                        } catch { session.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).disabled(saving || session.loading)
            }
        }
        .padding(20).frame(minWidth: 760, idealWidth: 950, minHeight: 600, idealHeight: 760)
        .task { session.start() }
        .onDisappear { session.close() }
        .interactiveDismissDisabled(saving)
    }
}

private struct PageWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context _: Context) -> WKWebView {
        webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}
}
