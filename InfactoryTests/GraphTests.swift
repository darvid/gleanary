import Foundation
import FoundationModels
import GRDB
@testable import Infactory
import Testing

@Test func plainLanguagePolicyPreservesTaskInstructions() {
    let task = "Copy the quotation exactly. Return JSON with evidenceID E3 and predicate partOf."
    let instructions = AIProsePolicy.instructions(for: task)
    #expect(instructions == task + "\n\n" + AIProsePolicy.guidance)
    #expect(instructions.contains("These rules apply only to prose you compose."))
    #expect(instructions.contains("Follow the task's output schema and tighter length limits."))
}

@Test func plainLanguagePolicyCoversMindMapProseAndAccuracy() {
    let instructions = AIProsePolicy.instructions(for: "Build a mind map from supplied evidence.")
    #expect(instructions.contains("Titles and summaries are plain text, not Markdown."))
    #expect(instructions.contains("Preserve uncertainty, limitations, and scope;"))
    #expect(instructions.contains("Never invent definitions or facts"))
    #expect(instructions.contains("at most 30 words per sentence."))
}

@Test func plainLanguagePolicyInvalidatesStoredCurationButNotSourceExtraction() {
    #expect(GraphExtractor.curationVersion.hasSuffix("/" + AIProsePolicy.version))
    #expect(GraphExtractor.version.contains(AIProsePolicy.version))
    #expect(!GraphExtractor.candidateVersion.contains(AIProsePolicy.version))
}

struct UnavailableGraphProvider: GraphExtracting {
    func extract(_: String) throws -> GraphProposal {
        throw GraphError.unavailable
    }
}

private struct SyntheticGraphProvider: GraphExtracting {
    func extract(_ text: String) -> GraphProposal {
        let quote = "Orion uses retrieval."
        guard text.contains(quote) else { return GraphProposal(entities: [], relations: []) }
        return GraphProposal(entities: [
            ProposedEntity(name: "Orion", kind: .tool, quote: quote),
            ProposedEntity(name: "retrieval", kind: .concept, quote: quote),
        ], relations: [ProposedRelation(
            source: "Orion",
            target: "retrieval",
            predicate: .uses,
            quote: quote
        )])
    }
}

private struct SlowSyntheticGraphProvider: GraphExtracting {
    func extract(_ text: String) throws -> GraphProposal {
        Thread.sleep(forTimeInterval: 0.03)
        return SyntheticGraphProvider().extract(text)
    }
}

private struct InvalidThenValidGraphProvider: GraphExtracting {
    func extract(_ text: String) -> GraphProposal {
        if text.contains("Orion uses retrieval.") {
            return SyntheticGraphProvider().extract(text)
        }
        return GraphProposal(
            entities: [ProposedEntity(name: "Ghost", kind: .concept, quote: "Invented quote")],
            relations: []
        )
    }
}

private struct CuratingGraphProvider: GraphExtracting {
    func extract(_: String) -> GraphProposal {
        GraphProposal(entities: [
            ProposedEntity(
                name: "Harness design",
                kind: .concept,
                quote: "Harness design uses context management."
            ),
            ProposedEntity(
                name: "context management",
                kind: .concept,
                quote: "Harness design uses context management."
            ),
            ProposedEntity(
                name: "incidental detail",
                kind: .concept,
                quote: "An incidental detail appears in one paragraph."
            ),
        ], relations: [ProposedRelation(
            source: "Harness design",
            target: "context management",
            predicate: .uses,
            quote: "Harness design uses context management."
        )])
    }

    func curate(_: GraphCurationWork) -> GraphProposal {
        GraphProposal(entities: [
            ProposedEntity(
                name: "Harness design",
                kind: .concept,
                quote: "Harness design uses context management."
            ),
            ProposedEntity(
                name: "context management",
                kind: .concept,
                quote: "Harness design uses context management."
            ),
        ], relations: [ProposedRelation(
            source: "Harness design",
            target: "context management",
            predicate: .uses,
            quote: "Harness design uses context management."
        )])
    }

    func mindMap(
        _: GraphCurationWork,
        entities _: [ProposedEntity]
    ) -> MindMapProposal {
        MindMapProposal(nodes: [
            ProposedMindMapNode(
                key: "root",
                parentKey: "",
                title: "Harness design",
                summary: "The paper studies how harness design shapes coding agents.",
                role: .subject,
                evidenceID: "E1"
            ),
            ProposedMindMapNode(
                key: "context",
                parentKey: "root",
                title: "Context management",
                summary: "Context management is one mechanism used by the harness.",
                role: .mechanism,
                evidenceID: "E1"
            ),
        ])
    }
}

