import SwiftUI

/// The built-in automations as a list beside the selected one's settings, review and history,
/// laid out like the library.
struct AutomationsView: View {
    let model: AutomationsModel
    /// Shows an item mentioned in a run.
    let open: (UUID) -> Void
    @State private var selected: AutomationKind? = AutomationKind.allCases.first
    @State private var reviewing: AutomationKind?

    @State private var filter = AutomationFilter.all
    var body: some View {
        VStack(spacing: 0) {
            PageBar {
                PageTabs(
                    label: "Show",
                    items: AutomationFilter.allCases.map { ($0, $0.title) },
                    selection: $filter
                )
            } accessory: {
                if let nextRun {
                    Text(nextRun)
                        .font(.caption).foregroundStyle(.secondary).padding(.trailing, 6)
                }
            }
            columns
        }
    }

    /// An automation that has never run is due at the distant past, so it reads as due, not as
    /// a date.
    private var nextRun: String? {
        guard let next = AutomationKind.allCases.compactMap({ model.config($0).nextRunAt }).min()
        else { return nil }
        return next <= .now ? "Due now"
            : "Next run \(next.formatted(.relative(presentation: .numeric)))"
    }

    private var shown: [AutomationKind] {
        AutomationKind.allCases.filter { kind in
            switch filter {
            case .all: true
            case .toReview: !(model.pending[kind] ?? []).isEmpty
            case .on: model.config(kind).enabled
            }
        }
    }

