import Foundation

typealias InferenceFence = (accountID: String, epoch: UUID)

/// One hosted generation. Input items use the Responses API's shapes (role messages,
/// `function_call` and `function_call_output`), which each provider's client translates, so the
/// tool loop and its history stay provider-neutral. Tools use the Responses function shape too.
struct HostedRequest: Sendable {
    var instructions: String
    var input: [Data]
    var tools: Data?
    /// A JSON schema the reply must match, and the name it goes by.
    var schema: Data?
    var schemaName = "result"

    static func prompt(
        _ prompt: String,
        instructions: String,
        name: String,
        schema: [String: Any]
    ) throws -> HostedRequest {
        try HostedRequest(
            instructions: instructions,
            input: [JSONSerialization.data(withJSONObject: ["role": "user", "content": prompt])],
            schema: JSONSerialization.data(withJSONObject: schema),
            schemaName: name
        )
    }
}

/// A hosted model's wire format and credentials. `HostedInference` builds every feature from
/// these calls, so a provider only has to translate requests and responses.
protocol HostedModelAPI: Sendable {
    var provider: InferenceProvider { get }
    func authorizationFence() async throws -> InferenceFence
    func validateFence(_ fence: InferenceFence) async throws
    /// Reply text so far goes to `text`, for display or progress; the returned turn is
    /// authoritative. A schema request returns its JSON as the turn's text.
    func generate(
        _ request: HostedRequest,
        model: String,
        fence: InferenceFence,
        text: @escaping @Sendable (String) async -> Void
    ) async throws -> AgentTurn
    func researchWeb(
        model: String,
        question: String,
        sources: [ResearchSource],
        fence: InferenceFence,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> WebResearchResult
}

/// API-key providers: a client over the shared key store, and a model list for a key that
/// may not be saved yet, which is how a new key is checked before it's kept.
protocol KeyedModelAPI: HostedModelAPI {
    var keys: ProviderKeys { get }
    init(keys: ProviderKeys, transport: any ChatGPTTransporting)
    static func catalog(
        key: String,
        transport: any ChatGPTTransporting
    ) async throws -> [ChatGPTModelChoice]
}

extension KeyedModelAPI {
    func authorizationFence() async throws -> InferenceFence {
        try await keys.fence(for: provider)
    }

    func validateFence(_ fence: InferenceFence) async throws {
        try await keys.validate(fence)
    }
}

/// Input items read back from their Responses shapes.
enum HostedItem {
    case message(role: String, text: String, signature: String?)
    case call(id: String, name: String, arguments: String, signature: String?)
    case output(callID: String, output: String)

    static func read(_ input: [Data]) throws -> [HostedItem] {
        try input.map { data in
            guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ChatGPTError.invalidStream }
            let signature = item["thought_signature"] as? String
            switch item["type"] as? String {
            case "function_call":
                guard let id = item["call_id"] as? String, let name = item["name"] as? String
                else { throw ChatGPTError.invalidStream }
                return .call(
                    id: id, name: name, arguments: item["arguments"] as? String ?? "{}",
                    signature: signature
                )
            case "function_call_output":
                guard let id = item["call_id"] as? String else { throw ChatGPTError.invalidStream }
                return .output(callID: id, output: item["output"] as? String ?? "")
            default:
                guard let role = item["role"] as? String else { throw ChatGPTError.invalidStream }
                return .message(
                    role: role == "assistant" ? "assistant" : "user",
                    text: item["content"] as? String ?? "",
                    signature: signature
                )
            }
        }
    }

    static func callItem(
        id: String,
        name: String,
        arguments: String,
        signature: String? = nil
    ) throws -> Data {
        var item: [String: Any] = [
            "type": "function_call", "call_id": id, "name": name, "arguments": arguments,
        ]
        item["thought_signature"] = signature
        return try JSONSerialization.data(withJSONObject: item)
    }

