import SwiftUI

/// The library agent's changeset, summarized under its reply in chat. Nothing it proposes
/// applies until someone reviews it.
struct AgentChangesCard: View {
    let changes: [AgentChange]
    let review: () -> Void
    let undo: () -> Void

    private var pending: Bool {
        changes.contains { $0.status == "pending" }
    }

    private func count(_ status: String) -> Int {
        changes.count { $0.status == status }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checklist").foregroundStyle(Color.primary.opacity(0.72))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.breakdown(changes)).font(.callout.weight(.medium))
                Text(status).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                    .fadesOnChange(status)
            }
            Spacer(minLength: 8)
            if pending {
                Button("Review Changes…", action: review)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else if count("applied") > 0 {
                Button("Undo", action: undo).buttonStyle(.link).font(.caption)
                    .help("Put back everything this changeset changed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var status: String {
        if pending {
            return "Proposed. Nothing changes until you apply."
        }
        let parts = [
            ("applied", "applied"), ("undone", "undone"), ("stale", "skipped"), (
                "rejected",
                "rejected"
            ),
        ].compactMap { status, label in count(status) > 0 ? "\(count(status)) \(label)" : nil }
        return parts.formatted(.list(type: .and)).capitalizedFirst
    }

    static func breakdown(_ changes: [AgentChange]) -> String {
        let labels: [(AgentChange.Kind, String, String)] = [
            (.title, "title", "titles"), (.summary, "summary", "summaries"),
            (.filing, "filing", "filings"), (.category, "new category", "new categories"),
            (.link, "link", "links"), (.archive, "archive", "archives"),
            (.relink, "moved link", "moved links"),
        ]
        return labels.compactMap { kind, one, many in
            let count = changes.count { $0.kind == kind }
            return count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
        }.formatted(.list(type: .and))
    }
}

/// Every proposed change with a checkbox, grouped by kind. Applying the selection rejects the
/// rest; Undo on the card puts it all back.
struct AgentChangesReview: View {
    let changes: [AgentChange]
    let titles: [UUID: String]
    let apply: (Set<UUID>) -> Void
    let reject: () -> Void
    @State private var selected: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(
        changes: [AgentChange],
        titles: [UUID: String],
        apply: @escaping (Set<UUID>) -> Void,
        reject: @escaping () -> Void
    ) {
        let pending = changes.filter { $0.status == "pending" }
        self.changes = pending
        self.titles = titles
        self.apply = apply
        self.reject = reject
        _selected = State(initialValue: Set(pending.map(\.id)))
    }

    private var newCodes: Set<String> {
        Set(changes.filter { $0.kind == .category }.compactMap(\.code))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Proposed Changes").font(.title3.weight(.semibold))
                Text("Nothing changes until you apply. Undo puts everything back afterwards.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            List {
                ForEach(Self.kindOrder, id: \.self) { kind in
                    let group = changes.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section(Self.heading(kind, count: group.count)) {
                            ForEach(group) { change in
                                Toggle(isOn: binding(for: change)) { row(change) }
                                    .toggleStyle(.checkbox)
                                    .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button("Reject All", role: .destructive) { reject(); dismiss() }
                Button(selected.count == changes.count ? "Select None" : "Select All") {
                    selected = selected.count == changes.count ? [] : Set(changes.map(\.id))
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(selected.count)") { apply(selected); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
    }

    /// Every kind, in the order the sheet groups them; a test keeps it complete, since a kind
    /// left out would be applied without ever being shown.
    static let kindOrder: [AgentChange.Kind] = [
        .title, .summary, .category, .filing, .link, .relink, .archive,
    ]

    private static func heading(_ kind: AgentChange.Kind, count: Int) -> String {
        switch kind {
        case .category: count == 1 ? "New category" : "New categories"
        case .title: "Titles"
        case .summary: "Summaries"
        case .filing: "Filing"
        case .link: count == 1 ? "Link" : "Links"
        case .archive: "Archive"
        case .relink: count == 1 ? "Moved link" : "Moved links"
        }
    }

    /// A filing into a proposed category needs that category, so the two select together.
    private func binding(for change: AgentChange) -> Binding<Bool> {
        Binding {
            selected.contains(change.id)
        } set: { on in
            if on {
                selected.insert(change.id)
                if change.kind == .filing, let code = change.code, newCodes.contains(code) {
                    changes.filter { $0.kind == .category && $0.code == code }
                        .forEach { selected.insert($0.id) }
                }
            } else {
                selected.remove(change.id)
                if change.kind == .category {
                    changes.filter { $0.kind == .filing && $0.code == change.code }
                        .forEach { selected.remove($0.id) }
                }
            }
        }
    }

    private func row(_ change: AgentChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch change.kind {
            case .category:
                HStack(spacing: 6) {
                    Text("\(change.code ?? "") \(change.after)").fontWeight(.medium)
                    NewCategoryBadge()
                }
            case .title:
                Text(change.after).fontWeight(.medium)
                Text(change.before).strikethrough().foregroundStyle(.secondary).lineLimit(2)
            case .filing:
                Text(itemTitle(change)).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
                    Text(change.before).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("to")
                    Text(change.after)
                        .foregroundStyle(newCodes.contains(change.code ?? "") ? NewCategoryBadge
                            .tint : .primary)
                }
                .lineLimit(1)
            case .link:
                Text(itemTitle(change)).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("linked with")
                    Text(change.targetID.flatMap { titles[$0] } ?? "Item").lineLimit(1)
                }
            case .archive:
                Text(itemTitle(change)).fontWeight(.medium).lineLimit(1)
                Label(change.after, systemImage: "archivebox").font(.callout)
                    .foregroundStyle(.secondary)
            case .relink:
                Text(itemTitle(change)).fontWeight(.medium).lineLimit(1)
                Text(change.before).strikethrough().foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                        .foregroundStyle(.secondary).accessibilityLabel("now at")
                    Text(change.after).lineLimit(1).truncationMode(.middle)
                }
            case .summary:
                Text(itemTitle(change)).fontWeight(.medium).lineLimit(1)
                RowDisclosure(title: "New text") {
                    MarkdownPreview(markdown: change.after, font: .callout)
                        .textSelection(.enabled)
                }
            }
            if !change.reason.isEmpty {
                Text(change.reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemTitle(_ change: AgentChange) -> String {
        change.noteID.flatMap { titles[$0] } ?? "Item"
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
