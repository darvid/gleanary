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

/// A finished audit: up to three possible gaps first, each with how it was checked, then every
/// other criterion with its coverage as text.
struct AuditReportCard: View {
    let audit: ResearchAudit
    let report: AuditReport
    let open: (UUID) -> Void
    let dismiss: (String, Bool) -> Void
    @State private var showingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Research audit").font(.callout.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Read \(AuditReport.items(report.read)) · searched \(AuditReport.items(report.searchable)) · \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption.monospacedDigit()).foregroundStyle(Color.primary.opacity(0.72))
            }
            if audit.stale {
                Label(
                    "An item this audit read has changed or was deleted since. Ask again for a current audit.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            }
            let gaps = report.gaps
            if gaps.isEmpty {
                Text("No actionable gaps found under these criteria and this search.")
                    .font(.callout)
            }
            ForEach(showingAll ? gaps : Array(gaps.prefix(AuditLimits.shownFindings))) {
                finding($0)
            }
            if gaps.count > AuditLimits.shownFindings {
                Button(showingAll ? "Show Fewer" :
                    "Show \(gaps.count - AuditLimits.shownFindings) More")
                {
                    showingAll.toggle()
                }
                .buttonStyle(.link).font(.caption)
            }
            let others = report.results.filter { !$0.isGap }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other criteria").font(.caption.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(others) { other($0) }
                }
            }
            if !report.limitations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.limitations, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func finding(_ result: DimensionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Possible coverage gap: \(result.dimension.label)")
                .font(.callout.weight(.medium)).accessibilityAddTraits(.isHeader)
            Text(AuditReport.observation(result, report: report)).font(.callout)
            Text(AuditReport.reason(result.dimension)).font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
            DisclosureGroup("How it was checked") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Criterion: \(result.dimension.criteria)")
                    ForEach(result.searches, id: \.query) { search in
                        Text(search.failed ? "Searched “\(search.query)”: failed"
                            : "Searched “\(search.query)”: \(search.matches) passages")
                    }
                    Text(
                        "Read the matching passages of \(AuditReport.items(result.searchedItems)); none met the criterion."
                    )
                }
                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.caption)
            HStack {
                Spacer()
                Button("Dismiss") { dismiss(result.id, true) }
                    .controlSize(.small)
                    .help("Hide this finding. It isn't marked as answered.")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func other(_ result: DimensionResult) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(evidence.quote)”").textSelection(.enabled)
                            Text(evidence.outsideScope
                                ? "\(evidence.title), outside the audit's scope" : evidence.title)
                                .foregroundStyle(Color.primary.opacity(0.72))
                        }
                        Spacer(minLength: 4)
                        Button("Open \(evidence.title)", systemImage: "arrow.up.forward.square") {
                            open(evidence.itemID)
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                ForEach(result.limitations, id: \.self) {
                    Text($0).foregroundStyle(Color.primary.opacity(0.72))
                }
                if result.dismissed {
                    Button("Show Finding Again") { dismiss(result.id, false) }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(result.dimension.label)
                Text(result.dismissed ? "Dismissed" : result.coverage.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .font(.callout)
        }
    }
}
