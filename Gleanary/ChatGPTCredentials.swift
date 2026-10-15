import Foundation
import Security

protocol ChatGPTCredentialStoring: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

struct KeychainChatGPTCredentials: ChatGPTCredentialStoring {
    private let service = "app.gleanary.chatgpt.credentials.v1"

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data else { throw ChatGPTError.keychain }
        return data
    }

    func save(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess
            else { throw ChatGPTError.keychain }
        } else if status != errSecSuccess {
            throw ChatGPTError.keychain
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "registrations",
         kSecAttrSynchronizable as String: false]
    }
}

struct ChatGPTRegistration: Codable, Sendable, Identifiable {
    let id: String
    let clientID: String
    let subject: String
    var email: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var scopes: Set<String>
    var expiresAt: Date?

    var planAuthorized: Bool {
        accessToken != nil && scopes.isSuperset(of: [
            "resource.invoke",
            "chatgpt.tokens.use.direct",
        ])
    }

    var label: String {
        "\(email ?? "ChatGPT account") (\(id.prefix(6)))"
    }
}

struct ChatGPTCredentialRecords: Codable, Sendable {
    var accounts: [ChatGPTRegistration] = []
    var activeID: String?
}

struct ChatGPTAccountSummary: Sendable, Identifiable {
    let id: String
    let label: String
    let signedIn: Bool
    let planAuthorized: Bool
}

struct ChatGPTModelChoice: Codable, Sendable, Identifiable, Equatable {
    let slug: String
    let displayName: String
    let visibility: String
    var id: String {
        slug
    }

    enum CodingKeys: String, CodingKey {
        case slug, visibility
        case displayName = "display_name"
    }
}

enum ChatGPTStreamStage: String, Sendable {
    case none, started, reasoning, text, completed, incomplete, failed, other
}

enum ChatGPTResponseFormat: String, Sendable {
    case html = "an HTML page"
    case json = "unrecognized JSON"
    case text = "unrecognized text"
    case empty = "an empty response"
}

enum ChatGPTError: LocalizedError, Equatable {
    case unexpectedResponseFormat(format: ChatGPTResponseFormat, bytes: Int)
    case streamInterrupted(events: Int, last: ChatGPTStreamStage, characters: Int)
    case keychain, invalidCallback, invalidIdentity, cancelledConsent, signInRequired,
         planNotAuthorized
    case network, server, requestRejected, usageLimit, modelDenied, invalidStream, invalidOutput,
         invalidReply,
         timedOut, browser,
         busy

    var errorDescription: String? {
        switch self {
        case .keychain: "macOS Keychain could not read or save the ChatGPT connection. Unlock your login keychain and try again."
        case .invalidCallback: "The ChatGPT callback did not match this sign-in attempt. Start sign-in again."
        case .invalidIdentity: "The ChatGPT account could not be securely verified. No new credentials were saved. Try signing in again."
        case .cancelledConsent: "ChatGPT sign-in or plan permission was declined. Your local library is unchanged."
        case .signInRequired: "Sign in to ChatGPT again, or switch to on-device inference. Your saved sources are retained."
        case .planNotAuthorized: "This account has not authorized ChatGPT-plan usage. Continue with ChatGPT to grant permission, or use on-device inference."
        case .network: "Could not reach OpenAI. Check your connection and retry, or use on-device inference."
        case .server: "OpenAI could not complete this request. Retry later; saved sources are retained."
        case .requestRejected: "OpenAI rejected the request format or model. Try another model or reconnect ChatGPT. Your message is saved."
        case .usageLimit: "ChatGPT-plan usage is unavailable or its limit was reached. Manage usage in ChatGPT Settings, or use on-device inference."
        case .modelDenied: "This model is not available for the selected account. Refresh models or choose another model."
        case .invalidStream: "The ChatGPT response could not be read. Your message and saved sources are retained. Retry."
        case let .unexpectedResponseFormat(format, bytes): "OpenAI returned \(format.rawValue) instead of a model reply (\(bytes) bytes). Reconnect ChatGPT and try again. Your message is saved."
        case let .streamInterrupted(events, last, characters): "ChatGPT disconnected before completing its reply (events: \(events), last: \(last.rawValue), output characters: \(characters)). Your message is saved. Retry."
        case .invalidOutput: "ChatGPT returned a result that failed its source checks. No research artifact was saved."
        case .invalidReply: "ChatGPT did not return a complete reply. Retry; your message is saved."
        case .timedOut: "ChatGPT sign-in timed out. Start sign-in again."
        case .browser: "The system browser could not open ChatGPT sign-in. Check your default browser and retry."
        case .busy: "Finish or cancel the current ChatGPT sign-in before starting another."
        }
    }

    static func http(_ status: Int) -> ChatGPTError {
        switch status {
        case 401: .signInRequired
        case 403: .modelDenied
        case 429: .usageLimit
        default: .server
        }
    }

