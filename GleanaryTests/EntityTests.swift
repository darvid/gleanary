import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

/// Finds Orion and retrieval wherever a note says "Orion uses retrieval."
private struct OrionGraphProvider: GraphExtracting {
    func extract(_ text: String) -> GraphProposal {
        let quote = "Orion uses retrieval."
        guard text.contains(quote) else { return GraphProposal(entities: [], relations: []) }
        return GraphProposal(entities: [
            ProposedEntity(name: "Orion", kind: .tool, quote: quote),
            ProposedEntity(name: "retrieval", kind: .concept, quote: quote),
        ], relations: [ProposedRelation(
            source: "Orion", target: "retrieval", predicate: .uses, quote: quote
        )])
    }
}

/// Records the order notes are read in: each note's first pass, then its curation.
private actor OrderRecordingProvider: GraphExtracting {
    private(set) var steps: [String] = []

    func extract(_ text: String) async throws -> GraphProposal {
        steps.append("extract " + (text.contains("Alpha") ? "Alpha" : "Beta"))
        return OrionGraphProvider().extract(text)
    }

    func curate(_ work: GraphCurationWork) async throws -> GraphProposal {
        steps.append("curate " + work.job.name)
        return OrionGraphProvider().extract(work.evidence.text)
    }

    func relate(_: GraphCurationWork, entities _: [ProposedEntity]) async throws
        -> [ProposedRelation]
    {
        []
    }
}

private func call(_ name: String, _ arguments: [String: Any]) -> AgentCall {
    let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data()
    return AgentCall(
        id: UUID().uuidString,
        name: name,
        arguments: String(decoding: data, as: UTF8.self)
    )
}

@Suite(.serialized) struct EntityTests {
    private func store() async throws -> (URL, DocumentStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        return (root, store)
    }

    /// Records that a note mentions an entity, as extraction would.
    private func mention(
        _ name: String, kind: GraphNode.Kind, quote: String, in note: MarkdownDocument,
        store: DocumentStore
    ) async throws {
        let revision = try #require(note.revision)
        let job = GraphJob(
            noteID: note.id, revision: revision, token: UUID(), name: note.name,
            state: "running", completed: 0, total: 1, error: nil
        )
        let claim = GraphClaim(
            source: GraphNode(
                id: GraphNode.documentID(note.id), kind: .document, label: note.name,
                noteID: note.id
            ),
            target: GraphNode.entity(name, kind: kind, noteID: note.id),
            predicate: .mentions, quote: quote, citation: nil, offset: 0, origin: "model"
        )
        try await store.readyDatabase().write { db in
            try DocumentStore.insertGraphClaim(claim, job: job, chunk: 0, in: db)
        }
    }

    @Test func entitiesListByMentionsWithTheirWrittenNames() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.save(MarkdownDocument(name: "Swarms", markdown: "Notes."))
        let second = try await store.save(MarkdownDocument(name: "Scaling", markdown: "Notes."))
        let archived = try await store.save(MarkdownDocument(name: "Old", markdown: "Notes."))
        try await mention(
            "Toby Ord",
            kind: .person,
            quote: "Toby Ord wrote about swarms.",
            in: first,
            store: store
        )
        try await mention(
            "Toby Ord",
            kind: .person,
            quote: "As Toby Ord argues, it scales.",
            in: second,
            store: store
        )
        try await mention(
            "Synthetic Labs",
            kind: .organization,
            quote: "Synthetic Labs built it.",
            in: first,
            store: store
        )
        try await mention(
            "Ghost",
            kind: .person,
            quote: "Ghost was here.",
            in: archived,
            store: store
        )
        try await store.archive(archived.id, reason: "Synthetic")

        let all = try await store.entities()
        #expect(all.map(\.name) == ["Toby Ord", "Synthetic Labs"])
        #expect(all.map(\.noteCount) == [2, 1])
        #expect(try await store.entities(kind: .organization).map(\.name) == ["Synthetic Labs"])
        #expect(try await store.entities(matching: "ORD").map(\.name) == ["Toby Ord"])

