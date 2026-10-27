import Foundation

/// How eagerly Gleanary follows links inside what you save. Each level sets the score a link
/// needs before Gleanary acts on it and how much it may do; see `AcquisitionPolicy`.
enum SourceAcquisitionLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case off, lazy, suggest, balanced, eager

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .lazy: "Lazy"
        case .suggest: "Suggest"
        case .balanced: "Balanced"
        case .eager: "Eager"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Only what you paste or attach is saved. Links inside saved sources are ignored."
        case .lazy: "Links inside saved sources are noted. Nothing is fetched."
        case .suggest: "The most promising links are offered as suggestions to save with one click."
        case .balanced: "Reading the creator recommends is saved automatically and linked back. Other promising links are suggested."
        case .eager: "Links close to what your library covers are saved too, and very strong ones are followed a second hop."
        }
    }

    var policy: AcquisitionPolicy {
        switch self {
        case .off: AcquisitionPolicy(records: false, suggests: false, maximumHops: 0)
        case .lazy: AcquisitionPolicy(records: true, suggests: false, maximumHops: 1)
        case .suggest: AcquisitionPolicy(records: true, suggests: true, maximumHops: 1)
        case .balanced: AcquisitionPolicy(
                records: true, suggests: true, maximumHops: 1,
                autoSaveScore: 0.8, savesPerSource: 3, savesPerDay: 20
            )
        case .eager: AcquisitionPolicy(
                records: true, suggests: true, maximumHops: 2,
                autoSaveScore: 0.55, savesPerSource: 10, savesPerDay: 60,
                autoSaves: [.creatorRecommendation, .creatorLink, .citation], usesRelevance: true
            )
        }
    }
}

struct AcquisitionPolicy: Sendable, Equatable {
    static let suggestScore = 0.35
    static let suggestionsPerSource = 5

    /// Whether candidates are written down at all.
    let records: Bool
    let suggests: Bool
    /// Links are followed only from captures fewer than this many hops from your own saves.
    let maximumHops: Int
    /// Only creator recommendations at or above this score are saved without asking.
    var autoSaveScore: Double?
    var savesPerSource = 0
    var savesPerDay = 0
    /// Which kinds of link may be saved without asking.
    var autoSaves: Set<AcquisitionProvenance> = [.creatorRecommendation]
    /// Whether closeness to the library raises or lowers scores.
    var usesRelevance = false

    /// Each hop further from your own saves counts for less.
    static let hopDecay = 0.6
    /// How long an automatic save may go unused before it is archived.
    static let probation: TimeInterval = 30 * 24 * 60 * 60

    /// How closeness to the library scales a score: unrelated links drop, close ones rise.
    static func relevanceFactor(_ similarity: Double?) -> Double {
        guard let similarity else { return 1 }
        return min(1.2, max(0.6, 0.4 + similarity))
    }
}

/// How close a found link is to what the library already holds, from 0 to 1, or nil when
/// that can't be judged yet.
protocol LinkRelevanceScoring: Sendable {
    func relevance(of link: FoundLink, excluding noteID: UUID) async -> Double?
}

/// Compares a link's title and surrounding line with the library's indexed passages.
struct LibraryRelevance: LinkRelevanceScoring {
    let search: SearchEngine

    func relevance(of link: FoundLink, excluding noteID: UUID) async -> Double? {
        let query = [link.title.hasPrefix("http") ? "" : link.title, link.context]
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard let response = try? await search.search(query, limit: 10) else { return nil }
        let scores = response.matches.filter { $0.passage.documentID != noteID }
            .compactMap(\.semanticScore)
        return scores.max().map { Double(max(0, $0)) }
    }
}

/// Where a link was found, which says most about whether it is worth reading.
enum AcquisitionProvenance: String, Codable, Sendable {
    /// The creator points readers at it, for example "I'd recommend reading…".
    case creatorRecommendation
    case creatorLink
    /// The body cites or discusses it.
    case citation
    case bodyLink

    var label: String {
        switch self {
        case .creatorRecommendation: "Recommended by the creator"
        case .creatorLink: "Linked by the creator"
        case .citation: "Cited in the source"
        case .bodyLink: "Linked in the source"
        }
    }
}

