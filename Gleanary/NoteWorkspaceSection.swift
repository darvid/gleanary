import SwiftUI

/// The reading pane uses the same task records as Tasks, never a second editable copy.
struct NoteWorkspaceSection: View {
    let document: MarkdownDocument
    @Bindable var workspace: NoteWorkspaceModel
    var openNote: (UUID) -> Void
    @State private var profile = NoteProfile()
    @State private var tasks: [WorkspaceTask] = []
    @State private var names: [UUID: String] = [:]
    @State private var backlinks: [WorkspaceNoteLink] = []
    @State private var local: [MarkdownChecklistItem] = []
    @State private var expanded = false
    @State private var loaded = false
    @State private var more = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var editingProperties = false
    @State private var editingTask: WorkspaceTask?
    @State private var linkingTask = false
    @State private var tracking: MarkdownChecklistItem?
    @State private var removing: WorkspaceTask?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 16) {
                properties
                if let error = error ?? workspace
                    .error
                {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                taskHeader
                ForEach(tasks) { task in
                    WorkspaceTaskRow(
                        task: task,
                        workspace: workspace,
                        names: names,
                        openNote: openNote,
                        removePlacement: { removing = task }
                    ) { editingTask = task }
                }
                if more {
                    Button("Load more tasks") { Task { await loadTasks(reset: false) } }
                        .disabled(loadingMore || workspace.busy)
                }
                if !local.isEmpty {
                    checklist
                }
                if tasks.isEmpty, local.isEmpty {
                    Text("Local checklists stay in this note. Tracked tasks also appear in Tasks.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.top, 12)
        } label: {
            Text(profile.type == .note ? "Properties and tasks" : profile.type
                .label + " properties and tasks")
                .font(.headline)
        }
        .padding(.vertical, 8)
        .task(
            id: "\(document.id)/\(document.revision?.uuidString ?? "draft")/\(workspace.generation)"
        ) {
            await load()
        }
        .sheet(isPresented: $editingProperties) {
            NoteProfileEditor(workspace: workspace, document: document, profile: profile)
        }
        .sheet(item: $editingTask) { WorkspaceTaskEditor(
            workspace: workspace,
            task: $0,
            placement: document.id
        ) }
        .sheet(isPresented: $linkingTask) {
            WorkspaceTasksView(workspace: workspace, choose: { task in
                Task { await workspace.change { try await workspace.store.addTaskPlacement(
                    task.id,
                    in: document.id
                ) } }
            }).frame(width: 620, height: 580)
        }
        .confirmationDialog("Remove this task from the note?", isPresented: Binding(
            get: { removing != nil }, set: {
                if !$0 {
                    removing = nil
                }
            }
        )) {
            Button("Remove from note", role: .destructive) {
                guard let task = removing else { return }
                Task {
                    await workspace
                        .change(changesNote: true) { try await workspace.store.unlinkWorkspaceTask(
                            task,
                            from: document
                        ) }
                    removing = nil
                }
            }
        } message: {
            Text(
                "The task stays in Tasks. Its references are removed from this note. If this note is its project, that assignment is cleared."
            )
        }
        .confirmationDialog("Track this checklist item?", isPresented: Binding(
            get: { tracking != nil }, set: {
                if !$0 {
                    tracking = nil
                }
            }
        )) {
            Button("Track task") {
                guard let item = tracking else { return }
                Task {
                    await workspace
                        .change(changesNote: true) { _ = try await workspace.store.trackChecklist(
                            item,
                            in: document
                        ) }
                    tracking = nil
                }
            }
        } message: {
            Text(
                "The checkbox becomes a link to one shared task. Its title, status, and dates are edited here or in Tasks, not in two separate copies."
            )
        }
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(profile.type == .note ? "No special type" : profile.type.label).font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit properties…") { editingProperties = true }.controlSize(.small)
            }
            ForEach(profile.type.fields) { field in
                if let value = profile.values[field.id], !value.isEmpty {
                    LabeledContent(field.label, value: value).font(.callout)
                }
                ForEach(profile.links[field.id] ?? [], id: \.self) { id in
                    if let name = names[id] {
                        Button(field.label + ": " + name) { openNote(id) }.buttonStyle(.link)
                    }
                }
            }
            if !backlinks.isEmpty {
                Text("Referenced by").font(.caption).foregroundStyle(.secondary)
                ForEach(backlinks) { note in
                    Button(note.name) { openNote(note.id) }.buttonStyle(.link)
                }
            }
        }
    }

    private var taskHeader: some View {
        HStack {
            Text(profile.type == .project ? "Project tasks" : "Tracked tasks")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Button("New task…") {
                    editingTask = WorkspaceTask(
                        title: "",
                        projectID: profile.type == .project ? document.id : profile
                            .links["project"]?.first,
                        originID: document.id
                    )
                }
                Button("Link existing task…") { linkingTask = true }
            } label: { Label("Add task", systemImage: "plus") }
                .disabled(workspace.busy)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local checklist").font(.subheadline.weight(.semibold))
            ForEach(local.prefix(80)) { item in
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        Task {
                            await workspace
                                .change(changesNote: true) {
                                    _ = try await workspace.store.toggleChecklist(
                                        item,
                                        in: document
                                    )
                                }
                        }
                    } label: { Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                    }
                    .buttonStyle(.plain).disabled(workspace.busy)
                    .accessibilityLabel((item.checked ? "Uncheck " : "Check ") + item.title)
                    Text(item.title).strikethrough(item.checked).frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    Button("Track…") { tracking = item }.controlSize(.small)
                        .disabled(workspace.busy)
                        .accessibilityLabel("Track \(item.title) as a task")
                }
            }
            if local.count > 80 {
                Text("Showing the first 80 checklist items. Edit the note to manage the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            let value = try await workspace.store.noteProfile(document.id)
            let references = try await workspace.store.workspaceNoteLinks(
                to: document.id,
                limit: 80
            )
            let (page, titles) = try await readTasks(profile: value, existing: [])
            try Task.checkCancellation()
            profile = value
            backlinks = references
            local = MarkdownChecklist.items(in: document.markdown)
            tasks = page.tasks
            more = page.hasMore
            names = titles
            error = nil
            if !loaded {
                expanded = value.type != .note || !page.tasks.isEmpty || !local
                    .isEmpty; loaded = true
            }
        } catch is CancellationError {
        } catch { self.error = "Could not load note properties. Reopen the note to retry." }
    }

    private func loadTasks(reset: Bool) async {
        guard !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let generation = workspace.generation
        do {
            let existing = reset ? [] : tasks
            let (page, titles) = try await readTasks(profile: profile, existing: existing)
            try Task.checkCancellation()
            guard workspace.generation == generation else { return }
            tasks = existing + page.tasks
            more = page.hasMore
            names = titles
            error = nil
        } catch is CancellationError {
        } catch { self.error = "Could not load tasks. Reopen the note to retry." }
    }

    private func readTasks(
        profile: NoteProfile,
        existing: [WorkspaceTask]
    ) async throws -> (WorkspaceTaskPage, [UUID: String]) {
        let page = try await workspace.store.workspaceTasks(
            noteID: profile.type == .project ? nil : document.id,
            projectID: profile.type == .project ? document.id : nil,
            includeProjectPlacements: true, offset: existing.count
        )
        let ids = profile.links.values.flatMap(\.self) + (existing + page.tasks).flatMap {
            [$0.originID, $0.projectID].compactMap(\.self)
        }
        let titles = try await workspace.store.workspaceLinkNames(Array(Set(ids)))
        return (page, titles)
    }
}

private struct NoteProfileEditor: View {
    @Bindable var workspace: NoteWorkspaceModel
    let document: MarkdownDocument
    @State var profile: NoteProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Note properties").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await workspace.change(
                            changesNote: true,
                            { _ = try await workspace.store.save(document, profile: profile) }
                        ) {
                            dismiss()
                        }
                    }
                }.keyboardShortcut(.defaultAction)
            }
            NotePropertiesEditor(profile: $profile, store: workspace.store)
            if let error = workspace
                .error
            {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24).frame(minWidth: 460, idealWidth: 580).disabled(workspace.busy)
        .onAppear { workspace.error = nil }
    }
}