    static func apiCode(_ code: String?) -> ChatGPTError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable",
             "rate_limit_exceeded": .usageLimit
        case "invalid_grant", "invalid_token", "invalid_api_key",
             "invalid_authentication": .signInRequired
        case "model_not_found", "permission_denied": .modelDenied
        default: .server
        }
    }

    static func apiError(_ error: [String: Any]) -> ChatGPTError {
        let mapped = apiCode(error["code"] as? String)
        guard mapped == .server else { return mapped }
        switch error["type"] as? String {
        case "invalid_request_error": return .requestRejected
        case "authentication_error": return .signInRequired
        case "rate_limit_error": return .usageLimit
        default: return .server
        }
    }
}

protocol ChatGPTTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func lines(for request: URLRequest) -> AsyncThrowingStream<String, any Error>
}

private final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Never forward an OAuth bearer credential to a redirect destination.
        completionHandler(nil)
    }
}

struct ChatGPTTransport: ChatGPTTransporting {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
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
            guard let response = response as? HTTPURLResponse,
                  data.count <= 1_000_000 else { throw ChatGPTError.server }
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
                    guard response.statusCode == 200
                    else { throw ChatGPTError.http(response.statusCode) }
                    // Gate on the bounded response body, not a proxy's possibly incorrect MIME
                    // label.
                    var buffer = ChatGPTResponseFramer()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let line = try buffer.consume(byte) {
                            continuation.yield(line)
                        }
                    }
                    for line in try buffer.finish() {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
                catch let error as ChatGPTError { continuation.finish(throwing: error) }
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

struct ChatGPTResponseFramer {
    private enum Mode { case detecting, events, document }
    private var mode = Mode.detecting
    private var lines = ChatGPTLineBuffer()
    private var document = Data()

    mutating func consume(_ byte: UInt8) throws -> String? {
        if mode != .events {
            document.append(byte)
            guard document.count <= 1_000_000 else { throw ChatGPTError.invalidStream }
        }
        guard mode != .document, let line = try lines.consume(byte) else { return nil }
        if mode == .detecting {
            guard !line.isEmpty else { return nil }
            guard Self.isEventLine(line) else { mode = .document; return nil }
            mode = .events
            document.removeAll(keepingCapacity: false)
        }
        return line
    }

    mutating func finish() throws -> [String] {
        if mode == .events {
            return try (lines.finish()).map { [$0, ""] } ?? [""]
        }
        if mode == .detecting, let line = try lines.finish(), Self.isEventLine(line) {
            return [line, ""]
        }
        return try Self.documentEvents(document)
    }

    private static func isEventLine(_ line: String) -> Bool {
        ["data:", "event:", ":", "id:", "retry:"].contains { line.hasPrefix($0) }
    }

    private static func documentEvents(_ data: Data) throws -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let prefix = String(decoding: data.prefix(128), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let format: ChatGPTResponseFormat = data
                .isEmpty ? .empty : (prefix.hasPrefix("<") ? .html : .text)
            throw ChatGPTError.unexpectedResponseFormat(format: format, bytes: data.count)
        }
        if let error = object["error"] as? [String: Any] {
            throw ChatGPTError.apiError(error)
        }
        let event: [String: Any]
        if object["type"] as? String == "response.completed" {
            event = object
        } else if object["object"] as? String == "response",
                  object["status"] as? String == "completed"
        {
            // A proxy may buffer SSE into a full JSON response. Still require explicit completion.
            event = ["type": "response.completed", "response": object]
        } else {
            throw ChatGPTError.unexpectedResponseFormat(format: .json, bytes: data.count)
        }
        let payload = try JSONSerialization.data(withJSONObject: event)
        return ["data: " + String(decoding: payload, as: UTF8.self), ""]
    }
}

struct ChatGPTLineBuffer {
    private var bytes = Data()
    private var skipLineFeed = false
    private var firstLine = true

    mutating func consume(_ byte: UInt8) throws -> String? {
        if skipLineFeed {
            skipLineFeed = false
            if byte == 10 {
                return nil
            }
        }
        if byte == 13 {
            skipLineFeed = true
            return try decodedLine()
        }
        if byte == 10 {
            return try decodedLine()
        }
        bytes.append(byte)
        guard bytes.count <= 200_000 else { throw ChatGPTError.invalidStream }
        return nil
    }

    mutating func finish() throws -> String? {
        guard !bytes.isEmpty else { return nil }
        return try decodedLine()
    }

    private mutating func decodedLine() throws -> String {
        if firstLine, bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        firstLine = false
        guard let line = String(data: bytes, encoding: .utf8)
        else { throw ChatGPTError.invalidStream }
        bytes.removeAll(keepingCapacity: true)
        return line
    }
}
