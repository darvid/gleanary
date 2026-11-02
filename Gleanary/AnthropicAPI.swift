import Foundation

/// Anthropic's Messages API. Structured output is a forced call to a tool whose input schema is
/// the requested shape, which every Claude model supports.
struct AnthropicAPI: KeyedModelAPI {
    let keys: ProviderKeys
    let transport: any ChatGPTTransporting
    static let maxTokens = 16000

    var provider: InferenceProvider {
        .anthropic
    }

    func generate(
        _ request: HostedRequest,
        model: String,
        fence: InferenceFence,
        text: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTurn {
        do {
            let body = try Self.body(model: model, request: request)
            var decoder = AnthropicStreamDecoder(structured: request.schema != nil)
            var payloads = SSEPayloads()
            for try await line in try await transport.lines(for: post(body, fence: fence)) {
                try Task.checkCancellation()
                guard let payload = try payloads.consume(line) else { continue }
                let streamed = decoder.streamedText
                if let turn = try decoder.consume(payload) {
                    try await validateFence(fence)
                    return turn
                }
                if decoder.streamedText != streamed, request.schema == nil {
                    await text(decoder.streamedText)
                }
            }
            throw ChatGPTError.invalidStream
        } catch { throw ChatGPTError.from(error, provider: provider) }
    }

    func researchWeb(
        model: String,
        question: String,
        sources: [ResearchSource],
        fence: InferenceFence,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> WebResearchResult {
        do {
            await progress("Searching the web…")
            var messages: [[String: Any]] = try [["role": "user", "content": WebResearchResult
                    .prompt(question: question, sources: sources)]]
            var content: [[String: Any]] = []
            // A long search can pause mid-turn; sending its content back resumes it.
            for _ in 0 ..< 4 {
                let body = try JSONSerialization.data(withJSONObject: [
                    "model": model, "max_tokens": Self.maxTokens,
                    "system": WebResearchResult.instructions, "messages": messages,
                    "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 6]],
                ] as [String: Any])
                var request = try await post(body, fence: fence)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let response = try await transport.json(request)
                try Self.check(response)
                let blocks = response["content"] as? [[String: Any]] ?? []
                content += blocks
                guard response["stop_reason"] as? String == "pause_turn" else { break }
                await progress("Reading web sources…")
                messages.append(["role": "assistant", "content": blocks])
            }
            try await validateFence(fence)
            return Self.webResult(content)
        } catch { throw ChatGPTError.from(error, provider: provider) }
    }

    static func webResult(_ content: [[String: Any]]) -> WebResearchResult {
        var builder = WebPassageBuilder()
        var consulted: [URL] = []
        var searches = 0
        for block in content {
            switch block["type"] as? String {
            case "server_tool_use":
                searches += 1
            case "web_search_tool_result":
                for result in block["content"] as? [[String: Any]] ?? [] {
                    if let url = (result["url"] as? String).flatMap(URL.init(string:)) {
                        consulted.append(url)
                    }
                }
            case "text":
                builder.append(block["text"] as? String ?? "")
                var cited = Set<String>()
                for citation in block["citations"] as? [[String: Any]] ?? [] {
                    guard let url = citation["url"] as? String, cited.insert(url).inserted
                    else { continue }
                    builder.cite(title: citation["title"] as? String ?? "", url: url)
                }
            default:
                break
            }
        }
        return builder.result(searches: searches, consulted: consulted)
    }

    private static func check(_ response: [String: Any]) throws {
        switch response["stop_reason"] as? String {
        case "refusal": throw ChatGPTError.provider("Anthropic", .refused)
        case "max_tokens": throw ChatGPTError.provider("Anthropic", .truncated)
        default: break
        }
    }

    private func post(_ body: Data, fence: InferenceFence) async throws -> URLRequest {
        try await validateFence(fence)
        guard let url = URL(string: "https://api.anthropic.com/v1/messages")
        else { throw ChatGPTError.server }
        var request = try await Self.request(url, key: keys.key(for: .anthropic))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private static func request(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    static func body(model: String, request: HostedRequest) throws -> Data {
        var body: [String: Any] = try [
            "model": model, "max_tokens": maxTokens, "stream": true,
            "system": request.instructions, "messages": messages(HostedItem.read(request.input)),
        ]
        if let schema = request.schema {
            body["tools"] = try [[
                "name": request.schemaName,
                "description": "Return the result in exactly this shape.",
                "input_schema": JSONSerialization.jsonObject(with: schema),
            ]]
            body["tool_choice"] = ["type": "tool", "name": request.schemaName]
        } else if request.tools != nil {
            body["tools"] = try HostedTool.read(request.tools).map {
                ["name": $0.name, "description": $0.description, "input_schema": $0.parameters]
            }
            body["tool_choice"] = ["type": "auto"]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Claude takes alternating user and assistant turns, starting with the user, with tool
    /// calls and their results as content blocks.
    static func messages(_ items: [HostedItem]) -> [[String: Any]] {
        var messages: [(role: String, blocks: [[String: Any]])] = []
        func add(_ role: String, _ block: [String: Any]) {
            if messages.last?.role == role {
                messages[messages.count - 1].blocks.append(block)
            } else {
                messages.append((role, [block]))
            }
        }
        for item in items {
            switch item {
            case let .message(role, text, _):
                guard !text.isEmpty else { continue }
                add(role, ["type": "text", "text": text])
            case let .call(id, name, arguments, _):
                let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)))
                    as? [String: Any] ?? [:]
                add("assistant", ["type": "tool_use", "id": id, "name": name, "input": input])
            case let .output(callID, output):
                add("user", ["type": "tool_result", "tool_use_id": callID, "content": output])
            }
        }
        if messages.first?.role == "assistant" {
            messages.insert(("user", [["type": "text", "text": "(Earlier conversation.)"]]), at: 0)
        }
        return messages.map { ["role": $0.role, "content": $0.blocks] }
    }

    static func catalog(
        key: String,
        transport: any ChatGPTTransporting
    ) async throws -> [ChatGPTModelChoice] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")
        else { throw ChatGPTError.server }
        let models = try await transport.json(request(url, key: key))["data"] as? [[String: Any]]
        return (models ?? []).compactMap { model in
            guard let id = model["id"] as? String, id.hasPrefix("claude"), id.count <= 200
            else { return nil }
            let name = model["display_name"] as? String ?? id
            return ChatGPTModelChoice(
                slug: id, displayName: String(name.prefix(200)), visibility: "list"
            )
        }
    }
}

/// Collects one Messages stream: reply text, tool calls, or a forced tool's input as JSON.
struct AnthropicStreamDecoder {
    private struct Block {
        var type: String
        var id = ""
        var name = ""
        var text = ""
    }

    let structured: Bool
    private var blocks: [Int: Block] = [:]
    private var stopReason: String?
    private(set) var streamedText = ""

    init(structured: Bool) {
        self.structured = structured
    }

    mutating func consume(_ payload: String) throws -> AgentTurn? {
        guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8))
            as? [String: Any], let type = event["type"] as? String
        else { throw ChatGPTError.invalidStream }
        let index = event["index"] as? Int ?? 0
        switch type {
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            var started = Block(type: block["type"] as? String ?? "")
            started.id = block["id"] as? String ?? ""
            started.name = block["name"] as? String ?? ""
            started.text = block["text"] as? String ?? ""
            blocks[index] = started
        case "content_block_delta":
            try applyDelta(event["delta"] as? [String: Any] ?? [:], to: index)
        case "message_delta":
            stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String
        case "message_stop":
            return try turn()
        case "error":
            let error = event["error"] as? [String: Any] ?? [:]
            throw ChatGPTError.provider("Anthropic", Self.failure(error))
        default:
            break
        }
        return nil
    }

