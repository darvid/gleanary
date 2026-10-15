import SwiftUI

/// The gathered scope under the Curator's reply: every candidate with a checkbox, possible
/// strays unchecked and marked, the style and whether general knowledge may be used. Nothing is
/// read until Write Document.
struct WriterScopeCard: View {
    let request: WriterRequest
    let styles: [WritingStyle]
    let busy: Bool
    let open: (UUID) -> Void
    let confirm: ([UUID], WritingStyle, Bool) -> Void
    let cancel: () -> Void
    @State private var selection: Set<UUID>
    @State private var styleID: String
    @State private var generalKnowledge: Bool

    init(
        request: WriterRequest,
        styles: [WritingStyle],
        busy: Bool,
        open: @escaping (UUID) -> Void,
        confirm: @escaping ([UUID], WritingStyle, Bool) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.request = request
        // The request's own style stays choosable even if it was edited since.
        self.styles = styles
            .contains { $0.id == request.style.id } ? styles : [request.style] + styles
        self.busy = busy
        self.open = open
        self.confirm = confirm
        self.cancel = cancel
        _selection = State(initialValue: Set(request.selection))
        _styleID = State(initialValue: request.style.id)
        _generalKnowledge = State(initialValue: request.generalKnowledge)
    }

    private var style: WritingStyle {
        styles.first { $0.id == styleID } ?? request.style
    }

    private var overLimit: Int {
        max(0, selection.count - request.scopeLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Color.primary.opacity(0.72)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scope for this document").font(.callout.weight(.medium))
                    Text("\(selection.count) of \(request.candidates.count) checked")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .countsOnChange(selection.count)
                }
                Spacer(minLength: 8)
                Button(selection.isEmpty ? "Check All" : "Uncheck All") {
                    selection = selection.isEmpty ? Set(request.candidates.map(\.id)) : []
                }
                .buttonStyle(.link).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(request.candidates) { row($0) }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: request.candidates.count < 7)
            HStack(spacing: 16) {
                Picker("Style", selection: $styleID) {
                    ForEach(styles) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                Toggle("Allow general knowledge", isOn: $generalKnowledge)
                    .toggleStyle(.checkbox)
                    .help(
                        "Anything drawn from it, rather than your sources, is marked in the document."
                    )
            }
            .font(.callout)
            if overLimit > 0 {
                Text(request.scopeLimit == WriterLimits.localScope
                    ? "Composing on this Mac takes up to \(request.scopeLimit) items: uncheck \(overLimit), or connect ChatGPT in Settings."
                    :
                    "A document can draw on up to \(request.scopeLimit) items: uncheck \(overLimit).")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Write Document") {
                    confirm(
                        request.candidates.map(\.id).filter(selection.contains),
                        style,
                        generalKnowledge
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || overLimit > 0 || busy)
                .help(busy ? "Finish or stop the current task first" :
                    "Read the checked items and write the document")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func row(_ candidate: ScopeCandidate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding {
                selection.contains(candidate.id)
            } set: { on in
                if on {
                    selection.insert(candidate.id)
                } else {
                    selection.remove(candidate.id)
                }
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(candidate.title).lineLimit(1)
                        if candidate.offTopic {
                            OffTopicBadge()
                        }
                    }
                    Text(candidate.filing.map { "\($0), \(candidate.reason.lowercasedFirst)" }
                        ?? candidate.reason)
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.72)).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 4)
            Button("Open \(candidate.title)", systemImage: "arrow.up.forward.square") {
                open(candidate.id)
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Open this item")
        }
        .font(.callout)
    }
}

private extension String {
    var lowercasedFirst: String {
        prefix(1).lowercased() + dropFirst()
    }
}

private struct OffTopicBadge: View {
    var body: some View {
        Text("Possibly off-topic").font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.orange.opacity(0.22), in: Capsule())
            .help("Gathered by category or a weak meaning match only, so it's unchecked")
    }
}

/// A line diff of a document's text: removed lines struck through, added lines marked, and long
/// unchanged runs folded to a count.
struct TextDiffView: View {
    let lines: [TextDiff.Line]

    init(before: String, after: String) {
        lines = TextDiff.lines(before: before, after: after)
    }

    init(lines: [TextDiff.Line]) {
        self.lines = lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case let .same(text):
                    Text(text).foregroundStyle(.secondary).padding(.leading, 18)
                case let .folded(count):
                    Text(count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
                        .font(.caption).foregroundStyle(.tertiary).padding(.leading, 18)
                case let .added(text):
                    marked(text, symbol: "plus", label: "Added", tint: .green)
                case let .removed(text):
                    marked(text, symbol: "minus", label: "Removed", tint: .red, strike: true)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func marked(
        _ text: String,
        symbol: String,
        label: String,
        tint: Color,
        strike: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(tint)
                .frame(width: 12).accessibilityLabel(label)
            Text(text).strikethrough(strike).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
    }
}

enum TextDiff {
    enum Line: Equatable {
        case same(String), added(String), removed(String)
        /// Unchanged lines hidden between changes.
        case folded(Int)
    }

    static func lines(before: String, after: String, context: Int = 2) -> [Line] {
        let old = readable(before)
        let new = readable(after)
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var merged: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                merged.append(.removed(old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) || oldIndex >= old.count {
                merged.append(.added(new[newIndex]))
                newIndex += 1
            } else {
                merged.append(.same(old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }
        return fold(merged, context: context)
    }

    /// Lines as a reader sees them: blank lines dropped and in-app link targets hidden, so a
    /// citation reads "(2)" rather than a note address.
    private static func readable(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map {
                $0.replacingOccurrences(
                    of: #"\[([^\]]*)\]\(infactory://note/[^)]+\)"#, with: "$1",
                    options: .regularExpression
                )
            }
    }

    /// Keeps `context` unchanged lines either side of each change and folds the rest.
    private static func fold(_ lines: [Line], context: Int) -> [Line] {
        let changed = lines.indices.filter {
            if case .same = lines[$0] {
                return false
            }
            return true
        }
        var result: [Line] = []
        var hidden = 0
        for index in lines.indices {
            let near = changed.contains { abs($0 - index) <= context }
            if case .same = lines[index], !near {
                hidden += 1
                continue
            }
            if hidden > 0 {
                result.append(.folded(hidden))
                hidden = 0
            }
            result.append(lines[index])
        }
        if hidden > 0 {
            result.append(.folded(hidden))
        }
        return result
    }

    static func counts(_ lines: [Line]) -> (added: Int, removed: Int) {
        lines.reduce(into: (0, 0)) { counts, line in
            switch line {
            case .added: counts.0 += 1
            case .removed: counts.1 += 1
            default: break
            }
        }
    }
}
