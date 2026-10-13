import AppKit
import Foundation
@testable import Infactory
import Security
import SwiftUI
import Testing

private final class MemoryChatGPTVault: ChatGPTCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(_ records: ChatGPTCredentialRecords = ChatGPTCredentialRecords()) throws {
        data = try JSONEncoder().encode(records)
    }

    func load() throws -> Data? {
        lock.withLock { data }
    }

    func save(_ data: Data) throws {
        lock.withLock { self.data = data }
    }
}

private final class FixtureSSEURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?
            .host == "stream-fixture.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": ["/cr", "/eof", "/interrupted"].contains(url.path)
                          ? "text/event-stream; charset=utf-8" : "application/json",
                  ]
              ) else { client?.urlProtocol(self, didFailWithError: ChatGPTError.server); return }
        let completed = #"data: {"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"output_text","text":"Hello, fixture."}]}]}}"#
        let body: String = switch url.path {
        case "/cr": "\u{FEFF}" + completed + "\r\r"
        case "/eof": completed
        case "/mislabeled": completed + "\n\n"
        case "/json-response": #"{"object":"response","status":"completed","output":[{"content":[{"type":"output_text","text":"Hello, fixture."}]}]}"#
        case "/json-error": #"{"error":{"code":"subscription_sharing_usage_unavailable","message":"PRIVATE_FIXTURE"}}"#
        case "/html": "<html>PRIVATE_FIXTURE</html>"
        case "/interrupted": #"data: {"type":"response.output_text.delta","delta":"Unfinished fixture"}"# +
            "\n\n"
        default: "{}"
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for byte in body.utf8 {
            client?.urlProtocol(self, didLoad: Data([byte]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor FixtureChatGPTTransport: ChatGPTTransporting {
    var requests: [URLRequest] = []
    let response: Data
    let status: Int
    let delay: Duration
    init(response: String, status: Int = 200, delay: Duration = .zero) {
        self.response = Data(response.utf8)
        self.status = status
        self.delay = delay
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        try await Task.sleep(for: delay)
        let url = try #require(request.url)
        return try (
            response,
            #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            ))
        )
    }

    nonisolated func lines(for _: URLRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ChatGPTError.invalidStream) }
    }
}

private struct FixtureChatGPTIdentity: ChatGPTIdentityVerifying {
    let subject: String
    func verify(
        _: String,
        clientID _: String,
        nonce _: String?
    ) async throws -> VerifiedChatGPTIdentity {
        VerifiedChatGPTIdentity(subject: subject, email: "fixture@example.invalid")
    }
}

private actor FixtureChatGPTStream: ChatGPTTransporting {
    var requests: [URLRequest] = []
    var outputs: [String]
    init(_ outputs: [String]) {
        self.outputs = outputs
    }

    func data(for _: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ChatGPTError
            .server
    }

    private func next(_ request: URLRequest) throws -> String {
        requests.append(request)
        guard !outputs.isEmpty else { throw ChatGPTError.invalidStream }
        return outputs.removeFirst()
    }

    nonisolated func lines(for request: URLRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = try await self.next(request)
                    let event = try JSONSerialization.data(withJSONObject: [
                        "type": "response.completed",
                        "response": [
                            "status": "completed",
                            "output": [["content": [["type": "output_text", "text": output]]]],
                        ],
                    ])
                    continuation.yield("data: " + String(decoding: event, as: UTF8.self))
                    continuation.yield("")
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct ChatGPTTests {
    @Test func intentPlanningUsesStructuredSchemaRealIDsAndAccountFence() async throws {
        let account = registration()
        let id = UUID()
        let home = DecimalCategory(id: UUID(), code: "31.04", name: "Agent Architectures")
        let expected: [String: Any] = ["steps": [["action": "file",
                                                  "targets": [0],
                                                  "argument": "Fits existing architecture material.",
                                                  "categoryCode": home.code]]]
        let transport = try FixtureChatGPTStream([String(
            decoding: JSONSerialization.data(withJSONObject: expected),
            as: UTF8.self
        )])
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let context = ConversationPlanningContext(
            purpose: "request",
            history: [.init(author: "user", text: "We just saved this article.")],
            records: [.init(
                id: id,
                title: "Fixture article",
                excerpt: "Architecture evidence.",
                filing: ["10 Inbox"]
            )],
            categories: [home]
        )
        let plan = try await ChatGPTConversationInference(session: session, model: "fixture-model")
            .plan(
                request: "Could we organize it better?",
                context: context
            )
        try plan.validate(context: context, hasURL: false)
        #expect(plan.steps.first?.action == .file)
        #expect(plan.steps.first?.targets == [id])
        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(request.url?.host == "api.openai.com")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect((json["instructions"] as? String)?.contains("ALWAYS require a review card") == true)
        #expect(String(decoding: body, as: UTF8.self).contains(id.uuidString))
        #expect(String(decoding: body, as: UTF8.self).contains(home.id.uuidString))
        #expect(json["text"] != nil)
        _ = try await session.signOut()
        await #expect(throws: ChatGPTError.self) {
            _ = try await ChatGPTConversationInference(session: session, model: "fixture-model")
                .plan(
                    request: "File this",
                    context: context
                )
        }
        #expect(await transport.requests.count == 1)
    }

    private func registration(expired: Bool = false) -> ChatGPTRegistration {
        ChatGPTRegistration(
            id: "fixture-account",
            clientID: "oaiapp_fixture",
            subject: "fixture-subject",
            email: "fixture@example.invalid",
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            idToken: nil,
            scopes: ["resource.invoke", "chatgpt.tokens.use.direct"],
            expiresAt: Date().addingTimeInterval(expired ? -60 : 3600)
        )
    }

    @Test func authorizationUsesPKCEAndIssuedClientOnly() async throws {
        let session = try ChatGPTSession(vault: MemoryChatGPTVault(), hostID: "urn:uuid:fixture")
        let redirect = try #require(URL(string: "http://127.0.0.1:54321/auth/callback"))
        let attempt = try await session.beginAuthorization(redirect: redirect)
        let items = try #require(URLComponents(
            url: attempt.browserURL,
            resolvingAgainstBaseURL: false
        )?.queryItems)
        #expect(items.first { $0.name == "client_id" }?.value == "dynamic_agent_client")
        #expect(items.first { $0.name == "agent_name_hint" }?.value == "Infactory")
        #expect(items.first { $0.name == "code_challenge" }?.value == OAuthEncoding
            .challenge(attempt.verifier))
        #expect(items.first { $0.name == "redirect_uri" }?.value == redirect.absoluteString)
        #expect(throws: ChatGPTError.invalidCallback) {
            try attempt
                .callback(#require(URL(string: redirect
                        .absoluteString + "?code=fixture&state=wrong&client_id=oaiapp_fixture")))
        }
        #expect(throws: ChatGPTError.invalidCallback) {
            try attempt
                .callback(#require(URL(string: redirect
                        .absoluteString +
                        "?code=fixture&state=\(attempt.state)&client_id=dynamic_agent_client")))
        }
        #expect(throws: ChatGPTError.invalidCallback) {
            try attempt
                .callback(#require(URL(string: redirect
                        .absoluteString +
                        "?code=fixture&state=\(attempt.state)&state=\(attempt.state)&client_id=oaiapp_fixture")))
        }
        #expect(throws: ChatGPTError.cancelledConsent) {
            try attempt
                .callback(#require(URL(string: redirect
                        .absoluteString + "?error=access_denied&state=\(attempt.state)")))
        }
        #expect(try attempt
            .callback(#require(URL(string: redirect
                    .absoluteString +
                    "?code=fixture&state=\(attempt.state)&client_id=oaiapp_fixture")))
            .clientID == "oaiapp_fixture")
    }

    @Test func returningIdentityMismatchPreservesSavedAccount() async throws {
        let account = registration()
        let vault = try MemoryChatGPTVault(ChatGPTCredentialRecords(
            accounts: [account],
            activeID: account.id
        ))
        let before = try vault.load()
        let transport = FixtureChatGPTTransport(response: """
        {"access_token":"new-fixture","refresh_token":"new-refresh","id_token":"fixture-id","token_type":"Bearer","expires_in":3600,"scope":"resource.invoke chatgpt.tokens.use.direct"}
        """)
        let session = ChatGPTSession(
            vault: vault,
            transport: transport,
            verifier: FixtureChatGPTIdentity(subject: "wrong-subject"),
            hostID: "fixture"
        )
        let redirect = try #require(URL(string: "http://127.0.0.1:54321/auth/callback"))
        let attempt = try await session.beginAuthorization(
            redirect: redirect,
            accountID: account.id
        )
        #expect(!attempt.browserURL.absoluteString.contains("agent_name_hint"))
        await #expect(throws: ChatGPTError.invalidIdentity) {
            try await session.completeAuthorization(
                attempt,
                callback: #require(URL(string: redirect
                        .absoluteString + "?code=fixture&state=\(attempt.state)"))
            )
        }
        #expect(try vault.load() == before)
    }

    @Test func concurrentRefreshRotatesTokensOnceAndPersists() async throws {
        let account = registration(expired: true)
        let vault = try MemoryChatGPTVault(ChatGPTCredentialRecords(
            accounts: [account],
            activeID: account.id
        ))
        let transport = FixtureChatGPTTransport(response: """
        {"access_token":"rotated-fixture","refresh_token":"rotated-refresh","token_type":"Bearer","expires_in":3600}
        """, delay: .milliseconds(30))
        let session = ChatGPTSession(vault: vault, transport: transport, hostID: "fixture")
        async let first = session.accessToken()
        async let second = session.accessToken()
        let tokens = try await [first, second]
        #expect(tokens == ["rotated-fixture", "rotated-fixture"])
        #expect(await transport.requests.count == 1)
        let saved = try JSONDecoder().decode(
            ChatGPTCredentialRecords.self,
            from: #require(try vault.load())
        )
        #expect(saved.accounts.first?.refreshToken == "rotated-refresh")
        #expect(saved.accounts.first?.planAuthorized == true)
        let restarted = ChatGPTSession(vault: vault, transport: transport, hostID: "fixture")
        #expect(try await restarted.accessToken() == "rotated-fixture")
        #expect(await transport.requests.count == 1)
    }

    @Test func switchingAccountsCancelsRefreshAndInvalidatesFence() async throws {
        let account = registration(expired: true)
        var other = registration()
        other = ChatGPTRegistration(
            id: "other-account",
            clientID: "oaiapp_other",
            subject: "other",
            email: other.email,
            accessToken: other.accessToken,
            refreshToken: nil,
            idToken: nil,
            scopes: other.scopes,
            expiresAt: other.expiresAt
        )
        let transport = FixtureChatGPTTransport(response: "{}", delay: .seconds(5))
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account, other],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let fence = try await session.authorizationFence()
        let task = Task { try await session.accessToken() }
        while await transport.requests.isEmpty {
            await Task.yield()
        }
        try await session.select(other.id)
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: CancellationError.self) { try await session.validateFence(fence) }
    }

    @Test func planScopesAreRequiredAndLocalSignOutSurvivesRevocationFailure() async throws {
        var account = registration()
        account.scopes = ["openid"]
        let vault = try MemoryChatGPTVault(ChatGPTCredentialRecords(
            accounts: [account],
            activeID: account.id
        ))
        let transport = FixtureChatGPTTransport(response: "{}", status: 503)
        let session = ChatGPTSession(vault: vault, transport: transport, hostID: "fixture")
        await #expect(throws: ChatGPTError.planNotAuthorized) { try await session.accessToken() }
        #expect(await transport.requests.isEmpty)
        #expect(try await session.signOut() == false)
        let saved = try JSONDecoder().decode(
            ChatGPTCredentialRecords.self,
            from: #require(try vault.load())
        )
        #expect(saved.accounts.first?.clientID == account.clientID)
        #expect(saved.accounts.first?.accessToken == nil)
        #expect(saved.accounts.first?.refreshToken == nil)
        #expect(saved.accounts.first?.idToken == nil)
    }

    @Test @MainActor func remoteProviderRequiresSeparateSourceConsent() async throws {
        let account = registration()
        let transport = FixtureChatGPTTransport(response: """
        {"models":[{"slug":"fixture-model","display_name":"Fixture model","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"}]}
        """)
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let suite = "infactory-chatgpt-test-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let connection = ChatGPTConnection(session: session, preferences: preferences)
        preferences.set(true, forKey: "chatgpt.cloud-consent." + account.id)
        preferences.set(true, forKey: "chatgpt.enabled")
        await connection.load()
        #expect(!connection.consented)
        #expect(!connection.useChatGPT)
        #expect(connection.models.map(\.slug) == ["fixture-model"])
        connection.setEnabled(true)
        #expect(!connection.useChatGPT)
        #expect(try connection.inference().capabilities.local)
        connection.setConsent(true)
        connection.setEnabled(true)
        connection.selectModel("fixture-model")
        #expect(preferences.string(forKey: "chatgpt.model." + account.id) == "fixture-model")
        #expect(try !connection.inference().capabilities.local)
        connection.setConsent(false)
        #expect(!connection.useChatGPT)
        #expect(try connection.inference().capabilities.local)
    }

    @Test @MainActor func selectingChatGPTPromptsForConsentInsteadOfSilentlyIgnoringTheChoice(
    ) async throws {
        let account = registration()
        let transport =
            FixtureChatGPTTransport(
                response: "{\"models\":[{\"slug\":\"fixture\",\"display_name\":\"Fixture model\",\"visibility\":\"list\"}]}"
            )
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let suite = "infactory-provider-selection-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let connection = ChatGPTConnection(session: session, preferences: preferences)
        await connection.load()
        connection.selectProvider(true)
        #expect(connection.providerPrompt == .sharing(accountID: account.id))
        #expect(!connection.consented)
        #expect(!connection.useChatGPT)
        connection.cancelProviderSelection()
        #expect(connection.providerPrompt == nil)
        #expect(!connection.useChatGPT)
        connection.selectProvider(true)
        let prompt = try #require(connection.providerPrompt)
        // A native dialog may clear its presentation binding before invoking the action.
        connection.providerPrompt = nil
        connection.confirmProviderSelection(prompt)
        #expect(connection.consented)
        #expect(connection.useChatGPT)
        connection.selectProvider(false)
        #expect(!connection.useChatGPT)
        connection.selectProvider(true)
        #expect(connection.useChatGPT)
        #expect(connection.providerPrompt == nil)
        connection.selectProvider(false)
        connection.setConsent(false)
        connection.selectProvider(true)
        let stale = try #require(connection.providerPrompt)
        connection.activeID = "changed-account"
        connection.confirmProviderSelection(stale)
        #expect(!connection.consented)
        #expect(!connection.useChatGPT)
        connection.accounts = []
        connection.activeID = nil
        connection.selectProvider(true)
        #expect(connection.providerPrompt == .signIn)
        #expect(!connection.signingIn)
    }

    @Test(arguments: [
        "/cr",
        "/eof",
        "/mislabeled",
        "/json-response",
    ]) func realURLSessionStreamingAcceptsBOMCarriageReturnsAndFinalTerminalEvents(
        path: String
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureSSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = ChatGPTTransport(session: session)
        let request =
            try URLRequest(url: #require(URL(string: "https://stream-fixture.invalid" + path)))
        var decoder = ChatGPTSSEDecoder()
        var result: String?
        for try await line in transport.lines(for: request) {
            if let complete = try decoder.consume(line) {
                result = complete; break
            }
        }
        #expect(result == "Hello, fixture.")
    }

    @Test func interruptedStreamsNeverPublishPartialTextAndReportSafeDiagnostics() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureSSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = ChatGPTTransport(session: session)
        var decoder = ChatGPTSSEDecoder()
        for try await line in try transport
            .lines(
                for: URLRequest(url: #require(
                    URL(string: "https://stream-fixture.invalid/interrupted")
                ))
            )
        {
            #expect(try decoder.consume(line) == nil)
        }
        #expect(throws: ChatGPTError.streamInterrupted(events: 1, last: .text, characters: 18)) {
            try decoder.finish()
        }
        await #expect(throws: ChatGPTError.unexpectedResponseFormat(format: .json, bytes: 2)) {
            for try await _ in try transport
                .lines(
                    for: URLRequest(url: #require(
                        URL(string: "https://stream-fixture.invalid/json")
                    ))
                ) {}
        }
    }

    @Test func nonSSEErrorsAreClassifiedWithoutExposingResponseContent() async throws {
        #expect(ChatGPTError.apiError([
            "type": "invalid_request_error",
            "message": "PRIVATE_FIXTURE",
        ]) == .requestRejected)
        #expect(!ChatGPTError.requestRejected.localizedDescription.contains("PRIVATE_FIXTURE"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureSSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = ChatGPTTransport(session: session)
        await #expect(throws: ChatGPTError.usageLimit) {
            for try await _ in try transport
                .lines(
                    for: URLRequest(url: #require(
                        URL(string: "https://stream-fixture.invalid/json-error")
                    ))
                ) {}
        }
        let htmlError = ChatGPTError.unexpectedResponseFormat(
            format: .html,
            bytes: Data("<html>PRIVATE_FIXTURE</html>".utf8).count
        )
        #expect(!htmlError.localizedDescription.contains("PRIVATE_FIXTURE"))
        await #expect(throws: htmlError) {
            for try await _ in try transport
                .lines(
                    for: URLRequest(url: #require(
                        URL(string: "https://stream-fixture.invalid/html")
                    ))
                ) {}
        }
    }

    @Test func responseBodyUsesOnlySupportedStatelessPreviewFields() throws {
        let body = try ChatGPTConversationInference.requestBody(
            model: "fixture",
            prompt: "Fixture question",
            instructions: "Fixture instructions",
            name: "grounded_research",
            schema: ChatGPTConversationInference.researchSchema(ids: ["E1"])
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "store", "stream", "instructions", "input", "text"])
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect((json["input"] as? [[String: String]])?.first?["role"] == "user")
    }

    @Test(arguments: AgentRole
        .allCases) func chatGPTConversationsUseRoleAndRecentHistory(role: AgentRole) async throws
    {
        let account = registration()
        let transport = FixtureChatGPTStream(["Hello from the fixture teammate."])
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let provider = ChatGPTConversationInference(session: session, model: "fixture-model")
        var result: String?
        for try await event in provider.reply(question: "hello", role: role, history: [
            ConversationTurn(author: "user", text: "My name is Morgan."),
            ConversationTurn(author: "researcher", text: "Hello, Morgan."),
        ]) {
            if case let .result(text) = event {
                result = text
            }
        }
        #expect(result == "Hello from the fixture teammate.")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(requests.first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "store", "stream", "instructions", "input"])
        #expect((json["instructions"] as? String)?.contains("Infactory's \(role.rawValue)") == true)
        let input = try #require(json["input"] as? [[String: String]])
        #expect(input.map { $0["role"] } == ["user", "assistant", "user"])
        #expect(input.first?["content"] == "My name is Morgan.")
        #expect(input.last?["content"] == "hello")
    }

    @Test(arguments: [
        true,
        false,
    ]) func providerChecksEvidenceBeforePublishing(supported: Bool) async throws {
        let account = registration()
        let transport = FixtureChatGPTStream([
            "{\"points\":[{\"text\":\"Fixture memory is local.\",\"evidenceID\":\"S1E1\"}]}",
            "{\"supported\":[\(supported)]}",
        ])
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let source = ResearchSource(
            note: MarkdownDocument(name: "Fixture source", markdown: "Fixture memory is local."),
            sourceIDs: [],
            document: CapturedDocument(
                title: "Fixture source",
                coverage: .note,
                blocks: [ContentBlock(
                    kind: .paragraph,
                    markdown: "Fixture memory is local.",
                    text: "Fixture memory is local."
                )]
            )
        )
        let inference = ChatGPTConversationInference(session: session, model: "fixture-model")
        var results: [String] = []
        do {
            for try await event in inference.research(
                question: "What does the fixture say?",
                sources: [source]
            ) {
                if case let .result(text) = event {
                    results.append(text)
                }
            }
            #expect(supported)
        } catch {
            #expect(!supported)
            #expect(error as? ChatGPTError == .invalidOutput)
        }
        #expect(results.count == (supported ? 1 : 0))
        if supported {
            #expect(results.first?.contains("[S1E1]") == true)
        }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests
            .allSatisfy { $0.url?.absoluteString == "https://api.openai.com/v1/responses" })
        #expect(requests
            .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access"
            })
    }

    @Test func streamingRequiresCompletionAndMapsPlanLimits() throws {
        var decoder = ChatGPTSSEDecoder()
        #expect(try decoder.consume(": heartbeat") == nil)
        #expect(try decoder
            .consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"fixture\"}") ==
            nil)
        #expect(try decoder.consume("") == nil)
        #expect(decoder.text == "fixture")
        _ = try decoder
            .consume(
                "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}"
            )
        #expect(try decoder.consume("") == "fixture")
        var failed = ChatGPTSSEDecoder()
        _ = try failed
            .consume(
                "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}"
            )
        #expect(throws: ChatGPTError.usageLimit) { try failed.consume("") }
        var incomplete = ChatGPTSSEDecoder()
        _ = try incomplete.consume("data: [DONE]")
        #expect(throws: ChatGPTError.streamInterrupted(events: 0, last: .none, characters: 0)) {
            try incomplete.consume("")
        }
    }

    @Test func byteFramingPreservesBlankLinesAndUnicode() throws {
        var buffer = ChatGPTLineBuffer()
        let lines = try Data("data: café\r\n\r\n".utf8).compactMap { try buffer.consume($0) }
        #expect(lines == ["data: café", ""])
    }

    @Test @MainActor func settingsPagesRenderWithoutCombiningAccountsAndFiling() async throws {
        let account = registration()
        let transport =
            FixtureChatGPTTransport(
                response: "{\"models\":[{\"slug\":\"fixture\",\"display_name\":\"Fixture model\",\"visibility\":\"list\"}]}"
            )
        let suite = "infactory-settings-pages-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let connection = ChatGPTConnection(session: session, preferences: preferences)
        await connection.load()
        connection.setConsent(true)
        connection.setEnabled(true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        let model = ConversationModel(
            store: store,
            coordinator: AgentCoordinator(store: store),
            chatGPT: connection
        )
        await model.load()
        #expect(model.categories.count == 4)
        let library = LibraryModel(store: store)
        for page in KnowledgeSettingsPage.allCases {
            for scheme in [ColorScheme.light, .dark] {
                try await renderSettings(
                    model: model,
                    library: library,
                    page: page,
                    scheme: scheme,
                    suffix: "\(page.rawValue).\(scheme == .light ? "light" : "dark")"
                )
            }
        }
        connection.setConsent(false)
        try await renderSettings(
            model: model,
            library: library,
            page: .inference,
            scheme: .dark,
            suffix: "needs-consent"
        )
        connection.accounts = []
        connection.activeID = nil
        try await renderSettings(
            model: model,
            library: library,
            page: .inference,
            scheme: .dark,
            suffix: "disconnected"
        )
        connection.signingIn = true
        try await renderSettings(
            model: model,
            library: library,
            page: .inference,
            scheme: .dark,
            suffix: "signing-in"
        )
    }

    @MainActor private func renderSettings(
        model: ConversationModel,
        library: LibraryModel,
        page: KnowledgeSettingsPage,
        scheme: ColorScheme,
        suffix: String
    ) async throws {
        let view = NSHostingView(rootView: ConversationSettings(
            model: model,
            library: library,
            initialPage: page
        )
        .environment(\.colorScheme, scheme))
        view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 780, height: 600)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = view.appearance
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        // Native table rows are created after attachment to a window and a run-loop turn.
        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(view.fittingSize.width == 780)
        #expect(view.fittingSize.height == 600)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["INFACTORY_SETTINGS_SCREENSHOT"],
           let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: path).appendingPathExtension(suffix + ".png"))
        }
    }

    @Test @MainActor func settingsRenderConnectedAndDisconnectedInBothAppearances() async throws {
        let account = registration()
        let transport =
            FixtureChatGPTTransport(
                response: "{\"models\":[{\"slug\":\"fixture\",\"display_name\":\"Fixture model\",\"visibility\":\"list\"}]}"
            )
        let session = try ChatGPTSession(
            vault: MemoryChatGPTVault(ChatGPTCredentialRecords(
                accounts: [account],
                activeID: account.id
            )),
            transport: transport,
            hostID: "fixture"
        )
        let suite = "infactory-chatgpt-render-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let connection = ChatGPTConnection(session: session, preferences: preferences)
        await connection.load()
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: ChatGPTSettings(connection: connection).padding(24)
                .environment(
                    \.colorScheme,
                    scheme
                ))
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 610)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 600)
            if let path = ProcessInfo.processInfo.environment["INFACTORY_CHATGPT_SCREENSHOT"],
               let png = bitmap.representation(using: .png, properties: [:])
            {
                try png
                    .write(to: URL(fileURLWithPath: path)
                        .appendingPathExtension(scheme == .light ? "light.png" : "dark.png"))
            }
        }
        connection.accounts = []
        connection.activeID = nil
        let empty = NSHostingView(rootView: ChatGPTSettings(connection: connection).padding(24))
        empty.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        empty.layoutSubtreeIfNeeded()
        #expect(empty.fittingSize.height <= 400)
        connection.signingIn = true
        let signingIn = NSHostingView(rootView: ChatGPTSettings(connection: connection)
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
        signingIn.appearance = NSAppearance(named: .darkAqua)
        signingIn.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        signingIn.layoutSubtreeIfNeeded()
        #expect(signingIn.fittingSize.height <= 400)
        let bitmap = try #require(signingIn.bitmapImageRepForCachingDisplay(in: signingIn.bounds))
        signingIn.cacheDisplay(in: signingIn.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["INFACTORY_CHATGPT_SCREENSHOT"],
           let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: path).appendingPathExtension("signing-in.png"))
        }
    }

    @Test func validatesRealRSASignatureNonceAudienceAndExpiry() throws {
        let key = try #require(SecKeyCreateRandomKey(
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary,
            nil
        ))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        // 2048-bit PKCS#1 fixture: sequence and INTEGER use long-form lengths.
        let modulus = der.subdata(in: 9 ..< 265)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "fixture",
            "kty": "RSA",
            "n": OAuthEncoding.encode(modulus),
            "e": "AQAB",
        ]]])
        let header = OAuthEncoding.encode(Data("{\"alg\":\"RS256\",\"kid\":\"fixture\"}".utf8))
        let claims = try OAuthEncoding.encode(JSONSerialization.data(withJSONObject: [
            "iss": "https://auth.openai.com",
            "sub": "fixture",
            "aud": "oaiapp_fixture",
            "nonce": "fixture-nonce",
            "exp": Date().timeIntervalSince1970 + 600,
        ]))
        let message = "\(header).\(claims)"
        let signature = try #require(SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(message.utf8) as CFData,
            nil
        ) as Data?)
        let token = message + "." + OAuthEncoding.encode(signature)
        #expect(try OpenAIIdentityVerifier.validate(
            token,
            clientID: "oaiapp_fixture",
            nonce: "fixture-nonce",
            jwks: jwks
        ).subject == "fixture")
        #expect(throws: ChatGPTError.invalidIdentity) { try OpenAIIdentityVerifier.validate(
            token,
            clientID: "wrong",
            nonce: "fixture-nonce",
            jwks: jwks
        ) }
        #expect(throws: ChatGPTError.invalidIdentity) { try OpenAIIdentityVerifier.validate(
            token,
            clientID: "oaiapp_fixture",
            nonce: "wrong",
            jwks: jwks
        ) }
        #expect(throws: ChatGPTError.invalidIdentity) { try OpenAIIdentityVerifier.validate(
            token,
            clientID: "oaiapp_fixture",
            nonce: "fixture-nonce",
            jwks: jwks,
            now: Date().addingTimeInterval(1200)
        ) }
        #expect(throws: ChatGPTError.invalidIdentity) { try OpenAIIdentityVerifier.validate(
            message + "." + OAuthEncoding.encode(Data(repeating: 0, count: 256)),
            clientID: "oaiapp_fixture",
            nonce: "fixture-nonce",
            jwks: jwks
        ) }
    }

    @Test func loopbackIgnoresUnrelatedRequestsAndAcceptsBoundState() async throws {
        let listener = OAuthLoopback()
        let redirect = try await listener.start()
        #expect(redirect.host == "127.0.0.1")
        await listener.expect(state: "fixture-state")
        let (_, rejected) = try await URLSession.shared
            .data(from: #require(URL(string: redirect
                    .absoluteString + "?code=fixture&state=wrong")))
        #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
        let url =
            try #require(URL(string: redirect
                    .absoluteString + "?code=fixture&state=fixture-state&client_id=oaiapp_fixture"))
        let (_, accepted) = try await URLSession.shared.data(from: url)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await listener.wait() == url)
        await listener.stop()
    }
}
