import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

/// Plays back scripted turns and records what the loop sent, standing in for ChatGPT.
private actor ScriptedAgent: ConversationInferring, AgentResponding {
    nonisolated let capabilities = InferenceCapabilities(
        identifier: "fixture.agent", local: false, structured: true, streaming: true
    )
    private var turns: [AgentTurn]
    private(set) var inputs: [[Data]] = []

    init(_ turns: [AgentTurn]) {
        self.turns = turns
    }

    func agentTurn(instructions _: String, input: [Data], tools _: Data) throws -> AgentTurn {
        inputs.append(input)
        return turns.isEmpty ? AgentTurn(text: "Nothing left.") : turns.removeFirst()
    }

    func plan(request _: String, context _: ConversationPlanningContext) -> ConversationPlan {
        ConversationPlan(steps: [.init(action: .organize)])
    }

    nonisolated func research(question _: String, sources _: [ResearchSource])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func reply(question _: String, role _: AgentRole, history _: [ConversationTurn])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}

private func call(_ id: String, _ name: String, _ arguments: [String: Any]) -> AgentCall {
    let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data()
    return AgentCall(id: id, name: name, arguments: String(decoding: data, as: UTF8.self))
}

private func turn(_ calls: AgentCall...) -> AgentTurn {
    AgentTurn(calls: calls)
}

@Suite(.serialized) struct LibraryAgentTests {
    private func fixture() async throws -> (URL, DocumentStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        try await store.seedExampleCategories()
        return (root, store)
    }

