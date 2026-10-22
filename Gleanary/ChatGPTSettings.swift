import SwiftUI

struct ChatGPTSettings: View {
    @Bindable var connection: ChatGPTConnection
    var localStatus: String = "Uses Apple Intelligence on this Mac."
    @State private var showingDetails = false
    private let pickerWidth: CGFloat = 180
    private let actionWidth: CGFloat = 24

    private var changingAccount: Bool {
        connection.busy || connection.signingIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InferenceSettingsRow(title: "Provider", detail: "Used for new chat messages.") {
                Picker("AI provider", selection: Binding(
                    get: { connection.useChatGPT }, set: { connection.selectProvider($0) }
                )) {
                    Text("On-device").tag(false)
                    Text("ChatGPT").tag(true)
                }
                .labelsHidden().fixedSize().frame(width: pickerWidth, alignment: .trailing)
                .disabled(changingAccount)
            }
            if connection.useChatGPT {
                Divider()
                InferenceSettingsRow(
                    title: "Model",
                    detail: connection.refreshingModels ? "Refreshing models…" : nil,
                    refreshingModels: connection.refreshingModels,
                    refreshModels: {
                        Task { await connection.refreshModels() }
                    }
                ) {
                    Picker("ChatGPT model", selection: Binding(
                        get: { connection.selectedModel }, set: { connection.selectModel($0) }
                    )) {
                        if connection.models.isEmpty {
                            Text(connection
                                .refreshingModels ? "Loading models…" : "No models loaded")
                                .tag("")
                        }
                        ForEach(connection.models) { Text($0.displayName).tag($0.slug) }
                    }.labelsHidden().fixedSize().frame(width: pickerWidth, alignment: .trailing)
                }.disabled(changingAccount)
                if let message = connection.modelCatalogError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.callout).foregroundStyle(.red)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button(connection.models
                            .isEmpty ? "Retry loading models" : "Retry refreshing models")
                        {
                            Task { await connection.refreshModels() }
                        }
                        .controlSize(.small).disabled(changingAccount)
                    }.padding(.bottom, 16)
                }
                InferenceSettingsRow(title: "Filing model") {
                    Picker("Filing model", selection: Binding(
                        get: { connection.filingModel },
                        set: { connection.selectFilingModel($0) }
                    )) {
                        Text("Same as chat").tag("")
                        ForEach(connection.models) { Text($0.displayName).tag($0.slug) }
                    }.labelsHidden().fixedSize().frame(width: pickerWidth, alignment: .trailing)
                        .disabled(changingAccount)
                        .help(
                            "Used to categorize unfiled items and plan imported folders. A small, fast model keeps large imports quick and within plan limits."
                        )
                }
            } else {
                Text(localStatus).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                    .fadesOnChange(localStatus)
                    .textSelection(.enabled).padding(.bottom, 8)
            }
            Text("ChatGPT").font(.headline).padding(.top, 24).padding(.bottom, 4)
            accountRow
            if connection.signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
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
                    ProgressView().controlSize(.small)
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
            DisclosureGroup(isExpanded: $showingDetails) {
                Text(
                    "ChatGPT uses your eligible plan, not an API key. Source-grounded research includes a second AI request to check the evidence. Saved-source summaries follow your selected AI provider. Graph features use Apple Intelligence. Failed ChatGPT requests never silently switch providers."
                )
                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } label: {
                // Outside a List, macOS only toggles from the chevron, not the label.
                Button("How AI is used") { withAnimation { showingDetails.toggle() } }
                    .buttonStyle(.plain)
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
                    Button("Allow and use ChatGPT") { connection.confirmProviderSelection(prompt) }
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
        .alert("You're using your ChatGPT plan", isPresented: $connection.welcome) {
            Button("Got it") { connection.acknowledgeWelcome() }
        } message: {
            Text(
                "Eligible AI requests in Gleanary use your ChatGPT plan. Manage usage in ChatGPT Settings. Allow sharing with OpenAI, then choose ChatGPT as your provider."
            )
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
                        Button("Add account…") { connection.signIn() }
                        Button("Reconnect…") { connection.signIn(accountID: connection.activeID) }
                        if connection.activeAccount?.signedIn == true {
                            Divider()
                            Button("Sign out", role: .destructive) {
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
                    Text(detail).font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            Spacer(minLength: 12)
            content()
        }.padding(.vertical, 16)
    }
}