private struct GraphFixture {
    let directory: URL
    let store: DocumentStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    }

    func clean() {
        try? FileManager.default.removeItem(at: directory)
    }

    func count(_ table: String) throws -> Int {
        try DatabaseQueue(path: store.url.path).read { try Int.fetchOne(
            $0,
            sql: "SELECT COUNT(*) FROM \(table)"
        ) ?? 0 }
    }

    func run(provider: any GraphExtracting = SyntheticGraphProvider()) async throws {
        try await GraphExtractor(store: store, provider: provider).run {}
    }

    func capture(_ text: String, url: URL, authors: [String] = []) async throws -> UUID {
        _ = try await store.enqueueCapture(CaptureRequest(
            url: url,
            identity: "url:" + CaptureRequest.canonicalURL(url),
            label: "Synthetic source"
        ))
        let job = try #require(await store.claimCapture())
        return try await store.publishCapture(
            job,
            document: CapturedDocument(
                title: "Synthetic source",
                authors: authors,
                sourceURL: url,
                coverage: .document,
                blocks: [ContentBlock(
                    kind: .paragraph,
                    markdown: text,
                    text: text,
                    page: 7
                )]
            ),
            artifacts: []
        )
    }
}

@Test func graphSchemaConstrainsNativeGenerationWithoutMacros() throws {
    let schema = try GraphProposal.schema()
    let data = try JSONEncoder().encode(schema)
    #expect(!data.isEmpty)
    let decoded = try JSONDecoder().decode(GenerationSchema.self, from: data)
    #expect(!decoded.debugDescription.isEmpty)
}

@Test @MainActor func initialGraphBuildPublishesOneCompleteSnapshot() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Synthetic",
        markdown: "Orion uses retrieval."
    )])
    let model = KnowledgeGraphModel(store: fixture.store, provider: SlowSyntheticGraphProvider())
    try await model.load()
    #expect(model.preparingInitialGraph)
    #expect(model.snapshot.nodes.isEmpty)
    await model.extractionTask?.value
    await model.layoutTask?.value
    #expect(!model.preparingInitialGraph)
    #expect(model.snapshot.nodes.map(\.label).sorted() == ["orion", "retrieval"])
    #expect(model.positions.keys.count == 2)
}

@Test func readyGraphRemainsVisibleWhileAnotherDocumentIsCurated() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Existing",
        markdown: "Orion uses retrieval."
    )])
    try await fixture.run()
    _ = try await fixture.store.save(MarkdownDocument(
        name: "New paper",
        markdown: "Harness design uses context management."
    ))
    let work = try #require(await fixture.store.nextGraphWork())
    let proposal = CuratingGraphProvider().extract(work.chunk.text)
    let candidates = GraphValidation.claims(proposal, work: work)
    try await fixture.store.publishGraphCandidates(work, claims: candidates)

    let snapshot = try await fixture.store.graphSnapshot()
    #expect(Set(snapshot.nodes.map(\.label)) == ["orion", "retrieval"])
    #expect(!snapshot.nodes.contains { $0.label == "harness design" })
}

@Test func mindMapValidationTurnsModelChainsIntoStableBranches() {
    let evidence =
        [
            GraphSegment(
                text: "A harness uses planning, reports measured findings, and has stated limitations."
            ),
        ]
    let proposal = MindMapProposal(nodes: [
        ProposedMindMapNode(
            key: "root",
            parentKey: "",
            title: "Harness study",
            summary: "The source studies harness design.",
            role: .subject,
            evidenceID: "E1"
        ),
        ProposedMindMapNode(
            key: "planning",
            parentKey: "root",
            title: "Planning",
            summary: "Planning structures the work.",
            role: .mechanism,
            evidenceID: "E1"
        ),
        ProposedMindMapNode(
            key: "finding",
            parentKey: "planning",
            title: "Measured result",
            summary: "The evaluation reports a measured result.",
            role: .finding,
            evidenceID: "E1"
        ),
        ProposedMindMapNode(
            key: "limit",
            parentKey: "finding",
            title: "Boundary",
            summary: "The source states a limitation.",
            role: .limitation,
            evidenceID: "E1"
        ),
    ])
    let claims = GraphValidation.mindMapClaims(proposal, evidence: evidence)
    #expect(claims.map(\.title) == [
        "Harness study", "How it works", "Planning", "Key findings", "Measured result",
        "Limitations", "Boundary",
    ])
    #expect(claims.first { $0.title == "Planning" }?.parentKey == "branch-mechanism")
    #expect(claims.first { $0.title == "How it works" }?.summary == "1 topic: Planning.")
    #expect(claims.first { $0.title == "Key findings" }?.summary == "1 topic: Measured result.")
}