    private var columns: some View {
        ListDetailColumns {
            list
        } detail: {
            if let selected {
                AutomationDetail(
                    model: model,
                    config: model.config(selected),
                    review: { reviewing = selected },
                    open: open
                )
                .id(selected)
            } else {
                ContentUnavailableView(
                    "Select an automation",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("Choose one to see its schedule and history.")
                )
            }
        }
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

    private var list: some View {
        List(selection: $selected) {
            ForEach(shown) { kind in
                AutomationListRow(model: model, config: model.config(kind)).tag(kind)
            }
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
        .accessibilityLabel("Automations")
    }
}

private enum AutomationFilter: CaseIterable, Hashable {
    case all, toReview, on

    var title: String {
        switch self {
        case .all: "All"
        case .toReview: "To review"
        case .on: "On"
        }
    }
}

/// One automation in the list: what it is, whether it's on, and how it's doing at a glance.
private struct AutomationListRow: View {
    let model: AutomationsModel
    let config: AutomationConfig

    private var kind: AutomationKind {
        config.kind
    }

    var body: some View {
        HStack(spacing: 10) {
            AutomationTile(kind: kind, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .fadesOnChange(status)
            }
            Spacer(minLength: 8)
            indicator
            Toggle(kind.title, isOn: Binding {
                config.enabled
            } set: { enabled in
                var updated = config
                updated.enabled = enabled
                model.update(updated)
            })
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.vertical, 4)
    }

    /// Running, failed, or waiting on you; the sidebar shows the same marks.
    @ViewBuilder private var indicator: some View {
        let waiting = model.pending[kind]?.count ?? 0
        if model.running == kind {
            WorkingProgress().accessibilityLabel("Running")
        } else if model.failed.contains(kind) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                .help("The last run failed")
                .accessibilityLabel("Last run failed")
        }
        if waiting > 0 {
            Text(waiting.formatted())
                .font(.caption.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.primary.opacity(0.1), in: Capsule())
                .countsOnChange(waiting)
                .help(waiting == 1 ? "1 proposal to review" : "\(waiting) proposals to review")
                .accessibilityLabel(waiting == 1 ? "1 proposal to review"
                    : "\(waiting) proposals to review")
        }
    }

    private var status: String {
        if model.running == kind {
            return model.progress ?? "Running…"
        }
        var parts = [config.enabled ? AutomationKind.intervalLabel(config.interval) : "Off"]
        if let run = model.runs[kind]?.first {
            parts.append(run.status == .failed
                ? "failed \(run.startedAt.formatted(.relative(presentation: .named)))"
                : "ran \(run.startedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ", ")
    }
}

private struct AutomationTile: View {
    let kind: AutomationKind
    let size: CGFloat

    var body: some View {
        Image(systemName: kind.symbol)
            .font(size > 32 ? .title2 : .body).foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// The selected automation's settings, what's waiting for review, and its runs.
private struct AutomationDetail: View {
    let model: AutomationsModel
    let config: AutomationConfig
    let review: () -> Void
    let open: (UUID) -> Void

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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = model.error {
                    AutomationCard {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let pending = model.pending[kind], !pending.isEmpty {
                    AutomationCard {
                        AutomationRow {
                            Label(
                                "\(AgentChangesCard.breakdown(pending)) waiting",
                                systemImage: "checklist"
                            )
                        } content: {
                            Button("Review \(pending.count.formatted())…", action: review)
                                .buttonStyle(.borderedProminent).tint(.primary).controlSize(.small)
                        }
                    }
                }
                AutomationCard {
                    AutomationRow("Schedule") {
                        if kind.intervals.count == 1 {
                            Text(AutomationKind.intervalLabel(config.interval))
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Schedule", selection: binding(\.interval)) {
                                ForEach(kind.intervals, id: \.self) {
                                    Text(AutomationKind.intervalLabel($0)).tag($0)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    if kind.rechecks {
                        Divider()
                        AutomationRow("Recheck items") {
                            Picker("Recheck items", selection: binding(\.recheck)) {
                                ForEach(AutomationKind.recheckChoices, id: \.self) {
                                    Text(AutomationKind.recheckLabel($0)).tag($0)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        .help(kind.recheckHelp)
                    }
                    Divider()
                    AutomationRow("Last run") { lastRunStatus }
                    if config.enabled, !running, let next = config.nextRunAt {
                        Divider()
                        AutomationRow("Next run") {
                            Text(next > Date() ? next
                                .formatted(.relative(presentation: .named)) : "Shortly")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    AutomationRow("Due now") {
                        Text(dueNow).foregroundStyle(.secondary).fadesOnChange(dueNow)
                    }
                    .help(kind.dueHelp)
                    Divider()
                    AutomationRow("Allowed to") {
                        Text(policy).foregroundStyle(.secondary).fadesOnChange(policy)
                    }
                }
                section("Options") { AutomationCard { options } }
                section("History") { AutomationCard { history } }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AutomationTile(kind: kind, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.title2.weight(.semibold))
                Text(kind.summary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Runs as the \(kind.role.title)").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Toggle(kind.title, isOn: binding(\.enabled)).labelsHidden().toggleStyle(.switch)
        }
    }

    private func section(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.leading, 4)
            content()
        }
    }

    private var lastRunStatus: some View {
        HStack(spacing: 10) {
            if running {
                Label {
                    StageProgressText(model.progress ?? "Running…").lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    ChatWorkingIndicator(color: .secondary)
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
        return "\(run.status.label) \(run.startedAt.formatted(.relative(presentation: .named)))"
    }

    @ViewBuilder private var options: some View {
        AutomationRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .weeklyDigest ? "Items listed at most" : "Items per run")
                Text(batchNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .fadesOnChange(batchNote)
            }
        } content: {
            Stepper(value: binding(\.batchLimit), in: kind.batchRange, step: kind.batchStep) {
                Text(config.batchLimit.formatted()).monospacedDigit()
            }
        }
        if kind == .linkChecker {
            Divider()
            AutomationRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dead links")
                    Text(
                        "After \(AutomationEngine.archiveFailures) failed checks over a week. Never for links that need a login."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } content: {
                Picker("Dead links", selection: binding(\.archivesDeadLinks)) {
                    Text("Ask first").tag(false)
                    Text("Archive automatically").tag(true)
                }
                .labelsHidden().fixedSize()
            }
            .help(
                "Archived items keep their saved copy and show under Archive; Undo or Unarchive puts them back."
            )
        }
        if kind == .weeklyDigest {
            Divider()
            AutomationRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write it up with the Writer")
                    Text(writerNote).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } content: {
                Toggle("Write it up with the Writer", isOn: binding(\.usesWriter))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        if kind.usesModel || config.usesWriter {
            Divider()
            AutomationRow("Allow ChatGPT when it's the AI provider") {
                Toggle("Allow ChatGPT", isOn: binding(\.cloudAllowed))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider()
            AutomationRow("Model calls per day") {
                Stepper(value: binding(\.dailyCalls), in: 10 ... 2000, step: 10) {
                    Text(config.dailyCalls.formatted()).monospacedDigit()
                }
            }
        }
    }

    private var writerNote: String {
        "Groups the week by topic in your default writing style, citing each item. More than \(WriterLimits.localScope) items need ChatGPT, and the newest \(WriterLimits.maximumScope) are written up; when it can't run, the digest lists the items as usual."
    }

    private var policy: String {
        kind == .linkChecker && config.archivesDeadLinks
            ? "Archives dead links and proposes link updates; you can undo a run" : kind.policy
    }

    /// How much is waiting, and how many runs at the current batch size will get through it.
    private var dueNow: String {
        guard let count = model.backlog[kind] else { return "…" }
        guard count > 0 else { return "All caught up" }
        let batch = model.plannedBatch(kind)
        let runs = (count + batch - 1) / batch
        let items = count == 1 ? "1 item" : "\(count.formatted()) items"
        return runs == 1 ? "\(items), all in the next run"
            : "\(items), about \(runs.formatted()) runs of \(batch.formatted())"
    }

    /// Says when runs take more than the setting, and why.
    private var batchNote: String {
        switch kind {
        case .summaryBackfill: return "Also limited by model calls per day."
        case .bookmarkFetcher:
            return "One page at a time. Summaries count toward model calls per day."
        case .captureRetry: return "Each is tried at most three times."
        case .weeklyDigest: return "The newest are listed when more were saved."
        case .sourceExplorer:
            return "One page at a time, within Source acquisition's daily budget."
        case .linkChecker, .crossLinker, .unfiledFiler: break
        }
        let planned = model.plannedBatch(kind)
        let interval = AutomationKind.recheckLabel(config.recheck).lowercased()
        return planned > config.batchLimit
            ? "Taking \(planned.formatted()) for now, so every item is checked \(interval)."
            : "Takes more when needed, so every item is checked \(interval)."
    }

    @ViewBuilder private var history: some View {
        let page = model.historyPages[kind] ?? AutomationRunPage(index: 0, total: 0, runs: [])
        let runs = page.runs
        if runs.isEmpty {
            Text("No runs yet.").foregroundStyle(.secondary)
        } else {
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                if index > 0 {
                    Divider()
                }
                RunRow(
                    model: model, run: run, expandedAtFirst: index == 0 && page.index == 0,
                    review: review, open: open
                )
            }
            Divider()
            HStack {
                Text(
                    "\(page.index * AutomationRunPage.size + 1)–\(page.index * AutomationRunPage.size + runs.count) of \(page.total) runs"
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Newer") {
                    Task { await model.showHistoryPage(page.index - 1, of: kind) }
                }.disabled(!page.hasNewer || model.loadingHistory)
                Button("Older") {
                    Task { await model.showHistoryPage(page.index + 1, of: kind) }
                }.disabled(!page.hasOlder || model.loadingHistory)
            }.buttonStyle(.bordered).controlSize(.small)
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

/// A rounded panel on the window, like a grouped form's section.
private struct AutomationCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Divider() }
    }
}

/// A label on the leading edge and its value or control on the trailing edge.
private struct AutomationRow<Label: View, Content: View>: View {
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            label
            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: 22)
    }
}

extension AutomationRow where Label == Text {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        label = Text(title)
        self.content = content()
    }
}

/// One run: a line saying what it did, opening to what happened to each item, grouped by
/// outcome.
private struct RunRow: View {
    let model: AutomationsModel
    let run: AutomationRun
    let expandedAtFirst: Bool
    let review: () -> Void
    let open: (UUID) -> Void
    @State private var expanded: Bool?

    private var isExpanded: Bool {
        expanded ?? expandedAtFirst
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: run.status.symbol).foregroundStyle(run.status.color)
                        .accessibilityLabel(run.status.label)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.headline).font(.callout.weight(.medium))
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides this run's details" : "Shows this run's details")
            if isExpanded {
                details.padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [run.startedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append("\(run.examined.formatted()) looked at")
        if run.calls > 0 {
            parts.append(run.calls == 1 ? "1 model call" : "\(run.calls) model calls")
        }
        return parts.joined(separator: ", ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(run.report.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(AutomationEntry.Outcome.allCases, id: \.self) { outcome in
                let entries = run.entries.filter { $0.outcome == outcome }
                if !entries.isEmpty {
                    OutcomeGroup(
                        outcome: outcome,
                        entries: entries,
                        trailing: trailing(for: outcome),
                        gone: model.goneItems,
                        open: open
                    )
                }
            }
            if run.fine > 0 {
                Label(run.fineLine, systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Review for proposals still waiting; Undo for what this run wrote.
    @ViewBuilder private func trailing(for outcome: AutomationEntry.Outcome) -> some View {
        if outcome == .proposed, model.pending[run.kind]?.contains(where: { $0.taskID == run.id })
            == true
        {
            Button("Review…", action: review).controlSize(.small)
        } else if outcome == .changed, model.canUndo(run) {
            Button("Undo") { Task { await model.undo(run) } }
                .controlSize(.small)
                .help(run.kind.undoHelp)
        } else if outcome == .changed, model.undoneRuns.contains(run.id) {
            Text("Undone").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The items that share one outcome, a few at a time.
private struct OutcomeGroup<Trailing: View>: View {
    let outcome: AutomationEntry.Outcome
    let entries: [AutomationEntry]
    let trailing: Trailing
    /// Items no longer in the library: struck through, with nothing to open.
    let gone: Set<UUID>
    let open: (UUID) -> Void
    @State private var showsAll = false

    private static var shown: Int {
        5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label {
                    HStack(spacing: 6) {
                        Text(outcome.title)
                        Text(entries.count.formatted()).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: outcome.symbol).foregroundStyle(outcome.color)
                }
                .font(.callout.weight(.semibold))
                Spacer()
                trailing
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 1) {
                    if let id = entry.itemID, gone.contains(id) {
                        Text(entry.title).strikethrough().foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("No longer in your library")
                            .accessibilityLabel("\(entry.title), no longer in your library")
                    } else if let id = entry.itemID {
                        Button { open(id) } label: {
                            Text(entry.title).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.link).lineLimit(2)
                        .help("Show this item")
                    } else {
                        Text(entry.title).lineLimit(1)
                    }
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                }
                .padding(.leading, 22)
            }
            if entries.count > Self.shown {
                Button(showsAll ? "Show fewer" : "Show all \(entries.count.formatted())") {
                    showsAll.toggle()
                }
                .buttonStyle(.link).font(.caption).padding(.leading, 22)
            }
        }
    }

    private var visible: ArraySlice<AutomationEntry> {
        showsAll ? entries[...] : entries.prefix(Self.shown)
    }
}

extension AutomationRun {
    /// Whether the run changed anything, then what it found that needs you.
    /// What the run itself did first (applied, proposed, or neither), then what it found.
    var headline: String {
        var parts: [String] = []
        if status == .failed || status == .cancelled {
            parts.append(status == .failed ? "Failed" : "Stopped")
        }
        if changed > 0 {
            parts.append(changedLine)
        }
        if proposed > 0 {
            parts.append("Proposed \(proposed) change\(proposed == 1 ? "" : "s") for review")
        }
        if parts.isEmpty, status != .running {
            parts.append("Nothing to change")
        }
        for outcome in AutomationEntry.Outcome.allCases
            where outcome != .changed && outcome != .proposed
        {
            let number = entries.count { $0.outcome == outcome }
            if number > 0 {
                parts.append("\(number) \(outcome.title.lowercased())")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// What the run itself changed, in the automation's own words.
    private var changedLine: String {
        switch kind {
        case .summaryBackfill: "Wrote \(changed) summar\(changed == 1 ? "y" : "ies")"
        case .bookmarkFetcher: "Fetched \(changed) page\(changed == 1 ? "" : "s")"
        case .captureRetry: "Saved \(changed) capture\(changed == 1 ? "" : "s")"
        case .weeklyDigest: "Wrote a digest of \(AutomationEngine.itemCount(examined))"
        case .linkChecker: "Archived \(changed) dead link\(changed == 1 ? "" : "s")"
        case .sourceExplorer: "Saved \(changed) source\(changed == 1 ? "" : "s")"
        case .crossLinker, .unfiledFiler:
            "Changed \(changed) item\(changed == 1 ? "" : "s")"
        }
    }

    var fineLine: String {
        switch kind {
        case .linkChecker: fine == 1 ? "1 link still works" : "\(fine) links still work"
        case .crossLinker: fine == 1 ? "1 item had nothing to link" : "\(fine) items had nothing to link"
        case .unfiledFiler:
            fine == 1 ? "1 item had no new home to suggest" : "\(fine) items had no new home to suggest"
        case .summaryBackfill, .bookmarkFetcher, .captureRetry, .weeklyDigest, .sourceExplorer:
            "\(fine) needed nothing"
        }
    }
}

extension AutomationEntry.Outcome {
    var title: String {
        switch self {
        case .changed: "Changed"
        case .proposed: "Proposed"
        case .moved: "Moved"
        case .unreachable: "Unreachable"
        case .restricted: "Need a login"
        case .retry: "Checking again"
        case .skipped: "Skipped"
        }
    }

    var symbol: String {
        switch self {
        case .changed: "checkmark.circle.fill"
        case .proposed: "checklist"
        case .moved: "arrow.turn.up.right"
        case .unreachable: "exclamationmark.triangle"
        case .restricted: "lock"
        case .retry: "arrow.clockwise"
        case .skipped: "forward"
        }
    }

    var color: Color {
        switch self {
        case .changed: .green
        case .proposed: .accentColor
        case .unreachable: .orange
        default: .secondary
        }
    }
}

private extension AutomationKind {
    /// What Recheck items means for this automation.
    var recheckHelp: String {
        switch self {
        case .linkChecker:
            "How long a link that works waits before it's checked again. Failing links are retried the next day either way."
        case .unfiledFiler:
            "How long an item nothing fitted waits before it's looked at again, in case your categories changed."
        default: "How long an item waits before it's looked at for links again."
        }
    }

    /// What Due now counts.
    var dueHelp: String {
        switch self {
        case .bookmarkFetcher: "Imported bookmarks never fetched, newest first."
        case .captureRetry:
            "Failed captures whose next try is due: an hour, a day, then a week after each failure."
        case .weeklyDigest: "Items saved since the last digest, at most a week back."
        case .sourceExplorer: "Links found in your sources that aren't saved or ruled out yet."
        case .summaryBackfill, .linkChecker, .crossLinker, .unfiledFiler:
            "New items haven't been checked yet, so they always come first; then the ones checked longest ago."
        }
    }

    var undoHelp: String {
        switch self {
        case .bookmarkFetcher:
            "Put back the bookmarks this run fetched, where the item hasn't changed since"
        case .weeklyDigest: "Remove this digest, unless you've edited it"
        case .linkChecker: "Unarchive the items this run archived"
        default: "Put back the summaries this run wrote, where the item hasn't changed since"
        }
    }

    /// Each automation's own colour, as Shortcuts gives each automation one.
    var color: Color {
        switch self {
        case .summaryBackfill: .purple
        case .bookmarkFetcher: .blue
        case .linkChecker: .orange
        case .crossLinker: .teal
        case .unfiledFiler: .brown
        case .captureRetry: .pink
        case .weeklyDigest: .indigo
        case .sourceExplorer: .green
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
