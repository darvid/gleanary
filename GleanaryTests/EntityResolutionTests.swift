import Foundation
@testable import Gleanary
import GRDB
import Testing

/// Says pairs are the same unless either side is in `different`.
private struct FakeMatchJudge: EntityMatchJudging {
    let different: Set<String>
    func judgeMatches(_ items: [EntityMatchJudgement.Item]) async throws
        -> [Int: EntityMatchJudgement.Verdict]
    {
        Dictionary(uniqueKeysWithValues: items.map { item in
            let same = !different.contains(item.left) && !different.contains(item.right)
            return (
                item.number,
                .init(same: same, reason: same ? "Same thing" : "Different things")
            )
        })
    }
}

@Suite(.serialized) struct EntityResolutionTests {
    private func store() async throws -> (URL, DocumentStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        return (root, store)
    }

    /// Records that a note mentions an entity, as extraction would.
    private func mention(
        _ name: String, kind: GraphNode.Kind, quote: String, in note: MarkdownDocument,
        store: DocumentStore, raw: Bool = false
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
            // Raw keeps the label as given, the way names were stored before people were put
            // in reading order.
            target: raw
                ? GraphNode(
                    id: "entity:" + ContentHash
                        .of([kind.rawValue, name].joined(separator: "\u{0}")),
                    kind: kind, label: name
                )
                : GraphNode.entity(name, kind: kind, noteID: note.id),
            predicate: .mentions, quote: quote, citation: nil, offset: 0, origin: "model"
        )
        try await store.readyDatabase().write { db in
            try DocumentStore.insertGraphClaim(claim, job: job, chunk: 0, in: db)
        }
    }

    @Test func matchKeysCollapseWritingVariants() {
        #expect(EntityKey.of("few-shot prompting") == EntityKey.of("few shot prompts"))
        #expect(EntityKey.of("Fine-Tuning") == EntityKey.of("fine tuning"))
        #expect(EntityKey.of("the transformer") == EntityKey.of("transformers"))
        #expect(EntityKey.of("AI agents") != EntityKey.of("agent loops"))
        #expect(EntityKey.of("Large Language Models (LLMs)") == EntityKey
            .of("large language model"))
        #expect(EntityKey.of("recursive self-improvement (RSI)")
            == EntityKey.of("recursive self-improvement"))
        #expect(EntityKey.initials("retrieval-augmented generation") == "rag")
        #expect(EntityKey.initials("reinforcement learning from human feedback") == "rlhf")
        #expect(EntityKey.abbreviation("LLMs") == "llm")
        #expect(EntityKey.abbreviation("large language models") == nil)
        let found = EntityKey.parentheticalAbbreviations(
            in: "We use retrieval-augmented generation (RAG) for answers."
        )
        #expect(found.first?.short == "rag")
        #expect(EntityKey.of(found.first?.long ?? "") == EntityKey
            .of("retrieval-augmented generation"))
    }

    @Test func sameKeyNamesMergeButPeopleAndKeptApartOnesDoNot() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try await store.save(MarkdownDocument(name: "One", markdown: "Notes."))
        let two = try await store.save(MarkdownDocument(name: "Two", markdown: "Notes."))
        try await mention(
            "few-shot prompting",
            kind: .concept,
            quote: "few-shot prompting helps",
            in: one,
            store: store
        )
        try await mention(
            "few-shot prompting",
            kind: .concept,
            quote: "few-shot prompting again",
            in: two,
            store: store
        )
        try await mention(
            "few shot prompts",
            kind: .concept,
            quote: "few shot prompts work",
            in: two,
            store: store
        )
        try await mention("Alex Kim", kind: .person, quote: "Alex Kim said", in: one, store: store)
        try await mention(
            "alex kim's",
            kind: .person,
            quote: "alex kim's view",
            in: two,
            store: store
        )
        let resolver = EntityResolver(store: store)
        #expect(try await resolver.autoMerge() == 1)
        let concepts = try await store.entities(kind: .concept)
        #expect(concepts.map(\.name) == ["few-shot prompting"])
        #expect(concepts.first?.noteCount == 2)
        #expect(concepts.first?.aliases.count == 1)
        #expect(try await store.entities(kind: .person).count == 2)

        // Unmerging keeps them apart from then on.
        let alias = try #require(concepts.first?.aliases.first)
        try await store.unmergeEntity(alias.id)
        #expect(try await resolver.autoMerge() == 0)
        #expect(try await store.entities(kind: .concept).count == 2)
    }

    @Test func likelyDuplicatesAreJudgedAndWaitForReview() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(name: "Note", markdown: "Notes."))
        try await mention(
            "retrieval-augmented generation",
            kind: .concept,
            quote: "We use retrieval-augmented generation (RAG) here.",
            in: note,
            store: store
        )
        try await mention(
            "RAG",
            kind: .concept,
            quote: "RAG answers questions.",
            in: note,
            store: store
        )
        try await mention(
            "evals platform",
            kind: .tool,
            quote: "the evals platform runs",
            in: note,
            store: store
        )
        try await mention(
            "evaluation platform",
            kind: .tool,
            quote: "an evaluation platform",
            in: note,
            store: store
        )
        try await mention(
            "agent loops",
            kind: .concept,
            quote: "agent loops repeat",
            in: note,
            store: store
        )
        try await mention(
            "agent loop design",
            kind: .concept,
            quote: "agent loop design matters",
            in: note,
            store: store
        )
        let resolver = EntityResolver(
            store: store, judge: FakeMatchJudge(different: ["Agent Loop Design"])
        )
        let found = try await resolver.findDuplicates()
        let suggestions = try await store.entitySuggestions()
        #expect(
            found == 2,
            "\(suggestions.map { "\($0.left.name) / \($0.right.name): \($0.reason)" })"
        )
        let names = Set(suggestions.map { Set([$0.left.name, $0.right.name]) })
        #expect(names.contains(["retrieval-augmented generation", "RAG"]))
        #expect(names.contains(["evals platform", "evaluation platform"]))
        // A pair judged different, and pairs already proposed, are not asked about again.
        #expect(try await resolver.findDuplicates() == 0)

        let rag = try #require(suggestions
            .first { Set([$0.left.name, $0.right.name]).contains("RAG") })
        try await store.resolveEntitySuggestion(rag, merge: true)
        let other = try #require(suggestions.first { $0.id != rag.id })
        try await store.resolveEntitySuggestion(other, merge: false)
        #expect(try await store.entitySuggestions().isEmpty)
        let concepts = try await store.entities(kind: .concept).map(\.name)
        #expect(!concepts.contains("RAG"))
        #expect(try await store.entities(kind: .tool).count == 2)
    }

    @Test func peopleMergeOnlyWhenTheFullNameMatchesInEitherOrder() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try await store.save(MarkdownDocument(name: "One", markdown: "Notes."))
        let two = try await store.save(MarkdownDocument(name: "Two", markdown: "Notes."))
        // Inserted as written, as older libraries stored bylines before names were put in order.
        try await mention(
            "barnes, elizabeth",
            kind: .person,
            quote: "Barnes, Elizabeth",
            in: one,
            store: store,
            raw: true
        )
        try await mention(
            "Elizabeth Barnes",
            kind: .person,
            quote: "Elizabeth Barnes said",
            in: two,
            store: store
        )
        try await mention(
            "Elizabeth",
            kind: .person,
            quote: "Elizabeth asked",
            in: two,
            store: store
        )
        #expect(try await EntityResolver(store: store).autoMerge() == 1)
        let people = try await store.entities(kind: .person)
        #expect(Set(people.map(\.name)) == ["Elizabeth Barnes", "Elizabeth"])
        #expect(people.first { $0.name == "Elizabeth Barnes" }?.noteCount == 2)
    }

    @Test func mergeAllHandlesOverlappingPairs() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try await store.save(MarkdownDocument(name: "One", markdown: "Notes."))
        let two = try await store.save(MarkdownDocument(name: "Two", markdown: "Notes."))
        try await mention(
            "large language model",
            kind: .concept,
            quote: "a large language model",
            in: one,
            store: store
        )
        try await mention(
            "large language model",
            kind: .concept,
            quote: "large language model again",
            in: two,
            store: store
        )
        try await mention("LLMs", kind: .concept, quote: "LLMs answer", in: one, store: store)
        try await mention(
            "foundation model",
            kind: .concept,
            quote: "a foundation model",
            in: two,
            store: store
        )
        let ids = try await Dictionary(uniqueKeysWithValues: store.entities()
            .map { ($0.name, $0.id) })
        let large = try #require(ids["large language model"])
        let llms = try #require(ids["LLMs"])
        let foundation = try #require(ids["foundation model"])
        // Three pairs among three names: once two merge, the third is already settled.
        try await store.recordEntityPairs([
            (llms, large, "Abbreviation", "pending"),
            (foundation, large, "Same thing", "pending"),
            (llms, foundation, "Same thing", "pending"),
        ])
        #expect(try await store.entitySuggestions().count == 3)
        #expect(try await store.mergeAllEntitySuggestions() == 2)
        let remaining = try await store.entities(kind: .concept)
        #expect(remaining.map(\.name) == ["large language model"])
        #expect(Set(remaining.first?.aliases.map(\.id) ?? []) == [llms, foundation])
        #expect(try await store.entitySuggestions().isEmpty)
    }

    @Test func sortingAndPagingCoverEveryEntityOnce() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await store.save(MarkdownDocument(name: "First", markdown: "Notes."))
        let second = try await store.save(MarkdownDocument(name: "Second", markdown: "Notes."))
        for index in 0 ..< 25 {
            try await mention(
                "Concept \(String(format: "%02d", index))",
                kind: .concept,
                quote: "Concept \(String(format: "%02d", index)) here",
                in: first,
                store: store
            )
        }
        try await mention(
            "Concept 07",
            kind: .concept,
            quote: "Concept 07 again",
            in: second,
            store: store
        )
        try await mention(
            "Ada Byron",
            kind: .person,
            quote: "Ada Byron wrote",
            in: second,
            store: store
        )
        #expect(try await store.entityCount() == 26)
        #expect(try await store.entities(sort: .mentions, limit: 1).first?.name == "Concept 07")
        #expect(try await store.entities(sort: .name, limit: 1).first?.name == "Ada Byron")
        #expect(try await store.entities(sort: .kind, limit: 1).first?.name == "Ada Byron")
        let recent = try await store.entities(sort: .recent, limit: 1).first?.name
        #expect(["Concept 07", "Ada Byron"].contains(recent ?? ""))
        var seen: [String] = []
        var offset = 0
        while true {
            let page = try await store.entities(sort: .name, offset: offset, limit: 10)
            if page.isEmpty {
                break
            }
            seen += page.map(\.id)
            offset += page.count
        }
        #expect(seen.count == 26)
        #expect(Set(seen).count == 26)
    }

    @Test func thousandsOfEntitiesPageQuickly() async throws {
        let (root, store) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        var notes: [MarkdownDocument] = []
        for index in 0 ..< 400 {
            try await notes.append(store.save(MarkdownDocument(
                name: "Note \(index)",
                markdown: "Notes."
            )))
        }
        let kinds: [GraphNode.Kind] = [.concept, .person, .organization, .tool]
        let saved = notes
        try await store.readyDatabase().write { db in
            for index in 0 ..< 5000 {
                let note = saved[index % saved.count]
                let job = GraphJob(
                    noteID: note.id, revision: note.revision ?? UUID(), token: UUID(),
                    name: note.name, state: "running", completed: 0, total: 1, error: nil
                )
                let name = "Synthetic entity \(index)"
                for copy in 0 ..< 3 {
                    let target = saved[(index + copy * 37) % saved.count]
                    let claim = GraphClaim(
                        source: GraphNode(
                            id: GraphNode.documentID(target.id), kind: .document,
                            label: target.name, noteID: target.id
                        ),
                        target: GraphNode.entity(name, kind: kinds[index % 4], noteID: target.id),
                        predicate: .mentions, quote: "\(name) appears", citation: nil,
                        offset: copy, origin: "model"
                    )
                    let targetJob = GraphJob(
                        noteID: target.id, revision: target.revision ?? UUID(), token: job.token,
                        name: target.name, state: "running", completed: 0, total: 1, error: nil
                    )
                    try DocumentStore.insertGraphClaim(claim, job: targetJob, chunk: 0, in: db)
                }
            }
        }
        let clock = ContinuousClock()
        var start = clock.now
        let count = try await store.entityCount()
        let countTime = (clock.now - start) / .seconds(1)
        var timings: [String] = []
        for sort in EntitySort.allCases {
            start = clock.now
            let page = try await store.entities(sort: sort, offset: 2000, limit: 200)
            timings.append(String(
                format: "%@ %.2fs (%d rows)",
                sort.rawValue,
                (clock.now - start) / .seconds(1),
                page.count
            ))
        }
        start = clock.now
        try await EntityResolver(store: store).autoMerge()
        let mergeTime = (clock.now - start) / .seconds(1)
        start = clock.now
        try await EntityResolver(store: store).findDuplicates()
        let duplicateTime = (clock.now - start) / .seconds(1)
        print(String(format: "SCALE %d entities: count %.2fs; ", count, countTime)
            + timings.joined(separator: "; ")
            + String(format: "; auto-merge %.2fs; find duplicates %.2fs", mergeTime, duplicateTime))
        #expect(count == 5000)
    }
}
