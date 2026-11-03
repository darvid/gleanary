import Foundation

/// A committed library change, not a background job or a proposal.
struct ActivityEvent: Identifiable, Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case created, updated, deleted, purged, sourceSaved, sourceLinked, sourceUnlinked,
             sourceUpdated
        case linkAdded, linkRemoved, filed, unfiled, primaryHome, archived, unarchived

        var label: String {
            switch self {
            case .created: "Note created"
            case .updated: "Note updated"
            case .deleted: "Note deleted"
            case .purged: "Note permanently deleted"
            case .sourceSaved: "Source saved"
            case .sourceLinked: "Source attached"
            case .sourceUnlinked: "Source detached"
            case .sourceUpdated: "Source address changed"
            case .linkAdded: "Link added"
            case .linkRemoved: "Link removed"
            case .filed: "Filed"
            case .unfiled: "Removed from filing"
            case .primaryHome: "Primary home changed"
            case .archived: "Archived"
            case .unarchived: "Unarchived"
            }
        }

        /// Whether a count means distinct items rather than individual changes: a note edited
        /// five times is one note edited, while five links are five links.
        var countsItems: Bool {
            switch self {
            case .sourceSaved, .sourceLinked, .sourceUnlinked, .linkAdded, .linkRemoved: false
            default: true
            }
        }

        /// What was done, in the past tense, for a sentence that starts with who did it.
        func phrase(_ count: Int) -> String {
            let (verb, one, many) = Self.phrases[self] ?? ("changed", "an item", "items")
            return "\(verb) " + (count == 1 ? one : "\(count.formatted()) \(many)")
        }

        private static let phrases: [Kind: (String, String, String)] = [
            .created: ("created", "a note", "notes"),
            .updated: ("edited", "a note", "notes"),
            .deleted: ("deleted", "a note", "notes"),
            .purged: ("permanently deleted", "a note", "notes"),
            .sourceSaved: ("saved", "a source", "sources"),
            .sourceLinked: ("attached", "a source", "sources"),
            .sourceUnlinked: ("detached", "a source", "sources"),
            .sourceUpdated: ("changed", "a source address", "source addresses"),
            .linkAdded: ("added", "a link", "links"),
            .linkRemoved: ("removed", "a link", "links"),
            .filed: ("filed", "a note", "notes"),
            .unfiled: ("unfiled", "a note", "notes"),
            .primaryHome: ("changed", "a primary home", "primary homes"),
            .archived: ("archived", "a note", "notes"),
            .unarchived: ("unarchived", "a note", "notes"),
        ]

        var symbol: String {
            switch self {
            case .created: "note.text.badge.plus"
            case .updated: "pencil"
            case .deleted, .purged: "trash"
            case .sourceSaved: "square.and.arrow.down"
            case .sourceLinked, .sourceUnlinked, .sourceUpdated: "doc.text"
            case .linkAdded, .linkRemoved: "link"
            case .filed, .unfiled, .primaryHome: "folder"
            case .archived, .unarchived: "archivebox"
            }
        }
    }

    let id: Int64
    let date: Date
    let kind: Kind
    let noteID: UUID?
    let relatedID: UUID?
    let title: String?
    let detail: String?
    let actor: String
    let revisionID: UUID?
    let groupID: String
    let batchLabel: String?

    var actorLabel: String {
        switch actor {
        case "manual": "You"
        case "agent": "Agent"
        case "automation": "Automation"
        case "import": "Import"
        case "legacy": "Earlier note history"
        default: "Gleanary"
        }
    }

    var displayTitle: String {
        title ?? "Permanently deleted item"
    }
}

enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All activity", notes = "Notes", sources = "Sources", links = "Links"
    case filing = "Filing", deletions = "Deletions"

    var id: String {
        rawValue
    }

    var kinds: [ActivityEvent.Kind] {
        switch self {
        case .all: ActivityEvent.Kind.allCases
        case .notes: [.created, .updated, .archived, .unarchived]
        case .sources: [.sourceSaved, .sourceLinked, .sourceUnlinked, .sourceUpdated]
        case .links: [.linkAdded, .linkRemoved]
        case .filing: [.filed, .unfiled, .primaryHome]
        case .deletions: [.deleted, .purged]
        }
    }
}

/// Who made a change, as a person reading the log would split it: their own work, or
/// Gleanary's agents and automations acting on its own.
enum ActivityScope: String, CaseIterable, Identifiable, Sendable {
    case everyone = "Everyone", you = "You", gleanary = "Gleanary"

    var id: String {
        rawValue
    }
}

struct ActivityQuery: Equatable, Sendable {
    var search = ""
    var filter = ActivityFilter.all
    var scope = ActivityScope.everyone
    /// Nil shows every day. Bounds are computed with Calendar, not 24-hour arithmetic.
    var day: Date?
}

