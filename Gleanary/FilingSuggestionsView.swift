import SwiftUI

/// File › Categorize Unfiled: suggests homes for unfiled items in the background, then lets
/// the person accept or reject them by category. Nothing is filed until accepted.
struct FilingSuggestionsView: View {
    let library: LibraryModel
    /// Resolved when a run starts, so it follows the current ChatGPT setting.
    let inference: () -> any ConversationInferring
    var noteIDs: Set<UUID>?
    @State private var suggestions: [FilingSuggestion] = []
    @State private var categories: [DecimalCategory] = []
    @State private var unfiled = 0
    @State private var lastBatch: (batch: UUID, count: Int)?
    @State private var creating: String?
    @State private var newCode = ""
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var byCategory: [(category: DecimalCategory, items: [FilingSuggestion])] {
        var grouped: [UUID: [FilingSuggestion]] = [:]
        for suggestion in suggestions {
            if let id = suggestion.categoryID {
                grouped[id, default: []].append(suggestion)
            }
        }
        return categories.compactMap { category in
            grouped[category.id].map { (category, $0) }
        }
    }

    private var proposedHomes: [(name: String, items: [FilingSuggestion])] {
        Dictionary(grouping: suggestions.filter { $0.categoryID == nil }) { $0.newCategory ?? "" }
            .map { ($0.key, $0.value) }
            .sorted { ($0.items.count, $1.name) > ($1.items.count, $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(noteIDs.map { "Organize \($0.count) notes" } ?? "Categorize Unfiled")
                .font(.title2.weight(.semibold))
            runStatus
            if !suggestions.isEmpty {
                reviewBar
                List {
                    if !proposedHomes.isEmpty {
                        Section("Suggested new categories") {
                            ForEach(proposedHomes, id: \.name) { home in
                                proposedRow(home.name, count: home.items.count)
                            }
                        }
                    }
                    Section("Existing categories") {
                        ForEach(byCategory, id: \.category.id) { group in
                            DisclosureGroup {
                                ForEach(group.items) { suggestionRow($0) }
                            } label: {
                                categoryLabel(group.category, items: group.items)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }
            if let message = error ?? library.categorizationError {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Text(
                    "Accepted items are filed in their category. Rejected suggestions aren't offered again."
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .task { await reload() }
        .task(id: library.categorization?.checked) { await reload() }
        .task(id: library.categorizationState) { await reload() }
    }

    // MARK: Run

    @ViewBuilder private var runStatus: some View {
        let engine = inference()
        let label = engine.capabilities.local ? "Apple Intelligence on this Mac" : "ChatGPT"
        if library.categorizing {
            let progress = library.categorization ?? CategorizationProgress()
            let stopping = library.categorizationState == .stopping
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(
                    value: Double(progress.checked),
                    total: Double(max(1, progress.total))
                ) {
                    Text(stopping ? "Stopping…"
                        : "Suggesting homes with \(library.categorizationEngine ?? label)…")
                        .fadesOnChange(stopping)
                } currentValueLabel: {
                    Text(stopping
                        ? "Waiting for requests already sent, \(progress.checked.formatted()) checked"
                        :
                        "\(progress.checked.formatted()) of \(progress.total.formatted()) checked")
                        .monospacedDigit()
                        .countsOnChange(progress.checked)
                }
                HStack(spacing: 8) {
                    Button(stopping ? "Stopping…" : "Stop") { library.stopCategorizing() }
                        .disabled(stopping)
                    if stopping {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(unfiled == 1 ? "1 unfiled item without a suggestion"
                        : "\(unfiled.formatted()) unfiled items without a suggestion")
                    Text(engine.capabilities.local
                        ? "Uses \(label). Nothing leaves your Mac."
                        :
                        "Uses \(label). Titles, sites and excerpts are sent to OpenAI; repeated runs reuse earlier answers.")
                        .font(.caption).foregroundStyle(.secondary)
                    if library.categorizationStopped, let progress = library.categorization {
                        Text(
                            "Stopped after \(progress.checked.formatted()) of \(progress.total.formatted()). Suggestions so far are saved; Suggest Homes picks up where it left off."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if let progress = library.categorization, progress.failed > 0 {
                        Text(
                            "\(progress.failed.formatted()) couldn't be read in the last run and will be retried."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Suggest Homes") { library.startCategorizing(
                    using: inference(),
                    noteIDs: noteIDs
                ) }
                .disabled(unfiled == 0 || !library.ready)
            }
        }
    }

    // MARK: Review

    private var reviewBar: some View {
        HStack {
            Text("\(suggestions.count.formatted()) suggestions to review")
                .font(.headline)
                .countsOnChange(suggestions.count)
            Spacer()
            if let lastBatch {
                Button("Undo \(lastBatch.count.formatted())") {
                    Task { await undo(lastBatch.batch) }
                }
                .disabled(working)
            }
            let confident = suggestions.filter(\.confident)
            Button("Accept \(confident.count.formatted()) Likely") {
                Task { await accept(confident.map(\.noteID)) }
            }
            .disabled(confident.isEmpty || working)
            .help(
                "Accepts suggestions the model was confident about. On-device suggestions always need a look."
            )
        }
    }

    private func categoryLabel(
        _ category: DecimalCategory,
        items: [FilingSuggestion]
    ) -> some View {
        HStack {
            Text(category.label).font(.body.weight(.medium))
            Text(items.count.formatted()).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Accept All") { Task { await accept(items.map(\.noteID)) } }
                .buttonStyle(.borderless).disabled(working)
            Button("Reject All") { Task { await reject(items.map(\.noteID)) } }
                .buttonStyle(.borderless).disabled(working)
        }
    }

    private func suggestionRow(_ suggestion: FilingSuggestion) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).lineLimit(1)
                if let host = suggestion.host {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !suggestion.confident {
                Text("Check").font(.caption).foregroundStyle(.secondary)
            }
            Button("Accept", systemImage: "checkmark") {
                Task { await accept([suggestion.noteID]) }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(working)
            .help("File in this category")
            Button("Reject", systemImage: "xmark") {
                Task { await reject([suggestion.noteID]) }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(working)
            .help("Leave unfiled")
        }
    }

    private func proposedRow(_ name: String, count: Int) -> some View {
        HStack {
            Label {
                Text(name)
            } icon: {
                Image(systemName: NewCategoryBadge.symbol).foregroundStyle(NewCategoryBadge.tint)
            }
            NewCategoryBadge()
            Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button("Create…") {
                newCode = Self.nextCode(in: categories)
                creating = name
            }
            .buttonStyle(.borderless)
            .popover(isPresented: Binding(
                get: { creating == name },
                set: {
                    if !$0 {
                        creating = nil
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Create “\(name)”").font(.headline)
                    TextField("Code", text: $newCode).frame(width: 90)
                    Text("Its \(count.formatted()) suggestions will point here for review.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Create") { Task { await create(name) } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16).frame(width: 280)
            }
            Button("Reject All") {
                Task {
                    await reject(suggestions.filter { $0.newCategory == name }.map(\.noteID))
                }
            }
            .buttonStyle(.borderless)
        }
    }

    /// The Inbox area's next code, else the first empty area's `X0`.
    static func nextCode(in categories: [DecimalCategory]) -> String {
        let areas = CategoryArea.group(categories)
        if let code = areas.first(where: { $0.digit == 1 })?.nextFreeCode {
            return code
        }
        let used = Set(areas.map(\.digit))
        if let digit = (2 ... 9).first(where: { !used.contains($0) }) {
            return "\(digit)0"
        }
        return areas.lazy.compactMap(\.nextFreeCode).first ?? ""
    }

    // MARK: Actions

    private func reload() async {
        do {
            suggestions = try await library.filingSuggestions()
                .filter { noteIDs?.contains($0.noteID) ?? true }
            categories = try await library.store.categories()
            unfiled = try await library.store.filingCandidates()
                .filter { noteIDs?.contains($0.id) ?? true }.count
        } catch { self.error = error.localizedDescription }
    }

    private func accept(_ ids: [UUID]) async {
        working = true
        defer { working = false }
        do {
            let result = try await library.acceptFilingSuggestions(
                ids,
                includeSources: noteIDs == nil
            )
            lastBatch = result.accepted > 0 ? (result.batch, result.accepted) : lastBatch
            error = nil
        } catch { self.error = error.localizedDescription }
        await reload()
    }

    private func reject(_ ids: [UUID]) async {
        working = true
        defer { working = false }
        do { try await library.rejectFilingSuggestions(ids) }
        catch { self.error = error.localizedDescription }
        await reload()
    }

    private func undo(_ batch: UUID) async {
        working = true
        defer { working = false }
        do {
            _ = try await library.undoFilingSuggestions(
                batch: batch,
                noteIDs: noteIDs,
                includeSources: noteIDs == nil
            )
            lastBatch = nil
        } catch { self.error = error.localizedDescription }
        await reload()
    }

    private func create(_ name: String) async {
        do {
            try await library.createSuggestedCategory(name, code: newCode, noteIDs: noteIDs)
            creating = nil
            error = nil
        } catch { self.error = error.localizedDescription }
        await reload()
    }
}

/// One collection-level follow-up; filing never hides or invalidates published notes.
struct SeriesFilingActions: View {
    let status: SeriesFiling.Status
    var working = false
    let review: () -> Void
    let undo: () -> Void

    var body: some View {
        ChipFlow(spacing: 10) {
            Text(summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.unfiled > 0 {
                Button("Organize notes…", action: review).buttonStyle(.link)
                    .help("Review filing for this collection with the Librarian")
            }
            if !status.batches.isEmpty {
                Button("Undo filing", action: undo).buttonStyle(.link)
                    .help("Undo filing for these new notes; keep the published collection")
            }
        }
        .disabled(working)
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        if working {
            return "The Librarian is checking filing. Published notes are saved."
        }
        if status.unfiled > 0 {
            let filed = status.noteIDs.count - status.unfiled
            return filed > 0 ? "\(filed) filed; \(status.unfiled) need filing." : "Published notes are saved. Filing needs review."
        }
        return "Filed in \(status.homes.formatted(.list(type: .and)))."
    }
}
