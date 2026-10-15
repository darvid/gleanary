import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var model: ConversationModel
    @Bindable var library: LibraryModel
    @State private var preview = DocumentPreviewModel()
    @State private var showingPreview = false
    @State private var source: SourceCitation?
    @State private var reviewingChanges: ReviewedChangeset?
    @State private var importing = false
    @State private var confirmingClear = false
    @State private var starterCategories = false
    @AppStorage("starterCategoriesOffered") private var starterCategoriesOffered = false
    @State private var followLatest = true
    @FocusState private var composing: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(
        model: ConversationModel,
        library: LibraryModel,
        previewModel: DocumentPreviewModel? = nil
    ) {
        self.model = model
        self.library = library
        _preview = State(initialValue: previewModel ?? DocumentPreviewModel())
        _showingPreview = State(initialValue: previewModel?.selectedID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                HSplitView {
                    // Reserve room for the preview even at the main window's minimum width.
                    feed.frame(
                        minWidth: showingPreview ? min(460, max(240, viewport.size.width - 321)) :
                            240,
                        maxWidth: .infinity, maxHeight: .infinity
                    )
                    if showingPreview {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Saved document").font(.headline)
                                Spacer()
                                Button("Close preview", systemImage: "xmark") {
                                    showingPreview = false
                                }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }.padding()
                            DocumentPreview(
                                model: preview,
                                openSource: { source = $0 },
                                summaryEnabled: false,
                                generatingSummary: false,
                                generateSummary: { _ in },
                                cancelSummary: {},
                                suggestHome: HomeSuggester(
                                    suggest: { try await model.suggestHome(for: $0) },
                                    file: { id, suggestion in
                                        let ids = try await model.fileAsSuggested(id, suggestion)
                                        await preview.load(from: model.store)
                                        await model.didMutate?()
                                        return ids
                                    },
                                    undo: { ids in
                                        try await model.undoSuggestedFiling(ids)
                                        await preview.load(from: model.store)
                                        await model.didMutate?()
                                    },
                                    addHome: { id, home in
                                        let added = try await model.addSuggestedHome(id, home)
                                        await preview.load(from: model.store)
                                        await model.didMutate?()
                                        return added
                                    },
                                    removeHome: { id, home in
                                        try await model.removeSuggestedHome(id, home)
                                        await preview.load(from: model.store)
                                        await model.didMutate?()
                                    }
                                ),
                                editHomes: FilingEditor(
                                    remove: { id, home in
                                        let before = try await model.store
                                            .removeHome(id, categoryID: home.id)
                                        await preview.load(from: model.store)
                                        await model.didMutate?()
                                        return before
                                    },
                                    makePrimary: { id, home in
                                        let before = try await model.store
                                            .makePrimaryHome(id, categoryID: home.id)
                                        await preview.load(from: model.store)
                                        await model.didMutate?()
                                        return before
                                    },
                                    restore: { id, homes in
                                        try await model.store.restoreHomes(id, homes)
                                        await preview.load(from: model.store)
                                        await model.didMutate?()
                                    }
                                ),
                                refreshDocument: { document in
                                    Task { await model.refreshDocument(document.id) }
                                }
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
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { toolbar }
        .environment(\.openURL, OpenURLAction { url in
            if let id = NoteLink.id(from: url) {
                open(id)
                return .handled
            }
            return .systemAction
        })
        .task {
            await library.load()
            model.didMutate = { await library.refreshConversationChanges() }
            await model.load()
            // Offer a starter scheme once, while filing has nothing beyond the built-in Inbox.
            if model.ready, !starterCategoriesOffered, model.categories.count <= 1 {
                starterCategoriesOffered = true
                starterCategories = true
            }
            composing = true
        }
        .task(id: preview.selectedID) { await preview.load(from: model.store) }
        .sheet(item: $source) { CaptureSourceView(citation: $0, library: library) }
        .sheet(item: $reviewingChanges) { target in
            let changes = model.agentChanges[target.id] ?? []
            AgentChangesReview(
                changes: changes,
                titles: model.titles,
                apply: { ids in Task { await model.applyAgentChanges(ids, of: changes) } },
                reject: { Task { await model.rejectAgentChanges(changes) } }
            )
        }
        .sheet(isPresented: $starterCategories) {
            StarterCategoriesView(store: model.store, existing: model.categories) {
                await model.refresh()
                await model.didMutate?()
            }
        }
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
        .focusedSceneValue(\.gleanaryActions, GleanaryActions(
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

    /// The same trailing More menu as the library, so the toolbar keeps its shape when
    /// switching; settings live in the app menu's Settings window (⌘,).
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Menu("More", systemImage: "ellipsis") {
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
                Divider()
                Button("Clear Conversation…", systemImage: "trash", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(!model.ready || model.messages.isEmpty || model.clearingConversation)
            }
            .menuIndicator(.hidden)
            .help("Conversation options")
        }
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
                    ForEach(model.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .overlay {
                if model.messages.isEmpty {
                    ContentUnavailableView(
                        "No messages yet",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Paste a URL, attach a document, or write a message.")
                    )
                }
            }
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
            .overlay(alignment: .bottom) {
                if !followLatest {
                    Button("Latest messages", systemImage: "arrow.down") {
                        followLatest = true; proxy.scrollTo("latest", anchor: .bottom)
                    }
                    .labelStyle(.iconOnly).font(.body.weight(.semibold))
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .help("Jump to the latest message")
                    .padding(.bottom, 16)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: followLatest)
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
            if message.author == "user" {
                userBubble(message)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(message.author.capitalized).font(.headline)
                    if let role = AgentRole(rawValue: message.author) {
                        Text(role.responsibility).font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.72))
                    }
                }
                .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                MarkdownPreview(markdown: message.text).textSelection(.enabled)
            }
            ForEach(message.references, id: \.self) { id in
                ReferenceChip(
                    title: model.titles[id] ?? "Saved document",
                    selected: model.selectedSources.contains(id),
                    available: model.titles[id] != "Deleted document",
                    open: { open(id) },
                    toggleSource: { model.select(id) }
                )
            }
            if let taskID = message.taskID, message.author == "user",
               let task = model.tasks.first(where: { $0.id == taskID }),
               ["failed", "cancelled"].contains(task.state)
            {
                // Sits under the person's bubble, on the same trailing edge.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(task.progress).textSelection(.enabled).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await model.send(retry: task) }
                    }
                    .buttonStyle(.link).disabled(model.running)
                }
                .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 80).padding(.trailing, 4)
            }
            ForEach(model.proposals
                .filter {
                    $0.appears(in: message, history: model.messages)
                }) { proposal in
                    proposalCard(proposal)
                }
            if let taskID = message.taskID, isLastReply(message) {
                if let changes = model.agentChanges[taskID], !changes.isEmpty {
                    AgentChangesCard(
                        changes: changes,
                        review: { reviewingChanges = ReviewedChangeset(id: taskID) },
                        undo: { Task { await model.undoAgentChanges(changes) } }
                    )
                }
                if let scope = model.writerScopes[taskID] {
                    WriterScopeCard(
                        request: scope,
                        styles: WritingStyleChoice.current().styles,
                        busy: model.running,
                        open: open,
                        confirm: { selection, style, general in
                            Task {
                                await model.confirmScope(
                                    taskID, selection: selection, style: style,
                                    generalKnowledge: general
                                )
                            }
                        },
                        cancel: { Task { await model.cancelScope(taskID) } }
                    )
                    .id(scope.taskID)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The person's own messages sit right-aligned in a bubble, as in ChatGPT, so the agents'
    /// replies read as the main column. Times only show on hover, for every message.
    /// Cards for a task sit under its last agent reply, whichever agent wrote it.
    private func isLastReply(_ message: ConversationMessage) -> Bool {
        message.author != "user" && model.messages.last(where: {
            $0.taskID == message.taskID && $0.author != "user"
        })?.id == message.id
    }

    private func userBubble(_ message: ConversationMessage) -> some View {
        Text(message.text).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(
                Color.primary.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
            .frame(maxWidth: 560, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 80)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "You, \(message.createdAt.formatted(date: .omitted, time: .shortened))"
            )
            .accessibilityValue(message.text)
    }

    private func filingDetail(_ change: FilingChange) -> String {
        change.newCategory == nil
            ? "Changes the primary filing home. Secondary memberships and document text are preserved. Undo restores the previous filing."
            : "Creates this category and makes it the primary filing home. Document text is preserved. Undo restores the previous filing and removes the category if nothing else uses it."
    }

    /// One header line (what, which document, state), the move itself, then the agent's reason.
    /// The standing explanation of what applying does lives in help text to keep the card short.
    private func proposalCard(_ proposal: KnowledgeProposal) -> some View {
        let creates = proposal.filing?.newCategory != nil
        let explanation = proposal.filing.map(filingDetail)
            ?? "Adds a reversible cross-link. Neither document's text will change."
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: proposal
                .filing == nil ? "link" : creates ? "folder.badge.plus" : "folder")
                .foregroundStyle(creates ? Self.newCategoryTint : Color.primary.opacity(0.72))
                .help(proposal.filing == nil ? "Connection" : creates ? "New category" : "Filing")
                .accessibilityLabel(proposal
                    .filing == nil ? "Connection" : creates ? "New category" : "Filing")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if proposal.filing == nil {
                            Text(
                                "\(model.titles[proposal.left] ?? "Document") ↔ \(model.titles[proposal.right] ?? "Document")"
                            )
                        } else {
                            Text(model.titles[proposal.left] ?? "Document")
                        }
                    }.font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    proposalStatus(proposal, explanation: explanation)
                }
                if let filing = proposal.filing {
                    HStack(spacing: 6) {
                        Text(filing.previousLabel).foregroundStyle(Color.primary.opacity(0.72))
                            .lineLimit(1)
                        Image(systemName: "arrow.right").font(.caption2)
                            .foregroundStyle(Color.primary.opacity(0.72)).accessibilityHidden(true)
                        categoryChip(filing.destinationLabel, isNew: creates)
                    }.font(.callout)
                }
                if !proposal.rationale.isEmpty {
                    Text(proposal.rationale).font(.callout)
                        .foregroundStyle(Color.primary.opacity(0.72)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if proposal.status == "pending" {
                    // macOS convention: secondary action leading, decisions trailing, primary last.
                    HStack {
                        Button("Review document") {
                            open(proposal.filing == nil ? proposal.right : proposal.left)
                        }.buttonStyle(.link)
                        Spacer()
                        Button("Reject") { Task { await model.review(proposal, action: "reject") } }
                        Button(proposal.filing == nil ? "Apply link" : "Apply filing") {
                            Task { await model.review(proposal, action: "apply") }
                        }
                        .buttonStyle(.borderedProminent).help(explanation)
                        .accessibilityHint(explanation)
                    }.controlSize(.small).padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    /// The decision state, with Undo beside it once applied.
    @ViewBuilder private func proposalStatus(
        _ proposal: KnowledgeProposal,
        explanation: String
    ) -> some View {
        if proposal.status == "pending" {
            Text("Proposed").font(.caption).foregroundStyle(Color.primary.opacity(0.72))
        } else {
            HStack(spacing: 6) {
                Text(proposal.status.capitalized).font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.72))
                if proposal.status == "applied" {
                    Text("·").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                    Button(proposal.filing == nil ? "Undo link" : "Undo filing") {
                        Task { await model.review(proposal, action: "undo") }
                    }
                    .buttonStyle(.link).font(.caption).help(explanation)
                    .accessibilityHint(explanation)
                }
            }
        }
    }

    private static let newCategoryTint = NewCategoryBadge.tint

    private func categoryChip(_ label: String, isNew: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isNew ? "folder.badge.plus" : "folder").accessibilityHidden(true)
                .foregroundStyle(isNew ? Self.newCategoryTint : .primary)
            Text(label)
            if isNew {
                NewCategoryBadge()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(
            isNew ? Self.newCategoryTint.opacity(0.14) : Color.primary.opacity(0.08),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isNew ? "New category \(label)" : "Existing category \(label)")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    // Opening sets `ready`; it is false while loading too, so offer a retry only
                    // once opening has actually failed.
                    if !model.ready {
                        Button("Retry") { Task { await model.load() } }
                    }
                    Button("Dismiss", systemImage: "xmark") { model.error = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }.controlSize(.small)
            }
            if let task = model.activeTask {
                HStack(spacing: 8) {
                    // The mini spinner's glyph sits ~0.5pt above the caption's lowercase centre.
                    ProgressView().controlSize(.mini).offset(y: 0.5)
                    StageProgressText(task.progress.isEmpty ? "Working…" : task.progress)
                        .font(.caption).foregroundStyle(.secondary)
                }
                // The composer's send button doubles as Stop; keep Escape without a second control.
                .background {
                    Button("Stop current task") { Task { await model.cancel() } }
                        .keyboardShortcut(.escape, modifiers: [])
                        .hidden().accessibilityHidden(true)
                }
                .padding(.horizontal, composerInset)
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
            VStack(alignment: .leading, spacing: 8) {
                if !model.selectedSources.isEmpty {
                    sourceAttachments
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
                        "Ask Gleanary or save something…",
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
                        .running && draftIsEmpty ? "Stop current task" : "Send message")
                    .disabled(!model.ready || (!model.running && draftIsEmpty))
                }
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
        }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: 868)
            .frame(maxWidth: .infinity)
    }

    /// Documents pinned as context for the next message, shown like attachments in the composer.
    private var sourceAttachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.selectedSources, id: \.self) { id in
                    let title = model.titles[id] ?? "Saved document"
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(title).lineLimit(1).frame(maxWidth: 220)
                        Button("Remove \(title)", systemImage: "xmark") { model.select(id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .help("Used as a source for your next message")
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Source: \(title)")
                }
            }.padding(.leading, 4)
        }.scrollIndicators(.never)
    }

    /// Clears the composer's 24pt rounded corner so status text lines up with its flat edge.
    private let composerInset: CGFloat = 16

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
            Text(assigned.isEmpty ? "Not filed" : assigned.map(\.label).joined(separator: ", "))
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
    case inference, capture, filing, writing
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .inference: "AI & accounts"
        case .capture: "Capture"
        case .filing: "Filing"
        case .writing: "Writing"
        }
    }

    var symbol: String {
        switch self {
        case .inference: "sparkles"
        case .capture: "tray.and.arrow.down"
        case .filing: "folder"
        case .writing: "doc.richtext"
        }
    }
}

