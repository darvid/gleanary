import Foundation
import GRDB
@testable import Sink
import Testing

private actor SuspendedGraphProvider: GraphExtracting {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var first = true
    func extract(_: String) async -> GraphProposal {
        if first {
            first = false
            await withCheckedContinuation { continuation = $0; observer?.resume(); observer = nil }
        }
        return GraphProposal(entities: [], relations: [])
    }

    func wait() async {
        if continuation == nil {
            await withCheckedContinuation { observer = $0 }
        }
    }

    func release() {
        continuation?.resume(); continuation = nil
    }
}

@Test func graphWorkerCannotPublishAfterConcurrentEdit() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    var note = try #require(await store.open(seed: [MarkdownDocument(
        name: "Synthetic",
        markdown: "Original synthetic data."
    )]).first)
    let provider = SuspendedGraphProvider()
    let extractor = GraphExtractor(store: store, provider: provider)
    let task = Task { try await extractor.run {} }
    await provider.wait()
    note.markdown = "Replacement synthetic data."
    note = try await store.save(note)
    await provider.release()
    try await task.value
    let job = try #require(await store.graphJobs().first)
    #expect(job.state == "ready")
    #expect(job.revision == note.revision)
    #expect(job.error == nil)
}

@Test func graphCancellationPreservesCheckpointAndCanResume() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    let note = try #require(await store.open(seed: [MarkdownDocument(
        name: "Synthetic",
        markdown: "Original synthetic data."
    )]).first)
    let provider = SuspendedGraphProvider()
    let extractor = GraphExtractor(store: store, provider: provider)
    let task = Task { try await extractor.run {} }
    await provider.wait()
    task.cancel()
    await provider.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await store.graphJobs().first?.state == "paused")
    #expect(try await store.graphJobs().first?.completed == 0)
    try await store.retryGraph(note.id)
    try await extractor.run {}
    #expect(try await store.graphJobs().first?.state == "ready")
}

@Test func sharedRelationshipRetainsOnlySurvivingSourceEvidence() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    let quote = "Retrieval is part of information processing."
    let notes = try await store.open(seed: [
        MarkdownDocument(name: "First", markdown: quote),
        MarkdownDocument(name: "Second", markdown: quote),
    ])
    let proposal = GraphProposal(entities: [
        ProposedEntity(name: "Retrieval", kind: .concept, quote: quote),
        ProposedEntity(name: "information processing", kind: .concept, quote: quote),
    ], relations: [ProposedRelation(
        source: "Retrieval",
        target: "information processing",
        predicate: .partOf,
        quote: quote
    )])
    while let work = try await store.nextGraphWork() {
        try await store.publishGraph(
            work,
            claims: GraphValidation.claims(proposal, work: work)
        )
    }
    let first = try #require(notes.first)
    let topic = GraphNode.entity("retrieval", kind: .concept, noteID: first.id)
    let evidence = try await store.graphEvidence(nodeID: topic.id)
        .filter { $0.edge.predicate == .partOf }
    #expect(evidence.count == 2)
    #expect(Set(evidence.map(\.edge.id)).count == 1)
    var edited = first; edited.markdown = "Revision two. " + quote
    edited = try await store.save(edited)
    let work = try #require(await store.nextGraphWork())
    try await store.publishGraph(work, claims: GraphValidation.claims(proposal, work: work))
    #expect(try await store.graphEvidence(nodeID: topic.id).filter { $0.edge.predicate == .partOf }
        .count == 2)
    _ = try await store.permanentlyRemove(edited)
    let remaining = try await store.graphEvidence(nodeID: topic.id)
    #expect(remaining.contains { $0.edge.predicate == .partOf })
    #expect(remaining.allSatisfy { $0.noteID != first.id })
}

@Test func graphPublicationIsAtomicOnDatabaseFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    _ = try await store.open(seed: [MarkdownDocument(
        name: "Synthetic",
        markdown: "Retrieval matters."
    )])
    let work = try #require(await store.nextGraphWork())
    let proposal = GraphProposal(
        entities: [ProposedEntity(name: "Retrieval", kind: .concept, quote: "Retrieval matters.")],
        relations: []
    )
    let claims = GraphValidation.claims(proposal, work: work)
    try await DatabaseQueue(path: store.url.path).write {
        try $0
            .execute(
                sql: "CREATE TRIGGER synthetic_graph_failure BEFORE INSERT ON graph_edges BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;"
            )
    }
    await #expect(throws: DatabaseError.self) { try await store.publishGraph(work, claims: claims) }
    #expect(try await store.graphSnapshot().totalNodes == 0)
    #expect(try await store.graphJobs().first?.completed == 0)
}
