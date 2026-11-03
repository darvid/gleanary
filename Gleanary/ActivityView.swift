import SwiftUI

/// Committed changes to the library, with captures still being saved or needing you pinned
/// above them, so a source moves from saving to saved without changing pages.
struct ActivityView<Intake: View>: View {
    let store: DocumentStore
    var open: (UUID) -> Void
    var openSource: (SourceCitation) -> Void = { _ in }
    /// Proposals waiting in the automations review queue.
    var pendingReviews = 0
    var reviewChanges: () -> Void = {}
    /// Puts back what an automation run applied; returns what to tell the person, if anything.
    var undoRun: (UUID) async -> String? = { _ in nil }
    /// Captures in progress or needing attention, as list sections; shown while any exist.
    let intake: Intake
    let intakeCount: Int
    @State private var model: ActivityModel
    @State private var choosingDate = false
    @FocusState private var searchFocused: Bool

    init(
        store: DocumentStore,
        open: @escaping (UUID) -> Void,
        openSource: @escaping (SourceCitation) -> Void = { _ in },
        pendingReviews: Int = 0,
        reviewChanges: @escaping () -> Void = {},
        undoRun: @escaping (UUID) async -> String? = { _ in nil },
        intakeCount: Int = 0,
        model: ActivityModel? = nil,
        @ViewBuilder intake: () -> Intake
    ) {
        self.intake = intake()
        self.intakeCount = intakeCount
        self.store = store
        self.open = open
        self.openSource = openSource
        self.pendingReviews = pendingReviews
        self.reviewChanges = reviewChanges
        self.undoRun = undoRun
        _model = State(initialValue: model ?? ActivityModel(store: store))
    }