/// Gleanary › Settings… (⌘,): toolbar tabs in the standard Settings window.
struct ConversationSettings: View {
    static let size = CGSize(width: 680, height: 560)
    @Bindable var model: ConversationModel
    let library: LibraryModel
    @State private var page: KnowledgeSettingsPage

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
        TabView(selection: $page) {
            Tab(
                KnowledgeSettingsPage.inference.title,
                systemImage: KnowledgeSettingsPage.inference.symbol,
                value: KnowledgeSettingsPage.inference
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.running {
                            HStack {
                                Text("Stop the current task to change AI settings.")
                                    .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                                Spacer()
                                Button("Stop Task") { Task { await model.cancel() } }
                            }
                        }
                        ChatGPTSettings(
                            connection: model.chatGPT,
                            localStatus: library.intelligenceStatus
                        )
                        .disabled(model.running)
                    }
                    .padding(24)
                }
            }
            Tab(
                KnowledgeSettingsPage.capture.title,
                systemImage: KnowledgeSettingsPage.capture.symbol,
                value: KnowledgeSettingsPage.capture
            ) {
                CaptureSettingsView()
            }
            Tab(
                KnowledgeSettingsPage.filing.title,
                systemImage: KnowledgeSettingsPage.filing.symbol,
                value: KnowledgeSettingsPage.filing
            ) {
                FilingSettings(model: model).padding(24)
            }
            Tab(
                KnowledgeSettingsPage.writing.title,
                systemImage: KnowledgeSettingsPage.writing.symbol,
                value: KnowledgeSettingsPage.writing
            ) {
                WritingSettingsView()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Settings can open before the conversation has, from the app menu.
        .task { await model.load() }
    }
}

