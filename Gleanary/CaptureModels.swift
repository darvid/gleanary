import Foundation
import NaturalLanguage

enum CaptureLimits {
    static let artifactBytes = 50_000_000
    static let markdownBytes = 5_000_000
    static let pdfPages = 250
    static let blocks = 20000
}

enum ArtifactKind: String, Codable, Sendable {
    case pdf, html, markdown, text, capture, json, audio, image
}

struct Artifact: Codable, Sendable, Equatable {
    let hash: String
    let kind: ArtifactKind
    let name: String
    let byteCount: Int
    var sourceURL: URL?
    var textEncoding: String? = nil
}

struct CaptureRequest: Codable, Sendable {
    var url: URL?
    var artifact: Artifact?
    let identity: String
    let label: String
    var audioLocale: String? = nil
    var downloadSpeechModel: Bool? = nil
    // Nil preserves the incumbent summary-first capture behavior for old durable jobs.
    var summarizeLink: Bool? = nil
    var submittedURL: URL? = nil
    /// An imported bookmark note this capture upgrades in place, if it is still unedited.
    var replacingNoteID: UUID? = nil

    static func classify(_ input: String) throws -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CaptureError.emptyInput }
        if text.contains(where: \.isWhitespace) {
            return nil
        }
        if let url = URL(string: text), let scheme = url.scheme {
            guard ["http", "https"].contains(scheme.lowercased()), url.host != nil else {
                throw CaptureError.unsafeURL
            }
            return url
        }
        // Bare domain names are useful pastes; ordinary words remain notes.
        if text.contains("."), !text.hasPrefix("/"),
           let url = URL(string: "https://" + text), let host = url.host,
           host.contains("."), !host.hasSuffix(".")
        {
            return url
        }
        return nil
    }

    static func canonicalURL(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = components.host, components.user == nil, components.password == nil,
              ["https", "http"].contains(components.scheme?.lowercased() ?? "")
        else {
            throw CaptureError.unsafeURL
        }
        components.host = host.lowercased()
        components.scheme = components.scheme?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80)
        {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        guard let value = components.string else { throw CaptureError.unsafeURL }
        return value
    }
}

enum SourceIdentity {
    static func arxiv(_ url: URL) -> (url: URL, identity: String)? {
        guard ["arxiv.org", "www.arxiv.org"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let path = url.path.replacingOccurrences(
            of: #"^/(abs|pdf)/"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\.pdf$"#, with: "", options: .regularExpression)
        guard path.range(
            of: #"^(?:\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v[1-9]\d*)?$"#,
            options: .regularExpression
        ) != nil,
            let canonical = URL(string: "https://arxiv.org/abs/" + path) else { return nil }
        // Explicit versions stay distinct; an unversioned identifier means the latest-source
        // identity.
        return (canonical, "arxiv:" + path)
    }
}

enum CaptureState: String, Codable, Sendable {
    case queued, fetching, extracting, ready, failed, cancelled
    var terminal: Bool {
        self == .ready || self == .failed || self == .cancelled
    }
}

struct CaptureJob: Identifiable, Sendable {
    let id: UUID
    let token: UUID
    let request: CaptureRequest
    let state: CaptureState
    let acquired: [Artifact]
    let progress: String
    let error: String?
    let noteID: UUID?
    var recovery: CaptureRecovery?
    /// Failed for a reason that may pass on its own, so the failed-capture retry may try again.
    var retryable = false
    /// How many times the failed-capture retry has tried it.
    var autoRetries = 0
}

/// Whether a capture that failed may succeed later with nobody doing anything: the network, a
/// busy server or a slow extraction, rather than a login, a locked file or a page with no text.
enum CaptureFailure {
    static func retryable(_ error: any Error) -> Bool {
        switch error {
        case let error as CaptureError: error.retryable
        case let error as MediaError: error == .blocked
        case is LinkSummaryError, is SummaryFailure, is ChatGPTError: false
        // Anything else is recorded as an extraction failure, which says to retry.
        default: true
        }
    }

    /// The same judgement from a recorded message, for failures saved before it was kept.
    static func retryable(message: String) -> Bool {
        let passing: [any LocalizedError] = [
            CaptureError.downloadFailed, CaptureError.extractionFailed, MediaError.blocked,
        ]
        if passing.contains(where: { $0.errorDescription == message }) {
            return true
        }
        guard let match = message.firstMatch(of: /^The source returned HTTP (\d{3})\./),
              let status = Int(match.1) else { return false }
        return CaptureError.http(status).retryable
    }
}

enum Coverage: String, Codable, Sendable {
    case note, article, document, abstractOnly, partial, transcript, visibleThread, bookmark
    var label: String {
        switch self {
        case .note: "Pasted or imported text"
        case .article: "Article text"
        case .document: "Document text"
        case .abstractOnly: "Abstract only"
        case .partial: "Partial extraction"
        case .transcript: "Timestamped transcript"
        case .visibleThread: "Loaded posts, partial thread"
        case .bookmark: "Bookmark only, page not fetched yet"
        }
    }
}

struct ContentBlock: Codable, Sendable, Equatable {
    enum Kind: String, Codable,
        Sendable { case heading, paragraph, list, code, table, quote, image }
    let kind: Kind
    let markdown: String
    let text: String
    var section: String?
    var page: Int?
    var method: String = "text"
    var sourceURL: URL? = nil
    var startTime: Double? = nil
    var endTime: Double? = nil
    var author: String? = nil
    var externalID: String? = nil
    var parentID: String? = nil
    var quoteID: String? = nil
}

struct CapturedDocument: Codable, Sendable {
    static let extractorVersion = "documents-v1/readability-0.6.0/turndown-7.2.0/pdf-2/vision-1/media-1"
    var title: String
    var authors: [String] = []
    var published: String?
    var identifier: String?
    var sourceURL: URL?
    var language: String?
    var coverage: Coverage
    var warnings: [String] = []
    var blocks: [ContentBlock]

    var markdown: String {
        blocks.map(\.markdown).joined(separator: "\n\n")
    }

    var fingerprint: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try ContentHash.bytes(encoder.encode(self))
        }
    }

