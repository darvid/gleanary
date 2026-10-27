import Foundation
@testable import Gleanary
import Testing

private actor ConversationToolFixture: ConversationInferring, AgentResponding, WebResearching {
    nonisolated let capabilities = InferenceCapabilities(
        identifier: "fixture.tools",
        local: false,
        structured: true,
        streaming: false
    )
    private var turns: [AgentTurn]
    private let delay: Duration?
    private let webResult: WebResearchResult?
    private(set) var inputs: [[Data]] = []
    private(set) var tools: [Data] = []
    private(set) var plans = 0

    init(_ turns: [AgentTurn], delay: Duration? = nil, webResult: WebResearchResult? = nil) {
        self.turns = turns
        self.delay = delay
        self.webResult = webResult
    }

    func agentTurn(instructions _: String, input: [Data], tools: Data) async throws -> AgentTurn {
        inputs.append(input); self.tools.append(tools)
        if let delay {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        guard !turns.isEmpty else { throw ConversationError.invalidReply }
        return turns.removeFirst()
    }

    func plan(
        request _: String,
        context _: ConversationPlanningContext
    ) throws -> ConversationPlan {
        plans += 1
        throw ConversationError.invalidPlan
    }

    func researchTitle(for _: String) throws -> String {
        guard webResult != nil else { throw ConversationError.invalidOutput }
        return "Synthetic resource research"
    }

    func researchWeb(
        question _: String,
        sources _: [ResearchSource],
        progress _: @escaping @Sendable (String) async -> Void
    ) throws
        -> WebResearchResult
    {
        guard let webResult else { throw ConversationError.webResearchUnavailable }
        return webResult
    }

    nonisolated func research(
        question _: String,
        sources _: [ResearchSource]
    ) -> AsyncThrowingStream<ResearchEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ConversationError.invalidOutput) }
    }

    nonisolated func reply(
        question _: String,
        role _: AgentRole,
        history _: [ConversationTurn]
    ) -> AsyncThrowingStream<ResearchEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ConversationError.invalidReply) }
    }
}

private actor ConversationSourceFetcher: SourceFetching {
    private(set) var requests: [URL] = []
    private let failing: Set<String>
    init(failing: Set<String> = []) {
        self.failing = failing
    }

    var sourceCalls: Int {
        requests.filter { $0.path.hasPrefix("/source-") }.count
    }

    func fetch(_ url: URL) throws -> DownloadedContent {
        requests.append(url)
        if failing.contains(url.path) {
            throw CaptureError.http(404)
        }
        return DownloadedContent(
            data: Data("Synthetic retained source text.".utf8),
            url: url,
            mime: "text/plain",
            encoding: "utf-8"
        )
    }
}