    private mutating func applyDelta(_ delta: [String: Any], to index: Int) throws {
        switch delta["type"] as? String {
        case "text_delta":
            let text = delta["text"] as? String ?? ""
            blocks[index]?.text += text
            streamedText += text
        case "input_json_delta":
            blocks[index]?.text += delta["partial_json"] as? String ?? ""
        default:
            break
        }
        guard streamedText.utf8.count <= 64000,
              blocks.values.reduce(0, { $0 + $1.text.utf8.count }) <= 400_000
        else { throw ChatGPTError.invalidStream }
    }

    private func turn() throws -> AgentTurn {
        switch stopReason {
        case "refusal": throw ChatGPTError.provider("Anthropic", .refused)
        case "max_tokens": throw ChatGPTError.provider("Anthropic", .truncated)
        default: break
        }
        var turn = AgentTurn()
        for (_, block) in blocks.sorted(by: { $0.key < $1.key }) {
            switch block.type {
            case "text":
                guard !structured, !block.text.isEmpty else { continue }
                turn.text += block.text
                try turn.output.append(HostedItem.messageItem(block.text))
            case "tool_use":
                let arguments = block.text.isEmpty ? "{}" : block.text
                if structured {
                    turn.text = arguments
                    return turn
                }
                turn.calls.append(AgentCall(id: block.id, name: block.name, arguments: arguments))
                try turn.output.append(HostedItem.callItem(
                    id: block.id, name: block.name, arguments: arguments
                ))
            default:
                break
            }
        }
        guard !structured else { throw ChatGPTError.invalidOutput }
        return turn
    }

    static func failure(_ error: [String: Any]) -> ProviderFailure {
        switch error["type"] as? String {
        case "authentication_error", "permission_error": .keyRejected
        case "rate_limit_error", "billing_error": .rateLimited
        case "overloaded_error": .overloaded
        case "invalid_request_error":
            .rejected(String((error["message"] as? String ?? "invalid request").prefix(300)))
        default: .unavailable
        }
    }
}
