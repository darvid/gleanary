import Foundation
import Observation

enum InferenceProvider: String, CaseIterable, Identifiable, Sendable {
    case apple, chatGPT = "chatgpt", openAI = "openai", anthropic, gemini, openRouter = "openrouter"

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .apple: "On-device"
        case .chatGPT: "ChatGPT"
        case .openAI: "OpenAI API"
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        case .openRouter: "OpenRouter"
        }
    }

    /// Who receives requests, for sharing consent and errors.
    var company: String {
        switch self {
        case .apple: "Apple"
        case .chatGPT, .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google"
        case .openRouter: "OpenRouter"
        }
    }

    var usesKey: Bool {
        switch self {
        case .apple, .chatGPT: false
        case .openAI, .anthropic, .gemini, .openRouter: true
        }
    }

    static var keyed: [InferenceProvider] {
        allCases.filter(\.usesKey)
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .gemini: "AIza…"
        case .openRouter: "sk-or-…"
        default: "sk-…"
        }
    }

    var keyPage: URL? {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")
        default: nil
        }
    }

    private var client: (any KeyedModelAPI.Type)? {
        switch self {
        case .openAI: OpenAIKeyAPI.self
        case .anthropic: AnthropicAPI.self
        case .gemini: GeminiAPI.self
        case .openRouter: OpenRouterAPI.self
        default: nil
        }
    }

    func api(keys: ProviderKeys, transport: any ChatGPTTransporting) -> (any HostedModelAPI)? {
        client?.init(keys: keys, transport: transport)
    }

    func catalog(
        key: String,
        transport: any ChatGPTTransporting
    ) async throws -> [ChatGPTModelChoice] {
        guard let client else { return [] }
        do { return try await client.catalog(key: key, transport: transport) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ChatGPTError.from(error, provider: self) }
    }
}

/// API keys for hosted providers, kept together in one Keychain item. Each saved key gets a new
/// epoch, so work started with a key that's since been replaced or removed is discarded.
actor ProviderKeys {
    private let vault: any ChatGPTCredentialStoring
    private var keys: [String: String]?
    private var epochs: [InferenceProvider: UUID] = [:]

    init(vault: any ChatGPTCredentialStoring = KeychainChatGPTCredentials(
        service: "app.gleanary.provider-keys.v1", account: "api-keys"
    )) {
        self.vault = vault
    }

    /// The last four characters of each saved key, to show which one is in use.
    func saved() throws -> [InferenceProvider: String] {
        var result: [InferenceProvider: String] = [:]
        for (raw, key) in try load() {
            if let provider = InferenceProvider(rawValue: raw) {
                result[provider] = String(key.suffix(4))
            }
        }
        return result
    }

    func key(for provider: InferenceProvider) throws -> String {
        guard let key = try load()[provider.rawValue]
        else { throw ChatGPTError.provider(provider.company, .missingKey) }
        return key
    }

    func fence(for provider: InferenceProvider) throws -> InferenceFence {
        _ = try key(for: provider)
        return (provider.rawValue, epoch(provider))
    }

    func validate(_ fence: InferenceFence) throws {
        guard let provider = InferenceProvider(rawValue: fence.accountID),
              epochs[provider] == fence.epoch,
              try load()[fence.accountID] != nil else { throw CancellationError() }
    }

    func save(_ key: String, for provider: InferenceProvider) throws {
        var all = try load()
        all[provider.rawValue] = key
        try persist(all)
        epochs[provider] = UUID()
    }

    func remove(_ provider: InferenceProvider) throws {
        var all = try load()
        all[provider.rawValue] = nil
        try persist(all)
        epochs[provider] = UUID()
    }

    private func epoch(_ provider: InferenceProvider) -> UUID {
        if let epoch = epochs[provider] {
            return epoch
        }
        let epoch = UUID()
        epochs[provider] = epoch
        return epoch
    }

    private func load() throws -> [String: String] {
        if let keys {
            return keys
        }
        do {
            let loaded = try vault.load()
                .map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            keys = loaded
            return loaded
        } catch { throw ChatGPTError.provider("API key", .keychain) }
    }

    private func persist(_ all: [String: String]) throws {
        do { try vault.save(JSONEncoder().encode(all)) }
        catch { throw ChatGPTError.provider("API key", .keychain) }
        keys = all
    }
}