/// Streams each turn's text in two growing drafts before returning the turn.
private actor StreamingToolFixture: AgentResponding {
    private var turns: [AgentTurn]

    init(_ turns: [AgentTurn]) {
        self.turns = turns
    }

    func agentTurn(instructions _: String, input _: [Data], tools _: Data) async throws
        -> AgentTurn
    {
        guard !turns.isEmpty else { throw ConversationError.invalidReply }
        return turns.removeFirst()
    }

    func agentTurn(
        instructions: String,
        input: [Data],
        tools: Data,
        text: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTurn {
        let turn = try await agentTurn(instructions: instructions, input: input, tools: tools)
        if !turn.text.isEmpty {
            await text(String(turn.text.prefix(turn.text.count / 2)))
            await text(turn.text)
        }
        return turn
    }
}

private actor DraftRecorder {
    private(set) var drafts: [String] = []
    func record(_ text: String) {
        drafts.append(text)
    }
}

private actor ConversationToolCounter {
    private(set) var count = 0
    func dispatch(_: AgentCall) -> String {
        count += 1; return "{}"
    }
}

@Suite(.serialized) struct ConversationAgentTests {
    private func call(
        _ name: String,
        _ arguments: [String: Any] = [:],
        id: String = UUID().uuidString
    ) throws -> AgentTurn {
        try AgentTurn(calls: [AgentCall(
            id: id,
            name: name,
            arguments: String(
                decoding: JSONSerialization.data(withJSONObject: arguments),
                as: UTF8.self
            )
        )])
    }

    private func result(_ inputs: [[Data]], id: String) throws -> String {
        let last = try #require(inputs.last)
        for data in last.reversed() {
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if object["call_id"] as? String == id,
               let value = object["output"] as? String
            {
                return value
            }
        }
        Issue.record("No application result for \(id)")
        return ""
    }

    @Test func followUpRetainsAllLinksBeyondTheHistoryAndItemExcerpts() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let links = (0 ..< 13).map { "[Resource \($0)](https://fixture.example/source-\($0))" }
            .joined(separator: "\n")
        let body = String(repeating: "Synthetic research context. ", count: 350) + "\n\n" + links
        let note = try await fixture.note("Synthetic resource research", body: body)
        let prior = try await fixture.store.beginConversation("Find resources", owner: .researcher)
        try await fixture.store.postConversation(
            author: .researcher,
            text: body,
            references: [note.id],
            taskID: prior
        )
        try await fixture.store.updateConversationTask(
            prior,
            state: "succeeded",
            progress: "Completed"
        )
        let model = try ConversationToolFixture([
            call("get_item_links", ["item": "i1", "offset": 0], id: "links"),
            call("capture_sources", ["sources": (1 ... 13).map { "u\($0)" }], id: "capture-many"),
            AgentTurn(text: "Retained 13 sources. Filing is separate from capture."),
        ])
        let fetcher = ConversationSourceFetcher()
        let task = try await fixture.store.beginConversation(
            "Add all the resources you found as sources",
            owner: .assistant
        )
        let coordinator = AgentCoordinator(store: fixture.store, fetcher: fetcher, inference: model)
        try await coordinator.execute(
            taskID: task,
            request: "Add all the resources you found as sources",
            selected: [],
            changed: {}
        )
        let fetchCount = await fetcher.sourceCalls
        #expect(fetchCount == 13)
        #expect(try fixture.counts()["captures"] == 13)
        #expect(try fixture.counts()["notes"] == 14)
        #expect(try await fixture.store.linkedItems(for: note.id).count == 13)
        #expect(try await result(model.inputs, id: "links").contains("source-12"))
        let rows = try #require(try await JSONSerialization.jsonObject(with: Data(result(
            model.inputs,
            id: "capture-many"
        ).utf8)) as? [[String: Any]])
        #expect(rows.count == 13 && rows.allSatisfy { $0["state"] as? String == "ready" })
        #expect(await model.plans == 0)
        #expect(try await fixture.store.document(id: note.id)?.markdown == body)
        let repeatModel = try ConversationToolFixture([
            call("get_item_links", ["item": "i1", "offset": 0]),
            call("capture_sources", ["sources": (1 ... 13).map { "u\($0)" }]),
            AgentTurn(text: "The existing retained Sources were reused."),
        ])
        let retry = try await fixture.store.beginConversation(
            "Retain these linked resources again",
            owner: .assistant,
            sources: [note.id]
        )
        try await AgentCoordinator(store: fixture.store, fetcher: fetcher, inference: repeatModel)
            .execute(
                taskID: retry,
                request: "Retain these linked resources again",
                selected: [note.id],
                changed: {}
            )
        #expect(await fetcher.sourceCalls == fetchCount)
        #expect(try fixture.counts()["captures"] == 13)
    }

    @Test func failedSourceCapturesRemainVisibleWithoutClaimingBatchSuccess() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note(
            "Resources",
            body: "[Good](https://fixture.example/source-good)\n[Failed](https://fixture.example/source-failed)"
        )
        let model = try ConversationToolFixture([
            call("get_item_links", ["item": "i1", "offset": 0]),
            call("capture_sources", ["sources": ["u1", "u2"]], id: "batch"),
            AgentTurn(text: "One Source is retained; the other capture failed and can be retried."),
        ])
        let fetcher = ConversationSourceFetcher(failing: ["/source-failed"])
        let task = try await fixture.store.beginConversation(
            "Retain the linked sources",
            owner: .assistant,
            sources: [note.id]
        )
        try await AgentCoordinator(store: fixture.store, fetcher: fetcher, inference: model)
            .execute(
                taskID: task,
                request: "Retain the linked sources",
                selected: [note.id],
                changed: {}
            )
        let jobs = try await fixture.store.captureJobs()
        #expect(jobs.filter { $0.state == .ready }.count == 1)
        #expect(jobs.filter { $0.state == .failed }.count == 1)
        #expect(try await fixture.store.conversationTasks().first { $0.id == task }?
            .state == "failed")
        #expect(try await result(model.inputs, id: "batch").contains("failed"))
        #expect(try fixture.counts()["captures"] == 1)
    }

    @Test func oneRequestCanPublishAResourceListThenRetainItsSources() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let one = try #require(URL(string: "https://fixture.example/source-one"))
        let two = try #require(URL(string: "https://fixture.example/source-two"))
        let web = WebResearchResult(passages: [.init(text: "One [1]. Two [2].", citations: [
            .init(startIndex: 4, endIndex: 7, title: "One", url: one),
            .init(startIndex: 13, endIndex: 16, title: "Two", url: two),
        ])], consultedURLs: [one, two], searchCount: 1)
        let model = try ConversationToolFixture([
            call(
                "start_workflow",
                ["workflow": "research_web", "items": [], "url": "", "content": ""]
            ),
            call("get_item_links", ["item": "i1", "offset": 0]),
            call("capture_sources", ["sources": ["u1", "u2"]]),
            AgentTurn(text: "Saved the resource list and retained its two linked Sources."),
        ], webResult: web)
        let task = try await fixture.store.beginConversation(
            "Find public resources on the web and retain them as sources",
            owner: .assistant
        )
        let fetcher = ConversationSourceFetcher()
        try await AgentCoordinator(store: fixture.store, fetcher: fetcher, inference: model)
            .execute(
                taskID: task,
                request: "Find public resources on the web and retain them as sources",
                selected: [],
                changed: {}
            )
        let fetchCount = await fetcher.sourceCalls
        #expect(fetchCount == 2)
        #expect(try fixture.counts()["captures"] == 2)
        #expect(try fixture.counts()["notes"] == 3)
        #expect(try await fixture.store.conversationTasks().first { $0.id == task }?
            .state == "succeeded")
    }

    @Test func olderConversationRetrievalRestoresArtifactReferencesWithoutReadingFutureMessages(
    ) async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note(
            "Earlier research",
            body: "[Resource](https://fixture.example/resource)"
        )
        let prior = try await fixture.store.beginConversation("Discover", owner: .researcher)
        try await fixture.store.postConversation(
            author: .researcher,
            text: "An earlier result",
            references: [note.id],
            taskID: prior
        )
        for index in 0 ..< 14 {
            _ = try await fixture.store.beginConversation(
                "Synthetic intervening message \(index)",
                owner: .assistant
            )
        }
        let old = try await fixture.store.conversationMessages()
        let cursor = try #require(old.suffix(8).first?.sequence)
        let task = try await fixture.store.beginConversation(
            "Find the earlier resources",
            owner: .assistant
        )
        _ = try await fixture.store.beginConversation("LATER_SYNTHETIC_MESSAGE", owner: .assistant)
        let model = try ConversationToolFixture([
            call("read_conversation", ["before": 0], id: "latest"),
            call("read_conversation", ["before": cursor], id: "older"),
            call("get_item_links", ["item": "i1", "offset": 0], id: "links"),
            AgentTurn(text: "Retrieved the earlier resource list."),
        ])
        let beforeCounts = try fixture.counts()
        try await AgentCoordinator(store: fixture.store, inference: model).execute(
            taskID: task, request: "Find the earlier resources", selected: [], changed: {}
        )
        #expect(try await !result(model.inputs, id: "latest").contains("LATER_SYNTHETIC_MESSAGE"))
        #expect(try await result(model.inputs, id: "older").contains("Earlier research"))
        let linkResult = try #require(try await JSONSerialization.jsonObject(with: Data(result(
            model.inputs,
            id: "links"
        ).utf8)) as? [String: Any])
        let returnedLinks = try #require(linkResult["links"] as? [[String: String]])
        #expect(returnedLinks.first?["url"] == "https://fixture.example/resource")
        #expect(try fixture.counts() == beforeCounts)
    }

    @Test func linkReadsDoNotCaptureAndStaleOrInventedCandidatesCannotQueue() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        var note = try await fixture.note("Resources", body: "[One](https://fixture.example/one)")
        let toolbox = AgentToolbox(store: fixture.store, search: SearchEngine(store: fixture.store))
        _ = await toolbox.describe([note.id])
        let before = try fixture.counts()
        _ = try await toolbox
            .run(#require(call("get_item_links", ["item": "i1", "offset": 0]).calls.first))
        #expect(try fixture.counts() == before)
        await #expect(throws: (any Error).self) {
            try await toolbox.resolveSourceLinks(["https://fixture.example/one"])
        }
        note.markdown = "The link was removed."
        _ = try await fixture.store.save(note)
        await #expect(throws: (any Error).self) { try await toolbox.resolveSourceLinks(["u1"]) }
        #expect(try fixture.counts()["ingestion_jobs"] == 0)
    }

    @Test func taxonomyQuestionsReceiveModelAnswersAfterRealToolResults() async throws {
        for request in [
            "Do we have categories for audiophile reviews?",
            "Where does a lens comparison fit?",
            "音楽の記事を分類できますか？",
        ] {
            let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
            try await fixture.store.seedExampleCategories()
            let expected = try await fixture.store.categories().map(\.code)
            let before = try fixture.counts()
            let model = try ConversationToolFixture([call("list_categories", id: "taxonomy"),
                                                     AgentTurn(
                                                         text: "A model-authored, topic-specific answer."
                                                     )])
            let task = try await fixture.store.beginConversation(request, owner: .assistant)
            let coordinator = AgentCoordinator(store: fixture.store, inference: model)
            try await coordinator.execute(taskID: task, request: request, selected: [], changed: {})
            let messages = try await fixture.store.conversationMessages()
                .filter { $0.taskID == task && $0.author != "user" }
            #expect(messages.map(\.text) == ["A model-authored, topic-specific answer."])
            #expect(await model.plans == 0)
            let output = try await result(model.inputs, id: "taxonomy")
            for code in expected {
                #expect(output.contains(code))
            }
            #expect(try fixture.counts() == before)
        }
    }

    @Test @MainActor func ordinaryChatDoesNotAutoCaptureOrRejectMultipleURLs() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let model =
            ConversationToolFixture(
                [AgentTurn(text: "Those are links in your question, not a request to save them.")]
            )
        let coordinator = AgentCoordinator(store: fixture.store, inference: model)
        let chat = ConversationModel(store: fixture.store, coordinator: coordinator)
        await chat.load()
        let before = try fixture.counts()
        chat.composer = "Discuss https://fixture.example/one and https://fixture.example/two without saving them."
        await chat.send()
        while chat.running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.error == nil)
        #expect(try fixture.counts() == before)
        #expect(await model.inputs.count == 1)
        #expect(await model.plans == 0)
        #expect(chat.messages.last?
            .text == "Those are links in your question, not a request to save them.")
    }

    @Test func searchAndReadFeedTheModelInsteadOfPostingSearchTemplates() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note(
            "Synthetic optics",
            body: "A synthetic lens retains fine detail."
        )
        let model = try ConversationToolFixture([
            call("list_items", ["scope": "all", "category_code": "", "offset": 0]),
            call("get_item", ["item": "i1"], id: "read"),
            AgentTurn(text: "The saved optics note describes retained detail."),
        ])
        let task = try await fixture.store.beginConversation(
            "What do my saved notes say?",
            owner: .assistant
        )
        try await AgentCoordinator(store: fixture.store, inference: model).execute(
            taskID: task, request: "What do my saved notes say?", selected: [], changed: {}
        )
        let messages = try await fixture.store.conversationMessages()
            .filter { $0.taskID == task && $0.author != "user" }
        #expect(messages.count == 1 && messages.first?.references == [note.id])
        #expect(try await result(model.inputs, id: "read").contains(note.markdown))
    }

    @Test func reviewResultsAndUnknownApprovalToolsCannotApplyChanges() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note("Original title")
        let origin = try await fixture.store.beginConversation("Propose a title", owner: .assistant)
        try await fixture.store.saveAgentChanges(
            [.init(
                kind: .title,
                noteID: note.id,
                before: note.name,
                after: "Proposed title",
                reason: "Synthetic review",
                baseRevision: note.revision
            )],
            taskID: origin
        )
        let model = try ConversationToolFixture([
            call("review_state", id: "review"), call("apply_changes", id: "apply"),
            AgentTurn(text: "The title proposal is pending; use its review controls."),
        ])
        let task = try await fixture.store.beginConversation("Approve that", owner: .assistant)
        try await AgentCoordinator(store: fixture.store, inference: model).execute(
            taskID: task, request: "Approve that", selected: [], changed: {}
        )
        #expect(try await fixture.store.document(id: note.id)?.name == note.name)
        #expect(try await fixture.store.agentChanges(taskID: origin).first?.status == "pending")
        #expect(try await result(model.inputs, id: "review").contains("Proposed title"))
        #expect(try await result(model.inputs, id: "apply").contains("error"))
    }

    @Test func publishingIsModelChosenAndLimitedToOneWorkflow() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let model = try ConversationToolFixture([
            call(
                "start_workflow",
                [
                    "workflow": "save_note",
                    "items": [],
                    "url": "",
                    "content": "Synthetic personal thought.",
                ],
                id: "save"
            ),
            call(
                "start_workflow",
                [
                    "workflow": "save_note",
                    "items": ["invalid-after-completion"],
                    "url": "",
                    "content": "A duplicate save must not occur.",
                ],
                id: "duplicate"
            ),
            AgentTurn(text: "Your personal thought is saved."),
        ])
        let task = try await fixture.store.beginConversation(
            "Save my personal thought",
            owner: .assistant
        )
        try await AgentCoordinator(store: fixture.store, inference: model).execute(
            taskID: task, request: "Save my personal thought", selected: [], changed: {}
        )
        let notes = try await fixture.store.documents()
        #expect(notes.count == 1 && notes.first?.markdown == "Synthetic personal thought.")
        #expect(try await result(model.inputs, id: "save").contains("completed"))
        #expect(try await result(model.inputs, id: "duplicate").contains("already started"))
        #expect(try await fixture.store.conversationTasks().first { $0.id == task }?
            .state == "succeeded")
        #expect(try await fixture.store.conversationMessages().last?.references == notes.map(\.id))
        #expect(try await !fixture.store.conversationMessages()
            .contains { $0.text.hasPrefix("Saved your note") })
        #expect(await model.plans == 0)
    }

    @Test func inventedHandlesAndSourceURLsDoNotAuthorizeWorkflows() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let before = try fixture.counts()
        let model = try ConversationToolFixture([
            call(
                "start_workflow",
                ["workflow": "research_sources", "items": ["i99"], "url": "", "content": ""],
                id: "invented"
            ),
            call(
                "start_workflow",
                [
                    "workflow": "capture",
                    "items": [],
                    "url": "https://fixture.example/unrequested",
                    "content": "",
                ],
                id: "capture"
            ),
            AgentTurn(text: "No authorized source was supplied; nothing was saved."),
        ])
        let task = try await fixture.store.beginConversation(
            "Discuss what is available",
            owner: .assistant
        )
        try await AgentCoordinator(store: fixture.store, inference: model).execute(
            taskID: task, request: "Discuss what is available", selected: [], changed: {}
        )
        #expect(try fixture.counts() == before)
        #expect(try await result(model.inputs, id: "invented").contains("error"))
        #expect(try await result(model.inputs, id: "capture").contains("error"))
    }

    @Test func failedPublishingDoesNotBecomeACompletedTask() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note("Synthetic source", body: "Only a synthetic observation.")
        let model = try ConversationToolFixture([
            call(
                "start_workflow",
                ["workflow": "research_sources", "items": ["i1"], "url": "", "content": ""],
                id: "failed-research"
            ),
            AgentTurn(text: "The research workflow failed; no research note was saved."),
        ])
        let task = try await fixture.store.beginConversation(
            "Write a verified analysis",
            owner: .assistant,
            sources: [note.id]
        )
        try await AgentCoordinator(store: fixture.store, inference: model).execute(
            taskID: task, request: "Write a verified analysis", selected: [note.id], changed: {}
        )
        #expect(try await fixture.store.documents().map(\.id) == [note.id])
        #expect(try await fixture.store.conversationTasks().first { $0.id == task }?
            .state == "failed")
        #expect(try await result(model.inputs, id: "failed-research").contains("error"))
        #expect(try await fixture.store.conversationMessages().last?
            .text == "The research workflow failed; no research note was saved.")
    }

    @Test func captureSourceValidationPreservesTheWholeUserRequest() throws {
        let request = "@librarian Save https://fixture.example/one and compare with https://fixture.example/two, focusing on timing."
        let route = try AgentCoordinator.authorizedCaptureRoute(
            "https://fixture.example/two",
            request: request
        )
        #expect(route.url?.absoluteString == "https://fixture.example/two")
        #expect(route.text.contains("focusing on timing"))
        #expect(route.roles == [.librarian])
        #expect(throws: ConversationError.self) {
            try AgentCoordinator.authorizedCaptureRoute(
                "https://fixture.example/",
                request: request
            )
        }
        #expect(throws: ConversationError.self) {
            try AgentCoordinator.authorizedCaptureRoute(
                "https://fixture.example/from-retrieved-content",
                request: request
            )
        }
    }

    @Test func modelProposedConnectionsStayOnReviewCards() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let left = try await fixture.note("Synthetic left")
        let right = try await fixture.note("Synthetic right")
        let model = try ConversationToolFixture([
            call("get_item", ["item": "i1"]), call("get_item", ["item": "i2"]),
            call(
                "propose_link",
                ["item": "i1", "target": "i2", "reason": "Shared synthetic topic"]
            ),
            AgentTurn(text: "A connection is ready for review; nothing is applied."),
        ])
        let task = try await fixture.store.beginConversation(
            "Propose a connection",
            owner: .assistant,
            sources: [left.id, right.id]
        )
        try await AgentCoordinator(store: fixture.store, inference: model).execute(
            taskID: task, request: "Propose a connection", selected: [left.id, right.id],
            changed: {}
        )
        let changes = try await fixture.store.agentChanges(taskID: task)
        #expect(changes.map(\.kind) == [.link])
        #expect(changes.first?.status == "pending")
        #expect(try await fixture.store.linkedItems(for: left.id).isEmpty)
    }

    @Test func emptyModelReplyDoesNotBecomeACannedSuccess() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let model = ConversationToolFixture([AgentTurn()])
        let task = try await fixture.store.beginConversation("Hello", owner: .assistant)
        await #expect(throws: ConversationError.self) {
            try await AgentCoordinator(store: fixture.store, inference: model).execute(
                taskID: task, request: "Hello", selected: [], changed: {}
            )
        }
        #expect(try await fixture.store.conversationMessages().allSatisfy { $0.author == "user" })
    }

    @Test func repeatedCallIDsStopBeforeReexecutingTheTool() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let model = try ConversationToolFixture([call("list_categories", id: "same"),
                                                 call("list_categories", id: "same")])
        let agent = LibraryAgent(
            model: model,
            toolbox: AgentToolbox(store: fixture.store, search: SearchEngine(store: fixture.store))
        )
        await #expect(throws: AgentLoopError.self) {
            try await agent.run(
                request: "Read the taxonomy",
                history: [],
                selected: [],
                progress: { _ in }
            )
        }
        #expect(await model.inputs.count == 2)
    }

    @Test func turnBudgetDoesNotInventAFinalReply() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let turns = try (0 ..< LibraryAgent.maximumTurns + 1).map { try call(
            "list_categories",
            id: "call-\($0)"
        ) }
        let model = ConversationToolFixture(turns)
        let agent = LibraryAgent(
            model: model,
            toolbox: AgentToolbox(store: fixture.store, search: SearchEngine(store: fixture.store))
        )
        await #expect(throws: AgentLoopError.self) {
            try await agent.run(request: "Read", history: [], selected: [], progress: { _ in })
        }
        #expect(await model.inputs.count == LibraryAgent.maximumTurns)
    }

    @Test func callBudgetStopsBeforeExecutingTheExtraCall() async throws {
        let calls = (0 ... LibraryAgent.maximumCalls).map {
            AgentCall(id: "call-\($0)", name: "fixture", arguments: "{}")
        }
        let model = ConversationToolFixture([AgentTurn(calls: calls)])
        let counter = ConversationToolCounter()
        let loop = ToolLoop(model: model, instructions: "Fixture", tools: Data("[]".utf8))
        await #expect(throws: AgentLoopError.self) {
            try await loop.run(input: [], dispatch: { await counter.dispatch($0) }, progress: {})
        }
        #expect(await counter.count == LibraryAgent.maximumCalls)
    }

    @Test func toolLoopStreamsTheReplyAndWithdrawsTextBeforeToolCalls() async throws {
        let model = StreamingToolFixture([
            AgentTurn(
                calls: [AgentCall(id: "call-1", name: "fixture", arguments: "{}")],
                text: "Checking"
            ),
            AgentTurn(text: "Done."),
        ])
        let recorder = DraftRecorder()
        let loop = ToolLoop(model: model, instructions: "Fixture", tools: Data("[]".utf8))
        let reply = try await loop.run(
            input: [],
            dispatch: { _ in "{}" },
            progress: {},
            text: { await recorder.record($0) }
        )
        #expect(reply == "Done.")
        #expect(await recorder.drafts == ["Chec", "Checking", "", "Do", "Done."])
    }

    @Test func cancellationDuringAModelTurnExecutesNoTools() async throws {
        let model = try ConversationToolFixture([call("list_categories")], delay: .seconds(30))
        let counter = ConversationToolCounter()
        let loop = ToolLoop(model: model, instructions: "Fixture", tools: Data("[]".utf8))
        let work = Task { try await loop.run(
            input: [],
            dispatch: { await counter.dispatch($0) },
            progress: {}
        ) }
        for _ in 0 ..< 100 {
            if await !model.inputs.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(await counter.count == 0)
    }

    @Test func invalidReadArgumentsDoNotDefaultToReadingEverything() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let toolbox = AgentToolbox(store: fixture.store, search: SearchEngine(store: fixture.store))
        for arguments: [String: Any] in [
            ["scope": "invented", "category_code": "", "offset": 0],
            ["scope": "all", "category_code": "", "offset": true],
            ["scope": "all", "category_code": "", "offset": -1],
            ["scope": "all", "category_code": "", "offset": 0, "extra": "instruction"],
        ] {
            let turn = try call("list_items", arguments)
            let output = try await toolbox.run(#require(turn.calls.first))
            #expect(output.contains("error"))
            #expect(!output.contains("items"))
        }
    }

    @Test func terminalTasksRemainFencedAgainstLateToolOutcomes() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        for state in ["cancelled", "failed", "succeeded"] {
            let task = try await fixture.store.beginConversation("Fixture", owner: .assistant)
            try await fixture.store.updateConversationTask(task, state: state, progress: state)
            await #expect(throws: CancellationError.self) {
                try await fixture.store.postConversation(
                    author: .assistant,
                    text: "Late reply",
                    taskID: task,
                    isToolOutcome: true
                )
            }
        }
    }

    @Test func bothProvidersOfferTheSameToolContractsWithoutLiveInference() throws {
        let tools = try AgentToolbox.definitions(
            includingWorkflows: true,
            includingSourceCaptures: true
        )
        _ = try AppleConversationInference.agentSchema(tools: tools)
        let provider: any AgentResponding = AppleConversationInference()
        _ = provider
        let prompt = try AppleConversationInference.agentPrompt(
            input: [Data("Synthetic request".utf8)],
            tools: tools,
            instructions: LibraryAgent.instructions + String(repeating: " ", count: 1000)
        )
        #expect(prompt.contains("start_workflow") && prompt.contains("list_categories"))
        #expect(throws: LocalAgentError.self) {
            try AppleConversationInference.agentPrompt(
                input: [Data(repeating: 120, count: AppleConversationInference.agentPromptLimit)],
                tools: tools
            )
        }
    }
}
