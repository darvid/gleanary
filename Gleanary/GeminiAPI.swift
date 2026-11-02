import Foundation

/// Google's Gemini API. Structured output uses a JSON response schema limited to the keywords
/// Gemini supports; tool calls carry thought signatures, which must be sent back with them.
struct GeminiAPI: KeyedModelAPI {
    let keys: ProviderKeys
    let transport: any ChatGPTTransporting
    static let base = "https://generativelanguage.googleapis.com/v1beta/"

    var provider: InferenceProvider {
        .gemini
    }

    func generate(
        _ request: HostedRequest,
        model: String,
        fence: InferenceFence,
        text: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTurn {
        do {
            let body = try Self.body(request)
            let url = try await post(
                model: model, method: "streamGenerateContent?alt=sse", body: body, fence: fence
            )
            var decoder = GeminiStreamDecoder()
            var payloads = SSEPayloads()
            for try await line in transport.lines(for: url) {
                try Task.checkCancellation()
                guard let payload = try payloads.consume(line) else { continue }
                let streamed = decoder.streamedText
                try decoder.consume(payload)
                if decoder.streamedText != streamed, request.schema == nil {
                    await text(decoder.streamedText)
                }
            }
            try await validateFence(fence)
            return try decoder.turn()
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
            let body = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": WebResearchResult.instructions]]],
                "contents": [["role": "user", "parts": [["text": WebResearchResult.prompt(
                    question: question, sources: sources
                )]]]],
                "tools": [["google_search": [:] as [String: Any]]],
            ] as [String: Any])
            var request = try await post(
                model: model, method: "generateContent", body: body, fence: fence
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await transport.json(request)
            try await validateFence(fence)
            return try Self.webResult(response)
        } catch { throw ChatGPTError.from(error, provider: provider) }
    }

    /// Grounding marks spans of the answer by UTF-8 byte offset, each backed by search results;
    /// citations go after the span they support.
    static func webResult(_ response: [String: Any]) throws -> WebResearchResult {
        let candidate = (response["candidates"] as? [[String: Any]])?.first ?? [:]
        try GeminiStreamDecoder.check(candidate)
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }
            .compactMap { $0["text"] as? String }.joined()
        let grounding = candidate["groundingMetadata"] as? [String: Any] ?? [:]
        let chunks = (grounding["groundingChunks"] as? [[String: Any]] ?? []).map {
            $0["web"] as? [String: Any] ?? [:]
        }
        let supports = (grounding["groundingSupports"] as? [[String: Any]] ?? [])
            .compactMap { support -> (end: Int, chunks: [Int])? in
                guard let end = (support["segment"] as? [String: Any])?["endIndex"] as? Int
                else { return nil }
                return (end, support["groundingChunkIndices"] as? [Int] ?? [])
            }.sorted { $0.end < $1.end }
        let bytes = Array(text.utf8)
        var builder = WebPassageBuilder()
        var cursor = 0
        for support in supports where support.end >= cursor && support.end <= bytes.count {
            builder.append(String(decoding: bytes[cursor ..< support.end], as: UTF8.self))
            cursor = support.end
            for index in Set(support.chunks).sorted() where chunks.indices.contains(index) {
                builder.cite(
                    title: chunks[index]["title"] as? String ?? "",
                    url: chunks[index]["uri"] as? String ?? ""
                )
            }
        }
        builder.append(String(decoding: bytes[cursor...], as: UTF8.self))
        let queries = (grounding["webSearchQueries"] as? [String] ?? []).count
        return builder.result(searches: queries)
    }

    private func post(
        model: String,
        method: String,
        body: Data,
        fence: InferenceFence
    ) async throws -> URLRequest {
        try await validateFence(fence)
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: Self.base + "models/" + name + ":" + method)
        else { throw ChatGPTError.server }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        try await request.setValue(keys.key(for: .gemini), forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    static func body(_ request: HostedRequest) throws -> Data {
        var body: [String: Any] = try [
            "systemInstruction": ["parts": [["text": request.instructions]]],
            "contents": contents(HostedItem.read(request.input)),
        ]
        if let schema = request.schema,
           let object = try JSONSerialization.jsonObject(with: schema) as? [String: Any]
        {
            body["generationConfig"] = [
                "responseMimeType": "application/json",
                "responseJsonSchema": JSONSchemaSubset.filter(
                    object,
                    keeping: JSONSchemaSubset.gemini
                ),
            ]
        }
        if request.tools != nil {
            body["tools"] = try [["functionDeclarations": HostedTool.read(request.tools).map {
                [
                    "name": $0.name, "description": $0.description,
                    "parametersJsonSchema": JSONSchemaSubset.filter(
                        $0.parameters, keeping: JSONSchemaSubset.gemini
                    ),
                ]
            }]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Gemini's turns are `user` and `model`, with tool results as user parts that name the
    /// function they answer.
    static func contents(_ items: [HostedItem]) -> [[String: Any]] {
        var names: [String: String] = [:]
        var contents: [(role: String, parts: [[String: Any]])] = []
        func add(_ role: String, _ part: [String: Any]) {
            if contents.last?.role == role {
                contents[contents.count - 1].parts.append(part)
            } else {
                contents.append((role, [part]))
            }
        }
        for item in items {
            switch item {
            case let .message(role, text, signature):
                guard !text.isEmpty else { continue }
                var part: [String: Any] = ["text": text]
                part["thoughtSignature"] = signature
                add(role == "assistant" ? "model" : "user", part)
            case let .call(id, name, arguments, signature):
                names[id] = name
                let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)))
                    as? [String: Any] ?? [:]
                var call: [String: Any] = ["name": name, "args": args]
                if !id.hasPrefix(GeminiStreamDecoder.localCallPrefix) {
                    call["id"] = id
                }
                var part: [String: Any] = ["functionCall": call]
                part["thoughtSignature"] = signature
                add("model", part)
            case let .output(callID, output):
                var response: [String: Any] = [
                    "name": names[callID] ?? "tool", "response": ["result": output],
                ]
                if !callID.hasPrefix(GeminiStreamDecoder.localCallPrefix) {
                    response["id"] = callID
                }
                add("user", ["functionResponse": response])
            }
        }
        return contents.map { ["role": $0.role, "parts": $0.parts] }
    }

    static func catalog(
        key: String,
        transport: any ChatGPTTransporting
    ) async throws -> [ChatGPTModelChoice] {
        guard let url = URL(string: base + "models?pageSize=1000")
        else { throw ChatGPTError.server }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let models = try await transport.json(request)["models"] as? [[String: Any]] ?? []
        return models.compactMap { model in
            guard let name = model["name"] as? String, name.hasPrefix("models/gemini"),
                  (model["supportedGenerationMethods"] as? [String] ?? [])
                  .contains("generateContent"),
                  !["embedding", "image", "tts", "audio", "live"].contains(where: name.contains)
            else { return nil }
            let slug = String(name.dropFirst("models/".count))
            let display = model["displayName"] as? String ?? slug
            return ChatGPTModelChoice(
                slug: slug, displayName: String(display.prefix(200)), visibility: "list"
            )
        }
    }
}