@Test func relationEvidenceKeepsNearbyPairsWhenAParagraphHasDistantEntities() {
    let text = "coding harness uses a planning scaffold. " +
        String(repeating: "background ", count: 70) + "context management"
    let excerpts = DocumentStore.relationEvidence(
        in: [GraphChunk(segments: [GraphSegment(text: text)])],
        candidateNames: ["coding harness", "planning scaffold", "context management"],
        excluding: []
    )
    #expect(excerpts.contains {
        $0.text.localizedCaseInsensitiveContains("coding harness") &&
            $0.text.localizedCaseInsensitiveContains("planning scaffold")
    })
}

@Test func rawCandidatesRemainHiddenUntilDocumentCurationCompletes() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Synthetic paper",
        markdown: "Harness design uses context management."
    )])
    let work = try #require(await fixture.store.nextGraphWork())
    let proposal = CuratingGraphProvider().extract(work.chunk.text)
    let candidates = GraphValidation.claims(proposal, work: work)
    try await fixture.store.publishGraphCandidates(work, claims: candidates)
    #expect(try await fixture.store.graphJobs().first?.state == "curating")
    #expect(try await fixture.store.graphSnapshot().nodes.isEmpty)
    let curation = try #require(await fixture.store.nextGraphCurationWork())
    #expect(curation.relations.count == 1)
    #expect(curation.relations.first?.predicate == .uses)
    #expect(curation.relationExcerpts.contains {
        $0.localizedCaseInsensitiveContains("Harness design uses context management")
    })
}

@Test func documentCurationPublishesOnlySelectedCentralEntities() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Synthetic paper",
        markdown: "Harness design uses context management. An incidental detail appears in one paragraph."
    )])
    try await fixture.run(provider: CuratingGraphProvider())
    let job = try #require(try await fixture.store.graphJobs().first)
    #expect(job.state == "ready")
    let snapshot = try await fixture.store.graphSnapshot()
    #expect(Set(snapshot.nodes.map(\.label)) == ["harness design", "context management"])
    #expect(snapshot.edges.count == 1)
    #expect(snapshot.edges.first?.predicate == .uses)
    let map = try await fixture.store.mindMapSnapshot()
    #expect(map.nodes.map(\.title) == ["Harness design", "Context management"])
    try await fixture.store.setMindMapCollapsed(
        map.nodes[0].id,
        noteID: #require(map.noteID),
        collapsed: true
    )
    #expect(try await fixture.store.mindMapSnapshot().nodes[0].collapsed)
    #expect(try await fixture.store.mindMapEvidence(nodeID: map.nodes[1].id).count == 1)
}

@Test func mindMapSummariesExposeEveryReadySource() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [
        MarkdownDocument(name: "First source", markdown: "Harness design uses context management."),
        MarkdownDocument(
            name: "Second source",
            markdown: "Harness design uses context management."
        ),
    ])
    try await fixture.run(provider: CuratingGraphProvider())
    let summaries = try await fixture.store.mindMapSummaries()
    #expect(Set(summaries.map(\.title)) == ["First source", "Second source"])
    for summary in summaries {
        #expect(try await fixture.store.mindMapSnapshot(noteID: summary.id).title == summary.title)
    }
}

@Test @MainActor func aNewMindMapDoesNotReplaceTheSelectedSource() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "First source",
        markdown: "Harness design uses context management."
    )])
    try await fixture.run(provider: CuratingGraphProvider())
    let model = KnowledgeGraphModel(store: fixture.store, provider: CuratingGraphProvider())
    try await model.load()
    await model.extractionTask?.value
    let selected = try #require(model.mindMap.noteID)

    _ = try await fixture.store.save(MarkdownDocument(
        name: "Second source",
        markdown: "Harness design uses context management."
    ))
    try await fixture.run(provider: CuratingGraphProvider())
    await model.refresh()

    #expect(model.mindMaps.count == 2)
    #expect(model.mindMap.noteID == selected)
    #expect(model.mindMap.title == "First source")
}

@Test @MainActor func firstCaptureAfterEmptyLaunchStaysHiddenUntilComplete() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [])
    let model = KnowledgeGraphModel(store: fixture.store, provider: SlowSyntheticGraphProvider())
    try await model.load()
    await model.extractionTask?.value
    #expect(!model.preparingInitialGraph)
    #expect(model.snapshot.nodes.isEmpty)

    _ = try await fixture.store.save(MarkdownDocument(
        name: "Synthetic",
        markdown: "Orion uses retrieval."
    ))
    await model.refresh()
    #expect(model.preparingInitialGraph)
    #expect(model.snapshot.nodes.isEmpty)
    model.startExtraction()
    await model.extractionTask?.value
    await model.layoutTask?.value
    #expect(!model.preparingInitialGraph)
    #expect(model.snapshot.nodes.map(\.label).sorted() == ["orion", "retrieval"])
}

