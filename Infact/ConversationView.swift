import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var model: ConversationModel
    @Bindable var library: LibraryModel
    let showLibrary: () -> Void
    @State private var preview = DocumentPreviewModel()
    @State private var showingPreview = false
    @State private var source: SourceCitation?
    @State private var settings = false
    @State private var importing = false
    @State private var confirmingClear = false
    @State private var followLatest = true
    @FocusState private var composing: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                feed.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if showingPreview {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Saved document").font(.headline)
                            Spacer()
                            Button("Close preview", systemImage: "xmark") { showingPreview = false }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }.padding()
                        DocumentPreview(
                            model: preview,
                            openSource: { source = $0 },
                            summaryEnabled: false,
                            generatingSummary: false,
                            generateSummary: { _ in },
                            cancelSummary: {}
                        )
                        if let id = preview.selectedID {
                            CategoryMembershipView(
                                store: model.store,
                                noteID: id,
                                categories: model.categories
                            )
                        }
                    }
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 520)
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "infact", url.host == "note",
               let id = UUID(uuidString: url.lastPathComponent)
            {
                open(id)
                return .handled
            }
            return .systemAction
        })
        .task {
            await library.load()
            model.didMutate = { await library.refreshConversationChanges() }
            await model.load()
            composing = true
        }
        .task(id: preview.selectedID) { await preview.load(from: model.store) }
        .sheet(item: $source) { CaptureSourceView(citation: $0, library: library) }
        .sheet(isPresented: $settings) { ConversationSettings(model: model, library: library) }
        .confirmationDialog(
            "Clear conversation?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear conversation", role: .destructive) {
                Task { await model.clearConversation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Messages and recent chat context will be deleted. The current task will be cancelled and pending proposals dismissed. Saved notes, sources and applied connections will remain."
            )
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                library.refreshIntelligence()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .html, .plainText,
                                                                     UTType(
                                                                         filenameExtension: "md"
                                                                     ) ??
                                                                         .plainText])
        { result in
            switch result {
            case let .success(url): Task { await model.importFile(url) }
            case let .failure(error): model.error = error.localizedDescription
            }
        }
        .focusedSceneValue(\.infactActions, InfactActions(
            enabled: model.ready,
            newNote: {
                model
                    .composer =
                    "@librarian save: "; composing = true
            },
            attach: { importing = true },
            focus: { composing = true }
        ))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("#general").font(.title2.weight(.semibold))
            Text("Your shared knowledge workspace").font(.callout)
                .foregroundStyle(Color.primary.opacity(0.72))
            Spacer()
            Label(
                model.chatGPT
                    .useChatGPT ? "Using ChatGPT plan" :
                    (library.intelligenceAvailable ? "On-device" : "Local · model unavailable"),
                systemImage: model.chatGPT.useChatGPT ? "cloud" : "lock.shield"
            )
            .font(.caption).help(library.intelligenceStatus)
            Button("Library", systemImage: "books.vertical", action: showLibrary)
            Button("Clear conversation", systemImage: "trash") { confirmingClear = true }
                .disabled(!model.ready || model.messages.isEmpty || model.clearingConversation)
            Button("Settings", systemImage: "gearshape") { settings = true }
                .labelStyle(.iconOnly).help("Filing scheme and inference availability")
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.hasOlderMessages, model.messages.count >= 200 {
                        Button("Load earlier messages") {
                            followLatest = false; Task { await model.loadOlder() }
                        }
                    }
                    if model.messages.isEmpty {
                        Text("Paste a URL, attach a document, or write a message.")
                            .foregroundStyle(Color.primary.opacity(0.72))
                            .padding(.vertical, 48)
                    }
                    ForEach(model.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.isAtLatest(
                    contentHeight: geometry.contentSize.height,
                    visibleBottom: geometry.visibleRect.maxY,
                    bottomInset: geometry.contentInsets.bottom
                )
            } action: { _, atLatest in
                followLatest = atLatest
            }
            .onChange(of: model.messages.last?.id) {
                if followLatest {
                    proxy.scrollTo("latest", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followLatest {
                    Button("Latest messages", systemImage: "arrow.down") {
                        followLatest = true; proxy.scrollTo("latest", anchor: .bottom)
                    }
                    .padding(.trailing, 32)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    static func isAtLatest(
        contentHeight: CGFloat,
        visibleBottom: CGFloat,
        bottomInset: CGFloat = 0
    ) -> Bool {
        contentHeight + bottomInset - visibleBottom <= 40
    }

    private func messageRow(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(message.author == "user" ? "You" : message.author.capitalized).font(.headline)
                if let role = AgentRole(rawValue: message.author) {
                    Text(role.responsibility).font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.72))
                }
                Spacer()
                Text(message.createdAt, style: .time).font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.72))
            }
            MarkdownPreview(markdown: message.text).textSelection(.enabled)
            ForEach(message.references, id: \.self) { id in
                HStack {
                    Button { open(id) } label: {
                        Label(model.titles[id] ?? "Saved document", systemImage: "doc.text")
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }.buttonStyle(.borderless).foregroundStyle(.primary)
                    Spacer()
                    Button(model.selectedSources.contains(id) ? "Selected" : "Use as source") {
                        model.select(id)
                    }
                    .controlSize(.small).disabled(model.titles[id] == "Deleted document")
                }
            }
            if let taskID = message.taskID, message.author == "user",
               let task = model.tasks.first(where: { $0.id == taskID }),
               ["failed", "cancelled"].contains(task.state)
            {
                HStack(alignment: .top) {
                    Text(task.progress).font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await model.send(retry: task) } }
                        .disabled(model.running)
                }
            }
            ForEach(model.proposals
                .filter {
                    $0.appears(in: message, history: model.messages)
                }) { proposal in
                    proposalCard(proposal)
                }
        }
        .accessibilityElement(children: .contain)
    }

    private func proposalCard(_ proposal: KnowledgeProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                proposal.filing == nil ? "Proposed connection" : "Proposed filing",
                systemImage: proposal.filing == nil ? "link" : "folder"
            ).font(.headline)
            Text(
                proposal.filing
                    .map {
                        "\(model.titles[proposal.left] ?? "Document"): \($0.previousLabel) → \($0.destinationLabel)"
                    }
                    ?? "\(model.titles[proposal.left] ?? "Document") ↔ \(model.titles[proposal.right] ?? "Document")"
            )
            Text(proposal
                .filing == nil ?
                "Adds a reversible cross-link. Neither document's text will change." :
                "Changes the primary filing home. Secondary memberships and document text are preserved. Undo restores the previous filing.")
                .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
            HStack {
                if proposal.status == "pending" {
                    Button("Review document") {
                        open(proposal.filing == nil ? proposal.right : proposal.left)
                    }
                    Button(proposal.filing == nil ? "Apply link" : "Apply filing") {
                        Task { await model.review(
                            proposal,
                            action: "apply"
                        ) }
                    }
                    Button("Reject") { Task { await model.review(proposal, action: "reject") } }
                } else {
                    Text(proposal.status.capitalized).font(.callout)
                    if proposal.status == "applied" {
                        Button(proposal.filing == nil ? "Undo link" : "Undo filing") {
                            Task { await model.review(
                                proposal,
                                action: "undo"
                            ) }
                        }
                    }
                }
            }.controlSize(.small)
        }.padding(14).background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.error {
                HStack {
                    Text(error).font(.callout)
                        .textSelection(.enabled); Spacer(); Button("Dismiss") { model.error = nil }
                }
            }
            if !model.ready {
                Button("Retry opening workspace") { Task { await model.load() } }
            }
            if let task = model.activeTask {
                HStack {
                    Text(task.progress.isEmpty ? "Working…" : task.progress)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", systemImage: "stop.fill") { Task { await model.cancel() } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Stop current task")
                        .keyboardShortcut(
                            .escape,
                            modifiers: []
                        )
                }
            }
            if !model.selectedSources.isEmpty {
                HStack {
                    Text("\(model.selectedSources.count) sources selected for this request")
                        .font(.caption)
                    Button("Clear") { model.selectedSources = [] }.buttonStyle(.borderless)
                }
            }
            if ConversationRoute.mentionRange(in: model.composer) != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AgentRole.allCases, id: \.self) { role in
                        Button {
                            model.completeMention(role)
                            composing = true
                        } label: {
                            HStack(spacing: 12) {
                                Text("@\(role.rawValue)").frame(width: 100, alignment: .leading)
                                Text(role.responsibility).font(.caption)
                                    .foregroundStyle(Color.primary.opacity(0.72))
                            }
                        }.buttonStyle(.borderless).foregroundStyle(.primary)
                    }
                }.controlSize(.small)
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { importing = true } label: {
                    Image(systemName: "plus").font(.body.weight(.medium)).frame(
                        width: 32,
                        height: 32
                    )
                    .contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(!model.ready || model.running)
                .accessibilityLabel("Attach document").help("Import a document")
                TextField(
                    "Ask Infact or save something…",
                    text: $model.composer,
                    axis: .vertical
                )
                .lineLimit(1 ... 6).textFieldStyle(.plain).focused($composing)
                .padding(.vertical, 7)
                .accessibilityLabel("Message general").onSubmit { send() }
                Button {
                    if model.running, draftIsEmpty {
                        Task { await model.cancel() }
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: model.running && draftIsEmpty ? "stop.fill" : "arrow.up")
                        .font(.body.weight(.semibold)).frame(width: 32, height: 32)
                        .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                        .background(
                            Color.primary
                                .opacity(!model
                                    .ready || (!model.running && draftIsEmpty) ? 0.3 : 0.9),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.running && draftIsEmpty ? "Stop task" : model
                    .running ? "Redirect task" : "Send message")
                .help(model
                    .running && draftIsEmpty ? "Stop current task" : "Send message (⌘Return)")
                .disabled(!model.ready || (!model.running && draftIsEmpty))
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 24)
                )
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(
                    Color.primary.opacity(0.1),
                    lineWidth: 1
                ))
                .background {
                    Button("Send message", action: send).keyboardShortcut(
                        .return,
                        modifiers: .command
                    )
                    .hidden().accessibilityHidden(true).disabled(!model.ready || draftIsEmpty)
                }
            Text(model.chatGPT.useChatGPT
                ? "Messages, recent history and selected excerpts are sent to OpenAI. ⌘Return to send."
                : "Saved on this Mac. ⌘Return to send.")
                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
        }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: 868)
            .frame(maxWidth: .infinity)
    }

    private var draftIsEmpty: Bool {
        model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        followLatest = true; Task { await model.send() }
    }

    private func open(_ id: UUID) {
        preview.selectedID = id; showingPreview = true
    }
}

