import Observation
import SwiftUI

@MainActor @Observable final class EntitiesModel {
    let store: DocumentStore
    var kind: GraphNode.Kind?
    var query = ""
    var showHidden = false
    private(set) var entities: [EntitySummary] = []
    var selectedID: String?
    private(set) var mentions: [EntityMention] = []
    private(set) var error: String?

    init(store: DocumentStore) {
        self.store = store
    }

    var selected: EntitySummary? {
        entities.first { $0.id == selectedID }
    }

    func load() async {
        do {
            entities = try await store.entities(kind: kind, matching: query, hidden: showHidden)
            if selectedID.map({ id in !entities.contains { $0.id == id } }) ?? true {
                selectedID = entities.first?.id
            }
            await loadMentions()
            error = nil
        } catch { self.error = "Entities could not be loaded. Try again." }
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
/// mention it. Extraction keeps these current; nothing here edits them.
struct EntitiesView: View {
    @State private var model: EntitiesModel
    @State private var renaming = false
    @State private var draftName = ""
    @AppStorage(LibraryModel.backgroundEntitiesKey) private var readingInBackground = false
    var open: (UUID) -> Void

    init(store: DocumentStore, open: @escaping (UUID) -> Void) {
        _model = State(initialValue: EntitiesModel(store: store))
        self.open = open
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 280)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(model.kind?.rawValue ?? "all")/\(model.query)/\(model.showHidden)") {
            await model.load()
        }
        .onChange(of: model.selectedID) { Task { await model.loadMentions() } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Kind", selection: $model.kind) {
                Text("All").tag(GraphNode.Kind?.none)
                ForEach(Self.kinds, id: \.self) { kind in
                    Text(Self.plural(kind)).tag(Optional(kind))
                }
            }
            .pickerStyle(.menu).labelsHidden()
            TextField("Find a person, organization or concept", text: $model.query)
                .textFieldStyle(.roundedBorder)
            Toggle("Show hidden", isOn: $model.showHidden).toggleStyle(.checkbox)
                .font(.callout)
            if model.entities.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "No entities yet" : "No matches",
                    systemImage: "person.2",
                    description: Text(model.query.isEmpty ? emptyHint : "Try another name.")
                )
            } else {
                List(model.entities, selection: $model.selectedID) { entity in
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(entity.kind)).foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(entity.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(entity.noteCount.formatted()).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .tag(entity.id)
                    .accessibilityLabel(
                        "\(entity.name), \(Self.singular(entity.kind)), \(Self.noteCount(entity.noteCount))"
                    )
                }
                .listStyle(.sidebar)
            }
        }
        .padding(.top, 12).padding(.horizontal, 12)
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
                            Button {
                                open(group.noteID)
                            } label: {
                                Label(group.noteName, systemImage: "doc.text")
                                    .font(.headline)
                            }
                            .buttonStyle(.link)
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
