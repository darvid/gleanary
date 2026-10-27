import Observation
import SwiftUI

@MainActor @Observable final class EntitiesModel {
    /// Rows fetched at a time; the list asks for more as you near the end.
    static let pageSize = 200

    let store: DocumentStore
    let resolver: EntityResolver
    var kind: GraphNode.Kind?
    var query = ""
    var showHidden = false
    var sort = EntitySort.mentions
    private(set) var entities: [EntitySummary] = []
    private(set) var total = 0
    var selectedID: String?
    private(set) var mentions: [EntityMention] = []
    private(set) var suggestions: [EntitySuggestion] = []
    private(set) var findingDuplicates = false
    private(set) var error: String?
    @ObservationIgnored private var loadingMore = false
    @ObservationIgnored private var merged = false

    init(store: DocumentStore, judge: (any EntityMatchJudging)? = nil) {
        self.store = store
        resolver = EntityResolver(store: store, judge: judge)
    }

    var selected: EntitySummary? {
        entities.first { $0.id == selectedID }
    }

    func load() async {
        do {
            // Names that share a match key merge on the first visit; it needs no model.
            if !merged {
                merged = true
                try await resolver.autoMerge()
            }
            entities = try await store.entities(
                kind: kind, matching: query, hidden: showHidden, sort: sort, limit: Self.pageSize
            )
            total = try await store.entityCount(kind: kind, matching: query, hidden: showHidden)
            suggestions = try await store.entitySuggestions()
            if selectedID.map({ id in !entities.contains { $0.id == id } }) ?? true {
                selectedID = entities.first?.id
            }
            await loadMentions()
            error = nil
        } catch { self.error = "Entities could not be loaded. Try again." }
    }

    /// The next page, when the list has scrolled near the end of what's loaded.
    func loadMore() async {
        guard !loadingMore, entities.count < total else { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = await (try? store.entities(
            kind: kind, matching: query, hidden: showHidden, sort: sort,
            offset: entities.count, limit: Self.pageSize
        )) ?? []
        let known = Set(entities.map(\.id))
        entities += next.filter { !known.contains($0.id) }
    }

    /// Merges same-key names, then asks the model about likely duplicates.
    func findDuplicates() async {
        findingDuplicates = true
        defer { findingDuplicates = false }
        do {
            try await resolver.autoMerge()
            try await resolver.findDuplicates()
        } catch { self.error = "Duplicates couldn't be checked. Try again." }
        await load()
    }

    func mergeAllSuggestions() async {
        await apply { try await self.store.mergeAllEntitySuggestions() }
    }

    func resolve(_ suggestion: EntitySuggestion, merge: Bool) async {
        await apply { try await self.store.resolveEntitySuggestion(suggestion, merge: merge) }
    }

    /// Other entities this one could be merged into, the same kind first.
    var mergeTargets: [EntitySummary] {
        guard let selected else { return [] }
        let others = entities.filter { $0.id != selected.id }
        return Array((others.filter { $0.kind == selected.kind }
                + others.filter { $0.kind != selected.kind }).prefix(30))
    }

    func rename(_ id: String, to name: String?) async {
        await apply { try await self.store.renameEntity(id, to: name) }
    }

    func merge(_ id: String, into target: String) async {
        await apply { try await self.store.mergeEntity(id, into: target) }
        selectedID = target
        await loadMentions()
    }

    func unmerge(_ id: String) async {
        await apply { try await self.store.unmergeEntity(id) }
    }

    func setHidden(_ id: String, _ hidden: Bool) async {
        await apply { try await self.store.hideEntity(id, hidden: hidden) }
    }

    private func apply(_ change: () async throws -> Void) async {
        do {
            try await change()
            await load()
        } catch { self.error = "That change couldn't be saved. Try again." }
    }

    func loadMentions() async {
        guard let selectedID else {
            mentions = []
            return
        }
        mentions = await (try? store.entityMentions(selectedID)) ?? []
    }
}

/// People, organizations, tools and concepts found in your notes, each with the passages that
/// mention it. Extraction finds them; here you can rename, merge or hide them.
struct EntitiesView: View {
    @State private var model: EntitiesModel
    @State private var reviewingDuplicates = false
    @State private var renaming = false
    @State private var draftName = ""
    @AppStorage(LibraryModel.backgroundEntitiesKey) private var readingInBackground = false
    var open: (UUID) -> Void