private struct CategoryMembershipView: View {
    let store: DocumentStore
    let noteID: UUID
    let categories: [DecimalCategory]
    @State private var assigned: [DecimalCategory] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filing").font(.headline)
            Text(assigned.isEmpty ? "Not filed" : assigned.map(\.label).joined(separator: " · "))
                .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
            Menu("Set primary home") {
                ForEach(categories) { category in
                    Button(category.label) {
                        Task {
                            do { try await store.fileNote(
                                noteID,
                                categoryID: category.id
                            ); assigned = try await store.categories(for: noteID) } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption)
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .task(id: noteID) {
                do { assigned = try await store.categories(for: noteID) }
                catch { self.error = error.localizedDescription }
            }
    }
}

enum KnowledgeSettingsPage: String, CaseIterable, Identifiable {
    case inference, filing
    var id: String {
        rawValue
    }

    var title: String {
        self == .inference ? "AI & accounts" : "Filing"
    }

    var symbol: String {
        self == .inference ? "sparkles" : "folder"
    }
}

struct ConversationSettings: View {
    @Bindable var model: ConversationModel
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var page: KnowledgeSettingsPage
    @State private var filingCode = ""
    @State private var filingName = ""
    @State private var editingCategoryID: UUID?

    init(
        model: ConversationModel,
        library: LibraryModel,
        initialPage: KnowledgeSettingsPage = .inference
    ) {
        self.model = model
        self.library = library
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Close settings", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction).help("Close settings")
            }.padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(KnowledgeSettingsPage.allCases) { item in
                        Button {
                            page = item
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(
                                    page == item ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                    Spacer()
                }.padding(12).frame(width: 176)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.title).font(.title2.weight(.semibold))
                        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12)
                    switch page {
                    case .inference:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if model.running {
                                    Text("Finish or cancel the current task to change AI settings.")
                                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                                }
                                ChatGPTSettings(
                                    connection: model.chatGPT,
                                    localStatus: library.intelligenceStatus
                                )
                                .disabled(model.running)
                            }.padding(.horizontal, 28).padding(.bottom, 24)
                        }
                    case .filing:
                        FilingSettings(
                            model: model,
                            code: $filingCode,
                            name: $filingName,
                            editingID: $editingCategoryID
                        )
                        .padding(.horizontal, 28).padding(.bottom, 24)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(width: 780, height: 600)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FilingSettings: View {
    @Bindable var model: ConversationModel
    @Binding var code: String
    @Binding var name: String
    @Binding var editingID: UUID?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Organize saved material with Johnny Decimal categories.")
                .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
            HStack {
                Text("Categories").font(.headline)
                Spacer()
                Button("New category", systemImage: "plus") {
                    editingID = nil; code = ""; name = ""; error = nil
                }
            }
            Table(model.categories, selection: $editingID) {
                TableColumn("Code") { Text($0.code).monospacedDigit() }.width(70)
                TableColumn("Name", value: \.name)
            }.frame(minHeight: 160, maxHeight: .infinity)
                .onChange(of: editingID) {
                    guard let category = model.categories.first(where: { $0.id == editingID })
                    else { return }
                    code = category.code; name = category.name; error = nil
                }
            Divider()
            Text(editingID == nil ? "New category" : "Edit category").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Code")
                    TextField("e.g. 31.04", text: $code).frame(width: 110)
                        .accessibilityLabel("Category code")
                }
                GridRow {
                    Text("Name")
                    TextField("Category name", text: $name).accessibilityLabel("Category name")
                }
            }.disabled(saving)
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Spacer()
                Button(editingID == nil ? "Add category" : "Save changes") { Task { await save() } }
                    .disabled(saving || code.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let id = editingID ?? UUID()
        do {
            try await model.store.saveCategory(id: id, code: code, name: name)
            await model.refresh()
            editingID = id
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
