import Foundation

/// OpenRouter's OpenAI-compatible Chat Completions API. Requests ask to be routed only to hosts
/// that support every parameter they use, so a schema or tool request never lands on a model
/// that would ignore it.
struct OpenRouterAPI: KeyedModelAPI {
    let keys: ProviderKeys
    let transport: any ChatGPTTransporting
    static let base = "https://openrouter.ai/api/v1/"

    var provider: InferenceProvider {
        .openRouter
    }

    func generate(
        _ request: HostedRequest,
        model: String,
        fence: InferenceFence,
        text: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTurn {
        do {
            let body = try Self.body(model: model, request: request)
            var decoder = ChatCompletionsDecoder()
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
            try await validateFence(fence)
            return try decoder.finish()
        } catch { throw ChatGPTError.from(error, provider: provider) }
    }

    /// The web plugin searches first and hands results to the model, which cites them as
    /// URL annotations on its message.
    func researchWeb(
        model: String,
        question: String,
        sources: [ResearchSource],
        fence: InferenceFence,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> WebResearchResult {
        do {
            await progress("Searching the web…")
            let body = try JSONSerialization.data(withJSONObject: [
                "model": model, "plugins": [["id": "web"]],
                "messages": [
                    ["role": "system", "content": WebResearchResult.instructions],
                    ["role": "user", "content": WebResearchResult.prompt(
                        question: question, sources: sources
                    )],
                ],
            ] as [String: Any])
            var request = try await post(body, fence: fence)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await transport.json(request)
            try await validateFence(fence)
            return Self.webResult(response)
        } catch { throw ChatGPTError.from(error, provider: provider) }
    }

    static func webResult(_ response: [String: Any]) -> WebResearchResult {
        let message = ((response["choices"] as? [[String: Any]])?.first?["message"]
            as? [String: Any]) ?? [:]
        var builder = WebPassageBuilder()
        builder.append(message["content"] as? String ?? "")
        var cited = Set<String>()
        for annotation in message["annotations"] as? [[String: Any]] ?? [] {
            guard let citation = annotation["url_citation"] as? [String: Any],
                  let url = citation["url"] as? String, cited.insert(url).inserted
            else { continue }
            builder.cite(title: citation["title"] as? String ?? "", url: url)
        }
        return builder.result(searches: 1)
    }

    private func post(_ body: Data, fence: InferenceFence) async throws -> URLRequest {
        try await validateFence(fence)
        guard let url = URL(string: Self.base + "chat/completions")
        else { throw ChatGPTError.server }
        var request = try await Self.request(url, key: keys.key(for: .openRouter))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private static func request(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("Gleanary", forHTTPHeaderField: "X-Title")
        return request
    }

    static func body(model: String, request: HostedRequest) throws -> Data {
        var body: [String: Any] = try [
            "model": model, "stream": true,
            "messages": [["role": "system", "content": request.instructions]]
                + messages(HostedItem.read(request.input)),
            "provider": ["require_parameters": true],
        ]
        if let schema = request.schema {
            body["response_format"] = try ["type": "json_schema", "json_schema": [
                "name": request.schemaName, "strict": true,
                "schema": JSONSerialization.jsonObject(with: schema),
            ]]
        }
        if request.tools != nil {
            body["tools"] = try HostedTool.read(request.tools).map {
                ["type": "function", "function": [
                    "name": $0.name, "description": $0.description, "parameters": $0.parameters,
                ]]
            }
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Chat Completions puts tool calls on an assistant message and each result in its own
    /// `tool` message.
    static func messages(_ items: [HostedItem]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for item in items {
            switch item {
            case let .message(role, text, _):
                messages.append(["role": role, "content": text])
            case let .call(id, name, arguments, _):
                let call: [String: Any] = [
                    "id": id, "type": "function",
                    "function": ["name": name, "arguments": arguments],
                ]
                if var last = messages.last, last["role"] as? String == "assistant" {
                    last["tool_calls"] = (last["tool_calls"] as? [[String: Any]] ?? []) + [call]
                    messages[messages.count - 1] = last
                } else {
                    messages.append(["role": "assistant", "content": "", "tool_calls": [call]])
                }
            case let .output(callID, output):
                messages.append(["role": "tool", "tool_call_id": callID, "content": output])
            }
        }
        return messages
    }

    /// Only models that can call tools and follow a response schema can run Gleanary's
    /// features, so the rest aren't offered.
    static func catalog(
        key: String,
        transport: any ChatGPTTransporting
    ) async throws -> [ChatGPTModelChoice] {
        guard let check = URL(string: base + "key"), let url = URL(string: base + "models")
        else { throw ChatGPTError.server }
        // The model list is public, so the key is checked on its own.
        _ = try await transport.json(request(check, key: key))
        let models = try await transport.json(request(url, key: key))["data"] as? [[String: Any]]
        return (models ?? []).compactMap { model -> (ChatGPTModelChoice, Int)? in
            let supported = Set(model["supported_parameters"] as? [String] ?? [])
            guard let id = model["id"] as? String, id.count <= 200, supported.contains("tools"),
                  supported.contains("structured_outputs") || supported.contains("response_format")
            else { return nil }
            let name = model["name"] as? String ?? id
            return (
                ChatGPTModelChoice(
                    slug: id,
                    displayName: String(name.prefix(200)),
                    visibility: "list"
                ),
                model["created"] as? Int ?? 0
            )
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Collects a Chat Completions stream. Tool calls arrive in fragments keyed by index.
struct ChatCompletionsDecoder {
    private struct Call {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var calls: [Int: Call] = [:]
    private var finishReason: String?
    private(set) var streamedText = ""

    mutating func consume(_ payload: String) throws -> AgentTurn? {
        if payload == "[DONE]" {
            return try finish()
        }
        guard let chunk = try JSONSerialization.jsonObject(with: Data(payload.utf8))
            as? [String: Any] else { throw ChatGPTError.invalidStream }
        if let error = chunk["error"] as? [String: Any] {
            throw ProviderHTTPError(
                status: error["code"] as? Int ?? 500,
                body: (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data()
            )
        }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return nil }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        streamedText += delta["content"] as? String ?? ""
        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = fragment["index"] as? Int ?? 0
            var call = calls[index] ?? Call()
            call.id = fragment["id"] as? String ?? call.id
            let function = fragment["function"] as? [String: Any] ?? [:]
            call.name += function["name"] as? String ?? ""
            call.arguments += function["arguments"] as? String ?? ""
            calls[index] = call
        }
        guard streamedText.utf8.count <= 400_000 else { throw ChatGPTError.invalidStream }
        if let reason = choice["finish_reason"] as? String {
            finishReason = reason
        }
        return nil
    }

    func finish() throws -> AgentTurn {
        switch finishReason {
        case nil: throw ChatGPTError.invalidStream
        case "length": throw ChatGPTError.provider("OpenRouter", .truncated)
        case "content_filter": throw ChatGPTError.provider("OpenRouter", .refused)
        default: break
        }
        var turn = AgentTurn()
        if !streamedText.isEmpty {
            turn.text = streamedText
            try turn.output.append(HostedItem.messageItem(streamedText))
        }
        for (index, call) in calls.sorted(by: { $0.key < $1.key }) {
            guard !call.name.isEmpty else { throw ChatGPTError.invalidStream }
            let id = call.id.isEmpty ? "call_\(index)_\(UUID().uuidString)" : call.id
            let arguments = call.arguments.isEmpty ? "{}" : call.arguments
            turn.calls.append(AgentCall(id: id, name: call.name, arguments: arguments))
            try turn.output.append(HostedItem.callItem(
                id: id,
                name: call.name,
                arguments: arguments
            ))
        }
        return turn
    }
}
