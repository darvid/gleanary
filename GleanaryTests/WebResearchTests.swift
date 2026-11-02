import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

private final class WebFixtureVault: ChatGPTCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data

    init() throws {
        let account = ChatGPTRegistration(
            id: "web-fixture", clientID: "oaiapp_fixture", subject: "fixture",
            accessToken: "synthetic-access", refreshToken: nil, idToken: nil,
            scopes: ["resource.invoke", "chatgpt.tokens.use.direct"],
            expiresAt: Date().addingTimeInterval(3600)
        )
        data = try JSONEncoder().encode(ChatGPTCredentialRecords(
            accounts: [account],
            activeID: account.id
        ))
    }

    func load() -> Data? {
        lock.withLock { data }
    }

    func save(_ value: Data) {
        lock.withLock { data = value }
    }
}

private actor WebFixtureTransport: ChatGPTTransporting {
    let events: [[String: Any]]
    private(set) var requests: [URLRequest] = []

    init(events: [[String: Any]]) {
        self.events = events
    }

    func data(for _: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ChatGPTError
            .server
    }

    private func stream(_ request: URLRequest) throws -> [String] {
        requests.append(request)
        return try events.flatMap { event in
            try [
                "data: " + String(
                    decoding: JSONSerialization.data(withJSONObject: event),
                    as: UTF8.self
                ),
                "",
            ]
        }
    }

    nonisolated func lines(for request: URLRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for line in try await self.stream(request) {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct WebFixtureInference: ConversationInferring, WebResearching {
    let result: WebResearchResult
    var fails = false
    var titleFails = false
    var targets: [UUID] = []
    var expectedSourceCount = 0
    let capabilities = InferenceCapabilities(
        identifier: "synthetic-web",
        local: false,
        structured: true,
        streaming: true
    )

    func plan(
        request _: String,
        context _: ConversationPlanningContext
    ) async throws -> ConversationPlan {
        ConversationPlan(steps: [.init(
            action: .webResearch,
            targets: targets,
            argument: "Public topic"
        )])
    }

    func researchTitle(for _: String) throws -> String {
        if titleFails {
            throw ConversationError.invalidOutput
        }
        return "Synthetic web findings"
    }

    func researchWeb(
        question _: String,
        sources: [ResearchSource],
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> WebResearchResult {
        guard sources.count == expectedSourceCount else { throw ConversationError.invalidPlan }
        await progress("Searching the web…")
        if fails {
            throw ChatGPTError.modelDenied
        }
        return result
    }

    func research(
        question _: String,
        sources _: [ResearchSource]
    ) -> AsyncThrowingStream<ResearchEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ConversationError.invalidOutput) }
    }

    func reply(
        question _: String,
        role _: AgentRole,
        history _: [ConversationTurn]
    ) -> AsyncThrowingStream<ResearchEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ConversationError.invalidReply) }
    }
}

struct WebResearchTests {
    private func result(
        text: String = "Python [cite].",
        start: Int = 7,
        end: Int = 13,
        url: String = "https://www.python.org/"
    ) throws -> WebResearchResult {
        let url = try #require(URL(string: url))
        return WebResearchResult(passages: [.init(text: text, citations: [.init(
            startIndex: start, endIndex: end, title: "Python home", url: url
        )])], consultedURLs: [url], searchCount: 1)
    }

    private func items() -> [[String: Any]] {
        [["id": "ws_fixture", "type": "web_search_call", "status": "completed",
          "action": ["type": "search", "sources": [["url": "https://www.python.org/"]]]],
         ["id": "msg_fixture", "type": "message", "status": "completed", "content": [
             ["type": "output_text", "text": "Python [cite].", "annotations": [
                 ["type": "url_citation", "start_index": 7, "end_index": 13,
                  "title": "Python home", "url": "https://www.python.org/"],
             ]],
         ]]]
    }

    private func completed(output: [[String: Any]] = []) -> [String: Any] {
        ["type": "response.completed", "response": ["status": "completed", "output": output]]
    }

    private func feed(
        _ event: [String: Any],
        to decoder: inout WebResearchSSEDecoder
    ) throws -> WebResearchResult? {
        let line = try "data: " + String(
            decoding: JSONSerialization.data(withJSONObject: event),
            as: UTF8.self
        )
        #expect(try decoder.consume(line) == nil)
        return try decoder.consume("")
    }

