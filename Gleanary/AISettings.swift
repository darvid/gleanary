import SwiftUI

/// AI settings: the provider and models requests use, the ChatGPT sign-in, and API keys for
/// other hosted providers.
struct AISettings: View {
    @Bindable var providers: InferenceProviders
    var localStatus: String = "Uses Apple Intelligence on this Mac."
    @State private var showingDetails = false
    /// A provider picked before it has a key, shown as chosen while its key is entered.
    @State private var pendingProvider: InferenceProvider?
    private let pickerWidth: CGFloat = 180
    private let actionWidth: CGFloat = 24
    private let keyFieldWidth: CGFloat = 220

    private var connection: ChatGPTConnection {
        providers.chatGPT
    }

    private var changingAccount: Bool {
        providers.busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InferenceSettingsRow(title: "Provider", detail: "Used for new chat messages.") {
                Picker("AI provider", selection: Binding(
                    get: { pendingProvider ?? providers.selected }, set: choose
                )) {
                    ForEach(InferenceProvider.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize().frame(width: pickerWidth, alignment: .trailing)
                .disabled(changingAccount)
            }
            if let pendingProvider {
                Divider()
                InferenceSettingsRow(
                    title: "\(pendingProvider.company) API key",
                    detail: "Needed to use \(pendingProvider.name). Requests are billed to your key."
                ) {
                    APIKeyField(
                        provider: pendingProvider,
                        providers: providers,
                        focusOnAppear: true
                    ) {
                        self.pendingProvider = nil
                        providers.select(pendingProvider)
                    }
                    .frame(width: keyFieldWidth)
                }
                keyStatus(pendingProvider).padding(.bottom, 12)
            }
            let selected = providers.selected
            if pendingProvider != nil {
                // The chosen provider's models show once its key is saved.
            } else if selected != .apple {
                Divider()
                modelRows(selected)
            } else {
                Text(localStatus).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                    .fadesOnChange(localStatus)
                    .textSelection(.enabled).padding(.bottom, 8)
            }
            Text("ChatGPT").font(.headline).padding(.top, 24).padding(.bottom, 4)
            accountRow
            if connection.signingIn {
                HStack(spacing: 8) {
                    WorkingProgress()
                    Text("Signing in with ChatGPT…").font(.callout)
                    Spacer()
                    Button("Cancel") { connection.cancelSignIn() }.controlSize(.small)
                }.padding(.vertical, 12)
            }
            if connection.activeAccount?.planAuthorized == true {
                Divider()
                Toggle(isOn: Binding(
                    get: { connection.consented }, set: { connection.setConsent($0) }
                )) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Allow sharing with OpenAI")
                        Text(
                            "Sends your messages, recent chat history, document titles and selected excerpts. Original files and the full library aren’t uploaded."
                        )
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch).disabled(changingAccount).padding(.vertical, 16)
                if !connection.consented {
                    Text("Choosing ChatGPT will ask for permission to share.")
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.72)).padding(
                            .bottom,
                            12
                        )
                }
            }
            if connection.busy, !connection.refreshingModels {
                HStack(spacing: 8) {
                    WorkingProgress()
                    Text("Updating connection…").font(.caption)
                }.padding(.vertical, 12)
            }
            if let error = connection.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
            }
            Divider()
            Link(
                "Manage ChatGPT usage and access",
                destination: URL(string: "https://chatgpt.com/settings/usage")!
            )
            .font(.callout).padding(.vertical, 16)
            Text("API Keys").font(.headline).padding(.top, 16).padding(.bottom, 4)
            Text(
                "Use Claude, Gemini, OpenRouter or the OpenAI API with your own key. Keys stay in this Mac’s Keychain, and requests go straight to each provider."
            )
            .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            // The provider being set up above isn't repeated here.
            let listed = InferenceProvider.keyed.filter { $0 != pendingProvider }
            ForEach(listed) { provider in
                keyRow(provider)
                if provider != listed.last {
                    Divider()
                }
            }
            if let error = providers.keyError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            }
            Divider().padding(.top, 8)
            DisclosureGroup(isExpanded: $showingDetails) {
                Text(
                    "ChatGPT uses your eligible plan; other hosted providers bill your API key. Source-grounded research includes a second AI request to check the evidence. Saved-source summaries, filing and graph features follow your selected provider. Failed requests never silently switch providers."
                )
                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } label: {
                Text("How AI Is Used")
            }.font(.callout)
        }
        .confirmationDialog("Use ChatGPT?", isPresented: Binding(
            get: { connection.providerPrompt != nil },
            set: {
                if !$0 {
                    connection.providerPrompt = nil
                }
            }
        ), titleVisibility: .visible) {
            if let prompt = connection.providerPrompt {
                switch prompt {
                case .sharing:
                    Button("Allow and Use ChatGPT") { connection.confirmProviderSelection(prompt) }
                case .signIn:
                    Button("Continue with ChatGPT") { connection.confirmProviderSelection(prompt) }
                }
            }
            Button("Cancel", role: .cancel) { connection.cancelProviderSelection() }
        } message: {
            if case .sharing = connection.providerPrompt {
                Text(
                    "Your messages, recent chat history, document titles and selected excerpts will be sent to OpenAI using your ChatGPT plan. Original files and the full library aren’t uploaded."
                )
            } else {
                Text(
                    "Connect your ChatGPT account first. After sign-in, you’ll be asked to allow sharing before ChatGPT is used."
                )
            }
        }
        .alert("You're using your ChatGPT plan", isPresented: Binding(
            get: { connection.welcome }, set: { connection.welcome = $0 }
        )) {
            Button("Got It") { connection.acknowledgeWelcome() }
        } message: {
            Text(
                "Eligible AI requests in Gleanary use your ChatGPT plan. Manage usage in ChatGPT Settings. Allow sharing with OpenAI, then choose ChatGPT as your provider."
            )
        }
        .confirmationDialog(
            "Use \(providers.consentPrompt?.name ?? "")?",
            isPresented: Binding(
                get: { providers.consentPrompt != nil },
                set: {
                    if !$0 {
                        providers.consentPrompt = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let provider = providers.consentPrompt {
                Button("Allow and Use \(provider.name)") { providers.confirmConsent(provider) }
            }
            Button("Cancel", role: .cancel) { providers.consentPrompt = nil }
        } message: {
            Text(
                "Your messages, recent chat history, document titles and selected excerpts will be sent to \(providers.consentPrompt?.company ?? "") using your API key. Original files and the full library aren’t uploaded."
            )
        }
    }

    @ViewBuilder private func modelRows(_ provider: InferenceProvider) -> some View {
        let models = providers.catalog(provider)
        let refreshing = provider == .chatGPT ? connection.refreshingModels
            : providers.refreshing.contains(provider)
        let refresh = {
            Task {
                if provider == .chatGPT {
                    await connection.refreshModels()
                } else {
                    await providers.refreshModels(provider)
                }
            }
        }
        InferenceSettingsRow(
            title: "Model",
            detail: refreshing ? "Refreshing models…" : nil,
            refreshingModels: refreshing,
            refreshModels: { refresh() }
        ) {
            Picker("\(provider.name) model", selection: Binding(
                get: { providers.model(provider) },
                set: { providers.selectModel($0, for: provider) }
            )) {
                if models.isEmpty {
                    Text(refreshing ? "Loading models…" : "No models loaded").tag("")
                }
                ForEach(models) { Text($0.displayName).tag($0.slug) }
            }.labelsHidden().fixedSize().frame(width: pickerWidth, alignment: .trailing)
        }.disabled(changingAccount)
        let catalogError = provider == .chatGPT ? connection.modelCatalogError
            : providers.catalogErrors[provider]
        if let catalogError {
            VStack(alignment: .leading, spacing: 8) {
                Text(catalogError).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(models.isEmpty ? "Retry loading models" : "Retry refreshing models") {
                    refresh()
                }
                .controlSize(.small).disabled(changingAccount)
            }.padding(.bottom, 16)
        }
        InferenceSettingsRow(title: "Bulk work model") {
            Picker("Bulk work model", selection: Binding(
                get: { providers.filingModel(provider) },
                set: { providers.selectFilingModel($0, for: provider) }
            )) {
                Text("Same as chat").tag("")
                ForEach(models) { Text($0.displayName).tag($0.slug) }
            }.labelsHidden().fixedSize().frame(width: pickerWidth, alignment: .trailing)
                .disabled(changingAccount)
                .help(
                    "Used to categorize unfiled items, plan imported folders and find entities. A small, fast model keeps large batches quick and within usage limits."
                )
        }
    }

    /// Choosing a provider without a key asks for one here; the choice takes effect once a
    /// key is saved.
    private func choose(_ provider: InferenceProvider) {
        guard provider.usesKey, providers.savedKeys[provider] == nil else {
            pendingProvider = nil
            providers.select(provider)
            return
        }
        providers.keyErrors[provider] = nil
        pendingProvider = provider
    }

    private func keyRow(_ provider: InferenceProvider) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            InferenceSettingsRow(title: provider.name) {
                APIKeyField(provider: provider, providers: providers)
                    .frame(width: keyFieldWidth)
            }
            keyStatus(provider).padding(.bottom, 12)
        }
    }

    /// A key's state under its field: checking, saved, or why it wasn't saved.
    @ViewBuilder private func keyStatus(_ provider: InferenceProvider) -> some View {
        if providers.savingKey == provider {
            Text("Checking key with \(provider.company)…").font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
        } else if let error = providers.keyErrors[provider] {
            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let last = providers.savedKeys[provider] {
            Label("Saved · ends in \(last)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
        } else if let page = provider.keyPage {
            Link("Get an API key from \(provider.company)", destination: page).font(.caption)
        }
    }

    private var accountRow: some View {
        InferenceSettingsRow(title: "Account", detail: accountStatus) {
            HStack(spacing: 8) {
                if connection.accounts.count > 1 {
                    Picker("ChatGPT account", selection: Binding(
                        get: { connection.activeID ?? "" }, set: { id in
                            Task { await connection.selectAccount(id) }
                        }
                    )) {
                        ForEach(connection.accounts) { Text($0.label).tag($0.id) }
                    }.labelsHidden().fixedSize().frame(width: pickerWidth, alignment: .trailing)
                } else if let account = connection.activeAccount, account.signedIn {
                    Text(account.label).font(.callout).lineLimit(1).truncationMode(.middle)
                        .help(account.label)
                }
                if connection.activeAccount?.planAuthorized != true {
                    Button("Continue with ChatGPT") {
                        connection.signIn(accountID: connection.activeID)
                    }
                }
                if !connection.accounts.isEmpty {
                    Menu {
                        Button("Add Account…") { connection.signIn() }
                        Button("Reconnect…") { connection.signIn(accountID: connection.activeID) }
                        if connection.activeAccount?.signedIn == true {
                            Divider()
                            Button("Sign Out", role: .destructive) {
                                Task { await connection.signOut() }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .fixedSize().frame(width: actionWidth)
                        .accessibilityLabel("ChatGPT account actions")
                        .help("ChatGPT account actions")
                }
            }.disabled(changingAccount)
        }
    }

    private var accountStatus: String {
        guard let account = connection.activeAccount,
              account.signedIn else { return "Optional, uses your ChatGPT plan" }
        return account.planAuthorized ? "Connected" : "Plan permission required"
    }
}

private struct InferenceSettingsRow<Content: View>: View {
    let title: String
    var detail: String?
    var refreshingModels = false
    var refreshModels: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                    if refreshingModels {
                        ChatWorkingIndicator(color: .secondary)
                    } else if let refreshModels {
                        Button(
                            "Refresh models",
                            systemImage: "arrow.clockwise",
                            action: refreshModels
                        )
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Refresh models")
                    }
                }
                if let detail {
                    Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            Spacer(minLength: 12)
            content()
        }.padding(.vertical, 16)
    }
}

/// An API key field with no Save button: a key is checked when Return is pressed or a whole key
/// is pasted, and kept only if the provider accepts it. A saved key shows as its last four
/// characters, with a button to remove it; pasting another replaces it once that one checks out.
private struct APIKeyField: View {
    let provider: InferenceProvider
    @Bindable var providers: InferenceProviders
    var focusOnAppear = false
    var saved: () -> Void = {}
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// A paste adds this many characters at once; typing never does, so a half-typed key
    /// isn't checked and rejected.
    private static let pasteLength = 20

    var body: some View {
        let last = providers.savedKeys[provider]
        let checking = providers.savingKey == provider
        HStack(spacing: 6) {
            SecureField(
                last.map { "•••• \($0)" } ?? provider.keyPlaceholder,
                text: $draft
            )
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .accessibilityLabel("\(provider.company) API key")
            .accessibilityValue(last.map { "Saved, ends in \($0)" } ?? "Not set")
            .onSubmit(check)
            .onChange(of: draft) { old, new in
                if new.count - old.count >= Self.pasteLength {
                    check()
                }
            }
            .disabled(checking)
            if checking {
                ProgressView().controlSize(.small)
            } else if last != nil, draft.isEmpty {
                Button("Remove \(provider.name) key", systemImage: "xmark.circle.fill") {
                    Task { await providers.removeKey(provider) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Remove key")
            }
        }
        .onAppear {
            if focusOnAppear {
                focused = true
            }
        }
    }

    private func check() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, providers.savingKey == nil else { return }
        Task {
            if await providers.saveKey(key, for: provider) {
                draft = ""
                saved()
            }
        }
    }
}