@Test func invalidWindowDoesNotStopRemainingDocumentExtraction() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Long synthetic note",
        markdown: String(repeating: "context ", count: 1000) + "\n\nOrion uses retrieval."
    )])
    try await fixture.run(provider: InvalidThenValidGraphProvider())
    let job = try #require(try await fixture.store.graphJobs().first)
    #expect(job.state == "ready")
    #expect(job.completed == job.total)
    #expect(job.total >= 2)
    let snapshot = try await fixture.store.graphSnapshot()
    #expect(snapshot.nodes.map(\.label).contains("orion"))
    #expect(snapshot.nodes.map(\.label).contains("retrieval"))
    #expect(!snapshot.nodes.map(\.label).contains("ghost"))
}

@Test func graphBackfillAndStableDocumentIdentity() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Synthetic",
        markdown: "Orion uses retrieval."
    )])
    try await DatabaseQueue(path: fixture.store.url.path).write { db in
        try db.execute(sql: "DELETE FROM graph_jobs; DELETE FROM graph_nodes;")
    }
    try await fixture.store.recoverGraph()
    #expect(try await fixture.store.graphSnapshot().nodes.isEmpty)
    try await fixture.run()
    try await fixture.store.recoverGraph()
    #expect(try await fixture.store.graphJobs().first?.state == "ready")
    #expect(try fixture.count("graph_nodes") == 3)
    #expect(try fixture.count("graph_edges") == 3)
    let visible = try await fixture.store.graphSnapshot()
    #expect(visible.nodes.count == 2)
    #expect(visible.nodes.allSatisfy { $0.kind != .document })
    #expect(visible.edges.count == 1)
}

@Test func graphClaimsCarrySourceEvidenceAndConservativeIdentities() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    let notes = try await fixture.store.open(seed: [
        MarkdownDocument(name: "First", markdown: "Orion uses retrieval."),
        MarkdownDocument(name: "Second", markdown: "Orion uses retrieval."),
    ])
    try await fixture.run()
    let first = try #require(notes.first)
    let second = try #require(notes.last)
    let orion = GraphNode.entity("Orion", kind: .tool, noteID: first.id)
    let snapshot = try await fixture.store.graphSnapshot(focus: orion.id)
    #expect(snapshot.nodes.filter { $0.kind == .concept }.count == 1)
    #expect(snapshot.nodes.filter { $0.kind == .tool }.count == 1)
    #expect(GraphNode.entity("Orion", kind: .tool, noteID: first.id).id ==
        GraphNode.entity("Orion", kind: .tool, noteID: second.id).id)
    #expect(snapshot.edges.contains { $0.predicate == .uses })
    let evidence = try await fixture.store.graphEvidence(nodeID: GraphNode.documentID(first.id))
    #expect(evidence.count == 2)
    #expect(evidence
        .allSatisfy {
            $0.quote == "Orion uses retrieval." && $0.revision == first.revision && $0.inferred
        })
    let overview = try await fixture.store.graphSnapshot()
    #expect(overview.nodes.contains { $0.label == "retrieval" })
}

@Test func graphValidationRejectsInventedAmbiguousAndNegativeClaims() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Fixture",
        markdown: "🪐 Prefix. Orion does not use retrieval. Orion uses retrieval."
    )])
    let work = try #require(await fixture.store.nextGraphWork())
    var proposal = SyntheticGraphProvider().extract(work.chunk.text)
    proposal.entities.append(ProposedEntity(
        name: "Fabrication",
        kind: .person,
        quote: "Fabrication invented Orion."
    ))
    proposal.entities.append(ProposedEntity(
        name: "Or",
        kind: .concept,
        quote: "Orion uses retrieval."
    ))
    proposal.relations.append(ProposedRelation(
        source: "Orion",
        target: "retrieval",
        predicate: .uses,
        quote: "Orion does not use retrieval."
    ))
    let claims = GraphValidation.claims(proposal, work: work)
    #expect(claims.count == 3)
    #expect(claims.allSatisfy { $0.quote == "Orion uses retrieval." })
    let range = try #require(work.chunk.text.range(of: "Orion uses retrieval."))
    #expect(claims.allSatisfy { $0.offset == range.lowerBound.utf16Offset(in: work.chunk.text) })
    proposal.entities.append(ProposedEntity(
        name: "Orion",
        kind: .organization,
        quote: "Orion uses retrieval."
    ))
    #expect(GraphValidation.claims(proposal, work: work).allSatisfy { $0.predicate == .mentions })
}

