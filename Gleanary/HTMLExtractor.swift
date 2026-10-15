import Foundation
import SwiftSoup
import WebKit

struct HTMLAnalysis: Sendable {
    let sanitizedHTML: String
    let title: String
    let authors: [String]
    let published: String?
    let identifier: String?
    let pdfURL: URL?
    let faviconURL: URL?
    /// The page's chosen share card (`og:image` or `twitter:image`).
    let shareImageURL: URL?
    let academic: Bool
    let warnings: [String]
}

enum HTMLExtractor {
    static func analyze(_ html: String, url: URL?) throws -> HTMLAnalysis {
        let document = try SwiftSoup.parse(html, url?.absoluteString ?? "")
        func values(_ name: String) throws -> [String] {
            try document.select("meta[name=\"\(name)\"]").array().map { try $0.attr("content") }
                .filter { !$0.isEmpty }
        }
        let title = try values("citation_title").first ?? document.title()
        let titleLower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let blockedTitles = [
            "just a moment",
            "access denied",
            "sign in",
            "log in",
            "403 forbidden",
            "verify you are human",
        ]
        if blockedTitles
            .contains(where: {
                titleLower == $0 || titleLower.hasPrefix($0 + "…") || titleLower
                    .hasPrefix($0 + "...")
            })
        {
            throw CaptureError.needsBrowser
        }
        if try !document.select("input[type=password]").isEmpty(),
           try (document.body()?.text().count ?? 0) < 1500
        {
            throw CaptureError.needsBrowser
        }
        let academic = try !document.select("meta[name^=citation_]").isEmpty()
        var pdfCandidates: [URL] = []
        for value in try values("citation_pdf_url") {
            if let candidate = URL(string: value, relativeTo: url)?
                .absoluteURL
            {
                pdfCandidates.append(candidate)
            }
        }
        if pdfCandidates.isEmpty {
            for link in try document.select("link[type=application/pdf], a[href]").array() {
                let href = try link.attr("href")
                let label = try link.text().lowercased()
                let isPDF = try link.attr("type") == "application/pdf" || URL(string: href)?
                    .pathExtension.lowercased() == "pdf"
                let isMain = label.contains("full text") || label.contains("full-text") || label
                    .contains("download pdf") || label == "pdf" || link.tagName() == "link"
                if isPDF, isMain, !label.contains("supplement"), let candidate = URL(
                    string: href,
                    relativeTo: url
                )?.absoluteURL {
                    pdfCandidates.append(candidate)
                }
            }
        }
        let unique = Array(Set(pdfCandidates))
            .filter { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
        var warnings: [String] = []
        if unique
            .count >
            1
        {
            warnings
                .append(
                    "Multiple full-text PDFs were found. Paste the intended PDF URL to capture it directly."
                )
        }
        if try !document.select("img, svg, canvas, video")
            .isEmpty()
        {
            warnings
                .append(
                    "Images and diagrams are not interpreted; available text and links are retained."
                )
        }
        let authors = try values("citation_author")
        let fallbackAuthors = try values("author")
        let published = try values("citation_publication_date").first ?? values("date").first
        let identifier = try values("citation_doi").first ?? values("citation_arxiv_id").first
        let faviconURL = try document.select("link[rel]").array().first { link in
            try link.attr("rel").lowercased().split(whereSeparator: \.isWhitespace).contains("icon")
        }.flatMap { link in
            try URL(string: link.attr("href"), relativeTo: url)?.absoluteURL
        }
        let shareImageURL = try [
            "og:image:secure_url", "og:image", "twitter:image", "twitter:image:src",
        ].lazy.compactMap { key in
            try document.select("meta[property=\"\(key)\"], meta[name=\"\(key)\"]").first()
                .map { try $0.attr("content").trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        }.first { $0.scheme == "https" || $0.scheme == "http" }
        try sanitize(document, url: url)
        return try HTMLAnalysis(
            sanitizedHTML: document.outerHtml(),
            title: title,
            authors: authors.isEmpty ? fallbackAuthors : authors,
            published: published,
            identifier: identifier,
            pdfURL: unique.count == 1 ? unique.first : nil,
            faviconURL: faviconURL,
            shareImageURL: shareImageURL,
            academic: academic,
            warnings: warnings
        )
    }

    /// Source scripts, event handlers and subresources must never execute in the local DOM.
    private static func sanitize(_ document: SwiftSoup.Document, url: URL?) throws {
        try document
            .select("script, style, iframe, frame, object, embed, base, link, meta, form, noscript")
            .remove()
        for element in try document.select("*").array() {
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey().lowercased()
                if key.hasPrefix("on") || [
                    "srcset",
                    "style",
                    "srcdoc",
                    "action",
                    "formaction",
                    "ping",
                ].contains(key) {
                    try element.removeAttr(attribute.getKey())
                }
            }
            for key in ["href", "src"] where element.hasAttr(key) {
                let value = try element.attr(key)
                if let link = URL(string: value, relativeTo: url)?.absoluteURL,
                   ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "")
                {
                    try element.attr(key, link.absoluteString)
                } else {
                    try element.removeAttr(key)
                }
            }
        }
        try document.head()?
            .prepend(
                "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'none'; img-src 'none'; style-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'\">"
            )
    }

