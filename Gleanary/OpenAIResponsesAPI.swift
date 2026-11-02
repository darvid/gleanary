import Foundation

/// OpenAI's Responses API, reached with a ChatGPT plan sign-in or an API key.
struct OpenAIResponsesAPI: HostedModelAPI {
    enum Credential: Sendable {
        case chatGPT(ChatGPTSession)
        case apiKey(ProviderKeys)
    }

    let credential: Credential
    let transport: any ChatGPTTransporting

    init(session: ChatGPTSession) {
        credential = .chatGPT(session)
        transport = session.transport
    }

    init(keys: ProviderKeys, transport: any ChatGPTTransporting) {
        credential = .apiKey(keys)
        self.transport = transport
    }

    var provider: InferenceProvider {
        if case .chatGPT = credential {
            .chatGPT
        } else {
            .openAI
        }
    }

    func authorizationFence() async throws -> InferenceFence {
        switch credential {
        case let .chatGPT(session): try await session.authorizationFence()
        case let .apiKey(keys): try await keys.fence(for: .openAI)
        }
    }

    func validateFence(_ fence: InferenceFence) async throws {
        switch credential {
        case let .chatGPT(session): try await session.validateFence(fence)
        case let .apiKey(keys): try await keys.validate(fence)
        }
    }

    func generate(
        _ request: HostedRequest,
        model: String,
        fence: InferenceFence,
        text: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTurn {
        let urlRequest = try await authorizedRequest(
            body: Self.body(model: model, request: request), fence: fence
        )
        guard request.tools != nil else {
            return try await AgentTurn(text: consume(urlRequest, text))
        }
        var decoder = ChatGPTAgentDecoder()
        for try await line in transport.lines(for: urlRequest) {
            try Task.checkCancellation()
            let streamed = decoder.streamedText
            if let turn = try decoder.consume(line) {
                try await validateFence(fence)
                return turn
            }
            if decoder.streamedText != streamed {
                await text(decoder.streamedText)
            }
        }
        if let turn = try decoder.consume("") {
            return turn
        }
        throw ChatGPTError.invalidStream
    }

    func researchWeb(
        model: String,
        question: String,
        sources: [ResearchSource],
        fence: InferenceFence,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> WebResearchResult {
        let body = try Self.webResearchRequestBody(
            model: model,
            question: question,
            sources: sources
        )
        let request = try await authorizedRequest(body: body, fence: fence)
        await progress("Searching the web…")
        var decoder = WebResearchSSEDecoder()
        var lastProgress = ""
        for try await line in transport.lines(for: request) {
            try Task.checkCancellation()
            if let result = try decoder.consume(line) {
                try await validateFence(fence)
                return result
            }
            if let stage = decoder.progress, stage != lastProgress {
                lastProgress = stage
                await progress(stage)
            }
        }
        let result = try decoder.finish()
        try Task.checkCancellation()
        try await validateFence(fence)
        return result
    }

    private func authorizedRequest(
        body: Data,
        fence: InferenceFence
    ) async throws -> URLRequest {
        try await validateFence(fence)
        guard let url = URL(string: "https://api.openai.com/v1/responses")
        else { throw ChatGPTError.server }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let token = switch credential {
        case let .chatGPT(session): try await session.accessToken()
        case let .apiKey(keys): try await keys.key(for: .openAI)
        }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        try await validateFence(fence)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private func consume(
        _ request: URLRequest,
        _ progress: @Sendable (String) async -> Void
    ) async throws -> String {
        var decoder = ChatGPTSSEDecoder()
        var lastProgress = 0
        for try await line in transport.lines(for: request) {
            try Task.checkCancellation()
            if let result = try decoder.consume(line) {
                return result
            }
            if decoder.text.count - lastProgress >= 120 {
                lastProgress = decoder.text.count
                await progress(decoder.text)
            }
        }
        return try decoder.finish()
    }

    static func body(model: String, request: HostedRequest) throws -> Data {
        // Plan usage forbids persisted Responses state, so every turn resends the whole exchange.
        var body: [String: Any] = try [
            "model": model, "store": false, "stream": true, "instructions": request.instructions,
            "input": request.input.map { try JSONSerialization.jsonObject(with: $0) },
        ]
        if let schema = request.schema {
            body["text"] = try ["format": [
                "type": "json_schema",
                "name": request.schemaName,
                "strict": true,
                "schema": JSONSerialization.jsonObject(with: schema),
            ]]
        }
        if let tools = request.tools {
            body["tools"] = try JSONSerialization.jsonObject(with: tools)
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func requestBody(
        model: String,
        prompt: String,
        instructions: String,
        name: String,
        schema: [String: Any]
    ) throws -> Data {
        try body(model: model, request: .prompt(
            prompt, instructions: instructions, name: name, schema: schema
        ))
    }

    static func agentRequestBody(
        model: String,
        instructions: String,
        input: [Data],
        tools: Data
    ) throws -> Data {
        try body(model: model, request: HostedRequest(
            instructions: instructions, input: input, tools: tools
        ))
    }

    static func webResearchRequestBody(
        model: String,
        question: String,
        sources: [ResearchSource]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true,
            "tools": [["type": "web_search"]], "tool_choice": ["type": "web_search"],
            "include": ["web_search_call.action.sources"],
            "instructions": WebResearchResult.instructions,
            "input": [["role": "user", "content": WebResearchResult.prompt(
                question: question, sources: sources
            )]],
        ])
    }
}

/// The Responses API with an OpenAI API key, whose errors name the key rather than a sign-in.
struct OpenAIKeyAPI: KeyedModelAPI {
    let keys: ProviderKeys
    private let responses: OpenAIResponsesAPI

    init(keys: ProviderKeys, transport: any ChatGPTTransporting) {
        self.keys = keys
        responses = OpenAIResponsesAPI(keys: keys, transport: transport)
    }

    var provider: InferenceProvider {
        .openAI
    }

    func generate(
        _ request: HostedRequest,
        model: String,
        fence: InferenceFence,
        text: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTurn {
        do { return try await responses.generate(request, model: model, fence: fence, text: text) }
        catch { throw ChatGPTError.from(error, provider: .openAI) }
    }

    func researchWeb(
        model: String,
        question: String,
        sources: [ResearchSource],
        fence: InferenceFence,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> WebResearchResult {
        do {
            return try await responses.researchWeb(
                model: model, question: question, sources: sources, fence: fence,
                progress: progress
            )
        } catch { throw ChatGPTError.from(error, provider: .openAI) }
    }

    static func catalog(
        key: String,
        transport: any ChatGPTTransporting
    ) async throws -> [ChatGPTModelChoice] {
        guard let url = URL(string: "https://api.openai.com/v1/models")
        else { throw ChatGPTError.server }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let models = try await transport.json(request)["data"] as? [[String: Any]] ?? []
        return models
            .compactMap { model -> (ChatGPTModelChoice, Int)? in
                guard let id = model["id"] as? String, chatModel(id) else { return nil }
                return (
                    ChatGPTModelChoice(slug: id, displayName: id, visibility: "list"),
                    model["created"] as? Int ?? 0
                )
            }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The models list includes embeddings, audio, image and moderation models, which can't
    /// run a text conversation with tools.
    static func chatModel(_ id: String) -> Bool {
        let chat = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-")
            || (id.hasPrefix("o") && id.dropFirst().first?.isNumber == true)
        let excluded = [
            "audio", "realtime", "transcribe", "tts", "image", "search", "embedding",
            "instruct", "moderation", "codex", "deep-research",
        ]
        return chat && id.count <= 200 && !excluded.contains { id.contains($0) }
    }
}