@Test func graphValidationExpandsNearbyContextForGroundedRelationships() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    let text = "A coding harness coordinates its components: a planning scaffold maintains task structure. SWE-Bench is evaluated separately."
    _ = try await fixture.store.open(seed: [MarkdownDocument(name: "Fixture", markdown: text)])
    let work = try #require(await fixture.store.nextGraphWork())
    let entities = [
        ProposedEntity(name: "coding harness", kind: .concept, quote: text),
        ProposedEntity(name: "planning scaffold", kind: .concept, quote: text),
        ProposedEntity(name: "SWE-Bench", kind: .tool, quote: text),
    ]
    let explicit = GraphValidation.explicitComponentRelations(
        entities: entities,
        evidence: GraphChunk(segments: [GraphSegment(text: text)])
    )
    #expect(explicit.count == 1)
    #expect(GraphNode.normalize(explicit[0].source) == "planning scaffold")
    #expect(GraphNode.normalize(explicit[0].target) == "coding harness")
    let proposal = GraphProposal(entities: entities, relations: [ProposedRelation(
        source: "coding harness",
        target: "planning scaffold",
        predicate: .uses,
        quote: "a planning scaffold maintains task structure"
    )])
    let claims = GraphValidation.claims(proposal, work: work)
    let relation = try #require(claims.first { $0.predicate == .uses })
    #expect(relation.quote.localizedCaseInsensitiveContains("coding harness"))
    #expect(relation.quote.localizedCaseInsensitiveContains("planning scaffold"))
    #expect(text.contains(relation.quote))
}

@Test func graphValidationRejectsLowSignalLabelsAndListRelationships() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Fixture",
        markdown: "Harness design shapes agent behavior. Reproduce. T2. read_file."
    )])
    let work = try #require(await fixture.store.nextGraphWork())
    let proposal = GraphProposal(
        entities: [
            ProposedEntity(
                name: "Harness design",
                kind: .concept,
                quote: "Harness design shapes agent behavior."
            ),
            ProposedEntity(
                name: "agent behavior",
                kind: .concept,
                quote: "Harness design shapes agent behavior."
            ),
            ProposedEntity(name: "Reproduce", kind: .concept, quote: "Reproduce."),
            ProposedEntity(name: "T2", kind: .concept, quote: "T2."),
            ProposedEntity(name: "read_file", kind: .tool, quote: "read_file."),
        ],
        relations: [ProposedRelation(
            source: "Harness design",
            target: "agent behavior",
            predicate: .partOf,
            quote: "Harness design shapes agent behavior."
        )]
    )
    let claims = GraphValidation.claims(proposal, work: work)
    #expect(Set(claims.map(\.target.label)) == ["harness design", "agent behavior"])
    #expect(claims.allSatisfy { $0.predicate == .mentions })
}

@Test func overviewSelectionBoundsModelCallsWhileRetainingCompleteSource() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    let sentence = "Paper concept supports retrieval. "
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Large paper",
        markdown: String(repeating: sentence, count: 4500)
    )])
    let work = try #require(await fixture.store.nextGraphWork())
    #expect(work.job.total == 1)
    let overview = GraphProposal(entities: [
        ProposedEntity(
            name: "paper concept",
            kind: .concept,
            quote: sentence.trimmingCharacters(in: .whitespaces)
        ),
        ProposedEntity(
            name: "retrieval",
            kind: .concept,
            quote: sentence.trimmingCharacters(in: .whitespaces)
        ),
    ], relations: [])
    let claims = GraphValidation.claims(overview, work: work)
    #expect(!claims.isEmpty)
    try await fixture.store.publishGraphCandidates(work, claims: claims)
    let job = try #require(try await fixture.store.graphJobs().first)
    #expect(job.total == 7)
    let plan = try await DatabaseQueue(path: fixture.store.url.path).read { db in
        let stored = try Data.fetchOne(
            db,
            sql: "SELECT chunks FROM graph_jobs WHERE noteID = ?",
            arguments: [work.job.noteID.uuidString]
        )
        let data = try #require(stored)
        return try JSONDecoder().decode(GraphPlan.self, from: data)
    }
    #expect(plan.sourceChunks.count >= 18)
    #expect(plan.extractionChunks.count == 7)
}

@Test func graphPassageSelectionKeepsLateEvidenceForOverviewEntities() {
    let chunks = (0 ..< 12).map { index in
        GraphChunk(segments: [GraphSegment(text: index == 10
                ? "The rare harness architecture coordinates agent context."
                : "Background evaluation detail \(index).")])
    }
    let selected = DocumentStore.selectGraphPassages(
        GraphPlan(sourceChunks: chunks, extractionIndices: [0], selectionComplete: false),
        candidateNames: ["rare harness architecture"],
        title: "Harness architecture study"
    )
    #expect(selected.extractionIndices.contains(10))
    #expect(selected.extractionIndices.count == 7)
}