    @Test func appliesAndUndoesAChangeset() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(
            name: "Fixture Blog | How we cut build times in half with caching",
            markdown: "Caching cut fixture build times."
        ))
        let task = try await store.beginConversation("retitle", owner: .librarian)
        let target = try #require(await store.categories().first { $0.code == "31.04" })
        try await store.saveAgentChanges([
            AgentChangeDraft(
                kind: .category, code: "31.09", before: "", after: "Build systems",
                reason: "New home"
            ),
            AgentChangeDraft(
                kind: .title, noteID: note.id, before: note.name,
                after: "Faster builds with caching",
                reason: "Shorter", baseRevision: note.revision
            ),
            AgentChangeDraft(
                kind: .summary, noteID: note.id, before: note.markdown,
                after: "- Caching halves builds.",
                reason: "Tighter", baseRevision: note.revision
            ),
            AgentChangeDraft(
                kind: .filing, noteID: note.id, code: "31.09", before: "Unfiled",
                after: "31.09 Build systems", reason: "Fits"
            ),
        ], taskID: task)
        let changes = try await store.agentChanges(taskID: task)
        #expect(changes.map(\.kind) == [.category, .title, .summary, .filing])

        let report = try await store.applyAgentChanges(changes.map(\.id))
        #expect(report == AgentApplyReport(applied: 4, stale: 0))
        let renamed = try #require(await store.document(id: note.id))
        #expect(renamed.name == "Faster builds with caching")
        #expect(renamed.markdown == "- Caching halves builds.")
        #expect(try await store.categories(for: note.id).first?.code == "31.09")
        #expect(target.code == "31.04")

        #expect(try await store.undoAgentChanges(changes.map(\.id)) == 4)
        let restored = try #require(await store.document(id: note.id))
        #expect(restored.name == note.name)
        #expect(restored.markdown == note.markdown)
        #expect(try await store.categories(for: note.id).isEmpty)
        #expect(try await !store.categories().contains { $0.code == "31.09" })
        #expect(try await store.agentChanges(taskID: task).allSatisfy { $0.status == "undone" })
    }

    @Test func editedItemsGoStaleInsteadOfBeingOverwritten() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(name: "Draft", markdown: "Body"))
        let task = try await store.beginConversation("retitle", owner: .librarian)
        try await store.saveAgentChanges([AgentChangeDraft(
            kind: .title, noteID: note.id, before: "Draft", after: "Proposal",
            reason: "", baseRevision: note.revision
        )], taskID: task)
        var edited = note
        edited.name = "Edited by hand"
        _ = try await store.save(edited)
        let changes = try await store.agentChanges(taskID: task)
        #expect(try await store.applyAgentChanges(changes.map(\.id)) == AgentApplyReport(
            applied: 0,
            stale: 1
        ))
        #expect(try await store.document(id: note.id)?.name == "Edited by hand")
        #expect(try await store.agentChanges(taskID: task).first?.status == "stale")
    }

    @Test func toolboxOnlyChangesItemsItHasRead() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(name: "Long title", markdown: "Body"))
        let toolbox = AgentToolbox(store: store, search: SearchEngine(store: store))
        let unknown = await toolbox.run(call("a", "propose_title", [
            "item": "i9", "title": "Short", "reason": "",
        ]))
        #expect(unknown.contains("Unknown item handle"))
        _ = await toolbox.describe([note.id])
        let unread = await toolbox.run(call("b", "propose_title", [
            "item": "i1", "title": "Short", "reason": "",
        ]))
        #expect(unread.contains("get_item"))
        let read = await toolbox.run(call("c", "get_item", ["item": "i1"]))
        #expect(read.contains("untrusted_content"))
        _ = await toolbox.run(call(
            "d",
            "propose_title",
            ["item": "i1", "title": "Short", "reason": ""]
        ))
        // Filing into a category the agent proposes in the same run is allowed.
        let missing = await toolbox.run(call("e", "propose_filing", [
            "item": "i1", "category_code": "31.09", "reason": "",
        ]))
        #expect(missing.contains("Propose it first"))
        _ = await toolbox.run(call("f", "propose_category", [
            "code": "31.09", "name": "Build systems", "reason": "",
        ]))
        _ = await toolbox.run(call("g", "propose_filing", [
            "item": "i1", "category_code": "31.09", "reason": "",
        ]))
        let duplicate = await toolbox.run(call("h", "propose_category", [
            "code": "39", "name": "Inbox", "reason": "",
        ]))
        #expect(duplicate.contains("already exists"))
        #expect(await toolbox.changes.map(\.kind) == [.title, .category, .filing])
    }

    @Test @MainActor func chatRunsTheAgentAndShowsAReviewableChangeset() async throws {
        let (root, store) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try await store.save(MarkdownDocument(
            name: "Fixture Corp Engineering Blog | Notes on cobaltbeacon caching",
            markdown: "Cobaltbeacon caching notes."
        ))
        let agent = ScriptedAgent([
            turn(call("1", "list_items", ["scope": "all", "category_code": "", "offset": 0])),
            turn(call("2", "get_item", ["item": "i1"])),
            turn(call("3", "propose_title", [
                "item": "i1", "title": "Cobaltbeacon caching notes",
                "reason": "Drops the blog name",
            ])),
            AgentTurn(text: "Proposed 1 shorter title."),
        ])
        let coordinator = AgentCoordinator(store: store, inference: agent)
        let model = ConversationModel(store: store, coordinator: coordinator)
        await model.load()
        model.composer = "retitle everything with shorter titles"
        await model.send()
        while model.running {
            try await Task.sleep(for: .milliseconds(20))
        }
        await model.refresh()
        let reply = try #require(model.messages.last { $0.author == AgentRole.librarian.rawValue })
        #expect(reply.text == "Proposed 1 shorter title.")
        let taskID = try #require(reply.taskID)
        let changes = try #require(model.agentChanges[taskID])
        #expect(changes.map(\.after) == ["Cobaltbeacon caching notes"])
        #expect(try await store.document(id: note.id)?.name == note.name)

        // Each turn resends the whole exchange, ending with the last tool result.
        let inputs = await agent.inputs
        #expect(inputs.count == 4)
        let last = try #require(inputs.last?.last)
        let object = try #require(JSONSerialization.jsonObject(with: last) as? [String: Any])
        #expect(object["type"] as? String == "function_call_output")
        #expect(object["call_id"] as? String == "3")

        await model.applyAgentChanges(Set(changes.map(\.id)), of: changes)
        #expect(try await store.document(id: note.id)?.name == "Cobaltbeacon caching notes")
        await model.undoAgentChanges(model.agentChanges[changes[0].taskID] ?? [])
        #expect(try await store.document(id: note.id)?.name == note.name)
    }

    @Test func decoderCollectsCallsAndReplayableItems() throws {
        var decoder = ChatGPTAgentDecoder()
        let events = [
            #"{"type":"response.created"}"#,
            #"{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[]}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_item","arguments":"{\"item\":\"i1\"}"}}"#,
            #"{"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Reading."}]}}"#,
            #"{"type":"response.completed","response":{"status":"completed"}}"#,
        ]
        var result: AgentTurn?
        for event in events {
            _ = try decoder.consume("data: " + event)
            result = try decoder.consume("") ?? result
        }
        let turn = try #require(result)
        #expect(turn.calls == [AgentCall(
            id: "call_1",
            name: "get_item",
            arguments: #"{"item":"i1"}"#
        )])
        #expect(turn.text == "Reading.")
        // Reasoning can't be replayed without stored state, and item IDs are dropped.
        #expect(turn.output.count == 2)
        let replayed = try #require(JSONSerialization
            .jsonObject(with: turn.output[0]) as? [String: Any])
        #expect(replayed["id"] == nil)
        #expect(replayed["call_id"] as? String == "call_1")

        var failing = ChatGPTAgentDecoder()
        _ = try failing
            .consume(
                #"data: {"type":"response.failed","response":{"error":{"code":"server_error"}}}"#
            )
        #expect(throws: ChatGPTError.self) { try failing.consume("") }
    }

    @Test func requestBodyCarriesToolsWithoutStoredState() throws {
        let tools = try AgentToolbox.definitions()
        let body = try ChatGPTConversationInference.agentRequestBody(
            model: "fixture-model", instructions: "Help.", input: [
                JSONSerialization.data(withJSONObject: ["role": "user", "content": "hi"]),
            ], tools: tools
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        let names = (json["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names?.contains("propose_title") == true)
        #expect((json["tools"] as? [[String: Any]])?
            .allSatisfy { $0["strict"] as? Bool == true } == true)
    }

    /// Renders the review sheet and card for a visual check when GLEANARY_AGENT_SCREENSHOTS
    /// names a directory.
    @Test @MainActor func reviewSheetRenders() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GLEANARY_AGENT_SCREENSHOTS"]
        else { return }
        let note = UUID(), other = UUID(), task = UUID()
        func change(
            _ kind: AgentChange.Kind,
            _ id: UUID?,
            _ code: String?,
            _ before: String,
            _ after: String,
            _ reason: String
        ) -> AgentChange {
            AgentChange(
                id: UUID(), taskID: task, kind: kind, noteID: id, code: code, before: before,
                after: after, reason: reason, status: "pending"
            )
        }
        let changes = [
            change(
                .category,
                nil,
                "31.09",
                "",
                "Build systems",
                "Several build posts have no home"
            ),
            change(
                .title,
                note,
                nil,
                "Fixture Corp Engineering Blog | How we cut build times in half",
                "Cutting build times in half",
                "Drops the blog name"
            ),
            change(
                .title,
                other,
                nil,
                "PEP 701 – Syntactic formalization of f-strings | peps.python.org",
                "PEP 701: f-string syntax",
                "Shorter"
            ),
            change(
                .filing,
                note,
                "31.09",
                "10 Inbox",
                "31.09 Build systems",
                "About build caching"
            ),
            change(
                .summary,
                other,
                nil,
                "Long text",
                "- f-strings get a formal grammar.",
                "Tighter"
            ),
        ]
        let titles = [note: "Cutting build times in half", other: "PEP 701: f-string syntax"]
        for (name, view) in [
            (
                "agent-review",
                AnyView(AgentChangesReview(
                    changes: changes,
                    titles: titles,
                    apply: { _ in },
                    reject: {}
                ))
            ),
            (
                "agent-card",
                AnyView(AgentChangesCard(changes: changes, review: {}, undo: {}).frame(width: 560)
                    .padding())
            ),
        ] {
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: host.fittingSize),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        }
    }
}
