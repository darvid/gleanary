import SwiftUI

struct ActivityView: View {
    let store: DocumentStore
    var open: (UUID) -> Void
    var openSource: (SourceCitation) -> Void = { _ in }
    @State private var model: ActivityModel
    @State private var choosingDate = false
    @FocusState private var searchFocused: Bool

    init(
        store: DocumentStore,
        open: @escaping (UUID) -> Void,
        openSource: @escaping (SourceCitation) -> Void = { _ in },
        model: ActivityModel? = nil
    ) {
        self.store = store
        self.open = open
        self.openSource = openSource
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
            controls.padding(18)
            Divider()
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("Retry") { Task { await model.reload() } }
                }.padding(18)
            }
            if model.days.isEmpty {
                if model.loading {
                    ProgressView("Loading activity…").frame(
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
                    ForEach(model.days) { day in
                        Section {
                            ForEach(day.groups) { group in
                                ActivityGroupRow(
                                    group: group,
                                    query: model.query,
                                    store: store,
                                    generation: model.generation
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
                        Button("Load older activity") { Task { await model.loadMore() } }
                            .disabled(model.loading).padding(.vertical, 8)
                    }
                }
                .listStyle(.inset).accessibilityLabel("Daily activity")
                if model.loading {
                    ProgressView().controlSize(.small).padding(6)
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search activity", text: $model.query.search)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !model.query.search.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") {
                        model.query.search = ""
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }.padding(8).background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 7)
            )
            HStack {
                Picker("Event type", selection: $model.query.filter) {
                    ForEach(ActivityFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().accessibilityLabel("Event type")
                Spacer(minLength: 4)
                Button("Today") { model.query.day = Calendar.current.startOfDay(for: Date()) }
                    .help("Show today’s activity")
                Button("Jump to date", systemImage: "calendar") { choosingDate = true }
                    .labelStyle(.iconOnly)
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
            if let day = model.query.day {
                HStack {
                    Button("Previous day", systemImage: "chevron.left") { moveDay(-1) }
                        .labelStyle(.iconOnly)
                    Text(day.formatted(date: .abbreviated, time: .omitted)).font(.callout)
                    Button("Next day", systemImage: "chevron.right") { moveDay(1) }
                        .labelStyle(.iconOnly)
                    Spacer(minLength: 4)
                    Button("All dates") { model.query.day = nil }
                        .help(
                            "Clear the \(day.formatted(date: .abbreviated, time: .omitted)) date filter"
                        )
                }
            }
        }
    }

    @ViewBuilder private var inspection: some View {
        if model.inspecting {
            ProgressView("Loading change…")
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
                Button("Show day") { show(date) }
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
    @State private var expanded = false
    @State private var events: [ActivityEvent] = []
    @State private var requestToken = UUID()
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        if group.count == 1 {
            ActivityEventRow(event: group.latest).tag(group.latest.id)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(events) { ActivityEventRow(event: $0).tag($0.id) }
                if loading {
                    ProgressView().controlSize(.small)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if !loading, events.count < group.count {
                    Button(error == nil ? "Show more changes" : "Retry") {
                        Task { await loadMore() }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.label).font(.body.weight(.medium)).lineLimit(2)
                    Text("\(group.count.formatted()) changes · \(group.latest.actorLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }
            .task(id: expanded ? generation : -1) {
                guard expanded else { return }
                requestToken = UUID()
                loading = false
                events = []
                await loadMore()
            }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol).foregroundStyle(.secondary)
                .frame(width: 18).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                Text(event.kind.label + (event.detail.map { " · " + $0 } ?? ""))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Text(event.actorLabel)
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