    @MainActor static func extract(
        _ analysis: HTMLAnalysis,
        url: URL?
    ) async throws -> CapturedDocument {
        let json = try await LocalCaptureDOM(scripts: ["Readability", "Turndown", "CaptureArticle"])
            .extract(analysis.sanitizedHTML)
        let result = try JSONDecoder().decode(ArticleDOMResult.self, from: Data(json.utf8))
        guard result.blocks.map(\.text).joined().count >= 80 else { throw CaptureError.noContent }
        return CapturedDocument(
            title: analysis.title.isEmpty ? result.title : analysis.title,
            authors: analysis.authors.isEmpty ? result.byline
                .map { [$0] } ?? [] : analysis.authors,
            published: analysis.published,
            identifier: analysis.identifier,
            sourceURL: url,
            coverage: analysis.academic ? .abstractOnly :
                (result.blocks
                    .contains { $0.method == "html-main" || $0.method == "html-body" } ? .partial :
                    .article),
            warnings: analysis.warnings + result
                .warnings +
                (analysis
                    .academic ?
                    [
                        "Full-paper coverage has not been verified. This capture is labeled abstract only.",
                    ] :
                    []),
            blocks: result.blocks
        )
    }
}

private struct ArticleDOMResult: Decodable, Sendable {
    let title: String
    let byline: String?
    let blocks: [ContentBlock]
    let warnings: [String]
}

/// A local DOM only, with no source scripts, subresources, cookies, or native script bridge.
@MainActor final class LocalCaptureDOM: NSObject, WKNavigationDelegate {
    private let scripts: [String]
    private let arguments: [String: String]

    init(scripts: [String], arguments: [String: String] = [:]) {
        self.scripts = scripts
        self.arguments = arguments
    }

    private var webView: WKWebView?
    private var pending: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?

    func extract(_ html: String) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.defaultWebpagePreferences.allowsContentJavaScript = false
                let view = WKWebView(frame: .zero, configuration: configuration)
                view.navigationDelegate = self
                webView = view
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) }
                    catch { return }
                    self?.finish(.failure(CaptureError.extractionFailed))
                }
                view.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url?
            .absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor in
            do {
                let script = try scripts.map(CaptureResources.script).joined(separator: "\n")
                let result = try await webView.callAsyncJavaScript(
                    script,
                    arguments: arguments,
                    in: nil,
                    contentWorld: .defaultClient
                )
                guard let json = result as? String else { throw CaptureError.extractionFailed }
                guard json.utf8.count <= CaptureLimits.markdownBytes
                else { throw CaptureError.tooLarge }
                finish(.success(json))
            } catch let error as CaptureError { finish(.failure(error)) }
            catch { finish(.failure(CaptureError.extractionFailed)) }
        }
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

    private func finish(_ result: Result<String, any Error>) {
        guard let pending else { return }
        self.pending = nil
        timeout?.cancel()
        timeout = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        pending.resume(with: result)
    }
}

enum CaptureResources {
    static func script(_ name: String) throws -> String {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "js")
        else { throw CaptureError.resourceMissing }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
