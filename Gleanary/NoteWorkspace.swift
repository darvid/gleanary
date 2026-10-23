import Foundation

/// Optional meaning, independent of Source/Note identity and source provenance.
enum NoteRecordType: String, Codable, CaseIterable, Identifiable, Sendable {
    case note, meeting, project, decision, person
    var id: Self {
        self
    }

    var label: String {
        rawValue.capitalized
    }

    var fields: [NoteProperty] {
        switch self {
        case .note: []
        case .meeting: [.init(id: "date", label: "Date", kind: .date),
                        .init(
                            id: "participants",
                            label: "Participants",
                            kind: .links,
                            target: .person
                        ),
                        .init(id: "project", label: "Project", kind: .link, target: .project)]
        case .project: [.init(id: "outcome", label: "Outcome", kind: .text),
                        .init(id: "status", label: "Status", kind: .text)]
        case .decision: [.init(id: "date", label: "Date", kind: .date),
                         .init(id: "project", label: "Project", kind: .link, target: .project)]
        case .person: [.init(id: "organization", label: "Organization", kind: .text)]
        }
    }
}

struct NoteProperty: Identifiable, Sendable {
    enum Kind: Sendable { case text, date, link, links }
    let id: String
    let label: String
    let kind: Kind
    var target: NoteRecordType?
}

struct NoteProfile: Codable, Equatable, Sendable {
    var type = NoteRecordType.note
    var values: [String: String] = [:]
    var links: [String: [UUID]] = [:]
    var templateID: UUID?
}

struct NoteTemplate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var title = "Untitled"
    var body = ""
    var defaults = NoteProfile()
    var version = 0
    var stock = false

    func draft(at date: Date = .now) -> (MarkdownDocument, NoteProfile) {
        let day = WorkspaceDay(date: date).rawValue
        let name = title.replacingOccurrences(of: "{{date}}", with: day)
        let text = body.replacingOccurrences(of: "{{date}}", with: day)
            .replacingOccurrences(of: "{{title}}", with: name)
        var profile = defaults
        profile.templateID = id
        profile.values = profile.values.mapValues { $0.replacingOccurrences(
            of: "{{date}}",
            with: day
        ) }
        return (MarkdownDocument(name: name, markdown: text), profile)
    }

    static func starterBody(from markdown: String) -> String {
        markdown.replacingOccurrences(
            of: #"\[Tracked task\]\(gleanary://task/[A-Fa-f0-9-]{36}\)"#,
            with: "[ ] ",
            options: .regularExpression
        )
    }

    static let starters: [NoteTemplate] = [
        starter(
            1,
            "Meeting",
            type: .meeting,
            title: "{{date}} Meeting",
            body: "## Agenda\n\n- \n\n## Discussion\n\n## Decisions\n\n## Action items\n\n- [ ] "
        ),
        starter(
            2,
            "Project",
            type: .project,
            title: "New project",
            body: "## Outcome\n\n## Context\n\n## Next actions\n\n- [ ] "
        ),
        starter(
            3,
            "Decision",
            type: .decision,
            title: "New decision",
            body: "## Context\n\n## Options\n\n## Decision\n\n## Rationale\n\n## Consequences\n"
        ),
        starter(4, "Checklist", type: .note, title: "New checklist", body: "- [ ] "),
        starter(5, "Person", type: .person, title: "New person", body: "## Notes\n\n"),
    ]

    private static func starter(
        _ number: UInt8,
        _ name: String,
        type: NoteRecordType,
        title: String,
        body: String
    ) -> NoteTemplate {
        let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, number))
        let values = type.fields.contains { $0.id == "date" } ? ["date": "{{date}}"] : [:]
        return NoteTemplate(
            id: id,
            name: name,
            title: title,
            body: body,
            defaults: NoteProfile(type: type, values: values),
            version: 1,
            stock: true
        )
    }
}

/// A Gregorian local calendar day, not a UTC timestamp masquerading as a deadline.
struct WorkspaceDay: RawRepresentable, Codable, Comparable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        let pieces = rawValue.split(separator: "-").compactMap { Int($0) }
        guard rawValue.count == 10, pieces.count == 3,
              (1 ... 9999).contains(pieces[0]) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == pieces[0],
              calendar.component(.month, from: date) == pieces[1],
              calendar.component(.day, from: date) == pieces[2] else { return nil }
        self.rawValue = rawValue
        guard WorkspaceDay(date: date).rawValue == rawValue else { return nil }
    }

    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        rawValue = String(
            format: "%04d-%02d-%02d",
            parts.year ?? 1,
            parts.month ?? 1,
            parts.day ?? 1
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let day = WorkspaceDay(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a valid YYYY-MM-DD calendar date."
            )
        }
        self = day
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var date: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        return calendar
            .date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ??
            .distantPast
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WorkspaceTask: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable { case open, completed, canceled }
    var id = UUID()
    var title: String
    var status = Status.open
    var due: WorkspaceDay?
    var planned: WorkspaceDay?
    var projectID: UUID?
    var originID: UUID?
    var version = 0

    var reference: String {
        "[Tracked task](gleanary://task/\(id.uuidString))"
    }

    var markdown: String {
        let marker = status == .completed ? "x" : " "
        return "[\(marker)] \(title)" + (due.map { " (due \($0.rawValue))" } ?? "")
            + (planned.map { " (planned \($0.rawValue))" } ?? "")
            + (status == .canceled ? " (canceled)" : "")
    }
}

enum WorkspaceTaskView: String, CaseIterable, Identifiable, Sendable {
    case inbox, today, upcoming, all, completed
    var id: Self {
        self
    }

    var label: String {
        rawValue.capitalized
    }
}

struct WorkspaceTaskPage: Sendable {
    let tasks: [WorkspaceTask]
    let hasMore: Bool
}

struct WorkspaceNoteLink: Identifiable, Sendable {
    let id: UUID
    let name: String
}

enum WorkspaceError: LocalizedError {
    case invalidTitle, invalidProperties, invalidDate, stale, missingNote, stockTemplate,
         trackedTemplate
    var errorDescription: String? {
        switch self {
        case .invalidTitle: "Enter a title between 1 and 500 characters."
        case .invalidProperties: "A property has an invalid value. Check its type and linked notes."
        case .invalidDate: "Use a valid date in YYYY-MM-DD format."
        case .stale: "This item changed in another view. Reopen it before saving your changes."
        case .missingNote: "The linked note is no longer available. Choose another note."
        case .stockTemplate: "Duplicate a stock template before changing it."
        case .trackedTemplate: "Replace tracked-task links with local checkboxes before saving this template."
        }
    }
}
