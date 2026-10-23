import Foundation
import GRDB

/// Explicitly supports top-level Markdown task items. Code fences and quoted/indented code
/// are not tasks. A revision and exact line guard every mutation; line offsets are never IDs.
struct MarkdownChecklistItem: Identifiable, Equatable, Sendable {
    let line: Int
    let raw: String
    let title: String
    let checked: Bool
    var id: Int {
        line
    }
}

enum MarkdownChecklist {
    static func items(in markdown: String) -> [MarkdownChecklistItem] {
        guard markdown.contains("[ ]") || markdown.contains("[x]") || markdown.contains("[X]"),
              let parsed = try? AttributedString(
                  markdown: markdown,
                  options: .init(appliesSourcePositionAttributes: true)
              ) else { return [] }
        let lines = taskLines(in: parsed)
        return markdown.components(separatedBy: "\n").enumerated().compactMap { index, raw in
            guard lines.contains(index) else { return nil }
            let leading = raw.prefix(while: { $0 == " " })
            guard leading.count <= 3 else { return nil }
            let text = raw.dropFirst(leading.count)
            let marker = String(text.prefix(6))
            guard [
                "- [ ] ",
                "- [x] ",
                "- [X] ",
                "* [ ] ",
                "* [x] ",
                "* [X] ",
                "+ [ ] ",
                "+ [x] ",
                "+ [X] ",
            ].contains(marker) else { return nil }
            let title = text.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return .init(
                line: index,
                raw: raw,
                title: title,
                checked: marker.lowercased().contains("[x]")
            )
        }
    }

    static func replacing(
        _ item: MarkdownChecklistItem,
        in markdown: String,
        with replacement: String
    ) throws -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(item.line), lines[item.line] == item.raw,
              items(in: markdown).contains(item) else { throw WorkspaceError.stale }
        lines[item.line] = replacement
        return lines.joined(separator: "\n")
    }

    private static func taskLines(in parsed: AttributedString) -> Set<Int> {
        var lines = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let lists = components.filter {
                if case .listItem = $0.kind {
                    true
                } else {
                    false
                }
            }
            let literal = components.contains {
                switch $0.kind { case .codeBlock, .blockQuote: true; default: false }
            }
            guard lists.count == 1, !literal,
                  let position = run.markdownSourcePosition else { continue }
            for line in position.startLine ... position.endLine {
                lines.insert(line - 1)
            }
        }
        return lines
    }
}

extension DocumentStore {
    func toggleChecklist(
        _ item: MarkdownChecklistItem,
        in document: MarkdownDocument
    ) throws -> MarkdownDocument {
        try activityWrite(actor: "manual") { db in
            try Self.requireChecklistRevision(document, in: db)
            let old = item.checked ? (item.raw.contains("[X]") ? "[X]" : "[x]") : "[ ]"
            guard let range = item.raw.range(of: old) else { throw WorkspaceError.stale }
            var line = item.raw
            line.replaceSubrange(range, with: item.checked ? "[ ]" : "[x]")
            var updated = document
            updated.markdown = try MarkdownChecklist.replacing(
                item,
                in: document.markdown,
                with: line
            )
            return try Self.writeNote(updated, in: db)
        }
    }

    /// Replace the local checkbox with a stable task reference in the same transaction.
    func trackChecklist(
        _ item: MarkdownChecklistItem,
        in document: MarkdownDocument
    ) throws -> WorkspaceTask {
        try activityWrite(actor: "manual") { db in
            try Self.requireChecklistRevision(document, in: db)
            let profile = try Self.noteProfile(document.id, in: db)
            let task = try Self.writeWorkspaceTask(WorkspaceTask(
                title: item.title, status: item.checked ? .completed : .open,
                projectID: profile.type == .project ? document.id : profile.links["project"]?.first,
                originID: document.id
            ), in: db)
            try Self.placeWorkspaceTask(task.id, in: document.id, database: db)
            let indent = String(item.raw.prefix(while: { $0 == " " }))
            var updated = document
            updated.markdown = try MarkdownChecklist.replacing(
                item,
                in: document.markdown,
                with: indent + "- " + task.reference
            )
            _ = try Self.writeNote(updated, in: db)
            return task
        }
    }

    private static func requireChecklistRevision(
        _ document: MarkdownDocument,
        in db: Database
    ) throws {
        try requireWorkspaceNote(document.id, in: db)
        let revision = try String.fetchOne(
            db,
            sql: "SELECT revision FROM notes WHERE id = ?",
            arguments: [document.id.uuidString]
        )
        guard revision == document.revision?.uuidString else { throw WorkspaceError.stale }
    }
}