@Test func passageCandidateCacheSurvivesGraphRebuilds() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Cached paper",
        markdown: "Orion uses retrieval."
    )])
    let first = try #require(await fixture.store.nextGraphWork())
    let proposal = SyntheticGraphProvider().extract(first.chunk.text)
    try await fixture.store.cacheGraphProposal(proposal, for: first, overview: true)
    try await fixture.store.retryGraph(first.job.noteID, rebuild: true)
    let rebuilt = try #require(await fixture.store.nextGraphWork())
    let cached = try #require(try await fixture.store.cachedGraphProposal(
        for: rebuilt,
        overview: true
    ))
    #expect(cached.entities.map(\.name) == proposal.entities.map(\.name))
    #expect(try fixture.count("graph_passage_cache") == 1)
}

@Test func graphChunksPreserveUnicodeOffsetsAndEverySourceCharacter() {
    let text = String(repeating: "🪐 retrieval is useful.\n", count: 500)
    let chunks = GraphChunk.make([GraphSegment(text: text)])
    #expect(chunks.count > 2)
    #expect(chunks.map(\.text).joined() == text)
    for segment in chunks.flatMap(\.segments) {
        let range = NSRange(location: segment.offset, length: segment.text.utf16.count)
        #expect((text as NSString).substring(with: range) == segment.text)
        #expect(segment.text.count <= 1800)
    }
}

@Test func graphResumePersistsProgressAndRevokesOldAttempts() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Long synthetic",
        markdown: String(repeating: "Orion uses retrieval. ", count: 400)
    )])
    let first = try #require(await fixture.store.nextGraphWork())
    let proposal = SyntheticGraphProvider().extract(first.chunk.text)
    let claims = GraphValidation.claims(proposal, work: first)
    try await fixture.store.publishGraphCandidates(first, claims: claims)
    let interrupted = try #require(await fixture.store.nextGraphWork())
    #expect(interrupted.job.completed == 1)
    let reopened = DocumentStore(url: fixture.store.url)
    _ = try await reopened.open(seed: [])
    try await reopened.recoverGraph()
    await #expect(throws: GraphError.self) {
        try await reopened.publishGraph(interrupted, claims: [])
    }
    let resumed = try #require(await reopened.nextGraphWork())
    #expect(resumed.job.completed == 1)
    try await reopened.pauseGraph(resumed.job.noteID)
    try await reopened.retryGraph(resumed.job.noteID)
    try await reopened.pauseGraph(resumed.job.noteID, token: resumed.job.token)
    #expect(try await reopened.graphJobs().first?.state == "queued")
    await #expect(throws: GraphError.self) { try await reopened.publishGraph(resumed, claims: []) }
}

@Test func graphEditsInvalidateEvidenceAndLatePublication() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    let notes = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Original",
        markdown: "Orion uses retrieval."
    )])
    var note = try #require(notes.first)
    let old = try #require(await fixture.store.nextGraphWork())
    note.markdown = "A different synthetic note."
    note = try await fixture.store.save(note)
    await #expect(throws: GraphError.self) {
        try await fixture.store.publishGraph(
            old,
            claims: GraphValidation.claims(
                SyntheticGraphProvider().extract(old.chunk.text),
                work: old
            )
        )
    }
    #expect(try fixture.count("graph_evidence") == 0)
    #expect(try await fixture.store.graphJobs().first?.revision == note.revision)
}

@Test func legacyDismissalsAreClearedAndReextractedDuringRecovery() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    let notes = try await fixture.store.open(seed: [
        MarkdownDocument(name: "First", markdown: "Orion uses retrieval."),
        MarkdownDocument(name: "Second", markdown: "Orion uses retrieval."),
    ])
    try await fixture.run()
    let first = try #require(notes.first)
    let evidence = try #require(await fixture.store
        .graphEvidence(nodeID: GraphNode.documentID(first.id)).first)
    try await DatabaseQueue(path: fixture.store.url.path).write { db in
        try db.execute(
            sql: "INSERT INTO graph_decisions(noteID, edgeID) VALUES (?, ?)",
            arguments: [first.id.uuidString, evidence.edge.id]
        )
        try db.execute(
            sql: "DELETE FROM graph_evidence WHERE noteID = ? AND edgeID = ?",
            arguments: [first.id.uuidString, evidence.edge.id]
        )
    }
    try await fixture.store.recoverGraph()
    #expect(try fixture.count("graph_decisions") == 0)
    try await fixture.run()
    #expect(try await fixture.store.graphEvidence(nodeID: GraphNode.documentID(first.id))
        .count == 2)
}