    static func messageItem(_ text: String, signature: String? = nil) throws -> Data {
        var item: [String: Any] = ["role": "assistant", "content": text]
        item["thought_signature"] = signature
        return try JSONSerialization.data(withJSONObject: item)
    }
}

/// A function definition read from the Responses tool shape.
struct HostedTool {
    let name: String
    let description: String
    let parameters: [String: Any]

    static func read(_ tools: Data?) throws -> [HostedTool] {
        guard let tools else { return [] }
        guard let list = try JSONSerialization.jsonObject(with: tools) as? [[String: Any]]
        else { throw ChatGPTError.invalidStream }
        return list.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return HostedTool(
                name: name,
                description: tool["description"] as? String ?? "",
                parameters: tool["parameters"] as? [String: Any] ?? ["type": "object"]
            )
        }
    }
}

enum ProviderFailure: Equatable, Sendable {
    case missingKey, keychain, keyRejected, rateLimited, overloaded, truncated, refused
    case rejected(String)
    case unavailable
}

/// A failed HTTP request to an API-key provider, with the provider's own explanation.
struct ProviderHTTPError: Error, Equatable {
    let status: Int
    let message: String?

    init(status: Int, body: Data) {
        self.status = status
        message = Self.message(in: body)
    }

    static func message(in body: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"]
        let text = (error as? [String: Any])?["message"] as? String ?? error as? String
            ?? object?["message"] as? String
        return text.map { String($0.prefix(300)) }
    }

    func failure() -> ProviderFailure {
        let message = message ?? ""
        switch status {
        case 401, 403: return .keyRejected
        // Gemini reports an invalid key as a bad request.
        case 400 where message.localizedCaseInsensitiveContains("API key"): return .keyRejected
        case 402, 429: return .rateLimited
        case 503, 529: return .overloaded
        case 400, 404, 413, 422: return message.isEmpty ? .unavailable : .rejected(message)
        default: return .unavailable
        }
    }
}

extension ChatGPTError {
    /// Maps transport and decoding errors from an API-key provider's request.
    static func from(_ error: any Error, provider: InferenceProvider) -> any Error {
        switch error {
        case let error as ProviderHTTPError:
            if error.status == 404 {
                return ChatGPTError.modelDenied
            }
            return ChatGPTError.provider(provider.company, error.failure())
        case let error as ChatGPTError:
            switch error {
            case .signInRequired, .planNotAuthorized:
                return ChatGPTError.provider(provider.company, .keyRejected)
            case .usageLimit: return ChatGPTError.provider(provider.company, .rateLimited)
            case .server: return ChatGPTError.provider(provider.company, .unavailable)
            default: return error
            }
        default: return error
        }
    }
}

/// Joins an event stream's `data:` lines into payloads, one per blank-line-terminated event.
struct SSEPayloads {
    private var lines: [String] = []

    mutating func consume(_ line: String) throws -> String? {
        guard line.utf8.count <= 400_000 else { throw ChatGPTError.invalidStream }
        if line.hasPrefix("data:") {
            lines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            guard lines.reduce(0, { $0 + $1.utf8.count }) <= 400_000
            else { throw ChatGPTError.invalidStream }
            return nil
        }
        guard line.isEmpty, !lines.isEmpty else { return nil }
        defer { lines = [] }
        return lines.joined(separator: "\n")
    }
}

