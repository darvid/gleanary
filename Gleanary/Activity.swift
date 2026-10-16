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

struct ActivityQuery: Equatable, Sendable {
    var search = ""
    var filter = ActivityFilter.all
    /// Nil shows every day. Bounds are computed with Calendar, not 24-hour arithmetic.
    var day: Date?
}

struct ActivityGroup: Identifiable, Sendable {
    let key: String
    let day: String
    let latest: ActivityEvent
    let count: Int

    var id: String {
        day + "/" + key
    }

    var label: String {
        if count == 1 {
            return latest.displayTitle
        }
        return latest.batchLabel ?? "\(latest.displayTitle) · \(count.formatted()) edits"
    }
}

struct ActivityDay: Identifiable, Sendable {
    let id: String
    let date: Date
    let summary: String
    var groups: [ActivityGroup]
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
