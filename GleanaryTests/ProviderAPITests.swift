import Foundation
@testable import Gleanary
import Testing

private final class MemoryKeyVault: ChatGPTCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func load() throws -> Data? {
        lock.withLock { data }
    }

    func save(_ data: Data) throws {
        lock.withLock { self.data = data }
    }
}

/// Answers each request by URL path: a JSON document for plain requests, or event-stream lines.
private actor ProviderFixture: ChatGPTTransporting {
    struct Reply {
        var status = 200
        var body = Data("{}".utf8)
        var lines: [String] = []

        init(status: Int = 200, json: [String: Any] = [:], lines: [String] = []) {
            self.status = status
            body = (try? JSONSerialization.data(withJSONObject: json)) ?? body
            self.lines = lines
        }
    }

    private let replies: [String: Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [String: Reply]) {
        self.replies = replies
    }

    private func reply(_ request: URLRequest) throws -> Reply {
        requests.append(request)
        let path = request.url?.path() ?? ""
        guard let reply = replies.first(where: { path.hasSuffix($0.key) })?.value
        else { throw ChatGPTError.network }
        return reply
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try reply(request)
        let url = try #require(request.url)
        return try (
            reply.body,
            #require(HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil
            ))
        )
    }

    nonisolated func lines(for request: URLRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let reply = try await self.reply(request)
                    guard reply.status == 200 else {
                        throw ProviderHTTPError(
                            status: reply.status,
                            body: reply.body
                        )
                    }
                    for line in reply.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}

