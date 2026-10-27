import Foundation
@testable import Gleanary
import Testing

/// Times each model call while one note is read for entities. Opt-in: it uses the real
/// on-device model, so set GLEANARY_LIVE_GRAPH=1 to run it.
private actor TimingProvider: GraphExtracting {
    let base: any GraphExtracting

    init(base: any GraphExtracting = AppleGraphExtractor()) {
        self.base = base
    }

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

/// The synthetic article both timing runs read.
private func timingNote(in store: DocumentStore) async throws -> MarkdownDocument {
    let paragraph = """
    Synthetic Labs, a research group led by Dana Reyes, built Orion, a retrieval system for long \
    documents. Reyes argues that agents should split work into small tasks, an idea she credits \
    to Sam Okafor at Northwind Institute. Orion uses a planning scaffold and a vector index, and \
    the team evaluated it on the Atlas benchmark. Okafor's group later compared Orion with Vega, \
    a summarization tool from Bluefin, and found that Orion improves on Vega for multi-step \
    questions while costing more to run.
    """
    let markdown = (1 ... 14).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
    return try await store.save(MarkdownDocument(
        name: "Synthetic agents article",
        markdown: markdown
    ))
}

private func timeOneNote(with base: any GraphExtracting, label: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentStore(url: root.appending(path: "library.sqlite"))
    _ = try await store.open()
    let note = try await timingNote(in: store)
    try await store.prepareGraphJobs([note.id])
    let provider = TimingProvider(base: base)
    let start = ContinuousClock.now
    try await GraphExtractor(store: store, provider: provider).run(
        only: [note.id],
        mindMaps: false
    ) {}
    let total = (ContinuousClock.now - start) / .seconds(1)
    for (name, seconds) in await provider.calls {
        print(String(format: "  %6.1fs  %@", seconds, name))
    }
    let found = try await store.entities(in: [note.id]).map(\.name)
    await print(String(
        format: "%@ TOTAL %.1fs over %d model calls",
        label,
        total,
        provider.calls.count
    ))
    print("\(label) ENTITIES \(found.joined(separator: ", "))")
    #expect(try await store.graphProgress([note.id]).ready == 1)
}

/// Your ChatGPT sign-in, read from the app's keychain item; refreshed tokens are written back
/// so the app keeps working. Nothing here prints a token.
private struct WriteThroughVault: ChatGPTCredentialStoring {
    let keychain = KeychainChatGPTCredentials()
    func load() throws -> Data? {
        try keychain.load()
    }

    func save(_ data: Data) throws {
        try keychain.save(data)
    }
}

/// Opt-in: uses your ChatGPT plan. Set GLEANARY_LIVE_CHATGPT=1, and optionally
/// GLEANARY_CHATGPT_MODEL to pick a model.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_CHATGPT"] == "1"))
@MainActor func timeReadingOneNoteWithChatGPT() async throws {
    let session = ChatGPTSession(vault: WriteThroughVault())
    let suite = "gleanary-live-chatgpt-" + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let connection = ChatGPTConnection(session: session, preferences: preferences)
    await connection.load()
    let account = try #require(connection.activeAccount, "No ChatGPT account in the keychain")
    #expect(account.planAuthorized)
    let wanted = ProcessInfo.processInfo.environment["GLEANARY_CHATGPT_MODEL"]
    let model = try #require(
        connection.models.first { $0.slug == wanted }?.slug
            ?? (connection.selectedModel.isEmpty ? nil : connection.selectedModel)
            ?? connection.models.first?.slug,
        "No ChatGPT models available: \(connection.error ?? "")"
    )
    print("CHATGPT MODEL \(model) of \(connection.models.map(\.slug).joined(separator: ", "))")
    try await timeOneNote(
        with: ChatGPTConversationInference(session: session, model: model), label: "CHATGPT"
    )
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

/// Opt-in: four notes through chat's entity reading with ChatGPT, read together.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_CHATGPT_BATCH"] == "1"))
@MainActor func timeReadingFourNotesWithChatGPT() async throws {
    let session = ChatGPTSession(vault: WriteThroughVault())
    let suite = "gleanary-live-chatgpt-" + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let connection = ChatGPTConnection(session: session, preferences: preferences)
    await connection.load()
    let wanted = ProcessInfo.processInfo.environment["GLEANARY_CHATGPT_MODEL"]
    let model = try #require(
        connection.models.first { $0.slug == wanted }?.slug ?? connection.models.first?.slug
    )
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentStore(url: root.appending(path: "library.sqlite"))
    _ = try await store.open()
    var ids: [UUID] = []
    for _ in 1 ... 4 {
        try await ids.append(timingNote(in: store).id)
    }
    let coordinator = AgentCoordinator(
        store: store,
        graphProvider: ChatGPTConversationInference(session: session, model: model)
    )
    let task = try await store.beginConversation("find entities", owner: .assistant)
    let start = ContinuousClock.now
    let report = try await coordinator.findEntities(ids, taskID: task, changed: {})
    let total = (ContinuousClock.now - start) / .seconds(1)
    print(String(format: "CHATGPT BATCH %@ read %d of 4 notes in %.1fs", model, report.read, total))
    #expect(report.read == 4)
}

/// Opt-in, with GLEANARY_LIVE_CHATGPT=1: asks ChatGPT to research a (synthetic) person and
/// checks that it records them as an entity on the saved research without being told to.
/// The research itself is a stand-in that saves a fixed note, so nothing searches the web.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_CHATGPT"] == "1"))
@MainActor func researchingAPersonRecordsThemWithChatGPT() async throws {
    let session = ChatGPTSession(vault: WriteThroughVault())
    let suite = "gleanary-live-chatgpt-" + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let connection = ChatGPTConnection(session: session, preferences: preferences)
    await connection.load()
    let model = try #require(
        connection.selectedModel.isEmpty ? connection.models.first?.slug : connection.selectedModel
    )
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentStore(url: root.appending(path: "library.sqlite"))
    _ = try await store.open()
    let toolbox = AgentToolbox(store: store, search: SearchEngine(store: store))
    let workflows = ConversationWorkflows { request, _ in
        let note = try await store.save(MarkdownDocument(
            name: "Research: Dana Reyes",
            markdown: """
            # Dana Reyes

            Dana Reyes is a research scientist at the Northwind Institute who leads the Atlas
            benchmark for long-document retrieval.
            """
        ))
        return await ConversationWorkflows.Result(
            status: "completed",
            messages: [.init(
                author: "researcher",
                text: "Saved research on Dana Reyes (\(request.workflow.rawValue)).",
                truncated: false
            )],
            items: toolbox.describeResult([note.id])
        )
    }
    let agent = LibraryAgent(
        model: ChatGPTConversationInference(session: session, model: model),
        toolbox: toolbox,
        workflows: workflows
    )
    let outcome = try await agent.run(
        request: "Research Dana Reyes on the web and save what you find.",
        history: [],
        selected: [],
        progress: { print("PROGRESS \($0)") }
    )
    print("REPLY \(outcome.reply)")
    let people = try await store.entities(kind: .person).map(\.name)
    print("PEOPLE \(people)")
    #expect(people.contains("Dana Reyes"))
}