/// The selected AI provider and its models: on-device, ChatGPT through its plan sign-in, or a
/// hosted provider through an API key. ChatGPT keeps its own connection; this adds the keyed
/// providers and decides which one requests use.
@MainActor @Observable
final class InferenceProviders {
    let chatGPT: ChatGPTConnection
    @ObservationIgnored let keys: ProviderKeys
    @ObservationIgnored let transport: any ChatGPTTransporting
    @ObservationIgnored private let preferences: UserDefaults
    /// The last four characters of each saved key.
    private(set) var savedKeys: [InferenceProvider: String] = [:]
    private(set) var catalogs: [InferenceProvider: [ChatGPTModelChoice]] = [:]
    private(set) var catalogErrors: [InferenceProvider: String] = [:]
    private(set) var refreshing: Set<InferenceProvider> = []
    /// The chosen API-key provider, when neither ChatGPT nor on-device is chosen.
    private(set) var keyProvider: InferenceProvider?
    private(set) var savingKey: InferenceProvider?
    private(set) var keysLoaded = false
    /// A provider waiting on permission to share before it's used.
    var consentPrompt: InferenceProvider?
    var keyError: String?
    /// Why a key couldn't be saved or removed, shown under that provider's key field.
    var keyErrors: [InferenceProvider: String] = [:]
    /// Models chosen per provider, mirrored from preferences so views update.
    private var models: [InferenceProvider: String] = [:]
    private var filingModels: [InferenceProvider: String] = [:]

    init(
        chatGPT: ChatGPTConnection,
        keys: ProviderKeys = ProviderKeys(),
        transport: any ChatGPTTransporting = ProviderHTTPTransport(),
        preferences: UserDefaults = .standard
    ) {
        self.chatGPT = chatGPT
        self.keys = keys
        self.transport = transport
        self.preferences = preferences
        for provider in InferenceProvider.keyed {
            models[provider] = preferences.string(forKey: "inference.model." + provider.rawValue)
            filingModels[provider] = preferences
                .string(forKey: "inference.filing-model." + provider.rawValue)
        }
    }

    var selected: InferenceProvider {
        if chatGPT.useChatGPT {
            return .chatGPT
        }
        if let keyProvider, savedKeys[keyProvider] != nil, consented(keyProvider) {
            return keyProvider
        }
        return .apple
    }

    var loaded: Bool {
        chatGPT.loaded && keysLoaded
    }

    var busy: Bool {
        chatGPT.busy || chatGPT.signingIn || savingKey != nil
    }

    func load() async {
        await chatGPT.load()
        do { savedKeys = try await keys.saved() }
        catch { keyError = error.localizedDescription }
        let stored = preferences.string(forKey: "inference.provider")
            .flatMap(InferenceProvider.init(rawValue:))
        keyProvider = stored?.usesKey == true && !chatGPT.useChatGPT ? stored : nil
        keysLoaded = true
        if selected.usesKey {
            await refreshModels(selected)
        }
    }

    func consented(_ provider: InferenceProvider) -> Bool {
        preferences.bool(forKey: "inference.consent." + provider.rawValue)
    }

    /// Chooses the provider for new requests. ChatGPT runs its own sign-in and sharing prompts;
    /// a keyed provider needs a saved key, and asks to share the first time.
    func select(_ provider: InferenceProvider) {
        guard !busy else { return }
        switch provider {
        case .apple:
            setKeyProvider(nil)
            chatGPT.selectProvider(false)
        case .chatGPT:
            setKeyProvider(nil)
            chatGPT.selectProvider(true)
        default:
            guard savedKeys[provider] != nil else {
                keyError = "Add an API key for \(provider.name) below first."
                return
            }
            guard consented(provider) else { consentPrompt = provider; return }
            chatGPT.selectProvider(false)
            setKeyProvider(provider)
            if catalogs[provider]?.isEmpty ?? true {
                Task { await refreshModels(provider) }
            }
        }
    }

    func confirmConsent(_ provider: InferenceProvider) {
        consentPrompt = nil
        preferences.set(true, forKey: "inference.consent." + provider.rawValue)
        select(provider)
    }

    private func setKeyProvider(_ provider: InferenceProvider?) {
        keyProvider = provider
        preferences.set(provider?.rawValue, forKey: "inference.provider")
    }

