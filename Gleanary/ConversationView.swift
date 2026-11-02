import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var model: ConversationModel
    @Bindable var library: LibraryModel
    /// Shows a saved item in the Library; nil where there is no Library to switch to.
    var openInLibrary: ((UUID) -> Void)?
    @State private var preview = DocumentPreviewModel()
    @State private var showingPreview = false
    /// Hides the Chat column so the open document has the window to itself.
    @State private var focusingDocument = false
    @State private var filingDocument: MarkdownDocument?
    /// The open document the person removed from the composer, so it isn't offered again.
    @State private var aboutDismissed: UUID?
    @State private var queueExpanded = true
    @State private var source: SourceCitation?
    @State private var reviewingChanges: ReviewedChangeset?
    @State private var reviewingFiling: SeriesFiling.Status?
    @State private var importing = false
    @State private var confirmingClear = false
    @State private var startingNewChat = false
    @State private var starterCategories = false
    @AppStorage("starterCategoriesOffered") private var starterCategoriesOffered = false
    @State private var followLatest = true
    @State private var userScrolling = false
    @State private var feedPosition = ScrollPosition(edge: .bottom)
    @State private var scrollEdges = ScrollEdges()
    @FocusState private var composing: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.commandPaletteOpen) private var paletteOpen
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        model: ConversationModel,
        library: LibraryModel,
        previewModel: DocumentPreviewModel? = nil,
        openInLibrary: ((UUID) -> Void)? = nil
    ) {
        self.model = model
        self.library = library
        self.openInLibrary = openInLibrary
        _preview = State(initialValue: previewModel ?? DocumentPreviewModel())
        _showingPreview = State(initialValue: previewModel?.selectedID != nil)
    }

    var body: some View {
        // A saved document opens as the main pane, with Chat narrowed beside it so it can still
        // be asked about. The Chat column keeps its identity, so the feed keeps its place.
        HSplitView {
            if showingPreview {
                documentPane.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
            if !showingPreview || !focusingDocument {
                VStack(spacing: 0) {
                    feed.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    composer
                }
                .frame(
                    minWidth: showingPreview ? 280 : 240,
                    idealWidth: showingPreview ? 360 : nil,
                    maxWidth: showingPreview ? 480 : .infinity,
                    maxHeight: .infinity
                )
            }
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
        .task(
            id: "\(preview.selectedID?.uuidString ?? "")/\(library.documentGrid.generation)/\(preview.showsCapturedSource)"
        ) {
            await preview.load(from: model.store)
        }
        .sheet(item: $source) {
            CaptureSourceView(citation: $0, library: library, openDocument: open)
        }
        .onChange(of: model.composerFocusRequest) { composing = true }
        .onChange(of: model.documentRequest, initial: true) {
            if let id = model.documentRequest {
                model.documentRequest = nil
                open(id)
            }
        }
        .onChange(of: source?.id) {
            if source == nil {
                composing = true
            }
        }
        .sheet(item: $reviewingFiling, onDismiss: {
            Task { await model.refresh(); await model.didMutate?() }
        }) { status in
            FilingSuggestionsView(library: library, inference: {
                (try? model.chatGPT.filingInference()) ?? AppleConversationInference()
            }, noteIDs: Set(status.noteIDs))
        }
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
            startingNewChat ? "Start a new chat?" : "Clear conversation?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button(startingNewChat ? "Start New Chat" : "Clear conversation", role: .destructive) {
                let discardDraft = startingNewChat
                Task {
                    guard await model.clearConversation(discardDraft: discardDraft) else { return }
                    if discardDraft {
                        showingPreview = false
                        preview.selectedID = nil
                        followLatest = true
                        userScrolling = false
                        feedPosition = ScrollPosition(edge: .bottom)
                    }
                    composing = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                startingNewChat
                    ? "Messages, recent chat context, attachments and your unsent draft will be deleted. The current task will be cancelled and pending proposals dismissed. Saved notes, sources and applied connections will remain."
                    : "Messages and recent chat context will be deleted. The current task will be cancelled and pending proposals dismissed. Saved notes, sources and applied connections will remain."
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
        .focusedSceneValue(\.gleanaryActions, sceneActions)
    }

    private var sceneActions: GleanaryActions {
        var actions = GleanaryActions(
            enabled: model.ready && !model.clearingConversation,
            newItem: { requestClear(startNewChat: true) },
            attach: { importing = true },
            focus: { composing = true },
            newItemTitle: "New Chat"
        )
        if canClearConversation {
            actions.clearConversation = { requestClear() }
        }
        if model.ready, !draftIsEmpty {
            actions.sendMessage = send
        }
        return actions
    }

    private var documentPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: closePreview) {
                    Label("Chat", systemImage: "chevron.left")
                }
                .help("Back to Chat (Esc)")
                .accessibilityLabel("Close document and return to Chat")
                Spacer(minLength: 8)
                if let openInLibrary, let id = preview.selectedID {
                    Button("Open in Library", systemImage: "books.vertical") { openInLibrary(id) }
                        .help("Show this item in the Library")
                }
                Toggle(isOn: $focusingDocument.animation(.snappy(duration: 0.25))) {
                    Label(
                        focusingDocument ? "Show Chat" : "Focus",
                        systemImage: focusingDocument ? "sidebar.right" :
                            "arrow.up.left.and.arrow.down.right"
                    )
                }
                .toggleStyle(.button)
                .help(focusingDocument ? "Show Chat beside the document" :
                    "Hide Chat while reading")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            savedDocumentPreview(for: preview)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: closePreview)
        .sheet(item: $filingDocument) { document in
            FilingInspector(
                document: document, categories: model.categories, store: model.store,
                file: { document, categoryID in
                    do {
                        let includesSource = try await model.store
                            .captureID(for: document.id) != nil
                        try await model.store.fileNote(
                            document.id, categoryID: categoryID, includeSources: includesSource
                        )
                        await preview.load(from: model.store)
                        await model.didMutate?()
                    } catch { model.error = error.localizedDescription }
                },
                close: { filingDocument = nil }
            )
            .frame(width: 360, height: 480)
        }
    }

    private func closePreview() {
        withAnimation(.snappy(duration: 0.25)) {
            showingPreview = false
            focusingDocument = false
        }
        composing = true
    }

    func savedDocumentPreview(for preview: DocumentPreviewModel) -> DocumentPreview {
        DocumentPreview(
            model: preview,
            openSource: { source = $0 },
            summaryEnabled: library.canGenerateSummary(for: preview.selectedID),
            generatingSummary: preview.selectedID
                .map(library.summarizing) ?? false,
            generateSummary: { library.generateSummary(for: $0) },
            createAnotherSummary: { library.generateSummary(for: $0, createAnother: true) },
            cancelSummary: summaryCancel(for: preview),
            bookmarkFetch: preview.selectedID
                .flatMap { library.bookmarkFetch(for: $0)?.progress },
            openDocument: open,
            fileDocument: { filingDocument = $0 },
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
    }

    private func requestClear(startNewChat: Bool = false) {
        startingNewChat = startNewChat
        confirmingClear = true
    }

    private var canClearConversation: Bool {
        model.ready && !model.messages.isEmpty && !model.clearingConversation
    }

    private func summaryCancel(for preview: DocumentPreviewModel) -> (() -> Void)? {
        guard let id = library.generatingSummaryID, id == preview.selectedID else { return nil }
        return library.cancelSummary
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
                    requestClear()
                }
                .disabled(!canClearConversation)
            }
            .menuIndicator(.hidden)
            .help("Conversation options")
        }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if model.hasOlderMessages, model.messages.count >= 200 {
                    Button("Load Earlier Messages") {
                        followLatest = false; Task { await model.loadOlder() }
                    }
                }
                ForEach(ConversationFeedEntry.entries(
                    in: model.messages,
                    drafting: Set(model.replyDrafts.keys)
                )) { entry in
                    if let message = entry.userMessage {
                        messageRow(message)
                            .id(entry.id)
                    } else {
                        response(entry)
                            .id(entry.id)
                    }
                }
            }.padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .environment(\.tintedCategories, model.categories)
        .scrollPosition($feedPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .overlay {
            if model.messages.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Paste a URL, attach a document, or write a message.")
                )
            }
        }
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating
        }
        .onScrollGeometryChange(for: FeedGeometry.self) { geometry in
            FeedGeometry(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                visibleBottom: geometry.visibleRect.maxY,
                atLatest: Self.isAtLatest(
                    contentHeight: geometry.contentSize.height,
                    visibleBottom: geometry.visibleRect.maxY,
                    bottomInset: geometry.contentInsets.bottom
                )
            )
        } action: { old, new in
            followLatest = Self.shouldFollowLatest(
                following: followLatest, old: old, new: new, userScrolling: userScrolling
            )
            if followLatest, old.contentHeight != new.contentHeight ||
                old.viewportHeight != new.viewportHeight
            {
                feedPosition.scrollTo(edge: .bottom)
            }
        }
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            ScrollEdges(
                contentHeight: geometry.contentSize.height,
                visibleTop: geometry.visibleRect.minY,
                visibleBottom: geometry.visibleRect.maxY,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
        } action: { _, edges in
            scrollEdges = edges
        }
        .overlay { scrollEdgeFades }
        .onChange(of: model.messages.isEmpty) {
            if model.messages.isEmpty {
                followLatest = true
            }
        }
        .onChange(of: model.messages.last?.id) {
            if followLatest {
                feedPosition.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if !followLatest {
                Button("Latest Messages", systemImage: "arrow.down") {
                    followLatest = true; feedPosition.scrollTo(edge: .bottom)
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

    private var scrollEdgeFades: some View {
        VStack(spacing: 0) {
            edgeFade(from: .top, to: .bottom).opacity(scrollEdges.top)
            Spacer(minLength: 0)
            edgeFade(from: .bottom, to: .top).opacity(scrollEdges.bottom)
        }
        .opacity(model.messages.isEmpty || contrast == .increased || reduceTransparency ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Follow the actual scroll position, not the Latest messages button's animation.
        .transaction { $0.animation = nil }
    }

    private func edgeFade(from start: UnitPoint, to end: UnitPoint) -> some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), .clear],
            startPoint: start,
            endPoint: end
        )
        .frame(height: ScrollEdges.depth)
    }

    struct ScrollEdges: Equatable {
        static let depth: CGFloat = 22
        let top: CGFloat
        let bottom: CGFloat

        init(
            contentHeight: CGFloat = 0,
            visibleTop: CGFloat = 0,
            visibleBottom: CGFloat = 0,
            topInset: CGFloat = 0,
            bottomInset: CGFloat = 0
        ) {
            let viewportHeight = visibleBottom - visibleTop
            guard viewportHeight > 0,
                  contentHeight + topInset + bottomInset > viewportHeight + 0.5
            else {
                top = 0
                bottom = 0
                return
            }
            top = min(1, max(0, (visibleTop + topInset) / Self.depth))
            bottom = min(1, max(0, (contentHeight + bottomInset - visibleBottom) / Self.depth))
        }
    }

    struct FeedGeometry: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        let visibleBottom: CGFloat
        let atLatest: Bool
    }

    static func shouldFollowLatest(
        following: Bool, old: FeedGeometry, new: FeedGeometry, userScrolling: Bool
    ) -> Bool {
        // Layout growth must not look like the person scrolling away. The offset check also
        // recognizes keyboard and scrollbar movement that can arrive without a scroll phase.
        let movedUp = new.visibleBottom < old.visibleBottom - 0.5 &&
            new.contentHeight == old.contentHeight && new.viewportHeight == old.viewportHeight
        let userMoved = userScrolling && new.visibleBottom != old.visibleBottom
        return new.atLatest || (following && !userMoved && !movedUp)
    }

    static func isAtLatest(
        contentHeight: CGFloat,
        visibleBottom: CGFloat,
        bottomInset: CGFloat = 0
    ) -> Bool {
        contentHeight + bottomInset - visibleBottom <= 40
    }

    func response(_ entry: ConversationFeedEntry) -> some View {
        let working = entry.taskID.map { model.isWorking(on: $0) } ?? false
        let activity = entry.activity(working: working)
        let replies = entry.replies(working: working)
        let draft = entry.taskID.flatMap { model.replyDrafts[$0] }
        // The posted reply takes over its draft's view, so the reveal carries on.
        let drafting = draft.map { draft in !replies.contains { $0.sequence > draft.after } }
            ?? false
        let latest = drafting ? nil : replies.last
        let task = model.tasks.first { $0.id == entry.taskID }
        // No visible byline: the unboxed reply opposite the person's bubbles says who is talking.
        // VoiceOver still gets a heading per reply to move between turns.
        return VStack(alignment: .leading, spacing: 0) {
            Text("Gleanary")
                .frame(width: 0, height: 0).clipped()
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                if !activity.isEmpty {
                    ConversationActivityView(
                        messages: activity,
                        working: working,
                        progress: task?.progress,
                        agent: task?.owner
                    ) {
                        // The summary line already names a lone agent and carries the role
                        // symbols, so headings only tell several agents apart.
                        let namesAuthors = Set(activity.map(\.author)).count > 1
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(activity) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    if namesAuthors {
                                        Text(AgentRole(rawValue: message.author)?.title
                                            ?? message.author.capitalized)
                                            .font(.callout.weight(.semibold))
                                            .help(AgentRole(rawValue: message.author)?
                                                .responsibility ?? "")
                                    }
                                    messageText(message, readingFont: nil)
                                    references(for: message)
                                }
                                .accessibilityElement(children: .contain)
                            }
                        }
                    }
                }
                ForEach(drafting ? replies : replies.dropLast()) { message in
                    messageText(message)
                }
                if let live = drafting ? draft?.text : latest.map(displayedMarkdown) {
                    StreamingMarkdown(live, streaming: draft != nil, readingFont: .chat)
                        .textSelection(.enabled)
                        .help(latest?.createdAt.formatted(date: .abbreviated, time: .shortened)
                            ?? "")
                }
                // Keep each saved result visible once; activity retains per-message provenance.
                if !entry.referenceIDs.isEmpty {
                    savedItems(entry, captured: task?.captureID != nil).padding(.top, 4)
                }
                acquisitionSuggestions(entry)
                // Approvals remain reachable while activity is collapsed.
                ForEach(entry.messages) { message in
                    messageActions(message)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Splits a status message into its first sentence and the rest, so a long explanation
    /// can sit in a tooltip.
    nonisolated static func statusSentences(_ text: String) -> (String, String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = trimmed.range(of: ". "), end.upperBound < trimmed.endIndex else {
            return (trimmed, nil)
        }
        let rest = trimmed[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return (String(trimmed[..<end.lowerBound]), rest.isEmpty ? nil : rest)
    }

    /// The items a reply saved or cited, as one card of rows rather than loose chips.
    private func savedItems(_ entry: ConversationFeedEntry, captured: Bool) -> some View {
        let ids = entry.referenceIDs
        let saved = ids.filter { id in
            captured || entry.taskID != nil && model.referenceDetails[id]?.taskID == entry.taskID
        }.count
        let title = saved == ids.count
            ? (ids.count == 1 ? "Saved 1 item" : "Saved \(ids.count) items")
            : (ids.count == 1 ? "1 item" : "\(ids.count) items")
        return VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: saved == ids.count ? "checkmark" : "books.vertical")
                    .foregroundStyle(saved == ids.count ? Color.green : Color.secondary)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
            ForEach(ids, id: \.self) { id in
                Divider()
                savedItemRow(id)
            }
        }
        // A whole-point stroke: a 0.5pt hairline over a translucent fill renders unevenly on
        // dark backgrounds, heavier on the top and left edges.
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func savedItemRow(_ id: UUID) -> some View {
        let details = model.referenceDetails[id]
        let host = details?.sourceURL?.host()
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let kind = details.map { details in
            details.hasCapture ? "Source" : details.artifactKind == nil ? "Note"
                : details.researchKindTitle
        } ?? "Saved document"
        return SavedItemRow(
            title: model.titles[id] ?? details?.title ?? "Saved document",
            kind: kind, host: host,
            symbol: details?.hasCapture == true ? "doc.text" : "note.text",
            filing: details?.filing,
            selected: model.selectedSources.contains(id),
            available: model.titles[id] != "Deleted document",
            isOpen: showingPreview && preview.selectedID == id,
            open: { open(id) }, toggleSource: { model.select(id) },
            explore: model.exploringNotes.contains(id) ? nil : {
                Task { await model.exploreFrom(id) }
            },
            excerpt: { await excerpt(id) }
        )
    }

    private func displayedMarkdown(_ message: ConversationMessage) -> String {
        researchResult(in: message) == nil ? message.text : message.textWithoutResearchBibliography
    }

    /// Replies read at `ReadingFont.chat`; specialist activity stays at body size beneath them.
    private func messageText(
        _ message: ConversationMessage, readingFont: ReadingFont? = .chat
    ) -> some View {
        MarkdownPreview(markdown: displayedMarkdown(message), readingFont: readingFont)
            .textSelection(.enabled)
            .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
    }

    private func messageRow(_ message: ConversationMessage) -> some View {
        let queuePosition = message.author == "user"
            ? message.taskID.flatMap { id in model.queue.firstIndex { $0.id == id } } : nil
        return VStack(alignment: .leading, spacing: 9) {
            if message.author == "user" {
                // A waiting request is dimmed until its turn.
                userBubble(message).opacity(queuePosition == nil ? 1 : 0.7)
            }
            if let queuePosition {
                Label(
                    "Queued · \(queuePosition + 1) of \(model.queue.count)",
                    systemImage: "clock"
                )
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
            }
            if let taskID = message.taskID, message.author == "user",
               let task = model.tasks.first(where: { $0.id == taskID }),
               ["failed", "cancelled"].contains(task.state)
            {
                // Sits under the person's bubble, on the same trailing edge. The first sentence
                // says what happened; the rest is in the tooltip.
                let failed = task.state == "failed"
                let (headline, detail) = Self.statusSentences(task.progress)
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : "stop.circle")
                        .foregroundStyle(failed ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                    Text(headline).textSelection(.enabled).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(detail ?? headline)
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await model.send(retry: task) }
                    }
                    .controlSize(.small).disabled(model.running)
                    .help(detail ?? "Run this request again")
                }
                .font(.callout).foregroundStyle(.primary)
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 80).padding(.trailing, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func messageActions(_ message: ConversationMessage) -> some View {
        ForEach(model.proposals
            .filter {
                $0.appears(in: message, history: model.messages)
            }) { proposal in
                proposalCard(proposal)
            }
        if let taskID = message.taskID, isLastReply(message) {
            if let filing = model.seriesFiling[taskID] {
                SeriesFilingActions(
                    status: filing,
                    working: model.isWorking(on: taskID),
                    review: { reviewingFiling = filing },
                    undo: { Task { await model.undoSeriesFiling(filing) } }
                )
            }
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

    func researchResult(in message: ConversationMessage) -> ConversationReference? {
        guard let id = message.references.first,
              let reference = model.referenceDetails[id], reference.isResearchResult(in: message)
        else { return nil }
        return reference
    }

    @ViewBuilder func references(for message: ConversationMessage) -> some View {
        if let result = researchResult(in: message) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    let role = result.researchKindTitle
                    Text(role).font(.caption.weight(.semibold))
                    reference(
                        result.id,
                        title: result.researchTitle,
                        symbol: "text.alignleft",
                        role: role
                    )
                    Text("Generated by Researcher").font(.caption).foregroundStyle(.secondary)
                }
                if message.references.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message.references.count == 2 ? "Source" : "Sources")
                            .font(.caption.weight(.semibold))
                        ForEach(
                            Array(message.references.dropFirst().enumerated()),
                            id: \.element
                        ) { index, id in
                            VStack(alignment: .leading, spacing: 4) {
                                reference(id, role: "Source S\(index + 1)")
                                HStack(spacing: 8) {
                                    Text("S\(index + 1) · Saved document")
                                        .foregroundStyle(.secondary)
                                    if let url = model.referenceDetails[id]?.websiteURL {
                                        Link(destination: url) {
                                            Label("Open website", systemImage: "arrow.up.right")
                                        }.help(url.absoluteString)
                                    }
                                }.font(.caption)
                            }
                        }
                    }
                }
            }
        } else {
            ForEach(message.references, id: \.self) { id in reference(id) }
        }
    }

    private func reference(
        _ id: UUID, title: String? = nil, symbol: String = "doc.text", role: String? = nil
    ) -> some View {
        ReferenceChip(
            title: title ?? model.titles[id] ?? "Saved document",
            selected: model.selectedSources.contains(id),
            available: model.titles[id] != "Deleted document",
            open: { open(id) }, toggleSource: { model.select(id) }, symbol: symbol, role: role,
            filing: model.referenceDetails[id]?.filing,
            explore: model.exploringNotes.contains(id) ? nil : {
                Task { await model.exploreFrom(id) }
            },
            isOpen: showingPreview && preview.selectedID == id,
            kind: model.referenceDetails[id]?.attachmentKind,
            host: model.referenceDetails[id]?.sourceURL?.host()
                .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 },
            excerpt: { await excerpt(id) }
        )
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
        VStack(alignment: .leading, spacing: 9) {
            if !message.references.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.references, id: \.self) { id in
                        sentContext(id)
                    }
                }
            }
            // Cards stand in for a message that is only links.
            if !PastedLinks.isOnlyLinks(message.text) {
                Text(message.text).font(ReadingFont.chat.font).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(PastedLinks.urls(in: message.text), id: \.self) { url in
                linkCard(url)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(
            Color.primary.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .help(message.createdAt.formatted(date: .abbreviated, time: .shortened))
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "You, \(message.createdAt.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// Links found inside this reply's sources that are worth saving, from Source acquisition.
    /// Automatic saves already show as reference chips, so they are left out.
    @ViewBuilder private func acquisitionSuggestions(_ entry: ConversationFeedEntry) -> some View {
        var seen = Set<String>()
        // A source's suggestions sit under the latest reply that mentions it.
        let candidates = entry.referenceIDs
            .filter { id in
                model.messages.last { $0.author != "user" && $0.references.contains(id) }?
                    .taskID == entry.taskID
            }
            .flatMap { model.acquisitionSuggestions[$0] ?? [] }
            .filter { seen.insert($0.identity).inserted }
            .filter { candidate in
                guard candidate.state != .suggested else { return true }
                guard candidate.state == .queued else { return false }
                let saved = model.capturedLinks[candidate.identity]?.noteID
                return saved.map { !entry.referenceIDs.contains($0) } ?? true
            }
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                let note = CaptureSettings.current().acquisition.suggestionNote
                HStack(spacing: 4) {
                    Text("Suggested reading").font(.caption.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Image(systemName: "info.circle").font(.caption)
                        .accessibilityLabel(note)
                }
                .foregroundStyle(.secondary)
                .help(note)
                ForEach(candidates) { candidate in
                    suggestionRow(candidate)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func suggestionRow(_ candidate: AcquisitionCandidate) -> some View {
        let saved = model.capturedLinks[candidate.identity]
        let saving = model.savingAcquisitions.contains(candidate.id)
            || (candidate.state == .queued && saved == nil && candidate.captureError == nil)
        let title = saved?.title ?? candidate.displayTitle
        return HStack(spacing: 10) {
            Group {
                if candidate.captureError != nil, !saving {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .accessibilityLabel("Couldn't save")
                } else {
                    Image(systemName: saved == nil ? "link" : "doc.text")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1)
                HStack(spacing: 8) {
                    Text(candidate.host)
                    Text(candidate.provenance.label).foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(candidate.captureError.map { "Couldn't save: \($0)" } ?? candidate.context)
            Spacer(minLength: 8)
            if let saved {
                Button("Open") { open(saved.noteID) }.buttonStyle(.link)
            } else if saving {
                WorkingProgress().accessibilityLabel("Saving")
            } else {
                Button(candidate.captureError == nil ? "Save" : "Try Again") {
                    Task { await model.saveAcquisition(candidate) }
                }
                .controlSize(.small)
                Button("Dismiss", systemImage: "xmark") {
                    Task { await model.dismissAcquisition(candidate) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Don't suggest this link again")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Open in Browser") { NSWorkspace.shared.open(candidate.url) }
            Button("Don't Suggest Links from \(candidate.host)") {
                Task { await model.muteAcquisitionHost(candidate.host) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A pasted link, shown as what the library captured from it once it is saved.
    private func linkCard(_ url: URL) -> some View {
        let captured = PastedLinks.identity(of: url).flatMap { model.capturedLinks[$0] }
        let host = url.host(percentEncoded: false).map {
            $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
        } ?? url.absoluteString
        return Button {
            if let captured {
                open(captured.noteID)
            } else {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if let data = captured?.favicon, let icon = NSImage(data: data) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "link").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(captured?.title ?? url.absoluteString)
                        .font(.callout.weight(.medium)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(host).foregroundStyle(.secondary).lineLimit(1)
                        if let filing = captured?.filing {
                            FilingTag(category: filing)
                        }
                    }
                    .font(.caption)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(captured == nil ? "Open \(url.absoluteString) in your browser" :
            "Open the saved source")
        .contextMenu {
            if let captured {
                Button("Open Saved Source") { open(captured.noteID) }
                Button("Explore Links from Here") {
                    Task { await model.exploreFrom(captured.noteID) }
                }
                .disabled(model.exploringNotes.contains(captured.noteID))
            }
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    @ViewBuilder private func sentContext(_ id: UUID) -> some View {
        if let reference = model.referenceDetails[id] {
            Button { open(id) } label: {
                Label(
                    "\(reference.attachmentKind): \(reference.title)",
                    systemImage:
                    reference.hasCapture ? "doc.text" : "note.text"
                )
                .lineLimit(2).multilineTextAlignment(.leading)
                .font(.callout)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Open the attached item")
        } else {
            Label("Deleted item", systemImage: "doc.text")
                .font(.callout).foregroundStyle(.secondary)
        }
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
                        Button("Review Document") {
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
            if ConversationRoute.mentionRange(in: model.composer) != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AgentRole.allCases, id: \.self) { role in
                        Button {
                            model.completeMention(role)
                            composing = true
                        } label: {
                            HStack(spacing: 12) {
                                Label("@\(role.rawValue)", systemImage: role.symbol)
                                    .frame(width: 120, alignment: .leading)
                                Text(role.responsibility).font(.caption)
                                    .foregroundStyle(Color.primary.opacity(0.72))
                            }
                        }.buttonStyle(.borderless).foregroundStyle(.primary)
                    }
                }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 8) {
                if model.activeTask != nil || !model.queue.isEmpty {
                    queueStrip
                    Divider().padding(.horizontal, -12)
                }
                if !model.selectedSources.isEmpty || aboutDocument != nil {
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
                        aboutDocument != nil ? "Ask about this document…" :
                            model.running ? "Add to the queue, or ask something…" :
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
                        .running ? "Add to queue" : "Send message")
                    .help(model.running && draftIsEmpty ? "Stop current task"
                        : model.running ? "Run this after the current request" : "Send message")
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
        }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: 868)
            .frame(maxWidth: .infinity)
    }

    /// What's running, and what's waiting its turn, at the top of the composer.
    @ViewBuilder private var queueStrip: some View {
        let queue = model.queue
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let task = model.activeTask {
                    ChatWorkingIndicator(color: .secondary)
                    Text(task.owner.title).fontWeight(.medium).fadesOnChange(task.owner)
                        .help(task.owner.responsibility)
                    StageProgressText(task.progress.isEmpty ? "Working…" : task.progress)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    Text("· \(Self.queueTitle(task.request))").foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else if model.queuePaused {
                    Image(systemName: "pause.fill").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Paused").fontWeight(.medium)
                    Text("· \(queue.count) queued from your last session")
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(queue.count) queued").fontWeight(.medium)
                }
                Spacer(minLength: 8)
                if model.queuePaused, model.activeTask == nil {
                    Button("Clear") { Task { await model.clearQueue() } }
                        .buttonStyle(.borderless)
                    Button("Resume") { Task { await model.resumeQueue() } }
                        .buttonStyle(.borderedProminent)
                } else if !queue.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { queueExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(queue.count) queued")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(queueExpanded ? 180 : 0))
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(queueExpanded ? "Expanded" : "Collapsed")
                    .help(queueExpanded ? "Hide the queue" : "Show the queue")
                }
            }
            .font(.caption)
            // The composer's send button doubles as Stop; keep Escape without a second control.
            .background {
                // Escape closes the palette instead while it's open.
                if model.activeTask != nil, !paletteOpen {
                    Button("Stop Current Task") { Task { await model.cancel() } }
                        .keyboardShortcut(.escape, modifiers: [])
                        .hidden().accessibilityHidden(true)
                }
            }
            if queueExpanded || model.queuePaused, !queue.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, task in
                        queueRow(task, index: index, count: queue.count)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Queued requests")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 4)
    }

    private func queueRow(_ task: ConversationTask, index: Int, count: Int) -> some View {
        let title = Self.queueTitle(task.request)
        return HStack(spacing: 8) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(title).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Move \(title) earlier", systemImage: "chevron.up") {
                Task { await model.moveInQueue(task.id, by: -1) }
            }
            .disabled(index == 0)
            Button("Move \(title) later", systemImage: "chevron.down") {
                Task { await model.moveInQueue(task.id, by: 1) }
            }
            .disabled(index == count - 1)
            Button("Remove \(title) from the queue", systemImage: "xmark") {
                Task { await model.removeFromQueue(task.id) }
            }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .font(.caption)
        .padding(.vertical, 3)
    }

    /// A request as one short line: a link without its scheme, otherwise its first line.
    nonisolated static func queueTitle(_ request: String) -> String {
        let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? request
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for scheme in ["https://", "http://"] where trimmed.hasPrefix(scheme) {
            let rest = trimmed.dropFirst(scheme.count)
            return String(rest.hasPrefix("www.") ? rest.dropFirst(4) : rest)
        }
        return trimmed
    }

    /// Documents pinned as context for the next message, shown like attachments in the composer.
    private var sourceAttachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if let about = aboutDocument {
                    HStack(spacing: 6) {
                        Image(systemName: "text.viewfinder").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("About: \(about.title)").lineLimit(1).frame(maxWidth: 220)
                        Button("Don't ask about \(about.title)", systemImage: "xmark") {
                            aboutDismissed = about.id
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(
                                lineWidth: 1,
                                dash: [3, 2]
                            ))
                    }
                    .help("Your next message includes the open document")
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("About: \(about.title)")
                }
                ForEach(model.selectedSources, id: \.self) { id in
                    let title = model.titles[id] ?? "Saved document"
                    let kind = model.referenceDetails[id]?.attachmentKind ?? "Note"
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("\(kind): \(title)").lineLimit(1).frame(maxWidth: 220)
                        Button("Remove \(title)", systemImage: "xmark") { model.select(id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .help("Used as a source for your next message")
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(kind): \(title)")
                }
            }.padding(.leading, 4)
        }.scrollIndicators(.never)
    }

    /// Clears the composer's 24pt rounded corner so status text lines up with its flat edge.
    private let composerInset: CGFloat = 16

    private var draftIsEmpty: Bool {
        model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The open document, offered as context for the next message until it's dismissed or
    /// attached outright.
    private var aboutDocument: (id: UUID, title: String)? {
        guard showingPreview, let document = preview.document,
              document.id == preview.selectedID, document.id != aboutDismissed,
              !model.selectedSources.contains(document.id) else { return nil }
        return (document.id, document.name)
    }

    private func send() {
        followLatest = true
        let about = aboutDocument.flatMap { model.selectedSources.count < 4 ? $0.id : nil }
        if let about {
            model.selectedSources.append(about)
        }
        Task {
            await model.send()
            // Only offered: a capture or a failed send leaves attachments in place.
            if let about {
                model.selectedSources.removeAll { $0 == about }
            }
        }
    }

    private func excerpt(_ id: UUID) async -> String? {
        guard let document = try? await model.store.document(id: id) else { return nil }
        return ReferencePeek.excerpt(from: document.markdown)
    }

    private func open(_ id: UUID) {
        preview.selectedID = id; showingPreview = true
    }
}

extension EnvironmentValues {
    @Entry var addToChat: (@MainActor (ChatAttachmentTarget) async -> String?)? = nil
    /// Shows a category's items in the Library, from wherever its chip appears.
    @Entry var showCategory: (@MainActor (UUID) -> Void)? = nil
}

struct AddToChatButton: View {
    let target: ChatAttachmentTarget
    var compact = false
    var added: () -> Void = {}
    @Environment(\.addToChat) private var addToChat
    @State private var adding = false
    @State private var error: String?
    @State private var showingError = false

    var body: some View {
        if let addToChat {
            Button {
                adding = true
                Task {
                    error = await addToChat(target)
                    adding = false
                    if error == nil {
                        added()
                    } else {
                        showingError = true
                    }
                }
            } label: {
                if compact {
                    Image(systemName: "text.bubble")
                } else {
                    Label("Add to Chat", systemImage: "text.bubble")
                }
            }
            .buttonStyle(.bordered)
            .disabled(adding)
            .accessibilityLabel("Add to Chat")
            .help("Attach this item to your chat draft without sending a message")
            .alert("Could not add to Chat", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "Try again.")
            }
        }
    }
}

enum KnowledgeSettingsPage: String, CaseIterable, Identifiable {
    case inference, appearance, capture, filing, writing, keyboard
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .inference: "AI & accounts"
        case .appearance: "Appearance"
        case .capture: "Capture"
        case .filing: "Filing"
        case .writing: "Writing"
        case .keyboard: "Keyboard"
        }
    }

    var symbol: String {
        switch self {
        case .inference: "sparkles"
        case .appearance: "textformat"
        case .capture: "tray.and.arrow.down"
        case .filing: "folder"
        case .writing: "doc.richtext"
        case .keyboard: "keyboard"
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
                KnowledgeSettingsPage.appearance.title,
                systemImage: KnowledgeSettingsPage.appearance.symbol,
                value: KnowledgeSettingsPage.appearance
            ) {
                AppearanceSettingsView()
            }
            Tab(
                KnowledgeSettingsPage.capture.title,
                systemImage: KnowledgeSettingsPage.capture.symbol,
                value: KnowledgeSettingsPage.capture
            ) {
                CaptureSettingsView(store: model.store, categories: model.categories)
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
            Tab(
                KnowledgeSettingsPage.keyboard.title,
                systemImage: KnowledgeSettingsPage.keyboard.symbol,
                value: KnowledgeSettingsPage.keyboard
            ) {
                KeyboardSettingsView()
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
    var symbol = "doc.text"
    var role: String?
    var filing: DecimalCategory?
    /// Follows this item's links once; nil while that is running.
    var explore: (() -> Void)?
    /// Whether this item is the document open beside Chat.
    var isOpen = false
    var kind: String?
    var host: String?
    /// The opening of the item's text, for the peek; nil when it can't be read.
    var excerpt: (() async -> String?)?
    @State private var hovering = false
    @State private var peeking = false
    @State private var hoveringPeek = false
    @State private var peekTimer: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                Label(title, systemImage: symbol).lineLimit(1)
            }
            .buttonStyle(.plain).help("Open \(title)")
            .accessibilityLabel(role.map { "\($0): \(title)" } ?? title)
            .accessibilityValue(isOpen ? "Open" : "")
            .accessibilityHint("Press Space to peek")
            .onKeyPress(.space) {
                guard excerpt != nil, available else { return .ignored }
                peeking.toggle()
                return .handled
            }
            .popover(isPresented: $peeking, arrowEdge: .bottom) {
                ReferencePeek(
                    title: title, kind: kind, host: host, filing: filing, selected: selected,
                    load: excerpt ?? { nil },
                    open: { peeking = false; open() },
                    toggleSource: toggleSource
                )
                .onHover { inside in
                    hoveringPeek = inside
                    if !inside {
                        schedulePeekClose()
                    }
                }
            }
            if let filing {
                FilingTag(category: filing)
            }
            if isOpen {
                Text("Open").font(.caption).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
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
        .overlay {
            if isOpen {
                Capsule().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
        }
        .onHover { inside in
            hovering = inside
            peekTimer?.cancel()
            if inside {
                guard excerpt != nil, available, !isOpen else { return }
                // Dwell first, so moving the pointer across a reply doesn't flash previews.
                peekTimer = Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if !Task.isCancelled {
                        peeking = true
                    }
                }
            } else {
                schedulePeekClose()
            }
        }
        .contextMenu {
            Button("Open", action: open)
            Button("Peek") { peeking = true }.disabled(excerpt == nil || !available)
            Button(selected ? "Remove from sources" : "Use as source", action: toggleSource)
                .disabled(!available)
            Button("Explore Links from Here", action: explore ?? {})
                .disabled(explore == nil || !available)
                .help("Follow this item's links once, as Eager source acquisition would")
        }
    }

    /// Leaves time to move the pointer from the chip into the peek.
    private func schedulePeekClose() {
        peekTimer?.cancel()
        peekTimer = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled, !hovering, !hoveringPeek {
                peeking = false
            }
        }
    }
}

/// One saved item in a reply's card: what it is, where it's filed, and whether it's the
/// document open beside Chat. Space or the menu peeks at it.
private struct SavedItemRow: View {
    let title: String
    let kind: String
    let host: String?
    let symbol: String
    let filing: DecimalCategory?
    let selected: Bool
    let available: Bool
    let isOpen: Bool
    let open: () -> Void
    let toggleSource: () -> Void
    let explore: (() -> Void)?
    let excerpt: () async -> String?
    @State private var peeking = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body).foregroundStyle(.secondary)
                    .frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text([kind, host].compactMap(\.self).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let filing {
                    FilingTag(category: filing)
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        .help("Used as a source for your next message")
                        .accessibilityLabel("In Chat")
                }
                if isOpen {
                    Text("Open").font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(isOpen ? Color.accentColor.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help("Open \(title)")
        .accessibilityLabel("\(kind): \(title)")
        .accessibilityValue(isOpen ? "Open" : "")
        .accessibilityHint("Press Space to peek")
        .onKeyPress(.space) {
            guard available else { return .ignored }
            peeking.toggle()
            return .handled
        }
        .popover(isPresented: $peeking, arrowEdge: .bottom) {
            ReferencePeek(
                title: title, kind: kind, host: host, filing: filing, selected: selected,
                load: excerpt, open: { peeking = false; open() }, toggleSource: toggleSource
            )
        }
        .contextMenu {
            Button("Open", action: open)
            Button("Peek") { peeking = true }.disabled(!available)
            Button(selected ? "Remove from Chat" : "Add to Chat", action: toggleSource)
                .disabled(!available)
            Button("Explore Links from Here", action: explore ?? {})
                .disabled(explore == nil || !available)
        }
    }
}

/// A glance at a saved item from Chat: its title, opening lines and filing, with Open on Return.
/// It uses system text like the rest of Chat; the reading font is for reading the item itself.
struct ReferencePeek: View {
    let title: String
    let kind: String?
    let host: String?
    let filing: DecimalCategory?
    let selected: Bool
    let load: () async -> String?
    var openTitle = "Open"
    let open: () -> Void
    /// Adds the item to the next Chat message; nil where there's no Chat to add it to.
    let toggleSource: (() -> Void)?
    @State private var excerpt: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let caption = [kind, host].compactMap(\.self).joined(separator: " · ")
            if !caption.isEmpty {
                Text(caption).font(.caption.weight(.semibold)).textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let excerpt {
                Text(excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !loaded {
                ProgressView().controlSize(.small).accessibilityLabel("Loading preview")
            }
            // Glass popovers separate by space, not rules: the filing sits beside the actions.
            HStack(spacing: 8) {
                if let filing {
                    FilingTag(category: filing)
                }
                Spacer(minLength: 12)
                if let toggleSource {
                    Button(selected ? "Remove from Chat" : "Add to Chat", action: toggleSource)
                }
                Button(openTitle, action: open).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .task {
            excerpt = await load()
            loaded = true
        }
    }

    /// The first paragraph of body text, without Markdown syntax, cut at a word near 280
    /// characters.
    nonisolated static func excerpt(from markdown: String, limit: Int = 280) -> String? {
        var paragraph: [String] = []
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence || text.hasPrefix("#") || text.hasPrefix("![") || text.hasPrefix("|")
                || text.hasPrefix(">") && paragraph.isEmpty || text == "---"
            {
                if !paragraph.isEmpty {
                    break
                }
                continue
            }
            if text.isEmpty {
                if !paragraph.isEmpty {
                    break
                }
                continue
            }
            paragraph.append(text)
        }
        guard !paragraph.isEmpty else { return nil }
        let joined = paragraph.joined(separator: " ")
        let plain = (try? AttributedString(
            markdown: joined,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )).map { String($0.characters) } ?? joined
        guard plain.count > limit else { return plain }
        let cut = plain.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}

/// A note's filing home, tinted with its category color from the library graph. The label
/// carries the meaning; the color echoes the graph.
struct FilingTag: View {
    let category: DecimalCategory
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ink = AtlasPalette.ink(
            AtlasHierarchy.hue(for: category.code),
            dark: colorScheme == .dark
        )
        Text(category.label).font(.caption).lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(ink.opacity(0.14), in: Capsule())
            .help("Filed in \(category.label)")
            .accessibilityLabel("Filed in \(category.label)")
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