private func events(_ payloads: [Any]) throws -> [String] {
    try payloads.flatMap { payload -> [String] in
        let text = try (payload as? String)
            ?? String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return ["data: " + text, ""]
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func keys(_ saved: [InferenceProvider: String]) async throws -> ProviderKeys {
    let keys = ProviderKeys(vault: MemoryKeyVault())
    for (provider, key) in saved {
        try await keys.save(key, for: provider)
    }
    return keys
}

/// A tool round trip in the Responses shapes the tool loop keeps.
private func toolHistory(signature: String? = nil) throws -> [Data] {
    try [
        JSONSerialization.data(withJSONObject: ["role": "assistant", "content": "Earlier reply"]),
        JSONSerialization.data(withJSONObject: ["role": "user", "content": "Find notes on tides"]),
        HostedItem.callItem(
            id: "call-1", name: "search_library", arguments: #"{"query":"tides"}"#,
            signature: signature
        ),
        JSONSerialization.data(withJSONObject: [
            "type": "function_call_output", "call_id": "call-1", "output": "i1: Tide tables",
        ]),
    ]
}

private func sampleSchema() -> [String: Any] {
    [
        "type": "object", "additionalProperties": false, "required": ["title"],
        "properties": ["title": ["type": "string", "minLength": 1, "maxLength": 80]],
    ]
}

struct ProviderAPITests {
    @Test func claudeRequestsForceTheSchemaToolAndPairToolResults() throws {
        let structured = try object(AnthropicAPI.body(
            model: "claude-fixture",
            request: .prompt(
                "Name it",
                instructions: "Be brief",
                name: "note_title",
                schema: sampleSchema()
            )
        ))
        #expect(structured["system"] as? String == "Be brief")
        #expect((structured["tool_choice"] as? [String: String]) == [
            "type": "tool",
            "name": "note_title",
        ])
        let tool = try #require((structured["tools"] as? [[String: Any]])?.first)
        #expect(tool["input_schema"] as? NSDictionary == sampleSchema() as NSDictionary)

        let agent = try object(AnthropicAPI.body(model: "claude-fixture", request: HostedRequest(
            instructions: "Help", input: toolHistory(),
            tools: AgentToolbox.definitions()
        )))
        let messages = try #require(agent["messages"] as? [[String: Any]])
        // Claude starts with the user, so a history opening on a reply gets a placeholder turn.
        #expect(messages.map { $0["role"] as? String } == [
            "user",
            "assistant",
            "user",
            "assistant",
            "user",
        ])
        let call = try #require((messages[3]["content"] as? [[String: Any]])?.first)
        #expect(call["type"] as? String == "tool_use")
        #expect((call["input"] as? [String: String]) == ["query": "tides"])
        let result = try #require((messages[4]["content"] as? [[String: Any]])?.first)
        #expect(result["tool_use_id"] as? String == "call-1")
        let tools = try #require(agent["tools"] as? [[String: Any]])
        #expect(!tools.isEmpty && tools.allSatisfy { $0["input_schema"] is [String: Any] })
    }

    @Test func claudeStreamsReplyTextToolCallsAndSchemaInput() throws {
        var decoder = AnthropicStreamDecoder(structured: false)
        let stream: [[String: Any]] = [
            ["type": "message_start"],
            [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "text", "text": ""],
            ],
            [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": "Looking"],
            ],
            ["type": "content_block_start", "index": 1, "content_block": [
                "type": "tool_use", "id": "toolu_1", "name": "search_library", "input": [:],
            ]],
            ["type": "content_block_delta", "index": 1, "delta": [
                "type": "input_json_delta", "partial_json": #"{"query":"#,
            ]],
            ["type": "content_block_delta", "index": 1, "delta": [
                "type": "input_json_delta", "partial_json": #""tides"}"#,
            ]],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"]],
        ]
        for event in stream {
            let payload = try String(
                decoding: JSONSerialization.data(withJSONObject: event),
                as: UTF8.self
            )
            #expect(try decoder.consume(payload) == nil)
        }
        #expect(decoder.streamedText == "Looking")
        let turn = try #require(try decoder.consume(#"{"type":"message_stop"}"#))
        #expect(turn.text == "Looking")
        #expect(turn.calls == [AgentCall(
            id: "toolu_1",
            name: "search_library",
            arguments: #"{"query":"tides"}"#
        )])
        #expect(try HostedItem.read(turn.output).count == 2)

        var schema = AnthropicStreamDecoder(structured: true)
        _ = try schema
            .consume(
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"note_title"}}"#
            )
        _ = try schema
            .consume(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"title\":\"Tides\"}"}}"#
            )
        #expect(try schema.consume(#"{"type":"message_stop"}"#)?.text == #"{"title":"Tides"}"#)

        var failing = AnthropicStreamDecoder(structured: false)
        #expect(throws: ChatGPTError.provider("Anthropic", .overloaded)) {
            try failing
                .consume(
                    #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
                )
        }
    }

    @Test func geminiKeepsSupportedSchemaKeywordsAndReturnsThoughtSignatures() throws {
        let structured = try object(GeminiAPI.body(
            .prompt("Name it", instructions: "Be brief", name: "note_title", schema: sampleSchema())
        ))
        let config = try #require(structured["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        let schema = try #require(config["responseJsonSchema"] as? [String: Any])
        let title =
            try #require((schema["properties"] as? [String: Any])?["title"] as? [String: Any])
        #expect(title as NSDictionary == ["type": "string"] as NSDictionary)
        #expect(schema["additionalProperties"] as? Bool == false)

        let agent = try object(GeminiAPI.body(HostedRequest(
            instructions: "Help", input: toolHistory(signature: "sig-1"),
            tools: AgentToolbox.definitions()
        )))
        let contents = try #require(agent["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["model", "user", "model", "user"])
        let callPart = try #require((contents[2]["parts"] as? [[String: Any]])?.first)
        #expect(callPart["thoughtSignature"] as? String == "sig-1")
        #expect((callPart["functionCall"] as? [String: Any])?["id"] as? String == "call-1")
        let response = try #require(
            (contents[3]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any]
        )
        // Gemini answers a call by its function's name, which the result item doesn't carry.
        #expect(response["name"] as? String == "search_library")
        let declarations = try #require(
            (agent["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]]
        )
        #expect(declarations.allSatisfy { $0["parametersJsonSchema"] is [String: Any] })

        var decoder = GeminiStreamDecoder()
        try decoder
            .consume(
                #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Planning","thought":true},{"text":"Let me "}]}}]}"#
            )
        try decoder
            .consume(
                #"{"candidates":[{"content":{"role":"model","parts":[{"text":"check."},{"functionCall":{"name":"search_library","args":{"query":"tides"}},"thoughtSignature":"sig-2"}]},"finishReason":"STOP"}]}"#
            )
        #expect(decoder.streamedText == "Let me check.")
        let turn = try decoder.turn()
        #expect(turn.text == "Let me check.")
        let call = try #require(turn.calls.first)
        #expect(call.id.hasPrefix(GeminiStreamDecoder.localCallPrefix))
        guard case let .call(_, _, _, signature) = try HostedItem.read(turn.output)[1] else {
            Issue.record("Expected a call item")
            return
        }
        #expect(signature == "sig-2")
        // An app-named call isn't sent back with an ID Gemini never gave it.
        let replayed = try GeminiAPI.contents(HostedItem.read(turn.output))
        let part = try #require((replayed.first?["parts"] as? [[String: Any]])?.last)
        #expect((part["functionCall"] as? [String: Any])?["id"] == nil)
    }

    @Test func geminiGroundingCitesAfterEachSupportedSpan() throws {
        let response: [String: Any] = ["candidates": [[
            "content": ["parts": [["text": "Tides follow the moon. Café owners know it."]]],
            "finishReason": "STOP",
            "groundingMetadata": [
                "webSearchQueries": ["tides moon"],
                "groundingChunks": [
                    ["web": ["uri": "https://example.org/tides", "title": "example.org"]],
                    ["web": ["uri": "https://example.net/cafe", "title": "example.net"]],
                ],
                "groundingSupports": [
                    ["segment": ["startIndex": 0, "endIndex": 22], "groundingChunkIndices": [0]],
                    // Byte offsets: "é" is two UTF-8 bytes.
                    [
                        "segment": ["startIndex": 23, "endIndex": 44],
                        "groundingChunkIndices": [0, 1],
                    ],
                ],
            ],
        ]]]
        let markdown = try GeminiAPI.webResult(response).markdown()
        #expect(markdown.hasPrefix(
            "Tides follow the moon.[Web 1](<https://example.org/tides>) Café owners know it."
                + "[Web 1](<https://example.org/tides>)[Web 2](<https://example.net/cafe>)"
        ))
    }

    @Test func claudeAndOpenRouterWebAnswersRenderTheirCitations() throws {
        let claude = AnthropicAPI.webResult([
            ["type": "server_tool_use", "name": "web_search"],
            ["type": "web_search_tool_result", "content": [
                ["type": "web_search_result", "url": "https://example.org/a", "title": "A"],
            ]],
            ["type": "text", "text": "Tides follow the moon.", "citations": [
                [
                    "type": "web_search_result_location",
                    "url": "https://example.org/a",
                    "title": "A",
                ],
            ]],
        ])
        #expect(try claude.markdown()
            .hasPrefix("Tides follow the moon.[Web 1](<https://example.org/a>)"))

        let routed = OpenRouterAPI.webResult(["choices": [["message": [
            "content": "Tides follow the moon.",
            "annotations": [["type": "url_citation", "url_citation": [
                "url": "https://example.org/b", "title": "B",
            ]]],
        ]]]])
        #expect(try routed.markdown().contains("[Web 1](<https://example.org/b>)"))
        // An answer without citations isn't saved as web research.
        #expect(throws: ConversationError.self) {
            try OpenRouterAPI.webResult(["choices": [["message": ["content": "Uncited"]]]])
                .markdown()
        }
    }

    @Test func openRouterGroupsToolCallsAndRoutesOnlyToCapableHosts() throws {
        let body = try object(OpenRouterAPI.body(model: "vendor/model", request: HostedRequest(
            instructions: "Help", input: toolHistory(), tools: AgentToolbox.definitions()
        )))
        #expect((body["provider"] as? [String: Bool]) == ["require_parameters": true])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == [
            "system",
            "assistant",
            "user",
            "assistant",
            "tool",
        ])
        #expect((messages[3]["tool_calls"] as? [[String: Any]])?.count == 1)
        #expect(messages[4]["tool_call_id"] as? String == "call-1")

        var decoder = ChatCompletionsDecoder()
        for chunk in [
            #"{"choices":[{"delta":{"content":"On it"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"search_library","arguments":"{\"query\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"tides\"}"}}]},"finish_reason":"tool_calls"}]}"#,
        ] {
            #expect(try decoder.consume(chunk) == nil)
        }
        let turn = try #require(try decoder.consume("[DONE]"))
        #expect(turn.text == "On it")
        #expect(turn.calls == [AgentCall(
            id: "c1",
            name: "search_library",
            arguments: #"{"query":"tides"}"#
        )])
    }

    @Test func providerFailuresNameTheCompanyAndTheKey() {
        #expect(ProviderHTTPError(status: 401, body: Data()).failure() == .keyRejected)
        let gemini = Data(
            #"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#
                .utf8
        )
        #expect(ProviderHTTPError(status: 400, body: gemini).failure() == .keyRejected)
        let schema = Data(#"{"error":{"message":"Unsupported schema keyword"}}"#.utf8)
        #expect(ProviderHTTPError(status: 400, body: schema)
            .failure() == .rejected("Unsupported schema keyword"))
        #expect(ProviderHTTPError(status: 529, body: Data()).failure() == .overloaded)
        let mapped = ChatGPTError.from(ChatGPTError.signInRequired, provider: .openAI)
        #expect(mapped as? ChatGPTError == .provider("OpenAI", .keyRejected))
        #expect(ChatGPTError.provider("Anthropic", .keyRejected).localizedDescription
            .contains("Anthropic rejected the API key"))
        // Summaries report a bad key as a provider-wide problem, not one page's failure.
        let progress = "Saved full text without a summary: "
            + ChatGPTError.provider("Google", .keyRejected).localizedDescription
        #expect(LibraryModel.providerProblem(in: progress) != nil)
    }

    @Test func replacingAKeyCancelsWorkStartedWithTheOldOne() async throws {
        let keys = try await keys([.anthropic: "sk-ant-first-1234"])
        #expect(try await keys.saved() == [.anthropic: "1234"])
        let fence = try await keys.fence(for: .anthropic)
        try await keys.validate(fence)
        try await keys.save("sk-ant-second-5678", for: .anthropic)
        await #expect(throws: CancellationError.self) { try await keys.validate(fence) }
        try await keys.remove(.anthropic)
        await #expect(throws: ChatGPTError.provider("Anthropic", .missingKey)) {
            try await keys.fence(for: .anthropic)
        }
    }

    @MainActor @Test func aKeyIsCheckedBeforeSavingAndSharingIsConfirmedBeforeUse() async throws {
        let defaults = try #require(UserDefaults(suiteName: "provider-tests-\(UUID().uuidString)"))
        let fixture = try ProviderFixture([
            "/v1/models": .init(json: ["data": [
                ["id": "claude-fixture", "display_name": "Claude Fixture"],
                ["id": "not-a-claude-model"],
            ]]),
            "/v1/messages": .init(lines: events([
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text"]],
                [
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": ["type": "text_delta", "text": "Hi"],
                ],
                ["type": "message_stop"],
            ])),
        ])
        let providers = InferenceProviders(
            chatGPT: ChatGPTConnection(preferences: defaults),
            keys: ProviderKeys(vault: MemoryKeyVault()),
            transport: fixture, preferences: defaults
        )
        providers.select(.anthropic)
        #expect(providers.selected == .apple)
        #expect(providers.keyError != nil)

        #expect(await providers.saveKey("  sk-ant-fixture-9876 \n", for: .anthropic))
        #expect(providers.savedKeys[.anthropic] == "9876")
        #expect(providers.catalog(.anthropic).map(\.slug) == ["claude-fixture"])
        let check = try #require(await fixture.requests.first)
        #expect(check.value(forHTTPHeaderField: "x-api-key") == "sk-ant-fixture-9876")

        providers.select(.anthropic)
        #expect(providers.consentPrompt == .anthropic)
        #expect(providers.selected == .apple)
        providers.confirmConsent(.anthropic)
        #expect(providers.selected == .anthropic)

        let inference = try #require(try providers.inference() as? HostedInference)
        #expect(inference.api.provider == .anthropic)
        #expect(inference.model == "claude-fixture")
        let turn = try await inference.agentTurn(
            instructions: "Help", input: [], tools: AgentToolbox.definitions()
        )
        #expect(turn.text == "Hi")

        await providers.removeKey(.anthropic)
        #expect(providers.selected == .apple)
        #expect(!providers.consented(.anthropic))
    }

    @MainActor @Test func aRejectedKeyIsNotSaved() async throws {
        let defaults = try #require(UserDefaults(suiteName: "provider-tests-\(UUID().uuidString)"))
        let fixture = ProviderFixture([
            "/v1beta/models": .init(
                status: 400,
                json: ["error": ["message": "API key not valid."]]
            ),
        ])
        let providers = InferenceProviders(
            chatGPT: ChatGPTConnection(preferences: defaults),
            keys: ProviderKeys(vault: MemoryKeyVault()),
            transport: fixture, preferences: defaults
        )
        #expect(await !(providers.saveKey("AIza-bad", for: .gemini)))
        #expect(providers.savedKeys.isEmpty)
        #expect(providers.keyErrors[.gemini] == ChatGPTError.provider("Google", .keyRejected)
            .localizedDescription)
    }

    @Test func openAIKeysListOnlyChatModels() {
        #expect(OpenAIKeyAPI.chatModel("gpt-5.2"))
        #expect(OpenAIKeyAPI.chatModel("o4-mini"))
        #expect(!OpenAIKeyAPI.chatModel("gpt-4o-realtime-preview"))
        #expect(!OpenAIKeyAPI.chatModel("text-embedding-3-large"))
        #expect(!OpenAIKeyAPI.chatModel("omni-moderation-latest"))
    }
}