    var body: some View {
        HSplitView {
            timeline.frame(minWidth: 300, idealWidth: 400, maxWidth: 520, maxHeight: .infinity)
            inspection.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            if let id = NoteLink.id(from: url) {
                open(id); return .handled
            }
            return .systemAction
        })
        .task { await model.observe() }
        .onDisappear { model.markLooked() }
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await model.reload()
        }
        .task(id: model.selection) { await model.inspectSelection() }
        .onChange(of: model.query) { model.selection = nil }
        .focusedSceneValue(\.activitySearch) { searchFocused = true }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Retry") { Task { await model.reload() } }
                }.padding(18)
            }
            if model.days.isEmpty, !showsIntake {
                if model.loading {
                    WorkingProgress("Loading activity…").frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                } else {
                    ContentUnavailableView(
                        model
                            .query == ActivityQuery() ? "Your library’s story starts here" :
                            "No matching activity",
                        systemImage: "clock",
                        description: Text(model.query == ActivityQuery()
                            ? "Create a note, save a source, or connect two ideas. Changes will appear here."
                            : "Try another date, event type, or search.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(selection: $model.selection) {
                    // Content, not a control: it scrolls away with the timeline.
                    if model.query.day == nil, let recap = model.recap {
                        recapView(recap).padding(.vertical, 6)
                            .listRowSeparator(.hidden).selectionDisabled()
                    }
                    if showsIntake {
                        intake
                    }
                    ForEach(model.days) { day in
                        Section {
                            ForEach(day.groups) { group in
                                if group.id == seenGroupID {
                                    seenDivider
                                }
                                ActivityGroupRow(
                                    group: group,
                                    query: model.query,
                                    store: store,
                                    generation: model.generation,
                                    undoRun: undoRun
                                )
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(dayHeading(day.date)).font(.headline).foregroundStyle(.primary)
                                Text(day.summary).font(.caption).foregroundStyle(.secondary)
                                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                            }.padding(.top, 8).padding(.bottom, 5)
                        }
                    }
                    if model.hasMore {
                        Button("Load Older Activity") { Task { await model.loadMore() } }
                            .disabled(model.loading).padding(.vertical, 8)
                    }
                }
                .listStyle(.inset).accessibilityLabel("Daily activity")
                if model.loading {
                    WorkingProgress().padding(6)
                }
            }
            if let since = model.trackingSince {
                Divider()
                Text(
                    "Includes earlier note history. Source, link, and filing tracking began \(since.formatted(date: .abbreviated, time: .omitted))."
                )
                .font(.caption).foregroundStyle(.secondary).padding(12)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Captures belong to the whole timeline, not to a date or search within it.
    private var showsIntake: Bool {
        intakeCount > 0 && model.query.day == nil && model.query.search.isEmpty
    }

    /// The first row from before the last visit, when newer rows sit above it.
    private var seenGroupID: String? {
        guard let lastLooked = model.lastLooked else { return nil }
        let groups = model.days.flatMap(\.groups)
        guard let index = groups.firstIndex(where: { $0.latest.date < lastLooked }), index > 0
        else { return nil }
        return groups[index].id
    }

    private var seenDivider: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text("Before your last visit").font(.caption.weight(.medium)).fixedSize()
            VStack { Divider() }
        }
        .foregroundStyle(.secondary).padding(.vertical, 2)
        .selectionDisabled().accessibilityElement(children: .combine)
    }

    private var recapHeading: String {
        guard let lastLooked = model.lastLooked else { return "This week" }
        guard Date().timeIntervalSince(lastLooked) >= 60 else { return "Since your last visit" }
        return "Since your last visit "
            + lastLooked.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    private func recapView(_ recap: ActivityRecap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recapHeading)
                .font(.callout.weight(.semibold))
            Text(recap.isEmpty ? "Nothing new." : recap.sentence.prefix(1).uppercased()
                + recap.sentence.dropFirst() + ".")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .fadesOnChange(recap.sentence)
            if pendingReviews > 0 {
                Button(
                    pendingReviews == 1 ? "1 change waiting for review"
                        : "\(pendingReviews.formatted()) changes waiting for review",
                    action: reviewChanges
                )
                .buttonStyle(.link).font(.callout)
                .help("Open Automations to review proposed changes")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    /// Two rows: search with what and when, then who. A picked date adds a row to step
    /// through days.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search activity", text: $model.query.search)
                        .textFieldStyle(.plain).focused($searchFocused)
                    if !model.query.search.isEmpty {
                        Button("Clear Search", systemImage: "xmark.circle.fill") {
                            model.query.search = ""
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }.padding(7).frame(maxWidth: .infinity).background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                Menu {
                    Picker("Event type", selection: $model.query.filter) {
                        ForEach(ActivityFilter.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    Label(
                        model.query.filter.rawValue,
                        systemImage: model.query.filter == .all
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize()
                .help("Event type: \(model.query.filter.rawValue)")
                .accessibilityLabel("Event type")
                .accessibilityValue(model.query.filter.rawValue)
                // Its popover has Today and Yesterday, so there's no separate Today button.
                Button("Jump to Date", systemImage: "calendar") { choosingDate = true }
                    .labelStyle(.iconOnly).fixedSize()
                    .help("Show one day’s activity")
                    .popover(isPresented: $choosingDate) {
                        ActivityDateJump(
                            date: model.query.day ?? Date(),
                            show: { date in
                                model.query.day = Calendar.current.startOfDay(for: date)
                                choosingDate = false
                            },
                            cancel: { choosingDate = false }
                        )
                    }
            }
            Picker("Who", selection: $model.query.scope) {
                ForEach(ActivityScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("Who made the change")
            if let day = model.query.day {
                HStack {
                    Button("Previous Day", systemImage: "chevron.left") { moveDay(-1) }
                        .labelStyle(.iconOnly)
                    Text(day.formatted(date: .abbreviated, time: .omitted)).font(.callout)
                    Button("Next Day", systemImage: "chevron.right") { moveDay(1) }
                        .labelStyle(.iconOnly)
                    Spacer(minLength: 4)
                    Button("All Dates") { model.query.day = nil }
                        .help(
                            "Clear the \(day.formatted(date: .abbreviated, time: .omitted)) date filter"
                        )
                }
            }
        }
    }

    @ViewBuilder private var inspection: some View {
        if model.inspecting {
            WorkingProgress("Loading change…")
        } else if let error = model.inspectionError {
            ContentUnavailableView {
                Label("Change unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await model.inspectSelection() } }
            }
        } else if let inspection = model.inspection {
            ActivityInspectionView(
                inspection: inspection,
                store: store,
                open: open,
                openSource: openSource
            )
            .id("\(inspection.event.id)/\(model.generation)")
        } else {
            ContentUnavailableView(
                "Select a change",
                systemImage: "clock.arrow.circlepath",
                description: Text("Read the item or inspect what changed without leaving Activity.")
            )
        }
    }

    private func moveDay(_ amount: Int) {
        guard let day = model.query.day else { return }
        model.query.day = Calendar.current.date(byAdding: .day, value: amount, to: day)
    }

    private func dayHeading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }
}

extension ActivityView where Intake == EmptyView {
    init(
        store: DocumentStore,
        open: @escaping (UUID) -> Void,
        openSource: @escaping (SourceCitation) -> Void = { _ in },
        model: ActivityModel? = nil
    ) {
        self.init(store: store, open: open, openSource: openSource, model: model) { EmptyView() }
    }
}

struct ActivityDateJump: View {
    let show: (Date) -> Void
    let cancel: () -> Void
    @State private var date: Date

    init(date: Date, show: @escaping (Date) -> Void, cancel: @escaping () -> Void) {
        self.show = show
        self.cancel = cancel
        _date = State(initialValue: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Jump to date").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Activity date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden().controlSize(.large)
                    .accessibilityLabel("Activity date")
                HStack(spacing: 8) {
                    Button("Today") { show(Date()) }
                    Button("Yesterday") {
                        if let yesterday = Calendar.current.date(
                            byAdding: .day,
                            value: -1,
                            to: Date()
                        ) {
                            show(yesterday)
                        }
                    }
                }.controlSize(.small)
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Show Day") { show(date) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 280)
    }
}

private struct ActivityGroupRow: View {
    let group: ActivityGroup
    let query: ActivityQuery
    let store: DocumentStore
    let generation: Int
    let undoRun: (UUID) async -> String?
    @State private var expanded = false
    @State private var undoing = false
    @State private var undoMessage: String?
    @State private var events: [ActivityEvent] = []
    @State private var requestToken = UUID()
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        if group.count == 1 {
            ActivityEventRow(event: group.latest, group: group).tag(group.latest.id)
                .contextMenu { undoButton }
        } else {
            // A row like any single event, so grouped and single changes line up under the day.
            Button { expanded.toggle() } label: {
                ActivityEventRow(
                    event: group.latest,
                    group: group,
                    title: group.title,
                    summary: group.isItem ? group.itemSummary
                        : group.context ?? (group.latest.batchLabel ?? group.latest.kind.label)
                        + " · \(group.count.formatted()) changes",
                    expanded: expanded
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { undoButton }
            .accessibilityHint(expanded ? "Hides these changes" : "Shows these changes")
            .task(id: expanded ? generation : -1) {
                guard expanded else { return }
                requestToken = UUID()
                loading = false
                events = []
                await loadMore()
            }
            if expanded {
                Group {
                    ForEach(events) { event in
                        ActivityEventRow(
                            event: event, item: group.isItem ? group.title : nil
                        ).tag(event.id)
                    }
                    if loading {
                        WorkingProgress()
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    if !loading, events.count < group.count {
                        Button(error == nil ? "Show more changes" : "Retry") {
                            Task { await loadMore() }
                        }
                    }
                    undoButton.buttonStyle(.link)
                    if let undoMessage {
                        Text(undoMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder private var undoButton: some View {
        if let runID = group.runID, group.automation?.undoable == true {
            Button("Undo This Run") {
                undoing = true
                Task {
                    undoMessage = await undoRun(runID)
                    undoing = false
                }
            }
            .disabled(undoing)
            .help(
                "Put back what this \(group.actorName.lowercased()) run changed, where the item hasn't changed since"
            )
        }
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        let expected = requestToken
        defer {
            if expected == requestToken {
                loading = false
            }
        }
        do {
            let result = try await store.activityEvents(
                in: group,
                query: query,
                before: events.last?.id
            )
            guard expected == requestToken, !Task.isCancelled else { return }
            events += result
            error = nil
        } catch {
            guard expected == requestToken, !Task.isCancelled else { return }
            self.error = "Could not load these changes."
        }
    }
}

private struct ActivityEventRow: View {
    let event: ActivityEvent
    /// The unit of work this row heads, for who did it and why; nil inside an expanded group.
    var group: ActivityGroup?
    /// Replaces the item's title, for a row standing for several changes.
    var title: String?
    /// Replaces the kind and detail line, for a row standing for several changes.
    var summary: String?
    /// Whether a group's changes are showing; nil for a single change.
    var expanded: Bool?
    /// The item an expanded row's changes are all about, so each change leads with what
    /// happened and names a note only when it's another one, such as a summary.
    var item: String?
    @Environment(\.colorScheme) private var colorScheme

    /// The category named on this line, as "code name", when the line is about filing.
    private var category: String? {
        if summary != nil {
            return group?.isItem == true ? group?.filedUnder : nil
        }
        return [.filed, .unfiled, .primaryHome].contains(event.kind) ? event.detail : nil
    }

    /// The summary line, with the category in its Atlas colour, as in the sidebar.
    private var summaryText: Text {
        let line = summary ??
            (event.kind == .filed ? event.detail.map { "Filed under " + $0 } : nil)
            ?? event.kind.label + (event.detail.map { " · " + $0 } ?? "")
        guard let category, let range = line.range(of: category, options: .backwards),
              let code = category.split(separator: " ").first
        else { return Text(line) }
        let ink = AtlasPalette.ink(
            AtlasHierarchy.hue(for: String(code)),
            dark: colorScheme == .dark
        )
        // A small symbol sits on the baseline; raised to the middle of the digits beside it.
        let dot = Text(Image(systemName: "circle.fill")).font(.system(size: 7))
            .baselineOffset(1.5).foregroundStyle(ink)
        let name = Text(category).foregroundStyle(ink)
        return Text("\(line[..<range.lowerBound])\(dot) \(name)\(line[range.upperBound...])")
    }

    var body: some View {
        if let item {
            change(in: item)
        } else {
            row
        }
    }

    /// One change inside an expanded item: what happened, on one line.
    private func change(in item: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.kind.symbol).foregroundStyle(.secondary)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                summaryText.font(.callout).lineLimit(2)
                if event.displayTitle != item {
                    Text(event.displayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(event.actorLabel) · \(event.date.formatted(.dateTime.hour().minute()))")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }.padding(.vertical, 3).accessibilityElement(children: .combine)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol).foregroundStyle(.secondary)
                .frame(width: 18).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title ?? event.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                    if let expanded {
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.snappy(duration: 0.15), value: expanded)
                            .accessibilityHidden(true)
                    }
                }
                summaryText.font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let context = group?.context, context != summary {
                    Text(context).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    if let group {
                        Label(
                            group.actorName,
                            systemImage: group.automation?.symbol
                                ?? (group.byYou ? "person" : "sparkles")
                        )
                    } else {
                        Text(event.actorLabel)
                    }
                    Spacer()
                    Text(event.date, format: .dateTime.hour().minute())
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 7).accessibilityElement(children: .combine)
    }
}

private struct ActivityInspectionView: View {
    let inspection: ActivityInspection
    let store: DocumentStore
    let open: (UUID) -> Void
    let openSource: (SourceCitation) -> Void
    @State private var changes = true
    @State private var preview = DocumentPreviewModel()

    private var event: ActivityEvent {
        inspection.event
    }

    private var canCompare: Bool {
        inspection.before != nil && inspection.after != nil
    }

    @ViewBuilder private var comparisonPicker: some View {
        if canCompare {
            Picker("Inspect", selection: $changes) {
                Text("Changes").tag(true)
                Text("Current item").tag(false)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var openButton: some View {
        Button("Open in Library") {
            if let id = inspection.current?.id {
                open(id)
            }
        }.fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label(event.kind.label, systemImage: event.kind.symbol).font(.headline)
                Text(event.displayTitle).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(
                    "\(event.actorLabel) · \(event.date.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.callout).foregroundStyle(.secondary)
                if let detail = event.detail {
                    Text(detail).font(.callout).textSelection(.enabled)
                }
                if let current = inspection.current {
                    AddToChatButton(target: .note(current.id))
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            comparisonPicker
                            Spacer()
                            openButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            comparisonPicker
                            openButton
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            if canCompare, changes {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let previous = inspection.previousTitle, previous != event.title {
                            Text("Previous title: \(previous)").font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if inspection.diffIsBounded {
                            TextDiffView(
                                before: inspection.before ?? "",
                                after: inspection.after ?? ""
                            )
                        } else {
                            Text(
                                "This change is too large for an inline comparison. Open the current item to read it."
                            )
                            .foregroundStyle(.secondary)
                        }
                    }.padding(24).frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if inspection.current != nil {
                DocumentPreview(
                    model: preview,
                    openSource: openSource,
                    showsLibraryDetails: true,
                    openDocument: open,
                    showsSummaryActions: false
                )
            } else if let text = inspection.after, event.title != nil {
                ScrollView {
                    MarkdownPreview(markdown: text).padding(24)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Item permanently deleted", systemImage: "trash",
                    description: Text(
                        "Only the event type and time remain. Its title and content are no longer available."
                    )
                )
            }
        }
        .task {
            preview.selectedID = inspection.current?.id
            await preview.load(from: store)
        }
    }
}

private struct ActivitySearchKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var activitySearch: (() -> Void)? {
        get { self[ActivitySearchKey.self] }
        set { self[ActivitySearchKey.self] = newValue }
    }
}