/// HTTP for API-key providers. A failed request reads the provider's error message, so a
/// rejected schema or model says why. Reasoning models can think for minutes before their first
/// byte, so requests wait longer than ChatGPT's.
struct ProviderHTTPTransport: ChatGPTTransporting {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(
            configuration: configuration,
            delegate: ChatGPTNoRedirects(),
            delegateQueue: nil
        )
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            // Model lists from aggregators run to a few megabytes.
            guard let response = response as? HTTPURLResponse,
                  data.count <= 16_000_000 else { throw ChatGPTError.server }
            return (data, response)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatGPTError { throw error }
        catch {
            try Task.checkCancellation()
            throw ChatGPTError.network
        }
    }

    func lines(for request: URLRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse
                    else { throw ChatGPTError.server }
                    guard response.statusCode == 200 else {
                        throw try await ProviderHTTPError(
                            status: response.statusCode, body: Self.prefix(of: bytes)
                        )
                    }
                    var buffer = ChatGPTLineBuffer()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let line = try buffer.consume(byte) {
                            continuation.yield(line)
                        }
                    }
                    if let line = try buffer.finish() {
                        continuation.yield(line)
                    }
                    continuation.yield("")
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
                catch let error as ChatGPTError { continuation.finish(throwing: error) }
                catch let error as ProviderHTTPError { continuation.finish(throwing: error) }
                catch {
                    continuation
                        .finish(throwing: Task.isCancelled ? CancellationError() : ChatGPTError
                            .network)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ProviderHTTPTransport {
    /// An error body, bounded so a misbehaving server can't stream forever.
    private static func prefix(of bytes: URLSession.AsyncBytes) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= 64000 {
                break
            }
        }
        return body
    }
}

extension ChatGPTTransporting {
    /// A JSON request whose response must be 200, else the provider's explanation is thrown.
    func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await data(for: request)
        guard response.statusCode == 200 else {
            throw ProviderHTTPError(status: response.statusCode, body: data)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ChatGPTError.invalidStream }
        return object
    }
}

/// Builds one web research passage from text and the sources each part cites. A citation
/// covers a one-character marker after the cited text, which rendering replaces with its link.
struct WebPassageBuilder {
    private(set) var text = ""
    private(set) var citations: [WebResearchResult.Citation] = []
    private(set) var urls: [URL] = []

    mutating func append(_ text: String) {
        self.text += text
    }

    mutating func cite(title: String, url: String) {
        guard let url = URL(string: url), WebResearchResult.safeURL(url) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = text.unicodeScalars.count
        text += "†"
        citations.append(.init(
            startIndex: start, endIndex: start + 1,
            title: title.isEmpty ? url.host() ?? url.absoluteString : String(title.prefix(1000)),
            url: url
        ))
        if !urls.contains(url) {
            urls.append(url)
        }
    }

    func result(searches: Int, consulted: [URL] = []) -> WebResearchResult {
        var all = urls
        for url in consulted where !all.contains(url) && WebResearchResult.safeURL(url) {
            all.append(url)
        }
        return WebResearchResult(
            passages: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : [.init(text: text, citations: citations)],
            consultedURLs: Array(all.prefix(256)),
            searchCount: max(searches, citations.isEmpty ? 0 : 1)
        )
    }
}

/// Keeps the JSON Schema keywords a provider supports, dropping the rest. Property and
/// definition names are kept as they are; only keywords are filtered.
enum JSONSchemaSubset {
    static let gemini: Set<String> = [
        "$id", "$defs", "$ref", "$anchor", "type", "format", "title", "description", "enum",
        "items", "prefixItems", "minItems", "maxItems", "minimum", "maximum", "anyOf", "oneOf",
        "properties", "additionalProperties", "required", "propertyOrdering",
    ]

    static func filter(_ schema: [String: Any], keeping keywords: Set<String>) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in schema where keywords.contains(key) {
            switch key {
            case "properties", "$defs":
                let named = value as? [String: Any] ?? [:]
                result[key] = named.mapValues { child in
                    (child as? [String: Any]).map { filter($0, keeping: keywords) } ?? child
                }
            case "items", "additionalProperties":
                result[key] = (value as? [String: Any]).map { filter($0, keeping: keywords) }
                    ?? value
            case "anyOf", "oneOf", "prefixItems":
                result[key] = (value as? [[String: Any]])?.map { filter($0, keeping: keywords) }
                    ?? value
            default:
                result[key] = value
            }
        }
        return result
    }
}
