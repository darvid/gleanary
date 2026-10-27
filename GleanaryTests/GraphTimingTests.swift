import Foundation
@testable import Gleanary
import Testing

/// Times each model call while one note is read for entities. Opt-in: it uses the real
/// on-device model, so set GLEANARY_LIVE_GRAPH=1 to run it.
private actor TimingProvider: GraphExtracting {
    let base = AppleGraphExtractor()
    private(set) var calls: [(String, Double)] = []

    private func time<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer { calls.append((name, (ContinuousClock.now - start) / .seconds(1))) }
        return try await work()
    }

    func extract(_ text: String) async throws -> GraphProposal {
        try await time("extract (\(text.count) chars)") { try await base.extract(text) }
    }

    func extractOverview(_ text: String) async throws -> GraphProposal {
        try await time("overview (\(text.count) chars)") { try await base.extractOverview(text) }
    }

    func curate(_ work: GraphCurationWork) async throws -> GraphProposal {
        try await time("curate (\(work.candidates.count) candidates)") {
            try await base.curate(work)
        }
    }

    func relate(_ work: GraphCurationWork, entities: [ProposedEntity]) async throws
        -> [ProposedRelation]
    {
        try await time("relate (\(entities.count) entities)") {
            try await base.relate(work, entities: entities)
        }
    }

    func mindMap(_ work: GraphCurationWork, entities: [ProposedEntity]) async throws
        -> MindMapProposal
    {
        try await time("mind map") { try await base.mindMap(work, entities: entities) }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_GRAPH"] == "1"))
func timeReadingOneNoteForEntities() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentStore(url: root.appending(path: "library.sqlite"))
    _ = try await store.open()
    let paragraph = """
    Synthetic Labs, a research group led by Dana Reyes, built Orion, a retrieval system for long \
    documents. Reyes argues that agents should split work into small tasks, an idea she credits \
    to Sam Okafor at Northwind Institute. Orion uses a planning scaffold and a vector index, and \
    the team evaluated it on the Atlas benchmark. Okafor's group later compared Orion with Vega, \
    a summarization tool from Bluefin, and found that Orion improves on Vega for multi-step \
    questions while costing more to run.
    """
    let markdown = (1 ... 14).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
    let note = try await store.save(MarkdownDocument(
        name: "Synthetic agents article",
        markdown: markdown
    ))
    try await store.prepareGraphJobs([note.id])
    let provider = TimingProvider()
    let start = ContinuousClock.now
    try await GraphExtractor(store: store, provider: provider).run(
        only: [note.id],
        mindMaps: false
    ) {}
    let total = (ContinuousClock.now - start) / .seconds(1)
    let calls = await provider.calls
    for (name, seconds) in calls {
        print(String(format: "  %6.1fs  %@", seconds, name))
    }
    print(String(
        format: "TOTAL %.1fs over %d model calls, %d characters",
        total,
        calls.count,
        markdown.count
    ))
    #expect(try await store.graphProgress([note.id]).ready == 1)
}
