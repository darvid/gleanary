import SwiftUI

struct NoteTemplatesView: View {
    @Bindable var workspace: NoteWorkspaceModel
    var current: MarkdownDocument?
    var use: (NoteTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NoteTemplate?
    @State private var deleting: NoteTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Note templates").font(.title2.weight(.semibold))
                Spacer()
                Button("New template", systemImage: "plus") {
                    editing = NoteTemplate(name: "New template")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(
                "Start with a stock template or make your own. Changing a template never rewrites existing notes."
            )
            .font(.callout).foregroundStyle(.secondary)
            if let error = workspace
                .error
            {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let current {
                Button("Save current note as template…") {
                    Task {
                        do {
                            let profile = try await workspace.store.noteProfile(current.id)
                            editing = NoteTemplate(
                                name: current.name + " template",
                                title: "Untitled",
                                body: NoteTemplate.starterBody(from: current.markdown),
                                defaults: NoteProfile(type: profile.type)
                            )
                        } catch { workspace.error = NoteWorkspaceModel.message(error) }
                    }
                }
                Text(
                    "Review copied text before saving. Tracked task links become empty local checkboxes. Dates and linked people are not copied as defaults."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            List(workspace.templates) { template in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name).font(.headline)
                        Text(template.defaults.type
                            .label + (template.stock ? " — Stock" : " — Personal"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use") { use(template); dismiss() }
                        .accessibilityLabel("Use \(template.name) template")
                    Button("Duplicate") {
                        var copy = template
                        copy.id = UUID(); copy.version = 0; copy.stock = false
                        copy.name += " copy"
                        editing = copy
                    }
                    if !template.stock {
                        Button("Edit") { editing = template }
                        Button("Delete", role: .destructive) { deleting = template }
                    }
                }.padding(.vertical, 6)
            }
            Button("Reload templates") { Task { await workspace.loadTemplates() } }
                .controlSize(.small)
        }
        .padding(24).frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 580)
        .task { await workspace.loadTemplates() }
        .sheet(item: $editing) { NoteTemplateEditor(workspace: workspace, template: $0) }
        .confirmationDialog("Delete this template?", isPresented: Binding(
            get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            }
        )) {
            Button("Delete template", role: .destructive) {
                guard let template = deleting else { return }
                Task {
                    if await workspace
                        .change({ try await workspace.store.deleteNoteTemplate(template) })
                    {
                        deleting = nil
                        await workspace.loadTemplates()
                    }
                }
            }
        } message: { Text("Existing notes created from it are kept unchanged.") }
        .disabled(workspace.busy)
    }
}

struct NoteTemplateEditor: View {
    @Bindable var workspace: NoteWorkspaceModel
    @State var template: NoteTemplate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit template").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save template") {
                    Task {
                        if await workspace
                            .change({ _ = try await workspace.store.saveNoteTemplate(template) })
                        {
                            await workspace.loadTemplates()
                            dismiss()
                        }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Template name", text: $template.name).textFieldStyle(.roundedBorder)
                    TextField("New note title", text: $template.title)
                        .textFieldStyle(.roundedBorder)
                    NotePropertiesEditor(
                        profile: $template.defaults,
                        store: workspace.store,
                        template: true
                    )
                    Text("Starter text").font(.subheadline.weight(.semibold))
                    TextEditor(text: $template.body).font(.body.monospaced()).frame(minHeight: 220)
                    Text(
                        "Use {{date}} for the local creation date and {{title}} for the new note title. Other text is literal; templates cannot run code or inference."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = workspace
                .error
            {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 640, minHeight: 520, idealHeight: 680)
        .disabled(workspace.busy)
        .onAppear { workspace.error = nil }
    }
}
