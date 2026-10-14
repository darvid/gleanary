import SwiftUI

/// The built-in automations: whether each runs, how often, what it may change, what it did,
/// and what it's waiting on you to review.
struct AutomationsView: View {
    let model: AutomationsModel
    @State private var reviewing: AutomationKind?

    var body: some View {
        Form {
            Section {
                Text(
                    "Automations run while Infactory is open, a batch at a time, and pause while you're importing or summarizing. Apart from summaries, nothing changes until you review it."
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .textSelection(.enabled)
                }
            }
            ForEach(AutomationKind.allCases) { kind in
                AutomationSection(
                    model: model,
                    config: model.config(kind),
                    review: { reviewing = kind }
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .task { await model.load() }
        .sheet(item: $reviewing) { kind in
            AgentChangesReview(
                changes: model.pending[kind] ?? [],
                titles: model.titles,
                apply: { ids in Task { await model.apply(ids, of: kind) } },
                reject: { Task { await model.reject(kind) } }
            )
        }
    }
}

private struct AutomationSection: View {
    let model: AutomationsModel
    let config: AutomationConfig
    let review: () -> Void

    private var kind: AutomationKind {
        config.kind
    }

    private var running: Bool {
        model.running == kind
    }

    private var lastRun: AutomationRun? {
        model.runs[kind]?.first
    }

    var body: some View {
        Section {
            header
            LabeledContent("Schedule") {
                Picker("Schedule", selection: binding(\.interval)) {
                    ForEach(kind.intervals, id: \.self) {
                        Text(AutomationKind.intervalLabel($0)).tag($0)
                    }
                }
                .labelsHidden().fixedSize()
            }
            LabeledContent("Allowed to") { Text(kind.policy) }
            LabeledContent("Last run") { lastRunStatus }
            if config.enabled, !running, let next = config.nextRunAt {
                LabeledContent("Next run") {
                    Text(next > Date() ? next
                        .formatted(.relative(presentation: .named)) : "Shortly")
                        .foregroundStyle(.secondary)
                }
            }
            if let pending = model.pending[kind], !pending.isEmpty {
                LabeledContent {
                    Button("Review \(pending.count.formatted())…", action: review)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                } label: {
                    Label(
                        "\(AgentChangesCard.breakdown(pending)) waiting",
                        systemImage: "checklist"
                    )
                }
            }
            DisclosureGroup("Options") { options }
            if let runs = model.runs[kind], !runs.isEmpty {
                DisclosureGroup("History") {
                    ForEach(runs.prefix(10)) { RunRow(model: model, run: $0) }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.title3).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(kind.color.gradient, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.headline)
                Text(kind.summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(kind.role.title)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Toggle(kind.title, isOn: binding(\.enabled)).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 4)
    }

    private var lastRunStatus: some View {
        HStack(spacing: 10) {
            if running {
                Label {
                    Text("Running…").fadesOnChange(running)
                } icon: {
                    Image(systemName: "progress.indicator")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
                .foregroundStyle(.secondary)
                Button("Stop") { model.stop() }.controlSize(.small)
            } else {
                Text(lastRunSummary).foregroundStyle(.secondary).fadesOnChange(lastRunSummary)
                Button("Run Now") { model.runNow(kind) }
                    .controlSize(.small)
                    .disabled(model.running != nil)
                    .help(model.running != nil ? "Another automation is running" : "Run once now")
            }
        }
    }

    private var lastRunSummary: String {
        guard let run = lastRun else {
            return "Never"
        }
        return [run.startedAt.formatted(.relative(presentation: .named)), run.status.label]
            .joined(separator: " · ")
    }

    @ViewBuilder private var options: some View {
        Stepper(value: binding(\.batchLimit), in: 1 ... 200, step: kind == .linkChecker ? 10 : 5) {
            LabeledContent("Items per run", value: config.batchLimit.formatted())
        }
        if kind.usesModel {
            Toggle("Allow ChatGPT when it's the AI provider", isOn: binding(\.cloudAllowed))
            Stepper(value: binding(\.dailyCalls), in: 10 ... 2000, step: 10) {
                LabeledContent("Model calls per day", value: config.dailyCalls.formatted())
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<AutomationConfig, Value>)
        -> Binding<Value>
    {
        Binding {
            config[keyPath: path]
        } set: { value in
            var updated = config
            updated[keyPath: path] = value
            model.update(updated)
        }
    }
}

private struct RunRow: View {
    let model: AutomationsModel
    let run: AutomationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: run.status.symbol).foregroundStyle(run.status.color)
                    .accessibilityLabel(run.status.label)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Text(counts).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.canUndo(run) {
                    Button("Undo") { Task { await model.undo(run) } }
                        .buttonStyle(.link).font(.caption)
                        .help(
                            "Put back the summaries this run wrote, where the item hasn't changed since"
                        )
                }
            }
            ForEach(Array(run.report.prefix(8).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if run.report.count > 8 {
                Text("and \(run.report.count - 8) more").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var counts: String {
        var parts = ["\(run.examined) checked"]
        if run.changed > 0 {
            parts.append("\(run.changed) changed")
        }
        if run.proposed > 0 {
            parts.append("\(run.proposed) proposed")
        }
        if run.skipped > 0 {
            parts.append("\(run.skipped) skipped")
        }
        return parts.joined(separator: " · ")
    }
}

private extension AutomationKind {
    /// Each automation's own colour, as Shortcuts gives each automation one.
    var color: Color {
        switch self {
        case .inboxSummarizer: .purple
        case .linkChecker: .orange
        case .crossLinker: .teal
        }
    }
}

extension AutomationRun.Status {
    var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Done"
        case .partial: "Partly done"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }

    var symbol: String {
        switch self {
        case .running: "progress.indicator"
        case .succeeded: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle"
        }
    }

    var color: Color {
        switch self {
        case .succeeded: .green
        case .failed: .orange
        default: .secondary
        }
    }
}