@Test func permanentDeletePurgesGraphAndCannotResurrectFromLateWork() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    let notes = try await fixture.store.open(seed: [
        MarkdownDocument(name: "First", markdown: "Orion uses retrieval."),
        MarkdownDocument(name: "Second", markdown: "Orion uses retrieval."),
    ])
    try await fixture.run()
    let first = try #require(notes.first)
    try await fixture.store.retryGraph(first.id, rebuild: true)
    let late = try #require(await fixture.store.nextGraphWork())
    _ = try await fixture.store.permanentlyRemove(first)
    await #expect(throws: GraphError.self) { try await fixture.store.publishGraph(late, claims: [])
    }
    #expect(try fixture.count("graph_decisions") == 0)
    #expect(try fixture.count("graph_nodes") == 3)
    #expect(try fixture.count("graph_jobs") == 1)
    try await fixture.store.saveGraphPositions([GraphNode.documentID(first.id): GraphPosition(
        x: 12,
        y: 34
    )])
    #expect(try fixture.count("graph_layout") == 0)
    _ = try await fixture.store.permanentlyRemove(#require(notes.last))
    for table in [
        "graph_nodes",
        "graph_node_fts",
        "graph_edges",
        "graph_evidence",
        "graph_jobs",
        "graph_links",
        "graph_layout",
        "graph_passage_cache",
        "mind_maps",
        "mind_map_nodes",
        "mind_map_evidence",
        "mind_map_state",
    ] {
        #expect(try fixture.count(table) == 0)
    }
}

@Test func graphCaptureCitationsPointToImmutableBlockAndPage() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [])
    let url = try #require(URL(string: "https://example.com/synthetic-paper"))
    let id = try await fixture.capture(
        "Orion uses retrieval.",
        url: url,
        authors: ["Synthetic Author"]
    )
    try await fixture.run()
    let evidence = try await fixture.store.graphEvidence(nodeID: GraphNode.documentID(id))
    #expect(evidence.contains { $0.edge.predicate == .authoredBy && !$0.inferred })
    #expect(evidence.filter(\.inferred)
        .allSatisfy {
            $0.citation?.page == 7 && $0.citation?.blockOrdinal == 0 && $0.citation?.url == url
        })
    var note = try #require(await fixture.store.documents().first)
    note.markdown = "Edited. Orion uses retrieval."
    _ = try await fixture.store.save(note)
    try await fixture.run()
    let edited = try await fixture.store.graphEvidence(nodeID: GraphNode.documentID(id))
    #expect(edited.allSatisfy { $0.citation == nil && $0.inferred })
}

@Test func unavailableModelStillPublishesExplicitLinksIncludingLateTargets() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    let url = try #require(URL(string: "https://example.com/synthetic-paper"))
    let notes = try await fixture.store.open(seed: [MarkdownDocument(
        name: "Link source",
        markdown: "Read [the source](https://example.com/synthetic-paper) for details."
    )])
    try await fixture.run(provider: UnavailableGraphProvider())
    #expect(try await fixture.store.graphJobs().first?.state == "unavailable")
    let target = try await fixture.capture("Orion uses retrieval.", url: url)
    let first = try #require(notes.first)
    let snapshot = try await fixture.store.graphSnapshot(noteIDs: [first.id])
    #expect(snapshot.nodes.isEmpty)
    #expect(snapshot.edges.isEmpty)
    #expect(target != first.id)
    #expect(try await fixture.store.graphEvidence(nodeID: GraphNode.documentID(first.id))
        .allSatisfy { !$0.inferred })
}

@Test func graphSearchReachesHiddenNodesAndHandlesLiteralQueries() async throws {
    let fixture = try GraphFixture(); defer { fixture.clean() }
    _ = try await fixture.store.open(seed: (0 ..< 230).map { MarkdownDocument(
        name: "Synthetic \($0)",
        markdown: "Orion uses retrieval."
    ) })
    try await fixture.run()
    let notes = try await fixture.store.documents()
    let first = try #require(notes.first)
    let revision = try #require(first.revision)
    let root = GraphNode.entity("retrieval", kind: .concept, noteID: first.id).id
    try await DatabaseQueue(path: fixture.store.url.path).write { db in
        for index in 0 ..< 230 {
            let id = "hidden-\(index)"
            let edge = GraphEdge(source: root, target: id, predicate: .uses)
            try db.execute(
                sql: "INSERT INTO graph_nodes(id, kind, label) VALUES (?, 'concept', ?)",
                arguments: [id, "Hidden \(index)"]
            )
            try db.execute(
                sql: "INSERT INTO graph_edges(id, source, target, predicate) VALUES (?, ?, ?, 'uses')",
                arguments: [edge.id, root, id]
            )
            try db.execute(
                sql: "INSERT INTO graph_evidence(id, edgeID, noteID, revision, quote, offset, origin, chunk) VALUES (?, ?, ?, ?, 'Synthetic hidden node', 0, 'model', 0)",
                arguments: [edge.id, edge.id, first.id.uuidString, revision.uuidString]
            )
        }
    }
    let overview = try await fixture.store.graphSnapshot(limit: 20)
    #expect(overview.nodes.count == 20)
    #expect(overview.totalNodes == 232)
    #expect(overview.nodes.allSatisfy { $0.kind != .document })
    let found = try await fixture.store.graphSnapshot(query: "Hidden 229", limit: 20)
    #expect(found.matchingIDs.contains("hidden-229"))
    #expect(found.nodes.contains { $0.label == "Hidden 229" })
    _ = try await fixture.store.graphSnapshot(query: "\" OR { ( : * ' ")
    let id = first.id
    let focused = try await fixture.store.graphSnapshot(noteIDs: [id], limit: 2)
    #expect(focused.nodes.count == 2)
    #expect(focused.nodes.allSatisfy { $0.kind != .document })
}