        let top = try #require(all.first)
        let mentions = try await store.entityMentions(top.id)
        #expect(Set(mentions.map(\.noteID)) == [first.id, second.id])
        #expect(mentions.allSatisfy { $0.predicate == .mentions && $0.other == nil })
        #expect(EntitiesView.byNote(mentions).count == 2)
        #expect(DocumentStore.entityName("toby ord", in: []) == "Toby Ord")
    }

    @Test func capturedAuthorsSurviveTheNoteChangingAndCreatorTextIsNotExtracted() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = IngestionEngine(
            store: store, fetcher: EssayFetcher(), youtube: CreatorVideoFixture(),
            settings: { CaptureSettings(summarize: false, previews: false) }
        )
        _ = try await engine.enqueue(
            "https://www.youtube.com/watch?v=abcdefghijk", summarizeLink: false
        )
        try await engine.run()
        var video = try #require(await store.documents().first)
        let work = try #require(await store.nextGraphWork())
        #expect(!work.chunk.extractionText.contains("next cohort"))
        #expect(work.chunk.extractionText.contains("shared plans"))
        #expect(try await store.entities(kind: .person).map(\.name) == ["Synthetic channel"])

        // Replaced text, as when a saved link becomes its summary, keeps its author.
        video.markdown = "A short synthetic summary."
        _ = try await store.save(video)
        while try await store.nextGraphWork() != nil {}
        let authors = try await store.entities(kind: .person)
        #expect(authors.map(\.name) == ["Synthetic channel"])
        let author = try #require(authors.first)
        let mention = try #require(await store.entityMentions(author.id).first)
        #expect(mention.predicate == .authoredBy)
        #expect(EntitiesView.relation(mention) == "Author")
    }

    @Test @MainActor func entitiesPageRenders() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(name: "Swarm notes", markdown: "Notes."))
        try await mention(
            "Toby Ord",
            kind: .person,
            quote: "Toby Ord wrote about swarm scaling.",
            in: note,
            store: store
        )
        try await mention(
            "Synthetic Labs",
            kind: .organization,
            quote: "Synthetic Labs built the benchmark.",
            in: note,
            store: store
        )
        for dark in [false, true] {
            let view = NSHostingView(rootView: EntitiesView(store: store, open: { _ in })
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
            let window = NSWindow(
                contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 900)
            if let path = ProcessInfo.processInfo.environment["GLEANARY_ENTITIES_SCREENSHOT"] {
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path + (dark ? ".dark.png" : ".light.png")))
            }
        }
    }

    @Test func theAssistantReadsEntitiesByHandle() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(name: "Swarm notes", markdown: "Notes."))
        try await mention(
            "Toby Ord",
            kind: .person,
            quote: "Toby Ord wrote about swarms.",
            in: note,
            store: store
        )
        let toolbox = AgentToolbox(store: store, search: SearchEngine(store: store))
        let listed = await toolbox.run(call("list_entities", ["kind": "person", "query": "ord"]))
        #expect(listed.contains(#""entity":"e1""#))
        #expect(listed.contains("Toby Ord"))
        let read = await toolbox.run(call("get_entity", ["entity": "e1"]))
        #expect(read.contains(#""item":"i1""#))
        #expect(read.contains("Toby Ord wrote about swarms."))
        let unknown = await toolbox.run(call("get_entity", ["entity": "e9"]))
        #expect(unknown.contains("Unknown entity handle"))
    }

    @Test func askingInChatReadsOnlyTheChosenItems() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = try await store.save(MarkdownDocument(
            name: "Orion paper", markdown: "Orion uses retrieval. More detail follows here."
        ))
        let other = try await store.save(MarkdownDocument(
            name: "Other paper", markdown: "Orion uses retrieval. Unchosen."
        ))
        let task = try await store.beginConversation("find entities", owner: .assistant)
        let coordinator = AgentCoordinator(store: store, graphProvider: OrionGraphProvider())
        let report = try await coordinator.findEntities([chosen.id], taskID: task, changed: {})
        #expect(report.read == 1)
        #expect(report.unavailable == 0)
        let found = try await store.entities(in: [chosen.id])
        #expect(Set(found.map(\.name)) == ["Orion", "retrieval"])
        #expect(try await store.graphProgress([other.id]).ready == 0)
        // Already read at this version, so asking again reads nothing new.
        #expect(try await store.prepareGraphJobs([chosen.id]) == 0)
    }

    @Test func findEntitiesValidatesItsScopeAndReportsWhatItFound() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(name: "Swarm notes", markdown: "Notes."))
        let toolbox = AgentToolbox(store: store, search: SearchEngine(store: store))
        _ = await toolbox.describe([note.id])
        let finder = ConversationEntityFinder { ids in
            try await mention(
                "Toby Ord",
                kind: .person,
                quote: "Toby Ord wrote it.",
                in: #require(await store.document(id: ids[0])),
                store: store
            )
            return ConversationEntityFinder.Report(read: ids.count, unavailable: 0, failed: 0)
        }
        let badScope = try await finder.run(call("find_entities", [
            "scope": "galaxy", "items": [], "category_code": "", "limit": 5,
        ]), toolbox: toolbox)
        #expect(badScope.contains("Scope is items, category, recent or all."))
        let result = try await finder.run(call("find_entities", [
            "scope": "items", "items": ["i1"], "category_code": "", "limit": 5,
        ]), toolbox: toolbox)
        #expect(result.contains(#""read":1"#))
        #expect(result.contains("Toby Ord"))
        let again = try await finder.run(call("find_entities", [
            "scope": "recent", "items": [], "category_code": "", "limit": 5,
        ]), toolbox: toolbox)
        #expect(again.contains("already being found"))
    }

    @Test func renamingHidingAndMergingFollowLaterExtraction() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.save(MarkdownDocument(name: "First", markdown: "Notes."))
        let second = try await store.save(MarkdownDocument(name: "Second", markdown: "Notes."))
        try await mention(
            "OpenAI",
            kind: .organization,
            quote: "OpenAI shipped it.",
            in: first,
            store: store
        )
        try await mention(
            "OpenAI, Inc.",
            kind: .organization,
            quote: "OpenAI, Inc. said so.",
            in: second,
            store: store
        )
        try await mention(
            "Open AI",
            kind: .organization,
            quote: "Open AI agreed.",
            in: second,
            store: store
        )
        let ids = try await Dictionary(uniqueKeysWithValues: store.entities()
            .map { ($0.name, $0.id) })
        let openAI = try #require(ids["OpenAI"])
        let incorporated = try #require(ids["OpenAI, Inc."])
        let spaced = try #require(ids["Open AI"])

        // A chain folds into one: Open AI into OpenAI, Inc., then that into OpenAI.
        try await store.mergeEntity(spaced, into: incorporated)
        try await store.mergeEntity(incorporated, into: openAI)
        var listed = try await store.entities()
        #expect(listed.map(\.name) == ["OpenAI"])
        #expect(listed.first?.noteCount == 2)
        #expect(Set(listed.first?.aliases.map(\.id) ?? []) == [incorporated, spaced])
        #expect(try await store.entityMentions(openAI).count == 3)

        // A later mention of a merged name still counts toward the one it was merged into.
        let third = try await store.save(MarkdownDocument(name: "Third", markdown: "Notes."))
        try await mention(
            "OpenAI, Inc.",
            kind: .organization,
            quote: "OpenAI, Inc. again.",
            in: third,
            store: store
        )
        #expect(try await store.entities().first?.noteCount == 3)

        try await store.renameEntity(openAI, to: "OpenAI (company)")
        listed = try await store.entities(matching: "company")
        #expect(listed.map(\.name) == ["OpenAI (company)"])
        #expect(listed.first?.renamed == true)
        try await store.renameEntity(openAI, to: nil)
        #expect(try await store.entities().first?.name == "OpenAI")

        try await store.unmergeEntity(spaced)
        #expect(try await Set(store.entities().map(\.name)) == ["OpenAI", "Open AI"])

        try await store.hideEntity(spaced, hidden: true)
        #expect(try await store.entities().map(\.name) == ["OpenAI"])
        #expect(try await store.entities(hidden: true).map(\.name) == ["Open AI"])
        let toolbox = AgentToolbox(store: store, search: SearchEngine(store: store))
        let listedToAssistant = await toolbox.run(call(
            "list_entities",
            ["kind": "any", "query": ""]
        ))
        #expect(!listedToAssistant.contains("Open AI\""))
    }

    @Test func chatGPTSchemasDecodeIntoTheSharedProposals() throws {
        for schema in [
            GraphJSONSchema.graph(maxEntities: 5, maxRelations: 4),
            GraphJSONSchema.candidates(maxEntities: 20),
            GraphJSONSchema.relations(maxRelations: 20),
            GraphJSONSchema.mindMap(maxNodes: 24),
        ] {
            #expect(JSONSerialization.isValidJSONObject(schema))
            #expect(schema["additionalProperties"] as? Bool == false)
        }
        let response = """
        {"entities":[{"name":"Toby Ord","kind":"person","quote":"Toby Ord wrote it."}],
         "relations":[{"source":"Orion","target":"retrieval","predicate":"partOf","quote":"q"}]}
        """
        let proposal = try JSONDecoder().decode(GraphProposal.self, from: Data(response.utf8))
        #expect(proposal.entities.first?.kind == .person)
        #expect(proposal.relations.first?.predicate == .partOf)
        let prompt = GraphPrompts.extraction(overview: true)
        #expect(prompt.contains("article, transcript"))
        #expect(prompt.contains("people the source is by, about, or quotes"))
        #expect(!prompt.contains("citation authors"))
    }

    @Test func aChatRequestFinishesEachNoteBeforeTheNext() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = try await store.save(MarkdownDocument(
            name: "Alpha", markdown: "Alpha. Orion uses retrieval."
        ))
        let beta = try await store.save(MarkdownDocument(
            name: "Beta", markdown: "Beta. Orion uses retrieval."
        ))
        try await store.prepareGraphJobs([alpha.id, beta.id])
        let provider = OrderRecordingProvider()
        try await GraphExtractor(store: store, provider: provider)
            .run(only: [alpha.id, beta.id]) {}
        let steps = await provider.steps
        #expect(
            steps == ["extract Alpha", "curate Alpha", "extract Beta", "curate Beta"],
            "\(steps)"
        )
        #expect(try await store.graphProgress([alpha.id, beta.id]).ready == 2)
    }
}