    mutating func validate() throws {
        title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard !title.isEmpty, !blocks.isEmpty, blocks.count <= CaptureLimits.blocks,
              markdown.utf8.count <= CaptureLimits.markdownBytes,
              blocks
              .contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw CaptureError.noContent
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(blocks.map(\.text).joined(separator: " ").prefix(10000)))
        if language == nil {
            language = recognizer.dominantLanguage?.rawValue
        }
        if let language, language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first != "en" {
            warnings
                .append(
                    "Detected language: \(language). Keyword search works; the current semantic model is English-only."
                )
        }
        warnings = Array(Set(warnings)).sorted()
    }
}

struct SourceCitation: Codable, Sendable, Equatable {
    let captureID: UUID
    let blockOrdinal: Int
    let page: Int?
    let section: String?
    let url: URL?
    var startTime: Double? = nil
    var endTime: Double? = nil
    var label: String {
        if let startTime {
            return MediaTarget.clock(startTime)
        }
        if let page {
            return "Page \(page)"
        }
        return section ?? "Original source"
    }
}

struct CaptureDetail: Identifiable, Sendable {
    let id: UUID
    let document: CapturedDocument
    let artifacts: [Artifact]
    let capturedAt: Date
}

enum CaptureError: LocalizedError {
    case emptyInput, unsafeURL, unsupported, tooLarge, tooManyPages, lockedPDF, invalidPDF
    case noContent, needsBrowser, extractionFailed, resourceMissing, staleJob
    case http(Int), downloadFailed, missingArtifact, deletedCapture

    /// A dropped connection, a timeout or a server having a bad day; never a refusal.
    var retryable: Bool {
        switch self {
        case .downloadFailed, .extractionFailed: true
        case let .http(status): status == 408 || status == 429 || status >= 500
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyInput: "Paste a URL or some text, or attach a file."
        case .unsafeURL: "Use a public HTTP or HTTPS URL without embedded credentials. Local and private network addresses are not supported."
        case .unsupported: "This source or file type is not supported. Paste its text, or attach a PDF, HTML, Markdown, or text file."
        case .tooLarge: "This capture exceeds the limit: 50 MB per original and 5 MB of extracted Markdown. Split the document and try again."
        case .tooManyPages: "This PDF exceeds the 250-page capture limit. Split it into smaller documents."
        case .lockedPDF: "This PDF requires a password. Unlock a copy locally and attach it again."
        case .invalidPDF: "The downloaded or attached file is not a readable PDF."
        case .noContent: "No usable document text was found. The page may require a browser, or the document may contain only unsupported visual content."
        case .needsBrowser: "This page appears to require login, browser verification, or JavaScript. Open it in your browser and paste the text or save a PDF instead."
        case .extractionFailed: "Local extraction failed or timed out. The original is retained; retry the capture."
        case .resourceMissing: "A bundled extraction resource is missing. Rebuild or reinstall Gleanary."
        case .staleJob: "This capture was cancelled or replaced."
        case let .http(status): "The source returned HTTP \(status). No login page or error response was imported."
        case .downloadFailed: "The source could not be downloaded. Check your connection and retry."
        case .missingArtifact: "The retained original is missing or damaged. Attach the file again or start a new URL capture."
        case .deletedCapture: "This exact source was previously captured and deleted. It was not restored automatically. Paste its text as a new note if you want another copy."
        }
    }
}
