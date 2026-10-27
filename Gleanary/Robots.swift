import Foundation

/// A site's robots.txt rules for Gleanary (RFC 9309). Only automatic saves consult them; a
/// capture you ask for acts for you, like your browser.
struct RobotsRules: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        let allow: Bool
        let pattern: String
    }

    static let agent = "gleanary"
    static let allowAll = RobotsRules(rules: [], crawlDelay: nil)
    static let disallowAll = RobotsRules(rules: [Rule(allow: false, pattern: "/")], crawlDelay: nil)

    let rules: [Rule]
    /// Seconds between requests the site asks for, when it says.
    let crawlDelay: Double?

    /// The group naming Gleanary, else the one for every agent; the longest matching rule
    /// wins, and Allow wins a tie.
    static func parse(_ text: String) -> RobotsRules {
        var groups: [(agents: [String], rules: [Rule], delay: Double?)] = []
        var collectingAgents = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "user-agent":
                if !collectingAgents || groups.isEmpty {
                    groups.append(([], [], nil))
                }
                groups[groups.count - 1].agents.append(value.lowercased())
                collectingAgents = true
            case "allow", "disallow":
                collectingAgents = false
                guard !groups.isEmpty, !value.isEmpty || key == "disallow" else { continue }
                // An empty Disallow allows everything, so it adds no rule.
                if !value.isEmpty {
                    groups[groups.count - 1].rules.append(Rule(
                        allow: key == "allow",
                        pattern: value
                    ))
                }
            case "crawl-delay":
                collectingAgents = false
                if !groups.isEmpty, let delay = Double(value), delay >= 0 {
                    groups[groups.count - 1].delay = delay
                }
            default:
                continue
            }
        }
        let named = groups.filter { $0.agents.contains { $0 != "*" && agent.contains($0) } }
        let chosen = named.isEmpty ? groups.filter { $0.agents.contains("*") } : named
        return RobotsRules(
            rules: chosen.flatMap(\.rules),
            crawlDelay: chosen.compactMap(\.delay).max()
        )
    }

    func allows(_ url: URL) -> Bool {
        var path = url.path(percentEncoded: true)
        if path.isEmpty {
            path = "/"
        }
        if let query = url.query(percentEncoded: true) {
            path += "?" + query
        }
        let matching = rules.filter { Self.matches($0.pattern, path) }
        guard let best = matching.max(by: {
            $0.pattern.count != $1.pattern.count
                ? $0.pattern.count < $1.pattern.count : !$0.allow && $1.allow
        }) else { return true }
        return best.allow
    }

    /// `*` matches any run of characters and a trailing `$` anchors the end.
    static func matches(_ pattern: String, _ path: String) -> Bool {
        let anchored = pattern.hasSuffix("$")
        let body = anchored ? String(pattern.dropLast()) : pattern
        let regex = "^" + body.components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: ".*") + (anchored ? "$" : "")
        return path.range(of: regex, options: .regularExpression) != nil
    }
}

/// Fetches and remembers each site's robots.txt for a day.
actor RobotsPolicy {
    private let fetcher: any SourceFetching
    private var cache: [String: (rules: RobotsRules, fetchedAt: Date)] = [:]
    private static let lifetime: TimeInterval = 24 * 60 * 60

    init(fetcher: any SourceFetching) {
        self.fetcher = fetcher
    }

    /// A missing robots.txt allows everything; one the site can't serve right now, or a
    /// failed request, allows nothing until it can be read.
    func rules(for url: URL) async -> RobotsRules {
        guard let host = url.host(percentEncoded: false)?.lowercased(),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let robots = URL(string: "\(scheme)://\(host)/robots.txt")
        else { return .disallowAll }
        if let cached = cache[host], Date().timeIntervalSince(cached.fetchedAt) < Self.lifetime {
            return cached.rules
        }
        let rules: RobotsRules
        do {
            let response = try await fetcher.fetch(robots)
            let text = String(decoding: response.data.prefix(500_000), as: UTF8.self)
            rules = RobotsRules.parse(text)
        } catch let CaptureError.http(status) where (400 ..< 500).contains(status) {
            rules = .allowAll
        } catch {
            rules = .disallowAll
        }
        cache[host] = (rules, Date())
        return rules
    }
}