enum AcquisitionState: String, Codable, Sendable {
    /// Noted on its source; nothing else happens.
    case noticed
    /// Offered to save with one click.
    case suggested
    /// Chosen for saving; a capture is queued once whoever runs the capture is ready.
    case approved
    /// A capture was queued.
    case queued
    /// Dismissed by you.
    case rejected
    /// Self-promotion, social profiles and the like.
    case filtered
    /// Saved automatically, then archived after going unused through probation.
    case expired
}

struct AcquisitionCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let identity: String
    let url: URL
    let title: String
    let foundInNoteID: UUID
    let context: String
    let provenance: AcquisitionProvenance
    let hop: Int
    let score: Double
    var state: AcquisitionState
    var reason: String
    var captureJobID: UUID?

    var host: String {
        url.host(percentEncoded: false).map {
            $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
        } ?? url.absoluteString
    }
}

/// A link as found in a saved source, before it is scored.
struct FoundLink: Sendable, Equatable {
    let identity: String
    let url: URL
    let title: String
    let context: String
    let fromCreator: Bool
}

/// Text the video's creator wrote beside the transcript. It is untrusted data: it feeds link
/// scoring and the saved source, never instructions.
struct CreatorText: Codable, Sendable, Equatable {
    var description: String
    /// A comment the creator pinned and wrote themselves.
    var pinnedComment: String?
    var author: String

    static let descriptionMethod = "youtube-description"
    static let pinnedCommentMethod = "youtube-pinned-comment"
    static let methods: Set<String> = [descriptionMethod, pinnedCommentMethod]

    /// A "From the creator" section, kept apart from the transcript.
    var blocks: [ContentBlock] {
        let paragraphs = String(description.prefix(5000))
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var blocks = paragraphs.map { paragraph in
            ContentBlock(
                kind: .paragraph, markdown: Self.linked(paragraph), text: paragraph,
                section: "From the creator", method: Self.descriptionMethod, author: author
            )
        }
        if let comment = pinnedComment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !comment.isEmpty
        {
            let text = String(comment.prefix(2000))
            blocks.append(ContentBlock(
                kind: .quote, markdown: "**Pinned comment**\n\n" + Self.linked(text), text: text,
                section: "From the creator", method: Self.pinnedCommentMethod, author: author
            ))
        }
        guard !blocks.isEmpty else { return [] }
        return [ContentBlock(
            kind: .heading, markdown: "## From the creator", text: "From the creator",
            section: "From the creator", method: Self.descriptionMethod
        )] + blocks
    }

    /// Bare URLs become autolinks so they read as links and linked sources find them.
    private static func linked(_ text: String) -> String {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return text }
        var result = text as NSString
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .reversed()
        {
            let original = result.substring(with: match.range)
            guard original.lowercased().hasPrefix("http") else { continue }
            result = result.replacingCharacters(in: match.range, with: "<\(original)>")
                as NSString
        }
        // Lines that start with "#" would otherwise turn into headings.
        return (result as String).components(separatedBy: "\n")
            .map { $0.hasPrefix("#") ? "\\" + $0 : $0 }.joined(separator: "\n")
    }
}

extension CapturedDocument {
    /// What summaries and research read: the source itself, without the creator's notes
    /// beside it.
    var evidenceBlocks: [ContentBlock] {
        let source = blocks.filter { !CreatorText.methods.contains($0.method) }
        return source.isEmpty ? blocks : source
    }

