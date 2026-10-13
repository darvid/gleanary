import Foundation

struct ChatGPTAuthorization: Sendable {
    let id: UUID
    let state: String
    let nonce: String
    let verifier: String
    let redirect: URL
    let clientID: String
    let accountID: String?
    let browserURL: URL

    func callback(_ url: URL) throws -> (code: String, clientID: String) {
        guard url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port,
              url.path == redirect.path, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw ChatGPTError.invalidCallback }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil,
                  let value = item.value else { throw ChatGPTError.invalidCallback }
            values[item.name] = value
        }
        guard values["state"] == state else { throw ChatGPTError.invalidCallback }
        if values["error"] != nil {
            throw ChatGPTError.cancelledConsent
        }
        guard let code = values["code"], !code.isEmpty,
              code.count <= 8192 else { throw ChatGPTError.invalidCallback }
        let issued = values["client_id"] ?? (accountID == nil ? "" : clientID)
        guard issued != "dynamic_agent_client", !issued.isEmpty, issued.count <= 200,
              issued.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              accountID == nil || issued == clientID else { throw ChatGPTError.invalidCallback }
        return (code, issued)
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: Double
    let scope: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case tokenType = "token_type", expiresIn = "expires_in", scope
    }
}

actor ChatGPTSession {
    let transport: any ChatGPTTransporting
    private let vault: any ChatGPTCredentialStoring
    private let verifier: any ChatGPTIdentityVerifying
    private var hostID: String?
    private var records: ChatGPTCredentialRecords?
    private var epoch = UUID()
    private var pendingAuthorization: UUID?
    private var refreshTask: (id: UUID, task: Task<ChatGPTRegistration, any Error>)?

    init(
        vault: any ChatGPTCredentialStoring = KeychainChatGPTCredentials(),
        transport: any ChatGPTTransporting = ChatGPTTransport(),
        verifier: (any ChatGPTIdentityVerifying)? = nil,
        hostID: String? = nil
    ) {
        self.vault = vault
        self.transport = transport
        self.verifier = verifier ?? OpenAIIdentityVerifier(transport: transport)
        self.hostID = hostID
    }

    func accounts() throws -> (accounts: [ChatGPTAccountSummary], activeID: String?) {
        let records = try load()
        return (records.accounts.map {
            ChatGPTAccountSummary(
                id: $0.id,
                label: $0.label,
                signedIn: $0.accessToken != nil,
                planAuthorized: $0.planAuthorized
            )
        }, records.activeID)
    }

    func select(_ id: String) throws {
        var records = try load()
        guard records.accounts.contains(where: { $0.id == id })
        else { throw ChatGPTError.signInRequired }
        invalidateOperations()
        records.activeID = id
        try persist(records)
    }

    func beginAuthorization(
        redirect: URL,
        accountID: String? = nil
    ) throws -> ChatGPTAuthorization {
        guard pendingAuthorization == nil else { throw ChatGPTError.busy }
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil,
              redirect.path == "/auth/callback", redirect.query == nil,
              redirect.fragment == nil else { throw ChatGPTError.invalidCallback }
        let records = try load()
        let returning = records.accounts.first { $0.id == accountID }
        guard accountID == nil || returning != nil else { throw ChatGPTError.signInRequired }
        let state = try OAuthEncoding.random(), nonce = try OAuthEncoding.random(),
            verifier = try OAuthEncoding.random()
        let clientID = returning?.clientID ?? "dynamic_agent_client"
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")
        var items = [
            "client_id": clientID,
            "ext_agent_host_id": prepareHostID(),
            "response_type": "code",
            "redirect_uri": redirect.absoluteString,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": "https://api.openai.com/v1",
            "state": state,
            "nonce": nonce,
            "code_challenge_method": "S256",
            "code_challenge": OAuthEncoding.challenge(verifier),
        ]
        if returning == nil {
            items["agent_name_hint"] = "Infact"
        }
        if let hint = returning?.idToken {
            items["id_token_hint"] = hint
        }
        if let email = returning?.email {
            items["login_hint"] = email
        }
        components?.queryItems = items.keys.sorted()
            .map { URLQueryItem(name: $0, value: items[$0]) }
        guard let browserURL = components?.url else { throw ChatGPTError.invalidCallback }
        let id = UUID()
        pendingAuthorization = id
        return ChatGPTAuthorization(
            id: id,
            state: state,
            nonce: nonce,
            verifier: verifier,
            redirect: redirect,
            clientID: clientID,
            accountID: accountID,
            browserURL: browserURL
        )
    }

    func completeAuthorization(_ attempt: ChatGPTAuthorization, callback: URL) async throws {
        guard pendingAuthorization == attempt.id else { throw CancellationError() }
        let callback = try attempt.callback(callback)
        let startingEpoch = epoch
        let token = try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": callback.clientID,
            "code": callback.code,
            "code_verifier": attempt.verifier,
            "redirect_uri": attempt.redirect.absoluteString,
            "resource": "https://api.openai.com/v1",
        ])
        guard let idToken = token.idToken else { throw ChatGPTError.invalidIdentity }
        let identity = try await verifier.verify(
            idToken,
            clientID: callback.clientID,
            nonce: attempt.nonce
        )
        try Task.checkCancellation()
        guard pendingAuthorization == attempt.id,
              epoch == startingEpoch else { throw CancellationError() }
        var records = try load()
        if let accountID = attempt.accountID {
            guard let account = records.accounts.first(where: { $0.id == accountID }),
                  account.subject == identity.subject,
                  account.clientID == callback.clientID else { throw ChatGPTError.invalidIdentity }
        }
        let id = ContentHash.of("https://auth.openai.com|\(identity.subject)|\(callback.clientID)")
        let account = ChatGPTRegistration(
            id: id,
            clientID: callback.clientID,
            subject: identity.subject,
            email: identity.email,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            idToken: idToken,
            scopes: Set((token.scope ?? "").split(separator: " ").map(String.init)),
            expiresAt: Date().addingTimeInterval(token.expiresIn)
        )
        records.accounts.removeAll { $0.id == id }
        records.accounts.append(account)
        records.activeID = id
        try persist(records)
        invalidateOperations()
    }

    func cancelAuthorization() {
        pendingAuthorization = nil
    }

    func accessToken() async throws -> String {
        let records = try load()
        guard let account = records.accounts.first(where: { $0.id == records.activeID }),
              account.accessToken != nil else { throw ChatGPTError.signInRequired }
        guard account.planAuthorized else { throw ChatGPTError.planNotAuthorized }
        if let expiry = account.expiresAt, expiry > Date().addingTimeInterval(60),
           let token = account.accessToken
        {
            return token
        }
        if let refreshTask {
            let currentEpoch = epoch
            let refreshed = try await refreshTask.task.value
            try Task.checkCancellation()
            guard epoch == currentEpoch,
                  let token = refreshed.accessToken else { throw ChatGPTError.signInRequired }
            return token
        }
        let id = UUID(), currentEpoch = epoch
        let task = Task { try await self.refresh(account, epoch: currentEpoch) }
        refreshTask = (id, task)
        defer {
            if refreshTask?.id == id {
                refreshTask = nil
            }
        }
        let refreshed = try await task.value
        try Task.checkCancellation()
        guard epoch == currentEpoch,
              let token = refreshed.accessToken else { throw ChatGPTError.signInRequired }
        return token
    }

    func catalog() async throws -> [ChatGPTModelChoice] {
        let fence = try authorizationFence()
        let token = try await accessToken()
        try validateFence(fence)
        var request = try URLRequest(url: endpoint("https://api.openai.com/v1/models"))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        try validateFence(fence)
        guard response.statusCode == 200 else { throw ChatGPTError.http(response.statusCode) }
        struct Catalog: Decodable { let models: [ChatGPTModelChoice] }
        return try JSONDecoder().decode(Catalog.self, from: data).models.filter {
            $0.visibility == "list" && !$0.slug.isEmpty && $0.slug.count <= 200 && $0.displayName
                .count <= 200
        }
    }

    /// Tokens are removed locally even if remote revocation cannot be confirmed.
    func signOut() async throws -> Bool {
        var records = try load()
        guard let index = records.accounts.firstIndex(where: { $0.id == records.activeID })
        else { return true }
        let account = records.accounts[index]
        invalidateOperations()
        records.accounts[index].accessToken = nil
        records.accounts[index].refreshToken = nil
        records.accounts[index].idToken = nil
        records.accounts[index].expiresAt = nil
        records.accounts[index].scopes = []
        try persist(records)
        guard let refreshToken = account.refreshToken else { return true }
        for attempt in 0 ..< 2 {
            do {
                let discovery = try await revocationEndpoint()
                let request = try formRequest(
                    discovery,
                    values: [
                        "token": refreshToken,
                        "token_type_hint": "refresh_token",
                        "client_id": account.clientID,
                    ]
                )
                let (_, response) = try await transport.data(for: request)
                if response.statusCode == 200 {
                    return true
                }
                if response.statusCode < 500 {
                    return false
                }
            } catch is CancellationError { return false }
            catch { /* Still attempt local sign-out if OpenAI cannot be reached. */ }
            if attempt == 0 {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return false }
            }
        }
        return false
    }

    func authorizationFence() throws -> (accountID: String, epoch: UUID) {
        let records = try load()
        guard let id = records.activeID,
              records.accounts.first(where: { $0.id == id })?.planAuthorized == true
        else { throw ChatGPTError.signInRequired }
        return (id, epoch)
    }

    func validateFence(_ fence: (accountID: String, epoch: UUID)) throws {
        guard epoch == fence.epoch,
              try load().activeID == fence.accountID else { throw CancellationError() }
    }

    private func refresh(
        _ account: ChatGPTRegistration,
        epoch expected: UUID
    ) async throws -> ChatGPTRegistration {
        guard let refreshToken = account.refreshToken else { throw ChatGPTError.signInRequired }
        var token: OAuthTokenResponse
        do {
            token = try await tokenRequest([
                "grant_type": "refresh_token",
                "client_id": account.clientID,
                "refresh_token": refreshToken,
                "resource": "https://api.openai.com/v1",
            ])
        } catch ChatGPTError.signInRequired {
            if epoch == expected {
                clearActiveTokens()
            }
            throw ChatGPTError.signInRequired
        }
        var updated = account
        if let idToken = token.idToken {
            let identity = try await verifier.verify(
                idToken,
                clientID: account.clientID,
                nonce: nil
            )
            guard identity.subject == account.subject else { throw ChatGPTError.invalidIdentity }
            updated.idToken = idToken
        }
        try Task.checkCancellation()
        guard epoch == expected else { throw CancellationError() }
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken ?? refreshToken
        updated.expiresAt = Date().addingTimeInterval(token.expiresIn)
        if let scope = token
            .scope
        {
            updated.scopes = Set(scope.split(separator: " ").map(String.init))
        }
        var records = try load()
        guard let index = records.accounts.firstIndex(where: { $0.id == account.id }),
              records.activeID == account.id else { throw CancellationError() }
        records.accounts[index] = updated
        try persist(records)
        guard updated.planAuthorized else { throw ChatGPTError.planNotAuthorized }
        return updated
    }

    private func tokenRequest(_ values: [String: String]) async throws -> OAuthTokenResponse {
        let request = try formRequest(
            "https://auth.openai.com/api/accounts/oauth/token",
            values: values
        )
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["error"] as? String == "invalid_grant"
            {
                throw ChatGPTError.signInRequired
            }
            throw ChatGPTError.http(response.statusCode)
        }
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard token.tokenType.lowercased() == "bearer", !token.accessToken.isEmpty,
              token.expiresIn.isFinite, token.expiresIn > 0,
              token.expiresIn <= 31_536_000 else { throw ChatGPTError.invalidIdentity }
        return token
    }

    private func revocationEndpoint() async throws -> String {
        let (data, response) = try await transport
            .data(
                for: URLRequest(
                    url: endpoint("https://auth.openai.com/.well-known/openid-configuration")
                )
            )
        guard response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["issuer"] as? String == "https://auth.openai.com",
              let endpoint = object["revocation_endpoint"] as? String,
              endpoint == "https://auth.openai.com/api/accounts/oauth/revoke"
        else { throw ChatGPTError.invalidIdentity }
        return endpoint
    }

    private func load() throws -> ChatGPTCredentialRecords {
        if let records {
            return records
        }
        let loaded = try vault.load().map { try JSONDecoder().decode(
            ChatGPTCredentialRecords.self,
            from: $0
        ) } ?? ChatGPTCredentialRecords()
        records = loaded
        return loaded
    }

    private func prepareHostID() -> String {
        if let hostID {
            return hostID
        }
        let key = "chatgpt.host-id.v1"
        let id = UserDefaults.standard.string(forKey: key) ?? "urn:uuid:" + UUID().uuidString
            .lowercased()
        UserDefaults.standard.set(id, forKey: key)
        hostID = id
        return id
    }

    private func persist(_ value: ChatGPTCredentialRecords) throws {
        try vault.save(JSONEncoder().encode(value))
        records = value
    }

    private func invalidateOperations() {
        epoch = UUID()
        pendingAuthorization = nil
        refreshTask?.task.cancel()
        refreshTask = nil
    }

    private func clearActiveTokens() {
        guard var value = records,
              let index = value.accounts.firstIndex(where: { $0.id == value.activeID })
        else { return }
        value.accounts[index].accessToken = nil
        value.accounts[index].refreshToken = nil
        value.accounts[index].idToken = nil
        value.accounts[index].scopes = []
        // Preserve the in-memory safety fence even if Keychain is locked during invalidation.
        records = value
        try? vault.save(JSONEncoder().encode(value))
    }

    private func endpoint(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw ChatGPTError.server }
        return url
    }

    private func formRequest(_ url: String, values: [String: String]) throws -> URLRequest {
        var request = try URLRequest(url: endpoint(url))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthEncoding.form(values)
        return request
    }
}