/// A saved document mentioned in a message. Clicking opens it; the trailing control, shown on
/// hover or once chosen, adds it to the sources for the next message.
private struct ReferenceChip: View {
    let title: String
    let selected: Bool
    let available: Bool
    let open: () -> Void
    let toggleSource: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                Label(title, systemImage: "doc.text").lineLimit(1)
            }
            .buttonStyle(.plain).help("Open \(title)")
            Button(
                selected ? "Remove from sources" : "Use as source",
                systemImage: selected ? "checkmark.circle.fill" : "plus.circle",
                action: toggleSource
            )
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.72))
            .help(selected ? "Remove from sources for the next message"
                : "Use as a source for the next message")
            .disabled(!available)
            .opacity(selected || hovering ? 1 : 0)
        }
        .font(.callout)
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 4)
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
            in: Capsule()
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button(selected ? "Remove from sources" : "Use as source", action: toggleSource)
                .disabled(!available)
        }
    }
}

/// Marks a category that doesn't exist yet. New categories read differently from existing ones by
/// icon, text and color together, never color alone.
struct NewCategoryBadge: View {
    static let tint = Color.green
    static let symbol = "folder.badge.plus"

    var body: some View {
        Text("New").font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Self.tint.opacity(0.25), in: Capsule())
            .accessibilityLabel("New category")
    }
}

/// The task whose changeset the review sheet shows.
struct ReviewedChangeset: Identifiable {
    let id: UUID
}
