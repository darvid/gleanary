import Foundation

struct MediaTarget: Equatable, Sendable {
    enum Site: String, Codable, Sendable { case youtube, reddit, x }
    let site: Site
    let id: String
    let url: URL
    var identity: String {
        "\(site.rawValue):\(id)"
    }

    static func parse(_ url: URL) throws -> MediaTarget? {
        _ = try CaptureRequest.canonicalURL(url)
        let host = url.host?.lowercased() ?? ""
        func domain(_ name: String) -> Bool {
            host == name || host.hasSuffix("." + name)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if domain("youtube.com") || domain("youtu.be") || domain("youtube-nocookie.com") {
            let id: String? = if domain("youtu.be") {
                parts.first
            } else if parts
                .first ==
                "watch"
            {
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "v" }?.value
            } else if let first = parts.first,
                      ["shorts", "embed", "live", "v"].contains(first)
            {
                parts.dropFirst().first
            } else {
                nil
            }
            guard let id, id.count == 11,
                  id
                  .allSatisfy({
                      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  let canonical = URL(string: "https://www.youtube.com/watch?v=\(id)")
            else { throw MediaError.invalidLink }
            return MediaTarget(site: .youtube, id: id, url: canonical)
        }
        if domain("reddit.com") || domain("redd.it") {
            let id = domain("redd.it") ? parts.first : parts.firstIndex(of: "comments")
                .flatMap { parts.dropFirst($0 + 1).first }
            guard let id, !id.isEmpty,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  let canonical =
                  URL(string: "https://www.reddit.com/comments/\(id.lowercased())/")
            else { throw MediaError.invalidLink }
            return MediaTarget(site: .reddit, id: id.lowercased(), url: canonical)
        }
        if domain("x.com") || domain("twitter.com") {
            guard let index = parts.firstIndex(of: "status"),
                  let id = parts.dropFirst(index + 1).first,
                  !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let canonical = URL(string: "https://x.com/i/status/\(id)")
            else { throw MediaError.invalidLink }
            return MediaTarget(site: .x, id: id, url: canonical)
        }
        return nil
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000 else { return "0:00" }
        let value = Int(seconds)
        return value >= 3600 ? String(
            format: "%d:%02d:%02d",
            value / 3600,
            value / 60 % 60,
            value % 60
        )
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

enum CaptureRecovery: String, Codable, Sendable { case browser, audio }

enum MediaError: LocalizedError {
    case invalidLink, blocked, noCaptions, browserRequired, speechModelMissing, speechUnavailable,
         durationLimit, wrongPage
    var recovery: CaptureRecovery? {
        switch self {
        case .noCaptions, .speechModelMissing, .speechUnavailable: .audio
        case .browserRequired: .browser
        default: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidLink: "Paste a link to a specific YouTube video, Reddit thread, or X post."
        case .blocked: "YouTube declined extraction or changed its page format. Retry later; login, age, and membership restrictions are not bypassed."
        case .noCaptions: "No captions are available. You can choose to download the audio and transcribe it locally."
        case .browserRequired: "This post needs a rendered page. Open Gleanary’s private capture browser, sign in if necessary, then capture the loaded posts."
        case .speechModelMissing: "The selected Apple speech model is not installed. Reopen audio options and allow its download, or choose an installed language."
        case .speechUnavailable: "On-device transcription is unavailable for this Mac or language. Choose another supported language or import a transcript."
        case .durationLimit: "Audio capture is limited to two hours and 50 MB. Import a shorter recording or its transcript."
        case .wrongPage: "Return to the requested post before capturing. No unrelated page was saved."
        }
    }
}

struct TimedText: Codable, Sendable {
    let text: String
    let start: Double
    let duration: Double
}

struct VideoTranscript: Codable, Sendable {
    let videoID: String
    let title: String
    let author: String
    let language: String
    let generated: Bool
    let method: String
    let segments: [TimedText]

    func document(for target: MediaTarget) throws -> CapturedDocument {
        guard videoID == target.id, !segments.isEmpty,
              segments.count <= 100_000 else { throw CaptureError.noContent }
        var blocks: [ContentBlock] = []
        var group: [TimedText] = []
        var words = 0
        var prior = -1.0
        func block(_ group: [TimedText]) -> ContentBlock? {
            guard let first = group.first else { return nil }
            let end = group.map { $0.start + $0.duration }.max() ?? first.start
            let text = group.map(\.text).joined(separator: " ")
            var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "v", value: videoID),
                URLQueryItem(name: "t", value: String(Int(first.start))),
            ]
            let link = components?.url ?? target.url
            return ContentBlock(
                kind: .paragraph,
                markdown: "[\(MediaTarget.clock(first.start))–\(MediaTarget.clock(end))](\(link.absoluteString))\n\n\(text)",
                text: text,
                method: method,
                sourceURL: link,
                startTime: first.start,
                endTime: end,
                author: author
            )
        }
        for segment in segments {
            guard segment.start.isFinite, segment.duration.isFinite, segment.start >= 0,
                  segment.duration >= 0,
                  segment.start + segment.duration <= 604_800 else { throw CaptureError.noContent }
            // Creator captions can start a cue just before the previous one ends. They stay
            // in caption order, which is the order of the words.
            prior = max(prior, segment.start)
            let count = segment.text.split(whereSeparator: \.isWhitespace).count
            if let first = group.first, words + count > 70 || segment.start - first.start >= 35 {
                if let value = block(group) {
                    blocks.append(value)
                }
                group = []; words = 0
            }
            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            {
                group.append(segment); words += count
            }
        }
        if let value = block(group) {
            blocks.append(value)
        }
        return CapturedDocument(
            title: title.isEmpty ? "YouTube · \(videoID)" : title,
            authors: author.isEmpty ? [] : [author],
            identifier: videoID,
            sourceURL: target.url,
            language: language,
            coverage: .transcript,
            warnings: [
                generated ? "Machine-generated transcript; verify wording against the video." :
                    "Creator-provided captions; timing refers to caption display, not exact word boundaries.",
                "Video images and diagrams are not interpreted. The original video is not retained.",
            ],
            blocks: blocks
        )
    }
}

struct SocialPost: Codable, Sendable {
    let id: String
    let url: URL
    let text: String
    let author: String?
    let published: String?
    let parentID: String?
    let quoteID: String?
}

struct SocialSnapshot: Codable, Sendable {
    let pageURL: URL
    let title: String
    let posts: [SocialPost]
    let truncated: Bool
}