    /// Links in the saved source with the line around each, skipping links back to the source
    /// itself.
    func foundLinks(excluding identity: String) -> [FoundLink] {
        var links: [FoundLink] = []
        var seen: Set<String> = [identity]
        for block in blocks where block.kind != .code {
            let fromCreator = CreatorText.methods.contains(block.method)
            let lines = block.markdown.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard let found = try? LinkedSourceLink.extract(from: line), !found.isEmpty
                else { continue }
                // A bare link on its own line takes its meaning from the line above, as in
                // "Recommended reading:" followed by the URL.
                let plain = Self.plain(line)
                let lead = index > 0 && Self.isMostlyLinks(plain) ? Self.plain(lines[
                    index - 1
                ]) : ""
                let context = String(([lead, plain].filter { !$0.isEmpty })
                    .joined(separator: " ").prefix(400))
                for link in found where seen.insert(link.id).inserted {
                    links.append(FoundLink(
                        identity: link.id, url: link.url,
                        title: String(link.title.trimmingCharacters(in: .whitespaces).prefix(200)),
                        context: context, fromCreator: fromCreator
                    ))
                }
            }
        }
        return links
    }

    private static func plain(_ line: String) -> String {
        let text = (try? AttributedString(
            markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )).map { String($0.characters) } ?? line
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMostlyLinks(_ line: String) -> Bool {
        line.split(whereSeparator: \.isWhitespace)
            .filter { !$0.lowercased().hasPrefix("http") && !$0.contains(".") }.count < 3
    }
}

/// Scores found links. Only provenance, wording and the address are used; the linked page is
/// not fetched to decide.
enum AcquisitionScorer {
    struct Score: Equatable {
        let value: Double
        let provenance: AcquisitionProvenance
        /// Why a link was filtered out, if it was.
        let filtered: String?
    }

    static func score(_ link: FoundLink, sourceURL: URL?) -> Score {
        let context = link.context.lowercased()
        let strong = matches(context, strongCues)
        let medium = matches(context, mediumCues)
        let provenance: AcquisitionProvenance = link.fromCreator
            ? (strong ? .creatorRecommendation : .creatorLink)
            : (strong || medium ? .citation : .bodyLink)
        if let reason = promotion(link.url, context: context, recommended: strong) {
            return Score(value: 0, provenance: provenance, filtered: reason)
        }
        var value = switch provenance {
        case .creatorRecommendation: 1.0
        case .creatorLink: medium ? 0.7 : 0.5
        case .citation: strong ? 0.7 : 0.5
        case .bodyLink: 0.3
        }
        let path = link.url.path(percentEncoded: false)
        // A bare domain is a landing page, not the piece being recommended.
        if path.isEmpty || path == "/" {
            value *= 0.5
        }
        if let source = sourceURL?.host(percentEncoded: false),
           let host = link.url.host(percentEncoded: false),
           domain(source) == domain(host)
        {
            value *= 0.5
        }
        if shorteners.contains(domain(link.url.host(percentEncoded: false) ?? "")) {
            value *= 0.7
        }
        return Score(value: (value * 100).rounded() / 100, provenance: provenance, filtered: nil)
    }

    /// Social profiles, sign-ups, sponsors and support links are self-promotion, not reading.
    static func promotion(_ url: URL, context: String, recommended: Bool) -> String? {
        let host = domain(url.host(percentEncoded: false) ?? "")
        let path = url.path(percentEncoded: false).lowercased()
        if socialHosts.contains(host) {
            return "Social profile"
        }
        if supportHosts.contains(host) {
            return "Support or storefront link"
        }
        if host == "youtube.com",
           ["/@", "/channel/", "/c/", "/user/"].contains(where: path.hasPrefix)
        {
            return "Channel link"
        }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           query
           .contains(where: { ["tag", "ref", "aff", "affiliate"].contains($0.name.lowercased()) })
        {
            return "Affiliate link"
        }
        // A recommendation outweighs a stray promotional word in the same line.
        if !recommended, matches(context, promotionCues) {
            return "Self-promotion"
        }
        return nil
    }