/// Collects a Gemini stream. Each event is a whole response chunk; text arrives in pieces and
/// function calls arrive whole. Thoughts are skipped.
struct GeminiStreamDecoder {
    /// Gemini may leave calls without IDs, so the app names them; such names aren't sent back.
    static let localCallPrefix = "gleanary-call-"
    private var parts: [[String: Any]] = []
    private var finished = false
    private(set) var streamedText = ""

    mutating func consume(_ payload: String) throws {
        guard let chunk = try JSONSerialization.jsonObject(with: Data(payload.utf8))
            as? [String: Any] else { throw ChatGPTError.invalidStream }
        if let error = chunk["error"] as? [String: Any] {
            let message = String((error["message"] as? String ?? "").prefix(300))
            throw ProviderHTTPError(
                status: error["code"] as? Int ?? 500,
                body: (try? JSONSerialization.data(withJSONObject: ["error": [
                    "message": message,
                ]])) ?? Data()
            )
        }
        if let feedback = chunk["promptFeedback"] as? [String: Any],
           feedback["blockReason"] != nil
        {
            throw ChatGPTError.provider("Google", .refused)
        }
        guard let candidate = (chunk["candidates"] as? [[String: Any]])?.first else { return }
        for part in (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            where part["thought"] as? Bool != true
        {
            parts.append(part)
            streamedText += part["text"] as? String ?? ""
        }
        guard streamedText.utf8.count <= 400_000 else { throw ChatGPTError.invalidStream }
        if candidate["finishReason"] != nil {
            try Self.check(candidate)
            finished = true
        }
    }

    static func check(_ candidate: [String: Any]) throws {
        switch candidate["finishReason"] as? String {
        case "MAX_TOKENS": throw ChatGPTError.provider("Google", .truncated)
        case "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII":
            throw ChatGPTError.provider("Google", .refused)
        case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL":
            throw ChatGPTError.invalidOutput
        default: break
        }
    }

    func turn() throws -> AgentTurn {
        guard finished else { throw ChatGPTError.invalidStream }
        var turn = AgentTurn()
        var text = ""
        var signature: String?
        func flush() throws {
            guard !text.isEmpty else { return }
            turn.text += text
            try turn.output.append(HostedItem.messageItem(text, signature: signature))
            text = ""
            signature = nil
        }
        for part in parts {
            if let call = part["functionCall"] as? [String: Any] {
                try flush()
                guard let name = call["name"] as? String else { throw ChatGPTError.invalidStream }
                let id = call["id"] as? String ?? Self.localCallPrefix + UUID().uuidString
                let args = call["args"] as? [String: Any] ?? [:]
                let arguments = try String(
                    decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self
                )
                turn.calls.append(AgentCall(id: id, name: name, arguments: arguments))
                try turn.output.append(HostedItem.callItem(
                    id: id, name: name, arguments: arguments,
                    signature: part["thoughtSignature"] as? String
                ))
            } else {
                text += part["text"] as? String ?? ""
                signature = part["thoughtSignature"] as? String ?? signature
            }
        }
        try flush()
        return turn
    }
}
