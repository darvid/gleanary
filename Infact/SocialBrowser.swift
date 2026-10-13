import Foundation
import Observation
import SwiftUI
import WebKit

@MainActor @Observable final class SocialBrowserSession: NSObject, WKNavigationDelegate {
    let target: MediaTarget
    @ObservationIgnored let webView: WKWebView
    var loading = true
    var error: String?
    var currentURL = ""
    private var closed = false

    init(target: MediaTarget) {
        self.target = target
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // This is a separate, explicitly opened live browser, never the restricted article DOM.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func start() async {
        do {
            let rule = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "infact-social-network-v1",
                encodedContentRuleList: Self.networkRules()
            )
            guard !closed else { return }
            if let rule {
                webView.configuration.userContentController.add(rule)
            }
            webView.load(URLRequest(url: target.url))
        } catch { self.error = "Could not create the restricted browser session."; loading = false }
    }

    func capture() async throws -> SocialSnapshot {
        guard !closed, let url = webView.url, let page = try? MediaTarget.parse(url),
              page.identity == target.identity
        else { throw MediaError.wrongPage }
        let result = try await webView.callAsyncJavaScript(
            CaptureResources.script("CaptureSocial"),
            arguments: [
                "sourceURL": target.url
                    .absoluteString,
                "platform": target.site.rawValue,
            ],
            in: nil,
            contentWorld: .defaultClient
        )
        guard !closed, let json = result as? String,
              json.utf8.count <= CaptureLimits.markdownBytes else { throw CaptureError.tooLarge }
        let snapshot = try JSONDecoder().decode(SocialSnapshot.self, from: Data(json.utf8))
        _ = try SocialCapture.document(snapshot, target: target)
        return snapshot
    }

    func close() {
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        let dataStore = webView.configuration.websiteDataStore
        Task { await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) }
    }

    func webView(
        _: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard !closed, let frame = action.targetFrame, let url = action.request.url,
              Self.allowedNavigation(url, site: target.site, mainFrame: frame.isMainFrame)
        else {
            if action.targetFrame?.isMainFrame == true {
                error = "Navigation outside this site's capture session was blocked. Return to the post to continue."
            }
            return .cancel
        }
        do { try await URLPolicy().validate(url); return .allow }
        catch {
            if frame
                .isMainFrame
            {
                self.error = "The browser could not open this public HTTPS address."
            }
            return .cancel
        }
    }

    nonisolated static func allowedNavigation(
        _ url: URL,
        site: MediaTarget.Site,
        mainFrame: Bool
    ) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        let domains = site == .reddit ? ["reddit.com", "redd.it"] : ["x.com", "twitter.com", "t.co"]
        if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        return !mainFrame && ["hcaptcha.com", "recaptcha.net", "challenges.cloudflare.com"]
            .contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        loading = true; error = nil
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        loading = false; currentURL = webView.url?.absoluteString ?? ""
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError _: any Error) {
        loading = false; error = "The page did not load. Retry or return to the requested post."
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError _: any Error
    ) {
        loading = false; error = "The page did not load. Retry or return to the requested post."
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        loading = false; error = "The browser process stopped. Reload to continue."
    }

    static func networkRules() throws -> String {
        let domains = [
            "reddit.com",
            "redditstatic.com",
            "redditmedia.com",
            "redd.it",
            "x.com",
            "twitter.com",
            "twimg.com",
            "t.co",
            "hcaptcha.com",
            "recaptcha.net",
            "challenges.cloudflare.com",
        ]
        var rules = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        // WebKit's rule compiler does not support regex alternation; one exception per domain.
        for domain in domains {
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": "^https://([a-z0-9-]+\\.)*\(escaped)(:443)?/"],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        return try String(decoding: JSONEncoder().encode(rules), as: UTF8.self)
    }
}

struct SocialBrowserView: View {
    let job: CaptureJob
    let library: LibraryModel
    @State private var session: SocialBrowserSession
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    init(job: CaptureJob, target: MediaTarget, library: LibraryModel) {
        self.job = job
        self.library = library
        _session = State(initialValue: SocialBrowserSession(target: target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Capture loaded posts").font(.title2)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            Text(
                "Sign in on the site if needed. Scroll or expand replies before capturing. Infact reads post content—not passwords or cookies. This private session is cleared when you close it."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Return to post") {
                    session.webView.load(URLRequest(url: session.target.url))
                }
                Text(session.currentURL.isEmpty ? session.target.url.absoluteString : session
                    .currentURL).lineLimit(1).textSelection(.enabled)
                Spacer()
                if session.loading {
                    ProgressView().controlSize(.small)
                }
            }
            SocialWebView(webView: session.webView)
            if let error = session.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(
                    "Loaded content only—not a complete thread. Some sites refuse embedded browsers."
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(saving ? "Saving…" : "Capture loaded posts") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            let snapshot = try await session.capture()
                            try await library.saveBrowserCapture(snapshot, job: job)
                            dismiss()
                        } catch { session.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || session.loading)
            }
        }.padding(20).frame(minWidth: 760, idealWidth: 950, minHeight: 600, idealHeight: 760)
            .task { await session.start() }
            .onDisappear { session.close() }
            .interactiveDismissDisabled(saving)
    }
}

private struct SocialWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context _: Context) -> WKWebView {
        webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}
}