    @Test func collectsItemsBeforeEmptyFinalOutputAndDeduplicatesFinalItems() throws {
        for finalOutput in [[], items()] {
            var decoder = WebResearchSSEDecoder()
            for item in items() {
                #expect(
                    try feed(["type": "response.output_item.done", "item": item], to: &decoder) ==
                        nil
                )
            }
            let answer = try #require(feed(completed(output: finalOutput), to: &decoder))
            #expect(try answer == result())
            #expect(try answer.markdown().contains("Python [Web 1](<https://www.python.org/>)."))
        }
        var decoder = WebResearchSSEDecoder()
        #expect(try feed(completed(output: items()), to: &decoder) == result())
    }

    @Test func rejectsTruncatedFailedAndUncitedStreams() throws {
        var truncated = WebResearchSSEDecoder()
        for item in items() {
            _ = try feed(["type": "response.output_item.done", "item": item], to: &truncated)
        }
        #expect(throws: ChatGPTError.self) { try truncated.finish() }
        for event in [
            ["type": "response.incomplete"],
            [
                "type": "response.failed",
                "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]],
            ],
        ] as [[String: Any]] {
            var decoder = truncated
            #expect(throws: ChatGPTError.self) { try feed(event, to: &decoder) }
        }
        for output in [[], [items()[0]], [items()[1]]] {
            var decoder = WebResearchSSEDecoder()
            #expect(throws: ConversationError.self) { try feed(
                completed(output: output),
                to: &decoder
            ) }
        }
    }

    @Test func rejectsInvalidCitationRangesAndUnsafeURLs() throws {
        for bounds in [(-1, 3), (7, 999), (7, 7)] {
            #expect(throws: ConversationError.self) {
                try result(start: bounds.0, end: bounds.1).markdown()
            }
        }
        for url in [
            "file:///tmp/fixture",
            "javascript:alert(1)",
            "https://user:password@example.invalid/",
        ] {
            #expect(throws: ConversationError.self) { try result(url: url).markdown() }
        }
        var decoder = WebResearchSSEDecoder()
        #expect(throws: ChatGPTError.self) { try decoder.consume(String(
            repeating: "x",
            count: 400_001
        )) }
    }

    @Test func rendersUnicodeCitationOffsets() throws {
        let prefix = "🐍 e\u{301} "
        let answer = try result(
            text: prefix + "[cite]",
            start: prefix.unicodeScalars.count,
            end: prefix.unicodeScalars.count + 6
        )
        #expect(try answer.markdown().hasPrefix(prefix + "[Web 1](<https://www.python.org/>)"))
        #expect(try answer.markdown().contains("## Web sources"))
        #expect(try answer.markdown().contains("not retained source originals"))
    }

    @Test func requestUsesHostedSearchAndNoPersistedResponseState() throws {
        let body = try OpenAIResponsesAPI.webResearchRequestBody(
            model: "fixture-model",
            question: "Find current public information",
            sources: []
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect((json["tools"] as? [[String: String]]) == [["type": "web_search"]])
        #expect(json["include"] as? [String] == ["web_search_call.action.sources"])
        #expect(json["previous_response_id"] == nil)
        #expect(json["background"] == nil)
        #expect(json["max_tool_calls"] == nil)
        let library = try OpenAIResponsesAPI.requestBody(
            model: "fixture",
            prompt: "Summarize",
            instructions: "Saved sources only",
            name: "fixture",
            schema: [:]
        )
        #expect(try (JSONSerialization.jsonObject(with: library) as? [String: Any])?["tools"] ==
            nil)
    }

    @Test func providerConsumesActualSIWCStreamShapeAndFencesRevocation() async throws {
        let events = items()
            .map { ["type": "response.output_item.done", "item": $0] as [String: Any] } +
            [completed()]
        let transport = WebFixtureTransport(events: events)
        let session = try ChatGPTSession(
            vault: WebFixtureVault(),
            transport: transport,
            hostID: "urn:uuid:fixture"
        )
        let provider = HostedInference(session: session, model: "fixture")
        let answer = try await provider.researchWeb(question: "Public topic", sources: []) { _ in }
        var expected = try result()
        expected.engine = "ChatGPT"
        #expect(answer == expected)
        #expect(await transport.requests.count == 1)
        _ = try await session.signOut()
        await #expect(throws: ChatGPTError.self) {
            try await provider.researchWeb(question: "Public topic", sources: []) { _ in }
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func coordinatorPublishesWebEvidenceAtomicallyAndRetainsItAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "fixture.sqlite"))
        _ = try await store.open()
        let source = try await store.save(MarkdownDocument(
            name: "Saved fixture",
            markdown: "Retained library evidence."
        ))
        let task = try await store.beginConversation(
            "Compare this with web sources",
            owner: .researcher
        )
        let inference = try WebFixtureInference(
            result: result(),
            targets: [source.id],
            expectedSourceCount: 1
        )
        let coordinator = AgentCoordinator(store: store, inference: inference)
        try await coordinator.execute(
            taskID: task,
            request: "Compare this with web sources",
            selected: [source.id],
            userSelected: true
        ) {}
        let messages = try await store.conversationMessages()
        let message = try #require(messages.first { $0.author == "researcher" })
        let noteID = try #require(message.references.first)
        let note = try #require(await store.document(id: noteID))
        #expect(note.markdown.contains("[Web 1](<https://www.python.org/>)"))
        #expect(note.markdown.contains("## Saved sources"))
        #expect(message.references == [noteID, source.id])
        #expect(try await store.document(id: source.id) == source)
        let reopened = DocumentStore(url: store.url)
        _ = try await reopened.open()
        #expect(try await reopened.webResearchEvidence(noteID: noteID) == result())
        #expect(try await reopened.document(id: noteID)?.markdown == note.markdown)
        #expect(try await reopened.documents().count == 2)
        let webOnlyTask = try await store.beginConversation(
            "Search only the web",
            owner: .researcher
        )
        let webOnly = try AgentCoordinator(
            store: store,
            inference: WebFixtureInference(result: result())
        )
        try await webOnly.execute(
            taskID: webOnlyTask,
            request: "Search only the web",
            selected: [source.id]
        ) {}
        let webOnlyMessage = try #require(await store.conversationMessages()
            .last { $0.author == "researcher" })
        #expect(webOnlyMessage.references.count == 1)
        #expect(!webOnlyMessage.text.contains("## Saved sources"))
    }

    @Test func failedResearchAndTitleLeaveNoArtifactOrWebEvidence() async throws {
        for titleFails in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DocumentStore(url: root.appending(path: "fixture.sqlite"))
            _ = try await store.open()
            let task = try await store.beginConversation("Search the web", owner: .researcher)
            let inference = try WebFixtureInference(
                result: result(),
                fails: !titleFails,
                titleFails: titleFails
            )
            let coordinator = AgentCoordinator(store: store, inference: inference)
            await #expect(throws: (any Error).self) {
                try await coordinator.execute(
                    taskID: task,
                    request: "Search the web",
                    selected: []
                ) {}
            }
            #expect(try await store.documents().isEmpty)
            let db = try await store.readyDatabase()
            #expect(try await db.read { try Int.fetchOne(
                $0,
                sql: "SELECT count(*) FROM web_research_evidence"
            ) } == 0)
        }
    }

    @Test func writerKeepsExternalCitationsAlongsideSavedResearchReferences() throws {
        let id = UUID()
        let answer = try result()
        let evidence = WriterEvidence([(id, "Saved web research", [FactRecord(
            sourceID: id, subject: "", field: "website", status: .stated,
            value: "Python home", quote: "Python home"
        )])], fields: ["website"], webSources: [id: answer.passages.flatMap(\.citations)])
        let document = WriterDocument(evidence: evidence, style: .plain, generalKnowledge: false)
        let draft = WriterDraft(
            title: "Python website",
            scale: .init(name: "", levels: []),
            sections: [
                .init(heading: "Website", columns: [], blocks: [
                    .init(
                        kind: .paragraph,
                        text: "Python home",
                        cells: [],
                        records: ["R1"],
                        grade: "",
                        general: false
                    ),
                ]),
            ],
            conflicts: []
        )
        try document.validate(draft)
        let rendered = document.render(draft).markdown
        #expect(rendered.contains("gleanary://note/\(id.uuidString)"))
        #expect(rendered.contains("[Python home](<https://www.python.org/>)"))
        #expect(rendered.contains("Web citations retained with this saved research note"))
    }

    @Test func webResearchPlansRequireQuestionAndCannotMixMutations() throws {
        let context = ConversationPlanningContext(
            purpose: "request",
            history: [],
            records: [],
            categories: []
        )
        try ConversationPlan(steps: [.init(
            action: .webResearch,
            argument: "Current public information"
        )]).validate(context: context, hasURL: false)
        for plan in [
            ConversationPlan(steps: [.init(action: .webResearch)]),
            ConversationPlan(steps: [
                .init(action: .webResearch, argument: "Public topic"),
                .init(action: .saveNote, argument: "Other work"),
            ]),
        ] {
            #expect(throws: ConversationError.self) { try plan.validate(
                context: context,
                hasURL: false
            ) }
        }
        let reference = ConversationReference(
            id: UUID(),
            title: "Web note",
            sourceURL: nil,
            artifactKind: "web-research",
            taskID: UUID()
        )
        #expect(reference.researchKindTitle == "Web research")
    }

    @Test @MainActor func webResearchUsesNativeReadingAndClickableCitationLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "fixture.sqlite"))
        _ = try await store.open()
        let task = try await store.beginConversation("Search the web", owner: .researcher)
        let answer = try result()
        let markdown = try answer.markdown()
        let note = try await store.saveResearch(
            markdown,
            name: "Python website",
            sources: [],
            taskID: task,
            provider: "synthetic",
            kind: "web-research",
            webEvidence: answer
        )
        try await store.updateConversationTask(task, state: "succeeded", progress: "Completed")
        let model = ConversationModel(store: store, coordinator: AgentCoordinator(store: store))
        await model.load()
        let message = try #require(model.messages.last { $0.author == "researcher" })
        let view = ConversationView(model: model, library: LibraryModel(store: store))
        #expect(view.researchResult(in: message)?.id == note.id)
        #expect(view.researchResult(in: message)?.researchKindTitle == "Web research")
        #expect(try await store.documentPage(limit: 10).documents.first?
            .kindLabel == "Web research")
        let attributed = try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        #expect(attributed.runs.contains { $0.link?.host == "www.python.org" })
        for dark in [false, true] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                MarkdownPreview(markdown: markdown)
                view.references(for: message)
            }.padding(20).frame(width: 400, height: 420, alignment: .topLeading)
                .preferredColorScheme(dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            host.display()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png
                .write(to: FileManager.default.temporaryDirectory
                    .appending(path: "gleanary-web-research-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func invalidEvidenceAndCancelledTasksCannotPublishPartialNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "fixture.sqlite"))
        _ = try await store.open()
        let task = try await store.beginConversation("Search the web", owner: .researcher)
        let invalid = WebResearchResult(passages: [], consultedURLs: [], searchCount: 0)
        await #expect(throws: ConversationError.self) {
            try await store.saveResearch(
                "Must roll back",
                name: "Invalid",
                sources: [],
                taskID: task,
                provider: "fixture",
                kind: "web-research",
                webEvidence: invalid
            )
        }
        #expect(try await store.documents().isEmpty)
        try await store.updateConversationTask(task, state: "cancelled", progress: "Cancelled")
        await #expect(throws: CancellationError.self) {
            try await store.saveResearch(
                "Must not save",
                name: "Cancelled",
                sources: [],
                taskID: task,
                provider: "fixture",
                kind: "web-research",
                webEvidence: result()
            )
        }
        #expect(try await store.documents().isEmpty)
        #expect(try await store.conversationMessages().filter { $0.author == "researcher" }.isEmpty)
    }

    @Test func migrationAddsWebEvidenceWithoutChangingExistingNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "fixture.sqlite"))
        _ = try await store.open()
        let note = try await store.save(MarkdownDocument(
            name: "Existing note",
            markdown: "Keep this exact source text."
        ))
        let db = try await store.readyDatabase()
        try await db.write {
            try $0.execute(sql: "DROP TABLE web_research_evidence")
            try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'web-research-v1'")
        }
        let reopened = DocumentStore(url: store.url)
        _ = try await reopened.open()
        #expect(try await reopened.document(id: note.id) == note)
        #expect(try await reopened.webResearchEvidence(noteID: note.id) == nil)
    }

    @Test func onDeviceProviderReportsWebResearchUnavailableWithoutSaving() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "fixture.sqlite"))
        _ = try await store.open()
        let task = try await store.beginConversation("Search the web", owner: .researcher)
        let coordinator = AgentCoordinator(store: store)
        await #expect(throws: ConversationError.self) {
            try await coordinator.researchWeb(
                taskID: task,
                question: "Public topic",
                references: []
            ) {}
        }
        #expect(try await store.documents().isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_WEB_RESEARCH"] == "1"))
    func liveHostedSearchWithExistingSignIn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "fixture.sqlite"))
        _ = try await store.open()
        let session = ChatGPTSession()
        let model = try #require(await session.catalog().first)
        let provider = HostedInference(session: session, model: model.slug)
        let request = "Search the web for the official Python website. In one sentence, state its URL and cite the source."
        let task = try await store.beginConversation(request, owner: .researcher)
        let coordinator = AgentCoordinator(store: store, inference: provider)
        try await coordinator.execute(taskID: task, request: request, selected: []) {}
        let note = try #require(await store.documents().first)
        let answer = try #require(await store.webResearchEvidence(noteID: note.id))
        #expect(answer.searchCount > 0)
        #expect(answer.passages.flatMap(\.citations)
            .contains { $0.url.host == "www.python.org" || $0.url.host == "python.org" })
        #expect(note.markdown.contains("[Web 1]"))
        #expect(note.name != "Synthetic web findings")
    }
}
