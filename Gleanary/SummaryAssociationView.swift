import SwiftUI

/// An explicit user assertion about an existing note. No generation or content rewriting.
struct SummaryAssociationView: View {
    let store: DocumentStore
    let sourceID: UUID
    var changed: @MainActor () async -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var notes: [DocumentSummary] = []
    @State private var summaries = Set<UUID>()
    @State private var explicitSummaries = Set<UUID>()
    @State private var offset = 0
    @State private var total = 0
    @State private var busy = false
    @State private var loading = false
    @State private var loadToken = UUID()
    @State private var error: String?
    @State private var associated: DocumentSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Use a note as this source’s summary").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(
                "Choose an existing note. Its text and filing stay unchanged; no summary is generated."
            )
            .font(.callout).foregroundStyle(.secondary)
            TextField("Search notes", text: $query).textFieldStyle(.roundedBorder)
            if let error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let associated {
                HStack {
                    Text("Associated: \(associated.name)").lineLimit(2)
                    Button("Remove summary role") { update(associated, enabled: false) }
                        .disabled(busy)
                        .help("Keep the note and its source reference")
                }.font(.callout)
            }
            List(notes) { note in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.name)
                        Text(note.kindLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if summaries.contains(note.id) {
                        Label("Summary", systemImage: "checkmark").foregroundStyle(.secondary)
                        if explicitSummaries.contains(note.id) {
                            Button("Remove") { update(note, enabled: false) }
                                .disabled(busy)
                                .help(
                                    "Remove the summary role, keeping the note and its source reference"
                                )
                                .accessibilityLabel("Remove summary association: \(note.name)")
                        }
                    } else {
                        Button("Use as summary") { update(note, enabled: true) }
                            .disabled(busy)
                            .accessibilityLabel("Use \(note.name) as a summary for this source")
                    }
                }.padding(.vertical, 4)
            }
            .overlay {
                if notes.isEmpty {
                    if loading {
                        ProgressView("Loading notes…")
                    } else {
                        ContentUnavailableView("No notes found", systemImage: "note.text")
                    }
                }
            }
            if offset < total {
                Button("Load more notes") { Task { await load(reset: false) } }
                    .disabled(busy || loading)
            }
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 400, idealHeight: 520)
        .task(id: query) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard reset || !loading else { return }
        let requestedQuery = query
        let token = UUID()
        loadToken = token
        loading = true
        defer {
            if loadToken == token {
                loading = false
            }
        }
        do {
            let page = try await store.documentPage(
                query: requestedQuery,
                offset: reset ? 0 : offset,
                scope: .notes
            )
            let existing = try await store.librarySummaries(for: sourceID)
            let explicit = try await store.explicitSummaryIDs(for: sourceID)
            guard !Task.isCancelled, query == requestedQuery, loadToken == token else { return }
            let candidates = page.documents.filter { $0.id != sourceID }
            notes = reset ? candidates : notes + candidates
            offset = (reset ? 0 : offset) + page.documents.count
            total = page.total
            summaries = Set(existing.map(\.id))
            explicitSummaries = explicit
            error = nil
        } catch {
            guard !Task.isCancelled, query == requestedQuery, loadToken == token else { return }
            self.error = "Notes could not be loaded. Try searching again."
        }
    }

    private func update(_ note: DocumentSummary, enabled: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.associateSummary(note.id, with: sourceID, enabled: enabled)
                associated = enabled ? note : nil
                await changed()
                await load(reset: true)
            } catch {
                self.error = "The summary association could not be saved. The note’s text is unchanged."
            }
        }
    }
}
