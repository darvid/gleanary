import Observation
import SwiftUI

@MainActor @Observable final class EntitiesModel {
    let store: DocumentStore
    var kind: GraphNode.Kind?
    var query = ""
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
            entities = try await store.entities(kind: kind, matching: query)
            if selectedID.map({ id in !entities.contains { $0.id == id } }) ?? true {
                selectedID = entities.first?.id
            }
            await loadMentions()
            error = nil
        } catch { self.error = "Entities could not be loaded. Try again." }
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
        .task(id: "\(model.kind?.rawValue ?? "all")/\(model.query)") { await model.load() }
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
            if model.entities.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "No entities yet" : "No matches",
                    systemImage: "person.2",
                    description: Text(model.query.isEmpty
                        ? "People, organizations and concepts appear as your notes are read for the graph."
                        : "Try another name.")
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

    @ViewBuilder private var detail: some View {
        if let entity = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(entity.name, systemImage: Self.symbol(entity.kind))
                            .font(.title2.weight(.semibold)).textSelection(.enabled)
                        HStack(spacing: 10) {
                            Text(Self.singular(entity.kind))
                            Text("Mentioned in \(Self.noteCount(entity.noteCount))")
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
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