    /// Checks a key by listing its models before keeping it, so a mistyped key never replaces
    /// a working one.
    func saveKey(_ raw: String, for provider: InferenceProvider) async -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.usesKey, savingKey == nil else { return false }
        guard !key.isEmpty, key.count <= 512, !key.contains(where: \.isWhitespace) else {
            keyErrors[provider] = "That doesn’t look like an API key."
            return false
        }
        savingKey = provider
        defer { savingKey = nil }
        do {
            let catalog = try await provider.catalog(key: key, transport: transport)
            guard !catalog.isEmpty else {
                keyErrors[provider] = "\(provider.company) accepted the key but offered no usable models."
                return false
            }
            try await keys.save(key, for: provider)
            savedKeys[provider] = String(key.suffix(4))
            catalogs[provider] = catalog
            catalogErrors[provider] = nil
            keyErrors[provider] = nil
            return true
        } catch {
            let message = error.localizedDescription
            keyErrors[provider] = savedKeys[provider] == nil ? message
                : message + " Your saved key is unchanged."
            return false
        }
    }

    /// Removing a key also withdraws permission to share with its provider.
    func removeKey(_ provider: InferenceProvider) async {
        guard savingKey == nil else { return }
        do {
            try await keys.remove(provider)
            savedKeys[provider] = nil
            catalogs[provider] = nil
            catalogErrors[provider] = nil
            preferences.set(false, forKey: "inference.consent." + provider.rawValue)
            if keyProvider == provider {
                setKeyProvider(nil)
            }
            keyErrors[provider] = nil
        } catch { keyErrors[provider] = error.localizedDescription }
    }

    func refreshModels(_ provider: InferenceProvider) async {
        guard provider.usesKey, savedKeys[provider] != nil,
              !refreshing.contains(provider) else { return }
        refreshing.insert(provider)
        defer { refreshing.remove(provider) }
        catalogErrors[provider] = nil
        do {
            let key = try await keys.key(for: provider)
            catalogs[provider] = try await provider.catalog(key: key, transport: transport)
        } catch is CancellationError {
        } catch {
            catalogErrors[provider] = (catalogs[provider]?.isEmpty ?? true
                ? "Could not load models. "
                : "Could not refresh models. Your current list is still available. ")
                + error.localizedDescription
        }
    }

    func catalog(_ provider: InferenceProvider) -> [ChatGPTModelChoice] {
        provider == .chatGPT ? chatGPT.models : catalogs[provider] ?? []
    }

    /// The chat model: the saved choice while the provider still offers it, else its first.
    func model(_ provider: InferenceProvider) -> String {
        if provider == .chatGPT {
            return chatGPT.selectedModel
        }
        let models = catalog(provider)
        return models.first { $0.slug == self.models[provider] }?.slug ?? models.first?.slug ?? ""
    }

    /// The bulk filing model, or empty to follow the chat model.
    func filingModel(_ provider: InferenceProvider) -> String {
        if provider == .chatGPT {
            return chatGPT.filingModel
        }
        let saved = filingModels[provider] ?? ""
        return catalog(provider).contains { $0.slug == saved } ? saved : ""
    }

    func selectModel(_ slug: String, for provider: InferenceProvider) {
        if provider == .chatGPT {
            return chatGPT.selectModel(slug)
        }
        guard catalog(provider).contains(where: { $0.slug == slug }) else { return }
        models[provider] = slug
        preferences.set(slug, forKey: "inference.model." + provider.rawValue)
    }

    func selectFilingModel(_ slug: String, for provider: InferenceProvider) {
        if provider == .chatGPT {
            return chatGPT.selectFilingModel(slug)
        }
        guard slug.isEmpty || catalog(provider).contains(where: { $0.slug == slug }) else {
            return
        }
        filingModels[provider] = slug
        preferences.set(slug, forKey: "inference.filing-model." + provider.rawValue)
    }

    /// The models for this provider haven't loaded, so a request should fetch them first.
    var needsModels: Bool {
        let provider = selected
        return provider == .chatGPT ? chatGPT.models.isEmpty
            : provider.usesKey && catalog(provider).isEmpty
    }

    /// Identifies the engine and model, so work tied to them restarts when either changes.
    var engineKey: String {
        guard loaded, !busy else { return "pending" }
        let provider = selected
        return provider == .apple ? "apple" : provider.rawValue + ":" + model(provider)
    }

    func inference() throws -> any ConversationInferring {
        let provider = selected
        guard provider.usesKey else { return try chatGPT.inference() }
        return try hosted(provider, model: model(provider))
    }

    /// The filing model when one is chosen, else the chat model.
    func filingInference() throws -> any ConversationInferring {
        let provider = selected
        guard provider.usesKey else { return try chatGPT.filingInference() }
        let filing = filingModel(provider)
        return try hosted(provider, model: filing.isEmpty ? model(provider) : filing)
    }

    /// `inference()` for a request made now: a provider whose models failed to load at launch
    /// fetches them again first, rather than failing every request until a manual refresh.
    func requestInference() async throws -> any ConversationInferring {
        let provider = selected
        guard provider.usesKey else { return try await chatGPT.requestInference() }
        if catalog(provider).isEmpty {
            await refreshModels(provider)
        }
        return try inference()
    }

    private func hosted(_ provider: InferenceProvider, model: String) throws -> HostedInference {
        guard !model.isEmpty, catalog(provider).contains(where: { $0.slug == model }),
              let api = provider.api(keys: keys, transport: transport)
        else { throw ChatGPTError.modelDenied }
        return HostedInference(api: api, model: model)
    }
}