private actor LayoutRecorder {
    var positions: [String: GraphPosition] = [:]
    var frames = 0
    func record(_ value: [String: GraphPosition]) {
        positions = value; frames += 1
    }
}

@Test func graphLayoutSettlesWithFiniteCoordinates() async throws {
    let nodes = (0 ..< 20).map { GraphNode(
        id: "synthetic-\($0)",
        kind: .concept,
        label: "Concept \($0)"
    ) }
    let edges = (1 ..< 20).map { GraphEdge(
        source: "synthetic-0",
        target: "synthetic-\($0)",
        predicate: .mentions
    ) }
    let recorder = LayoutRecorder()
    try await GraphLayout().settle(
        GraphSnapshot(nodes: nodes, edges: edges),
        positions: ["synthetic-0": GraphPosition(x: 0, y: 0)],
        animate: false
    ) { await recorder.record($0) }
    let points = await recorder.positions
    #expect(points.count == 20)
    #expect(points.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(await recorder.frames == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["INFACTORY_NATIVE_GRAPH_TESTS"] == "1"))
func nativeDocumentCurationSelectsCentralSyntheticConcepts() async throws {
    let id = UUID()
    let job = GraphJob(
        noteID: id,
        revision: UUID(),
        token: UUID(),
        name: "Synthetic harness study",
        state: "curating",
        completed: 1,
        total: 1,
        error: nil
    )
    let evidence = GraphChunk(segments: [
        GraphSegment(text: "Harness design uses context management to support coding agents."),
        GraphSegment(text: "Reproduce."),
        GraphSegment(text: "T2."),
    ])
    let work = GraphCurationWork(
        job: job,
        candidates: [
            GraphCandidate(
                name: "harness design",
                kind: .concept,
                mentions: 4,
                sections: 3,
                firstChunk: 0,
                quote: evidence.segments[0].text
            ),
            GraphCandidate(
                name: "context management",
                kind: .concept,
                mentions: 3,
                sections: 2,
                firstChunk: 1,
                quote: evidence.segments[0].text
            ),
            GraphCandidate(
                name: "reproduce",
                kind: .concept,
                mentions: 1,
                sections: 1,
                firstChunk: 8,
                quote: evidence.segments[1].text
            ),
            GraphCandidate(
                name: "t2",
                kind: .concept,
                mentions: 1,
                sections: 1,
                firstChunk: 9,
                quote: evidence.segments[2].text
            ),
        ],
        relations: [GraphRelationCandidate(
            source: "harness design",
            target: "context management",
            predicate: .uses,
            quote: evidence.segments[0].text
        )],
        relationExcerpts: [evidence.segments[0].text],
        evidence: evidence,
        sourceChunks: [evidence],
        mapEvidence: evidence.segments
    )
    let provider = AppleGraphExtractor()
    var proposal = try await provider.curate(work)
    proposal.relations = try await provider.relate(work, entities: proposal.entities)
    let claims = GraphValidation.claims(proposal, work: GraphWork(job: job, chunk: evidence))
    let labels = Set(claims.flatMap { [$0.source.label, $0.target.label] })
    #expect(labels.contains("harness design"))
    #expect(labels.contains("context management"))
    #expect(!labels.contains("reproduce"))
    #expect(!labels.contains("t2"))
    #expect(claims.contains { $0.predicate == .uses })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["INFACTORY_NATIVE_GRAPH_TESTS"] == "1"))
func nativePassageExtractionUsesOnlySyntheticLocalText() async throws {
    let provider = AppleGraphExtractor()
    let result = try await provider
        .extract(
            "The fictional tool Orion uses retrieval. Retrieval is part of information processing."
        )
    #expect(!result.entities.isEmpty)
    let text = "The fictional tool Orion uses retrieval. Retrieval is part of information processing."
    let job = GraphJob(
        noteID: UUID(),
        revision: UUID(),
        token: UUID(),
        name: "Synthetic",
        state: "running",
        completed: 0,
        total: 1,
        error: nil
    )
    let work = GraphWork(job: job, chunk: GraphChunk(segments: [GraphSegment(text: text)]))
    let claims = GraphValidation.claims(result, work: work)
    #expect(claims.contains { $0.predicate == .uses || $0.predicate == .partOf })
    #expect(claims.allSatisfy { text.contains($0.quote) })
}
