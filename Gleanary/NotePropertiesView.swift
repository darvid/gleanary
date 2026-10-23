import SwiftUI

struct NotePropertiesEditor: View {
    @Binding var profile: NoteProfile
    let store: DocumentStore
    var template = false
    @State private var linking: NoteProperty?
    @State private var names: [UUID: String] = [:]
    @State private var pendingType: NoteRecordType?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Type",
                selection: Binding(get: { profile.type }, set: { pendingType = $0 })
            ) {
                ForEach(NoteRecordType.allCases) { Text($0 == .note ? "None" : $0.label).tag($0) }
            }
            ForEach(profile.type.fields) { field in
                property(field)
            }
        }
        .confirmationDialog("Change type?", isPresented: Binding(
            get: { pendingType != nil }, set: {
                if !$0 {
                    pendingType = nil
                }
            }
        )) {
            Button("Change type") {
                guard let type = pendingType else { return }
                let keys = Set(type.fields.map(\.id))
                profile.type = type
                profile.values = profile.values.filter { keys.contains($0.key) }
                profile.links = profile.links.filter { keys.contains($0.key) }
                pendingType = nil
            }
        } message: {
            Text(
                "Properties not used by the new type will be removed when you save. The note's text, source identity, and filing stay unchanged."
            )
        }
        .sheet(item: $linking) { field in
            WorkspaceNotePicker(store: store, type: field.target) { note in
                if field.kind == .link {
                    profile.links[field.id] = [note.id]
                } else if profile.links[field.id, default: []].contains(note.id) == false {
                    profile.links[field.id, default: []].append(note.id)
                }
                names[note.id] = note.name
            }
        }
        .task(id: profile.links) {
            names = await (try? store
                .workspaceLinkNames(Array(Set(profile.links.values.flatMap(\.self))))) ?? [:]
        }
    }

    @ViewBuilder private func property(_ field: NoteProperty) -> some View {
        if field.kind == .text || field.kind == .date {
            HStack {
                TextField(field.label, text: Binding(
                    get: { profile.values[field.id] ?? "" }, set: { profile.values[field.id] = $0 }
                ), prompt: Text(field.kind == .date ? "YYYY-MM-DD" : field.label))
                    .textFieldStyle(.roundedBorder).accessibilityLabel(field.label)
                if field.kind == .date {
                    Button(template ? "Creation date" : "Today") {
                        profile.values[field.id] = template ? "{{date}}" : WorkspaceDay(date: .now)
                            .rawValue
                    }.controlSize(.small)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(field.label).font(.callout)
                    Spacer()
                    Button("Choose…") { linking = field }.controlSize(.small)
                        .accessibilityLabel("Choose \(field.label)")
                }
                ForEach(profile.links[field.id] ?? [], id: \.self) { id in
                    HStack {
                        Text(names[id] ?? "Unavailable note").lineLimit(2)
                        Spacer()
                        Button("Remove", systemImage: "xmark") {
                            profile.links[field.id]?.removeAll { $0 == id }
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(names[id] ?? field.label)")
                    }.font(.callout)
                }
            }
        }
    }
}

/// Bounded, searchable note references. This picker never generates or captures content.
struct WorkspaceNotePicker: View {
    let store: DocumentStore
    var type: NoteRecordType?
    var choose: (WorkspaceNoteLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var notes: [WorkspaceNoteLink] = []
    @State private var more = false
    @State private var loading = false
    @State private var loadToken = UUID()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(type.map { "Choose a \($0.label.lowercased())" } ?? "Choose a saved note")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search saved notes", text: $query).textFieldStyle(.roundedBorder)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            List(notes) { note in
                Button { choose(note); dismiss() } label: {
                    Text(note.name).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .overlay {
                if loading {
                    HStack { ChatWorkingIndicator(color: .secondary); Text("Loading notes…") }
                } else if notes.isEmpty {
                    ContentUnavailableView(
                        "No matching notes",
                        systemImage: "note.text"
                    )
                }
            }
            if more {
                Button("Load more") { Task { await load(reset: false) } }.disabled(loading)
            }
        }
        .padding(24).frame(minWidth: 420, idealWidth: 520, minHeight: 360, idealHeight: 480)
        .task(id: query) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard reset || !loading else { return }
        let token = UUID()
        loadToken = token
        loading = true
        error = nil
        if reset {
            notes = []; more = false
        }
        defer {
            if loadToken == token {
                loading = false
            }
        }
        do {
            let rows = try await store.workspaceNoteLinks(
                query: query,
                type: type,
                offset: reset ? 0 : notes.count,
                limit: 81
            )
            try Task.checkCancellation()
            guard loadToken == token else { return }
            if reset {
                notes = []
            }
            notes += rows.prefix(80)
            more = rows.count > 80
        } catch is CancellationError {
        } catch {
            if loadToken ==
                token
            {
                self.error = "Could not load saved notes. Try another search."
            }
        }
    }
}
