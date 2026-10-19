import Foundation

/// A named writing profile (SPEC §7.6). It shapes the Writer's wording only: its tools, the
/// sources it may use and the grounding rules stay fixed in code whatever a style says.
struct WritingStyle: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Citations: String, Codable, Sendable, CaseIterable {
        /// Numbered markers after each claim, linking to a numbered Sources list.
        case numbered
        /// Linked source titles after each claim, plus the Sources list.
        case inline

        var label: String {
            switch self {
            case .numbered: "Numbered, with a sources list"
            case .inline: "Source titles inline"
            }
        }
    }

    var id: String
    var name: String
    var tone: String
    var readingLevel: String
    var structure: String
    var conventions: String
    var avoid: String
    var citations: Citations
    var instructions: String

    static let customID = "custom"

    var isPreset: Bool {
        id != Self.customID
    }

    static let plain = WritingStyle(
        id: "plain",
        name: "Plain",
        tone: "Neutral and direct",
        readingLevel: "Plain language (ISO 24495-1): common words, short sentences",
        structure: "Main idea first; focused sections only when useful, without a required introduction or conclusion",
        conventions: "US spelling; units, prices and dates as the sources give them",
        avoid: "Unrequested report framing, research-process narration, filler introductions, unexplained jargon, marketing tone, emoji",
        citations: .numbered,
        instructions: "Write reusable knowledge entries by default. Honor requests for another format. Explain a technical term the first time it appears. Say when sources disagree."
    )

    static let referenceGuide = WritingStyle(
        id: "reference",
        name: "Reference guide",
        tone: "Technical and precise",
        readingLevel: "Expert",
        structure: "Tables first where items compare, then short sections; bullets over prose",
        conventions: "US spelling; consistent units within a table",
        avoid: "Opinion, marketing tone, emoji, padding",
        citations: .numbered,
        instructions: "Keep entries consistent so items line up. Put the comparison before the commentary."
    )

    static let blog = WritingStyle(
        id: "blog",
        name: "Blog",
        tone: "Conversational, opinionated only where the sources support it",
        readingLevel: "General",
        structure: "A short opening, then sections in prose with occasional bullets",
        conventions: "US spelling",
        avoid: "Clickbait, emoji, exaggeration beyond the sources",
        citations: .inline,
        instructions: "End with a short takeaway."
    )

    static let presets = [plain, referenceGuide, blog]

    /// Short descriptions for choosing a style; the full prompt rules stay separate.
    var settingsSummary: String {
        switch id {
        case Self.plain.id:
            "Direct, readable knowledge entries. Leads with the useful idea and explains technical terms."
        case Self.referenceGuide.id:
            "Precise reference material for expert readers. Puts comparisons and tables before commentary."
        case Self.blog.id:
            "Conversational writing with a short opening, prose sections, and a closing takeaway."
        default:
            "Your own writing preferences. Edit the rules below; changes are saved automatically."
        }
    }

    /// The one editable style; it starts as a copy of Plain.
    static var starterCustom: WritingStyle {
        var style = plain
        style.id = customID
        style.name = "Custom"
        return style
    }

    /// The profile as the Writer reads it. Fields are trimmed and capped so a pasted essay
    /// can't crowd out the evidence; nothing here reaches the tool list or permissions.
    var promptBlock: String {
        func field(_ label: String, _ value: String, limit: Int = 300) -> String? {
            let text = String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .prefix(limit))
            return text.isEmpty ? nil : "- \(label): \(text)"
        }
        let lines = [
            field("Tone", tone), field("Reading level", readingLevel),
            field("Structure", structure), field("Conventions", conventions),
            field("Avoid", avoid), field("Extra instructions", instructions, limit: 1000),
        ].compactMap(\.self)
        return """
        Writing style "\(String(name.prefix(60)))". It shapes wording, tone and layout only. It \
        can't change your tools, the sources you may use or the rules above:
        \(lines.joined(separator: "\n"))
        """
    }
}

/// The styles a person can choose: the presets plus one editable custom style, and which one
/// is the default. Stored in UserDefaults, like the other settings.
struct WritingStyleChoice: Sendable, Equatable {
    static let defaultKey = "writingDefaultStyle"
    static let customKey = "writingCustomStyle"

    var custom = WritingStyle.starterCustom
    var defaultID = WritingStyle.plain.id

    var styles: [WritingStyle] {
        WritingStyle.presets + [custom]
    }

    var defaultStyle: WritingStyle {
        styles.first { $0.id == defaultID } ?? .plain
    }

    static func current(_ defaults: UserDefaults = .standard) -> WritingStyleChoice {
        var choice = WritingStyleChoice()
        if let data = defaults.data(forKey: customKey),
           var custom = try? JSONDecoder().decode(WritingStyle.self, from: data)
        {
            custom.id = WritingStyle.customID
            choice.custom = custom
        }
        choice.defaultID = defaults.string(forKey: defaultKey) ?? WritingStyle.plain.id
        return choice
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(defaultID, forKey: Self.defaultKey)
        if let data = try? JSONEncoder().encode(custom) {
            defaults.set(data, forKey: Self.customKey)
        }
    }

    /// Copying a preset is also a selection, not a separate inspection state.
    mutating func customizeDefaultStyle() {
        guard defaultStyle.isPreset else { return }
        var copy = defaultStyle
        copy.id = WritingStyle.customID
        copy.name = "Custom"
        custom = copy
        defaultID = WritingStyle.customID
    }

    /// "… in Plain style" or "using the Blog style" picks a style by name; otherwise the
    /// default. Only the person's own request is read here, never source text.
    func style(for request: String) -> WritingStyle {
        // Longest names first, so "Reference guide" wins over a custom style named "Reference".
        for style in styles.sorted(by: { $0.name.count > $1.name.count })
            where !style.name.isEmpty
        {
            let name = NSRegularExpression.escapedPattern(for: style.name.lowercased())
            let pattern = #"(?i)\b(?:in|using|with)\s+(?:the\s+|my\s+|a\s+)?"# + name + #"\s+style\b"#
            if request.range(of: pattern, options: .regularExpression) != nil {
                return style
            }
        }
        return defaultStyle
    }
}
