import AppKit
import Foundation
import Observation

enum ChatGPTProviderPrompt: Equatable {
    case signIn
    case sharing(accountID: String)
}

@MainActor @Observable
final class ChatGPTConnection {
    let session: ChatGPTSession
    var accounts: [ChatGPTAccountSummary] = []
    var activeID: String?
    var models: [ChatGPTModelChoice] = []
    var selectedModel = ""
    var useChatGPT = false
    var busy = false
    var signingIn = false
    var error: String?
    var welcome = false
    var providerPrompt: ChatGPTProviderPrompt?
    private(set) var consented = false
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var enableAfterSignIn = false

    init(session: ChatGPTSession = ChatGPTSession(), preferences: UserDefaults = .standard) {
        self.session = session
        self.preferences = preferences
    }

    var activeAccount: ChatGPTAccountSummary? {
        accounts.first { $0.id == activeID }
    }

    func load() async {
        do {
            let snapshot = try await session.accounts()
            accounts = snapshot.accounts
            activeID = snapshot.activeID
            consented = activeID
                .map { preferences.bool(forKey: "chatgpt.cloud-consent.v2." + $0) } ?? false
            useChatGPT = preferences.bool(forKey: "chatgpt.enabled") && consented && activeAccount?
                .planAuthorized == true
            if activeAccount?.planAuthorized == true {
                await refreshModels()
            }
        } catch { self.error = ChatGPTError.keychain.localizedDescription }
    }

    func refreshModels() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        models = []
        selectedModel = ""
        do {
            models = try await session.catalog()
            let saved = preferences.string(forKey: "chatgpt.model." + (activeID ?? ""))
            selectedModel = models.first(where: { $0.slug == saved })?.slug ?? models.first?
                .slug ?? ""
            error = models
                .isEmpty ?
                "No models are available for this account. Use on-device inference or try another account." :
                nil
        } catch { self.error = safeMessage(error) }
    }

    func selectAccount(_ id: String) async {
        guard !busy, !signingIn else { return }
        useChatGPT = false
        preferences.set(false, forKey: "chatgpt.enabled")
        models = []
        selectedModel = ""
        do { try await session.select(id); await load() }
        catch { self.error = safeMessage(error) }
    }

    func setEnabled(_ enabled: Bool) {
        useChatGPT = enabled && consented && activeAccount?.planAuthorized == true
        preferences.set(useChatGPT, forKey: "chatgpt.enabled")
    }

    func selectProvider(_ chatGPT: Bool) {
        guard !busy, !signingIn else { return }
        if !chatGPT {
            cancelProviderSelection()
            setEnabled(false)
        } else if activeAccount?.planAuthorized != true {
            providerPrompt = .signIn
        } else if !consented, let activeID {
            providerPrompt = .sharing(accountID: activeID)
        } else {
            providerPrompt = nil
            setEnabled(true)
        }
    }

    func confirmProviderSelection(_ prompt: ChatGPTProviderPrompt) {
        guard !busy, !signingIn else { return }
        switch prompt {
        case .signIn:
            providerPrompt = nil
            enableAfterSignIn = true
            signIn(accountID: activeID)
        case let .sharing(accountID):
            guard accountID == activeID, activeAccount?.planAuthorized == true else {
                cancelProviderSelection()
                error = "The selected account changed. Choose ChatGPT again to confirm sharing for that account."
                return
            }
            providerPrompt = nil
            setConsent(true)
            setEnabled(true)
        }
    }

    func cancelProviderSelection() {
        providerPrompt = nil
        enableAfterSignIn = false
    }

    private func continueProviderSelection() {
        guard enableAfterSignIn, !welcome, !signingIn, !busy else { return }
        enableAfterSignIn = false
        // Called after the sign-in task releases its busy state.
        selectProvider(true)
    }

    func selectModel(_ slug: String) {
        guard models.contains(where: { $0.slug == slug }), let activeID else { return }
        selectedModel = slug
        preferences.set(slug, forKey: "chatgpt.model." + activeID)
    }

    func setConsent(_ consent: Bool) {
        guard let activeID else { return }
        preferences.set(consent, forKey: "chatgpt.cloud-consent.v2." + activeID)
        consented = consent
        if !consent {
            setEnabled(false)
        }
    }

    func inference() throws -> any ConversationInferring {
        guard useChatGPT else { return AppleConversationInference() }
        guard consented,
              activeAccount?.planAuthorized == true else { throw ChatGPTError.planNotAuthorized }
        guard models.contains(where: { $0.slug == selectedModel })
        else { throw ChatGPTError.modelDenied }
        preferences.set(selectedModel, forKey: "chatgpt.model." + (activeID ?? ""))
        return ChatGPTConversationInference(session: session, model: selectedModel)
    }

    func signIn(accountID: String? = nil) {
        guard !signingIn, !busy else { return }
        signingIn = true
        error = nil
        signInTask = Task {
            let listener = OAuthLoopback()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [session] in
                        let redirect = try await listener.start()
                        let attempt = try await session.beginAuthorization(
                            redirect: redirect,
                            accountID: accountID
                        )
                        await listener.expect(state: attempt.state)
                        let opened = await MainActor
                            .run { NSWorkspace.shared.open(attempt.browserURL) }
                        guard opened else { throw ChatGPTError.browser }
                        let callback = try await listener.wait()
                        try await session.completeAuthorization(attempt, callback: callback)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(180))
                        throw ChatGPTError.timedOut
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                await load()
                if let activeID, activeAccount?.planAuthorized == true,
                   !preferences.bool(forKey: "chatgpt.welcomed." + activeID)
                {
                    welcome = true
                }
            } catch is CancellationError { error = nil; enableAfterSignIn = false }
            catch { self.error = safeMessage(error); enableAfterSignIn = false }
            await listener.stop()
            await session.cancelAuthorization()
            signingIn = false
            signInTask = nil
            continueProviderSelection()
        }
    }

    func acknowledgeWelcome() {
        if let activeID {
            preferences.set(true, forKey: "chatgpt.welcomed." + activeID)
        }
        welcome = false
        continueProviderSelection()
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func signOut() async {
        guard !busy, !signingIn else { return }
        busy = true
        setEnabled(false)
        setConsent(false)
        models = []
        selectedModel = ""
        do {
            let revoked = try await session.signOut()
            let snapshot = try await session.accounts()
            accounts = snapshot.accounts
            activeID = snapshot.activeID
            error = revoked ? nil : "Signed out locally. Remote revocation could not be confirmed; disconnect Infactory in ChatGPT Settings as well."
        } catch { self.error = safeMessage(error) }
        busy = false
    }

    private func safeMessage(_ error: any Error) -> String {
        (error as? ChatGPTError)?.localizedDescription ?? ChatGPTError.server.localizedDescription
    }
}