struct ActivityGroup: Identifiable, Sendable {
    let key: String
    let day: String
    let latest: ActivityEvent
    let count: Int
    var byYou = true
    var byGleanary = false
    /// The automation whose run this is, when it is one.
    var automation: AutomationKind?
    /// Changed items or changes per kind, as the day summary counts them, except that a note
    /// a saved source created or filled in counts only as the source.
    var kinds: [ActivityEvent.Kind: Int] = [:]
    /// Why it happened, from the run or the source a save was found in.
    var context: String?
    /// For work on one item, its current title; a summary's work is its source's.
    var subjectTitle: String?
    /// Summary notes written for the item.
    var summaries = 0
    /// The category one item was filed under, when it was.
    var filedUnder: String?

    /// Whether this row is about one item rather than a batch across several.
    var isItem: Bool {
        key.hasPrefix("note:")
    }

    var title: String {
        isItem ? subjectTitle ?? latest.displayTitle : headline
    }

    /// What happened to one item, such as "Saved · Summarized · Filed under 18.01 Sales".
    var itemSummary: String {
        var parts: [String] = []
        for kind in ActivityEvent.Kind.allCases {
            guard let count = kinds[kind] else { continue }
            switch kind {
            case .sourceSaved: parts.append("Saved")
            case .created: parts.append("Created")
            case .updated: parts.append(count == 1 ? "Edited" : "Edited \(count.formatted()) times")
            case .filed: parts.append(filedUnder.map { "Filed under \($0)" } ?? "Filed")
            case .linkAdded, .linkRemoved, .sourceLinked, .sourceUnlinked:
                parts
                    .append(kind.phrase(count).prefix(1).uppercased() + kind.phrase(count)
                        .dropFirst())
            default: parts.append(kind.label)
            }
        }
        if summaries > 0 {
            // Right after the save or creation it summarizes, when that's on this row.
            let after = parts.firstIndex { $0 == "Saved" || $0 == "Created" }.map { $0 + 1 } ?? 0
            parts.insert("Summarized", at: after)
        }
        return parts.joined(separator: " · ")
    }

    var id: String {
        day + "/" + key
    }

    var label: String {
        if count == 1 {
            return latest.displayTitle
        }
        return latest.batchLabel ?? "\(latest.displayTitle) · \(count.formatted()) edits"
    }

    var runID: UUID? {
        automation == nil ? nil : UUID(uuidString: key)
    }

    var actorName: String {
        automation?.title ?? (byYou && byGleanary ? "You and Gleanary" : byYou ? "You" : "Gleanary")
    }

    /// One sentence for the whole unit of work, such as "Cross-linker added 6 links".
    var headline: String {
        let phrases = ActivityEvent.Kind.allCases.compactMap { kind in
            kinds[kind].map { kind.phrase($0) }
        }
        // Work on one item reads best as that item, like a single change.
        guard !phrases.isEmpty, kinds.values.reduce(0, +) > 1 else { return latest.displayTitle }
        return actorName + " " + phrases.formatted(.list(type: .and))
    }
}

struct ActivityDay: Identifiable, Sendable {
    let id: String
    let date: Date
    let summary: String
    var groups: [ActivityGroup]
}

/// What changed since a moment, split by who did it, for the top of Activity.
struct ActivityRecap: Equatable, Sendable {
    var sourcesByYou = 0
    var sourcesByGleanary = 0
    var notesCreated = 0
    var linksAdded = 0
    var notesFiled = 0

    var isEmpty: Bool {
        self == ActivityRecap()
    }

    var sentence: String {
        var parts: [String] = []
        let sources = sourcesByYou + sourcesByGleanary
        if sources > 0 {
            let split = sourcesByYou == 0 ? "all by Gleanary"
                : sourcesByGleanary == 0 ? "all by you"
                : "\(sourcesByYou.formatted()) by you, \(sourcesByGleanary.formatted()) by Gleanary"
            parts.append(
                "\(sources.formatted()) source\(sources == 1 ? "" : "s") saved (\(split))"
            )
        }
        for (count, noun, verb) in [(notesCreated, "note", "created"),
                                    (linksAdded, "link", "added"),
                                    (notesFiled, "note", "filed")] where count > 0
        {
            parts.append("\(count.formatted()) \(noun)\(count == 1 ? "" : "s") \(verb)")
        }
        return parts.formatted(.list(type: .and))
    }
}

struct ActivityPage: Sendable {
    let days: [ActivityDay]
    let hasMore: Bool
    let trackingSince: Date
}

struct ActivityInspection: Sendable {
    let event: ActivityEvent
    let current: MarkdownDocument?
    let before: String?
    let after: String?
    let previousTitle: String?

    /// CollectionDifference can become quadratic for unrelated, very long revisions.
    var diffIsBounded: Bool {
        [before, after].allSatisfy { text in
            guard let text else { return false }
            return text.utf8.count <= 100_000 && text.components(separatedBy: "\n").count <= 1000
        }
    }
}