    init(
        store: DocumentStore,
        judge: (any EntityMatchJudging)? = nil,
        open: @escaping (UUID) -> Void
    ) {
        _model = State(initialValue: EntitiesModel(store: store, judge: judge))
        self.open = open
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 280)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(
            id: "\(model.kind?.rawValue ?? "all")/\(model.query)/\(model.showHidden)/\(model.sort)"
        ) {
            await model.load()
        }
        .sheet(isPresented: $reviewingDuplicates) {
            DuplicateReview(model: model)
        }
        .onChange(of: model.selectedID) { Task { await model.loadMentions() } }
    }

    /// Filters on top, then the list flush with the pane, as in Mail or Notes.
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            filters.padding(12)
            Divider()
            if model.entities.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "No entities yet" : "No matches",
                    systemImage: "person.2",
                    description: Text(model.query.isEmpty ? emptyHint : "Try another name.")
                )
            } else {
                entityList
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Kind", selection: $model.kind) {
                    Text("All").tag(GraphNode.Kind?.none)
                    ForEach(Self.kinds, id: \.self) { kind in
                        Text(Self.plural(kind)).tag(Optional(kind))
                    }
                }
                .pickerStyle(.menu).labelsHidden()
                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(EntitySort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort by \(model.sort.title)", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Sorted by \(model.sort.title)")
            }
            TextField("Find a person, organization or concept", text: $model.query)
                .textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Show hidden", isOn: $model.showHidden).toggleStyle(.checkbox)
                Spacer()
                Text(model.total == 1 ? "1 entity" : "\(model.total.formatted()) entities")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack(spacing: 8) {
                if model.findingDuplicates {
                    // The same quiet pulse as Chat's working state, in place of the button.
                    HStack(spacing: 4) {
                        ChatWorkingIndicator(color: .secondary)
                        Text("Checking for duplicates…").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                } else {
                    Button("Find Duplicates") { Task { await model.findDuplicates() } }
                        .help("Merge names written differently and suggest likely duplicates")
                }
                if !model.findingDuplicates, !model.suggestions.isEmpty {
                    Button("Review \(model.suggestions.count)") { reviewingDuplicates = true }
                        .help("Possible duplicates for you to confirm")
                }
            }
            .controlSize(.small)
        }
    }

    private var entityList: some View {
        List(model.entities, selection: $model.selectedID) { entity in
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(entity.kind)).foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(entity.name).lineLimit(1)
                Spacer(minLength: 8)
                Text(entity.noteCount.formatted()).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .tag(entity.id)
            .onAppear {
                // Rows are built as they scroll into view, so the last one asks for more.
                if entity.id == model.entities.last?.id {
                    Task { await model.loadMore() }
                }
            }
            .accessibilityLabel(
                "\(entity.name), \(Self.singular(entity.kind)), \(Self.noteCount(entity.noteCount))"
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Says how entities get found, since nothing reads notes unless asked or turned on.
    private var emptyHint: String {
        readingInBackground
            ? "Notes are being read for people, organizations and concepts. They appear here as each note is done."
            : "Ask in chat, for example “Find the people and organizations in my recent saves”, or turn on background reading in Settings › Capture."
    }

    @ViewBuilder private var detail: some View {
        if let entity = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(entity.name, systemImage: Self.symbol(entity.kind))
                                .font(.title2.weight(.semibold)).textSelection(.enabled)
                            Spacer()
                            editMenu(entity)
                        }
                        HStack(spacing: 10) {
                            Text(Self.singular(entity.kind))
                            Text("Mentioned in \(Self.noteCount(entity.noteCount))")
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !entity.aliases.isEmpty {
                        aliases(entity)
                    }
                    ForEach(Self.byNote(model.mentions), id: \.noteID) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    open(group.noteID)
                                } label: {
                                    Label(group.noteName, systemImage: "doc.text")
                                        .font(.headline)
                                }
                                .buttonStyle(.link)
                                if let filing = group.mentions.first?.filing {
                                    FilingTag(category: filing)
                                }
                            }
                            ForEach(group.mentions) { mention in
                                VStack(alignment: .leading, spacing: 3) {
                                    if let relation = Self.relation(mention) {
                                        Text(relation).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(mention.quote).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.leading, 12)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.separator).frame(width: 2)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
            }
        } else if let error = model.error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableView("Select an entity", systemImage: "person.2")
        }
    }

    private func editMenu(_ entity: EntitySummary) -> some View {
        Menu("Edit") {
            Button("Rename…") {
                draftName = entity.name
                renaming = true
            }
            Menu("Merge Into") {
                ForEach(model.mergeTargets) { target in
                    Button(target.name) {
                        Task { await model.merge(entity.id, into: target.id) }
                    }
                }
            }
            .disabled(model.mergeTargets.isEmpty)
            Divider()
            Button(entity.hidden ? "Unhide" : "Hide") {
                Task { await model.setHidden(entity.id, !entity.hidden) }
            }
        }
        .fixedSize()
        .help("Fixes here also apply when the same name is found again")
        .alert("Rename \(entity.name)", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Rename") { Task { await model.rename(entity.id, to: draftName) } }
            if entity.renamed {
                Button("Use the Name in the Notes") {
                    Task { await model.rename(entity.id, to: nil) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Names merged into this entity, each with a way back out.
    private func aliases(_ entity: EntitySummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Also known as").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(entity.aliases, id: \.id) { alias in
                HStack(spacing: 8) {
                    Text(alias.name)
                    Button("Unmerge") { Task { await model.unmerge(alias.id) } }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    nonisolated static let kinds: [GraphNode.Kind] = [.person, .organization, .tool, .concept]

    nonisolated static func symbol(_ kind: GraphNode.Kind) -> String {
        switch kind {
        case .person: "person"
        case .organization: "building.2"
        case .tool: "wrench.and.screwdriver"
        case .concept: "lightbulb"
        case .document: "doc.text"
        }
    }

    nonisolated static func singular(_ kind: GraphNode.Kind) -> String {
        switch kind {
        case .person: "Person"
        case .organization: "Organization"
        case .tool: "Tool"
        case .concept: "Concept"
        case .document: "Item"
        }
    }

    nonisolated static func plural(_ kind: GraphNode.Kind) -> String {
        switch kind {
        case .person: "People"
        case .organization: "Organizations"
        case .tool: "Tools"
        case .concept: "Concepts"
        case .document: "Items"
        }
    }

    nonisolated static func noteCount(_ count: Int) -> String {
        count == 1 ? "1 note" : "\(count.formatted()) notes"
    }

    /// Mentions say nothing beyond the quote; other relationships name what they connect.
    nonisolated static func relation(_ mention: EntityMention) -> String? {
        switch mention.predicate {
        case .mentions: nil
        case .authoredBy: "Author"
        default: mention.other.map { "\(mention.predicate.label.capitalizedFirstWord) \($0)" }
            ?? mention.predicate.label.capitalizedFirstWord
        }
    }

    nonisolated static func byNote(_ mentions: [EntityMention])
        -> [(noteID: UUID, noteName: String, mentions: [EntityMention])]
    {
        var order: [UUID] = []
        var groups: [UUID: [EntityMention]] = [:]
        for mention in mentions {
            if groups[mention.noteID] == nil {
                order.append(mention.noteID)
            }
            groups[mention.noteID, default: []].append(mention)
        }
        return order.compactMap { id in
            groups[id].map { (id, $0[0].noteName, $0) }
        }
    }
}

private extension String {
    var capitalizedFirstWord: String {
        prefix(1).uppercased() + dropFirst()
    }
}

/// Possible duplicates, each merged or kept apart by you.
private struct DuplicateReview: View {
    let model: EntitiesModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Possible Duplicates").font(.title3.weight(.semibold))
                Text(
                    "Merging keeps the more mentioned name and shows the other under Also known as."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            if model.suggestions.isEmpty {
                ContentUnavailableView("All reviewed", systemImage: "checkmark.circle")
            } else {
                List(model.suggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(suggestion.left.name).fontWeight(.medium)
                            Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                                .accessibilityLabel("and")
                            Text(suggestion.right.name).fontWeight(.medium)
                            Spacer()
                            Button("Not the Same") {
                                Task { await model.resolve(suggestion, merge: false) }
                            }
                            Button("Merge") { Task { await model.resolve(suggestion, merge: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button("Merge All") { Task { await model.mergeAllSuggestions() } }
                    .disabled(model.suggestions.isEmpty)
                    .help("Merge every pair listed; Unmerge on an entity puts one back")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        // Nothing left to decide, so there's nothing to show; close rather than sit empty.
        .onChange(of: model.suggestions.isEmpty) { _, empty in
            if empty {
                dismiss()
            }
        }
    }
}
