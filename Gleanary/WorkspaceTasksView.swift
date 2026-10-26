import SwiftUI

struct WorkspaceTasksView: View {
    @Bindable var workspace: NoteWorkspaceModel
    var openNote: (UUID) -> Void = { _ in }
    var choose: ((WorkspaceTask) -> Void)?
    var selection: Binding<WorkspaceTaskView>?
    @Environment(\.dismiss) private var dismiss
    @State private var localView = WorkspaceTaskView.inbox
    @State private var query = ""
    @State private var tasks: [WorkspaceTask] = []
    @State private var names: [UUID: String] = [:]
    @State private var more = false
    @State private var loading = false
    @State private var loadToken = UUID()
    @State private var error: String?
    @State private var editing: WorkspaceTask?
    @State private var today = WorkspaceDay(date: .now)

    private var view: WorkspaceTaskView {
        selection?.wrappedValue ?? localView
    }

    private var viewBinding: Binding<WorkspaceTaskView> {
        selection ?? $localView
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if choose != nil {
                HStack {
                    Text("Link an existing task").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Cancel") { dismiss() }
                }
            }
            Picker("Task view", selection: viewBinding) {
                ForEach(WorkspaceTaskView.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            TextField("Search tasks", text: $query).textFieldStyle(.roundedBorder)
            if let message = error ?? workspace
                .error
            {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            List {
                if choose == nil {
                    WorkspaceTaskEntryRow(
                        workspace: workspace,
                        view: view,
                        today: today
                    ) { destination in
                        query = ""
                        viewBinding.wrappedValue = destination
                    }
                    .id("task-quick-entry")
                    if tasks.isEmpty, !query.isEmpty, !loading {
                        Text("No matching tasks.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(tasks) { task in
                    if let choose {
                        Button { choose(task); dismiss() } label: {
                            Text(task.title).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } else {
                        WorkspaceTaskRow(
                            task: task,
                            workspace: workspace,
                            names: names,
                            openNote: openNote
                        ) { editing = task }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if loading,
                   tasks
                   .isEmpty
                {
                    HStack { ChatWorkingIndicator(color: .secondary); Text("Loading tasks…") }
                        .allowsHitTesting(false)
                } else if tasks.isEmpty, choose != nil {
                    ContentUnavailableView(
                        "No tasks here",
                        systemImage: "checklist",
                        description: Text(view == .inbox ?
                            "Unplanned tasks without a due date appear in Inbox. Local checklists stay in their notes until you track them." :
                            "Change the view or search, or add a task.")
                    )
                }
            }
            if more {
                Button("Load more tasks") { Task { await load(reset: false) } }.disabled(loading)
            }
        }
        .padding(24).frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(view.rawValue)/\(query)/\(today.rawValue)/\(workspace.generation)") {
            await load(reset: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            today = WorkspaceDay(date: .now)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = WorkspaceDay(date: .now)
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification))
        { _ in
            today = WorkspaceDay(date: .now)
        }
        .sheet(item: $editing) { WorkspaceTaskEditor(workspace: workspace, task: $0) }
        .onAppear {
            if choose != nil {
                localView = .all
            }
        }
    }

    private func load(reset: Bool) async {
        guard reset || !loading else { return }
        let token = UUID()
        loadToken = token
        loading = true
        error = nil
        if reset {
            tasks = []; names = [:]; more = false
        }
        defer {
            if loadToken == token {
                loading = false
            }
        }
        do {
            let page = try await workspace.store.workspaceTasks(
                view: view,
                query: query,
                today: today,
                offset: reset ? 0 : tasks.count
            )
            try Task.checkCancellation()
            guard loadToken == token else { return }
            if reset {
                tasks = []
            }
            tasks += page.tasks
            more = page.hasMore
            let ids = tasks.flatMap { [$0.originID, $0.projectID].compactMap(\.self) }
            let loaded = try await workspace.store.workspaceLinkNames(Array(Set(ids)))
            guard loadToken == token else { return }
            names = loaded
        } catch is CancellationError {
        } catch {
            if loadToken ==
                token
            {
                self.error = "Could not load tasks. Change the view to retry."
            }
        }
    }
}

struct WorkspaceTaskEntryRow: View {
    let workspace: NoteWorkspaceModel
    let view: WorkspaceTaskView
    let today: WorkspaceDay
    var saved: (WorkspaceTaskView) -> Void
    @State private var entry = WorkspaceTaskEntryModel()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle")
                .font(.title3).frame(width: 24, height: 24)
                .foregroundStyle(focused ? .secondary : .tertiary)
                .accessibilityHidden(true)
                .onTapGesture { focused = true }
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    view == .today ? "Add a task for today…" : "Add a task…",
                    text: $entry.title
                )
                .textFieldStyle(.plain).font(.body)
                .opacity(entry.title.isEmpty ? 0.7 : 1)
                .frame(minHeight: 24)
                .focused($focused)
                .accessibilityLabel("New task title")
                .accessibilityIdentifier("task-quick-entry")
                .help("Press Return to add this task")
                .onSubmit {
                    Task {
                        if let destination = await entry.submit(
                            to: workspace,
                            view: view,
                            today: today
                        ) {
                            saved(destination)
                            focused = true
                        }
                    }
                }
                .onExitCommand { entry.title = ""; focused = false }
                if view == .upcoming || view == .completed {
                    Text("New tasks are added to Inbox.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct WorkspaceTaskRow: View {
    let task: WorkspaceTask
    @Bindable var workspace: NoteWorkspaceModel
    var names: [UUID: String] = [:]
    var openNote: (UUID) -> Void = { _ in }
    var removePlacement: (() -> Void)?
    var edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                var next = task
                next.status = task.status == .open ? .completed : .open
                update(next)
            } label: {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : task
                    .status == .canceled ? "xmark.circle" : "circle")
                    .font(.title3).frame(width: 24, height: 24)
            }.buttonStyle(.plain).disabled(workspace.busy)
                .accessibilityLabel(task
                    .status == .open ? "Complete \(task.title)" : "Reopen \(task.title)")
            VStack(alignment: .leading, spacing: 6) {
                Button(action: edit) {
                    Text(task.title).strikethrough(task.status != .open)
                        .multilineTextAlignment(.leading).frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }.buttonStyle(.plain)
                if let planned = task
                    .planned
                {
                    Text("Planned: \(planned.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                if let due = task.due {
                    Text(
                        "\(due < WorkspaceDay(date: .now) && task.status == .open ? "Overdue" : "Due"): \(due.rawValue)"
                    )
                    .font(.caption)
                    .foregroundStyle(due < WorkspaceDay(date: .now) && task
                        .status == .open ? Color.red : .secondary)
                }
                if task
                    .status ==
                    .canceled
                {
                    Text("Canceled").font(.caption).foregroundStyle(.secondary)
                }
                links
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Edit task…", action: edit)
            if let removePlacement {
                Button("Remove from this note…", role: .destructive, action: removePlacement)
            }
            Button("Plan for today") {
                var next = task; next.planned = WorkspaceDay(date: .now); update(next)
            }
            if task.status == .open {
                Button("Cancel task") { var next = task; next.status = .canceled; update(next) }
            }
        }
    }

    @ViewBuilder private var links: some View {
        if let id = task.projectID, let name = names[id] {
            Button("Project: " + name) { openNote(id) }.buttonStyle(.link).font(.caption)
        }
        if let id = task.originID, let name = names[id] {
            Button("From: " + name) { openNote(id) }.buttonStyle(.link).font(.caption)
        }
    }

    private func update(_ task: WorkspaceTask) {
        Task { await workspace.change { _ = try await workspace.store.saveWorkspaceTask(task) } }
    }
}

struct WorkspaceTaskEditor: View {
    @Bindable var workspace: NoteWorkspaceModel
    @State var task: WorkspaceTask
    var placement: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var choosingProject = false
    @State private var choosingOrigin = false
    @State private var names: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(task.version == 0 ? "New task" : "Edit task").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await workspace.change({
                            _ = try await workspace.store.saveWorkspaceTask(
                                task,
                                placingIn: task.version == 0 ? placement ?? task.originID : nil
                            )
                        }) {
                            dismiss()
                        }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Task title", text: $task.title).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Task title")
            Picker("Status", selection: $task.status) {
                ForEach(WorkspaceTask.Status.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
            WorkspaceDateField(title: "Plan for", day: $task.planned)
            WorkspaceDateField(title: "Due", day: $task.due)
            Text("Planning a day does not create a deadline or a reminder.").font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Project: " +
                    (task.projectID
                        .flatMap { names[$0] } ?? (task.projectID == nil ? "None" : "Unavailable")))
                    .lineLimit(2)
                Spacer()
                Button("Choose…") { choosingProject = true }.accessibilityLabel("Choose project")
                if task.projectID != nil {
                    Button("Clear") { task.projectID = nil }
                }
            }
            HStack {
                Text("Origin: " +
                    (task.originID
                        .flatMap { names[$0] } ?? (task.originID == nil ? "None" : "Unavailable")))
                    .lineLimit(2)
                Spacer()
                if task.version == 0, placement == nil {
                    Button("Choose…") { choosingOrigin = true }
                        .accessibilityLabel("Choose origin note")
                    if task.originID != nil {
                        Button("Clear") { task.originID = nil }
                    }
                }
            }
            if let error = workspace
                .error
            {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24).frame(minWidth: 440, idealWidth: 560)
        .disabled(workspace.busy)
        .onAppear { workspace.error = nil }
        .task(id: [task.projectID, task.originID]) {
            names = await (try? workspace.store
                .workspaceLinkNames([task.projectID, task.originID].compactMap(\.self))) ?? [:]
        }
        .sheet(isPresented: $choosingProject) {
            WorkspaceNotePicker(store: workspace.store, type: .project) {
                task.projectID = $0.id; names[$0.id] = $0.name
            }
        }
        .sheet(isPresented: $choosingOrigin) {
            WorkspaceNotePicker(store: workspace.store) {
                task.originID = $0.id; names[$0.id] = $0.name
            }
        }
    }
}

private struct WorkspaceDateField: View {
    let title: String
    @Binding var day: WorkspaceDay?
    var body: some View {
        HStack {
            Toggle(
                title,
                isOn: Binding(
                    get: { day != nil },
                    set: { day = $0 ? WorkspaceDay(date: .now) : nil }
                )
            )
            .toggleStyle(.checkbox)
            if day != nil {
                DatePicker(
                    title,
                    selection: Binding(
                        get: { day?.date ?? .now },
                        set: { day = WorkspaceDay(date: $0) }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden().accessibilityLabel(title + " date")
            }
            Spacer()
        }
    }
}
