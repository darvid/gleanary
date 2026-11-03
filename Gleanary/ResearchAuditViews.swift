import SwiftUI

/// An audit's scope under the Curator's reply: the gathered items and the proposed criteria,
/// each with a checkbox. Criteria the model suggested start unchecked and say so. Nothing is
/// read until Run Audit.
struct AuditScopeCard: View {
    let audit: ResearchAudit
    let busy: Bool
    let open: (UUID) -> Void
    let confirm: ([UUID], Set<String>) -> Void
    let cancel: () -> Void
    @State private var selection: Set<UUID>
    @State private var accepted: Set<String>

    init(
        audit: ResearchAudit,
        busy: Bool,
        open: @escaping (UUID) -> Void,
        confirm: @escaping ([UUID], Set<String>) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.audit = audit
        self.busy = busy
        self.open = open
        self.confirm = confirm
        self.cancel = cancel
        _selection = State(initialValue: Set(audit.selection))
        _accepted = State(initialValue: Set(audit.brief.dimensions.filter(\.accepted).map(\.id)))
    }

    private var overLimit: Int {
        max(0, selection.count - audit.scopeLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checklist")
                    .foregroundStyle(Color.primary.opacity(0.72)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scope for this audit").font(.callout.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "\(selection.count) of \(audit.candidates.count) items, \(accepted.count) of \(audit.brief.dimensions.count) criteria checked"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            Text("Criteria").font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ForEach(audit.brief.dimensions) { criterion($0) }
            HStack {
                Text("Items").font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(selection.isEmpty ? "Check All" : "Uncheck All") {
                    selection = selection.isEmpty ? Set(audit.candidates.map(\.id)) : []
                }
                .buttonStyle(.link).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(audit.candidates) { item($0) }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: audit.candidates.count < 6)
            if overLimit > 0 {
                Text("An audit can read up to \(audit.scopeLimit) items: uncheck \(overLimit).")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Run Audit") {
                    confirm(audit.candidates.map(\.id).filter(selection.contains), accepted)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || accepted.isEmpty || overLimit > 0 || busy)
                .help(busy ? "Finish or stop the current task first" :
                    "Read the checked items against the checked criteria, then search your library")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func criterion(_ dimension: AuditDimension) -> some View {
        Toggle(isOn: Binding {
            accepted.contains(dimension.id)
        } set: { on in
            if on {
                accepted.insert(dimension.id)
            } else {
                accepted.remove(dimension.id)
            }
        }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dimension.label)
                    Text(dimension.fromRequest ? "From your request" : "Suggested")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            Color.primary.opacity(dimension.fromRequest ? 0.08 : 0.14),
                            in: Capsule()
                        )
                        .help(dimension.fromRequest ? "“\(dimension.origin)”"
                            :
                            "Your request doesn't ask for this, so it's only checked if you check it")
                }
                Text(dimension.criteria).font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.72))
            }
        }
        .toggleStyle(.checkbox).font(.callout)
    }

    private func item(_ candidate: ScopeCandidate) -> some View {
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
                    Text(candidate.title).lineLimit(1)
                    Text(candidate.offTopic ? "\(candidate.reason) · possibly off-topic"
                        : candidate.reason)
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

/// A finished audit: a verdict, then one row per criterion (possible gaps first) with a
/// status dot, what the status rests on, and the status as text. Each row opens to its evidence,
/// grouped by item with the item as a link, or to how a gap was checked.
struct AuditReportCard: View {
    let audit: ResearchAudit
    let report: AuditReport
    let open: (UUID) -> Void
    let dismiss: (String, Bool) -> Void

    private var checked: [DimensionResult] {
        report.results.filter { $0.coverage != .outOfScope }
    }

    /// Possible gaps, then what couldn't be assessed, then what's answered, then the rest.
    private var rows: [DimensionResult] {
        func rank(_ result: DimensionResult) -> Int {
            if result.isGap {
                return 0
            }
            switch result.coverage {
            case .unknown: return 1
            case .supported: return 2
            case .notFound: return 3
            case .outOfScope: return 4
            }
        }
        return report.results.enumerated().sorted {
            (rank($0.element), $0.offset) < (rank($1.element), $1.offset)
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Research audit", systemImage: "checklist")
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                Text(audit.brief.query.isEmpty ? "Your research" : audit.brief.query
                    .capitalizedFirst)
                    .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(verdict).font(.callout)
                Text(
                    "Read \(AuditReport.items(report.read)) · searched \(AuditReport.items(report.searchable)) · \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.72))
                if audit.stale {
                    Label(
                        "An item this audit read has changed or was deleted since. Ask again for a current audit.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row($0) }
            }
            ForEach(report.limitations, id: \.self) {
                Text($0).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            }
            Text(
                "These states describe what your saved items establish, not whether the conclusions are true."
            )
            .font(.caption).foregroundStyle(Color.primary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var verdict: String {
        let gaps = report.gaps.count
        let unknown = checked.count(where: { $0.coverage == .unknown })
        if gaps > 0 {
            return gaps == 1 ? "1 criterion isn't established by your saved items."
                : "\(gaps) criteria aren't established by your saved items."
        }
        if unknown > 0 {
            return "No gaps found, but \(unknown == 1 ? "1 criterion" : "\(unknown) criteria") couldn't be assessed."
        }
        return "No gaps found: every criterion you checked is answered by a quote from your items."
    }

    private func status(_ result: DimensionResult) -> (text: String, tint: Color) {
        if result.dismissed {
            return ("Dismissed", .gray)
        }
        return switch result.coverage {
        case .supported: ("Supported", .green)
        case .notFound: ("Possible gap", .orange)
        case .unknown: ("Unknown", .gray)
        case .outOfScope: ("Not checked", .clear)
        }
    }

    /// One line on what the status rests on.
    private func basis(_ result: DimensionResult) -> String {
        let items = Set(result.evidence.map(\.itemID)).count
        switch result.coverage {
        case .supported:
            let quotes = result.evidence.count == 1 ? "1 quote" : "\(result.evidence.count) quotes"
            let outside = result.evidence.contains(where: \.outsideScope)
                ? ", found outside the scope" : ""
            return "\(quotes) from \(AuditReport.items(items))\(outside)"
        case .notFound:
            return "Not in the \(AuditReport.items(report.read)) read or a library search"
        case .unknown:
            return result.limitations.first ?? "Something that might answer it wasn't read"
        case .outOfScope:
            return "You didn't check this criterion"
        }
    }

    private func row(_ result: DimensionResult) -> some View {
        let status = status(result)
        return DisclosureGroup {
            details(result)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(status.tint.opacity(0.85))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                        .opacity(status.tint == .clear ? 1 : 0))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.dimension.label).font(.callout.weight(.medium))
                    Text(basis(result)).font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.72)).lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(status.text).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 3)
    }

    private func details(_ result: DimensionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checked for: \(result.dimension.criteria)")
                .foregroundStyle(Color.primary.opacity(0.72))
            if result.coverage == .notFound {
                Text(AuditReport.observation(result, report: report))
                Text(AuditReport.reason(result.dimension))
                    .foregroundStyle(Color.primary.opacity(0.72))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(result.searches, id: \.query) { search in
                        Text(search.failed ? "Searched “\(search.query)”: failed"
                            : "Searched “\(search.query)”: \(search.matches) passages")
                    }
                    Text(
                        "Read the matching passages of \(AuditReport.items(result.searchedItems)); none met the criterion."
                    )
                }
                .foregroundStyle(Color.primary.opacity(0.72))
                Button(result.dismissed ? "Show Finding Again" : "Dismiss") {
                    dismiss(result.id, !result.dismissed)
                }
                .controlSize(.small)
                .help(result.dismissed ? "Show this finding again"
                    : "Hide this finding. It isn't marked as answered.")
            }
            ForEach(Self.byItem(result.evidence), id: \.id) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        open(item.id)
                    } label: {
                        Text(item.outsideScope ? "\(item.title) (outside the scope)" : item.title)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.link)
                    .help("Open this item")
                    ForEach(item.quotes, id: \.self) { quote in
                        Text(quote).textSelection(.enabled)
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 2)
                            }
                    }
                }
            }
            ForEach(result.coverage == .unknown ? result.limitations : [], id: \.self) {
                Text($0).foregroundStyle(Color.primary.opacity(0.72))
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16).padding(.top, 6).padding(.bottom, 4)
    }

    /// Quotes under their item, in the order items first appear.
    private static func byItem(_ evidence: [AuditEvidence])
        -> [(id: UUID, title: String, outsideScope: Bool, quotes: [String])]
    {
        var order: [UUID] = []
        var grouped: [UUID: (title: String, outsideScope: Bool, quotes: [String])] = [:]
        for item in evidence {
            if grouped[item.itemID] == nil {
                order.append(item.itemID)
                grouped[item.itemID] = (item.title, item.outsideScope, [])
            }
            grouped[item.itemID]?.quotes.append(item.quote)
        }
        return order.compactMap { id in
            grouped[id].map { (id, $0.title, $0.outsideScope, $0.quotes) }
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