    static func domain(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    private static func matches(_ text: String, _ cues: [String]) -> Bool {
        cues.contains { cue in
            text.range(
                of: #"\b\#(NSRegularExpression.escapedPattern(for: cue))\b"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static let strongCues = [
        "recommend", "recommended", "recommending", "worth reading", "worth a read",
        "must read", "must-read", "further reading", "recommended reading", "great read",
        "great piece", "great article", "great paper", "great essay", "check out",
        "highly suggest", "i'd suggest", "suggest reading", "you should read", "go read",
    ]
    private static let mediumCues = [
        "paper", "essay", "article", "blog post", "post by", "mentioned", "resources",
        "references", "sources", "based on", "inspired by", "original", "reading", "study",
        "report", "research",
    ]
    private static let promotionCues = [
        "join", "cohort", "enroll", "subscribe", "newsletter", "sponsor", "sponsored",
        "affiliate", "discount", "coupon", "promo code", "use code", "merch", "follow me",
        "my x", "my twitter", "my instagram", "my linkedin", "sign up", "signup", "waitlist",
        "book a call", "hire me", "consulting", "my course", "membership", "patreon",
        "support the channel", "link in bio", "free trial", "get started",
    ]
    private static let socialHosts: Set<String> = [
        "x.com", "twitter.com", "instagram.com", "tiktok.com", "facebook.com", "fb.com",
        "threads.net", "bsky.app", "linkedin.com", "discord.gg", "discord.com", "t.me",
        "twitch.tv", "snapchat.com", "pinterest.com",
    ]
    private static let supportHosts: Set<String> = [
        "patreon.com", "ko-fi.com", "buymeacoffee.com", "linktr.ee", "beacons.ai",
        "gumroad.com", "skool.com", "calendly.com", "amzn.to", "geni.us",
    ]
    private static let shorteners: Set<String> = ["bit.ly", "tinyurl.com", "ow.ly", "buff.ly"]
}

/// Decides each found link's state under a policy. Pure, so the same rules apply wherever a
/// capture finishes.
enum AcquisitionPlanner {
    struct Plan: Equatable {
        let link: FoundLink
        let score: AcquisitionScorer.Score
        let state: AcquisitionState
        let reason: String
    }

    /// `savedToday` counts captures this feature queued in the last day; `saved` are
    /// identities already in the library.
    static func plan(
        _ links: [FoundLink],
        sourceURL: URL?,
        policy: AcquisitionPolicy,
        hop: Int = 1,
        relevance: [String: Double] = [:],
        savedToday: Int,
        saved: Set<String>,
        muted: Set<String> = []
    ) -> [Plan] {
        let decay = pow(AcquisitionPolicy.hopDecay, Double(max(0, hop - 1)))
        let scored = links.map { link in
            var base = AcquisitionScorer.score(link, sourceURL: sourceURL)
            if muted
                .contains(AcquisitionScorer.domain(link.url.host(percentEncoded: false) ?? ""))
            {
                base = AcquisitionScorer.Score(
                    value: 0,
                    provenance: base.provenance,
                    filtered: "Muted site"
                )
            }
            let factor = policy.usesRelevance
                ? AcquisitionPolicy.relevanceFactor(relevance[link.identity]) : 1
            let value = min(1, base.value * factor * decay)
            return (link, AcquisitionScorer.Score(
                value: (value * 100).rounded() / 100, provenance: base.provenance,
                filtered: base.filtered
            ))
        }
        let ranked = scored.enumerated().sorted {
            $0.element.1.value != $1.element.1.value
                ? $0.element.1.value > $1.element.1.value : $0.offset < $1.offset
        }.map(\.element)
        var autoSaves = 0
        var suggestions = 0
        var plans: [String: Plan] = [:]
        for (link, score) in ranked {
            let state: AcquisitionState
            let reason: String
            if let filtered = score.filtered {
                (state, reason) = (.filtered, filtered)
            } else if saved.contains(link.identity) {
                (state, reason) = (.noticed, "Already in your library")
            } else if let threshold = policy.autoSaveScore,
                      policy.autoSaves.contains(score.provenance), score.value >= threshold,
                      autoSaves < policy.savesPerSource, savedToday + autoSaves < policy.savesPerDay
            {
                autoSaves += 1
                (state, reason) = (.approved, score.provenance.label)
            } else if policy.suggests, score.value >= AcquisitionPolicy.suggestScore,
                      suggestions < AcquisitionPolicy.suggestionsPerSource
            {
                suggestions += 1
                (state, reason) = (.suggested, score.provenance.label)
            } else {
                (state, reason) = (.noticed, score.provenance.label)
            }
            plans[link.identity] = Plan(link: link, score: score, state: state, reason: reason)
        }
        // Keep the source's own order for display.
        return links.compactMap { plans[$0.identity] }
    }
}
