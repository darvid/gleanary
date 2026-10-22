import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var library: LibraryModel
    /// The Chat conversation shown beside the shared sidebar; nil in library-only hosts.
    var conversation: ConversationModel?
    @State private var chatting: Bool
    /// The Automations screen, in place of the library; Chat still takes precedence.
    @State private var automating = false
    @State private var showingActivity = false
    @State private var readerTarget: ChatAttachmentTarget?
    @State private var readerPreview = DocumentPreviewModel()
    var initialSelection: UUID?
    @State private var scope: LibraryScope? = .all
    @AppStorage("libraryKindFilter") private var kindFilter = LibraryKindFilter.all
    @State private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = ContentView.defaultSidebarWidth
    @AppStorage("librarySidebarExpanded") private var librarySidebarExpanded = true
    @State private var sidebarDragStart: Double?
    @State private var selection: Set<UUID> = []
    @State private var page = 0
    @State private var categories: [DecimalCategory] = []
    @State private var importing = false
    @State private var importingBookmarks = false
    @State private var categorizing = false
    /// An item to select once a scope change has cleared the old selection.
    @State private var pendingSelection: UUID?
    @State private var pendingSourceMode = false
    @State private var editing: MarkdownDocument?
    /// The filing inspector beside the selected item.
    @State private var showingFiling = false
    @State private var preview = DocumentPreviewModel()
    @State private var source: SourceCitation?
    @AppStorage("libraryPresentation") private var presentation = LibraryPresentation.map
    /// Area digits folded in the sidebar's Filing section, comma-separated.
    @AppStorage("collapsedFilingAreas") private var collapsedAreas = ""
    @State private var atlas = KnowledgeAtlasModel()
    @State private var graph = LibraryGraphModel()
    private var graphFocus: UUID? {
        get { graph.focus }
        nonmutating set { graph.focus = newValue }
    }

    /// Shared with the map's Hide empty toggle.
    @AppStorage("atlasHidesEmptyCategories") private var atlasHidesEmpty = false
    /// The item opened from the Atlas or Graph; each canvas keeps its state underneath.
    @State private var atlasItem: UUID?
    @State private var history = NavigationHistory<NavigationLocation>()
    /// The history entry being returned to; changes on the way there update it, not add more.
    @State private var restoring: NavigationLocation?
    /// Atlas state to restore once a scope change has reset the Atlas.
    @State private var pendingRestore: NavigationLocation?
    /// Atlas navigations already accounted for, so a context change from free zooming isn't one.
    @State private var seenAtlasNavigations = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        library: LibraryModel,
        conversation: ConversationModel? = nil,
        initialSelection: UUID? = nil,
        previewModel: DocumentPreviewModel? = nil,
        atlasModel: KnowledgeAtlasModel? = nil,
        graphModel: LibraryGraphModel? = nil
    ) {
        self.library = library
        self.conversation = conversation
        _chatting = State(initialValue: conversation != nil && initialSelection == nil)
        self.initialSelection = initialSelection
        _preview = State(initialValue: previewModel ?? DocumentPreviewModel())
        _atlas = State(initialValue: atlasModel ?? KnowledgeAtlasModel())
        _graph = State(initialValue: graphModel ?? LibraryGraphModel())
    }

    var body: some View {
        // Like ChatGPT: one toolbar spans the window, with the sidebar and content below it, so the
        // sidebar toggle never moves and content never scrolls into the titlebar.
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar.frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                // Above the content, so the handle's right half isn't covered by it.
                Divider().overlay { sidebarResizeHandle }.zIndex(1)
            }
            // Stacked, not a safe-area inset: HSplitView's AppKit columns ignore SwiftUI insets
            // and would draw under the banner.
            VStack(spacing: 0) {
                notice
                main.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A plain trailing column like the sidebar: SwiftUI's `.inspector` claims the window
            // toolbar, which pulls content under this window's custom titlebar.
            if showingFiling, !chatting, !showingActivity, readerTarget == nil {
                // One unit, so the edge slides in with the panel instead of appearing first.
                HStack(spacing: 0) {
                    Divider()
                    FilingInspector(
                        document: preview.document, categories: categories, store: library.store,
                        file: file,
                        close: { withAnimation(.snappy(duration: 0.25)) { showingFiling = false } }
                    )
                    .frame(width: Self.inspectorWidth)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .transition(.move(edge: .trailing))
            }
        }
        // Keep the sidebar's animation out of the window toolbar's layout transaction.
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: sidebarVisible)
        // One solid titlebar; sidebar translucency stays below its bottom edge.
        .safeAreaInset(edge: .top, spacing: 0) {
            Divider().background(alignment: .bottom) {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea(edges: .top)
            }
        }
        .toolbar { toolbar }
        .background {
            MouseNavigationMonitor(back: goBack, forward: goForward)
        }
        .focusedSceneValue(\.navigationActions, NavigationActions(
            canGoBack: history.canGoBack, canGoForward: history.canGoForward,
            back: goBack, forward: goForward
        ))
        .onChange(of: location, initial: true) { old, new in record(from: old, to: new) }
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.linkedSourceContext, LinkedSourceContext(
            store: library.store,
            revision: "\(library.documentGrid.generation)/\(library.captureRevision)",
            canAdd: library.ready && !library.busy,
            add: { url, noteID, jobID in
                try await library.addLinkedSource(url, from: noteID, retry: jobID)
            },
            viewSource: openSavedSource,
            summarize: { id in
                Task {
                    if let document = await library.document(id: id) {
                        library.generateSummary(for: document)
                    }
                }
            },
            createAnotherSummary: { id in
                Task {
                    if let document = await library.document(id: id) {
                        library.generateSummary(for: document, createAnother: true)
                    }
                }
            },
            summarizingID: library.generatingSummaryID,
            cancelSummary: { library.cancelSummary() },
            changed: { await library.summaryAssociationsChanged() }
        ))
        .environment(\.openURL, OpenURLAction { url in
            if let id = NoteLink.id(from: url) {
                selection = [id]; preview.selectedID = id
                return .handled
            }
            return .systemAction
        })
        // The conversation publishes its own actions while it is showing.
        .focusedSceneValue(
            \.gleanaryActions,
            chatting && readerTarget == nil ? nil : GleanaryActions(
                enabled: library.ready && !library.busy,
                newItem: {
                    // Activity and Captures have no editing pane.
                    showingActivity = false
                    readerTarget = nil
                    if scope == .captures {
                        scope = .all
                    }
                    editing = MarkdownDocument(name: "Untitled", markdown: "")
                },
                attach: { importing = true }, focus: {
                    if presentation == .graph {
                        NotificationCenter.default.post(name: .focusLibraryGraphSearch, object: nil)
                    } else {
                        searchFocused = true
                    }
                },
                importBookmarks: { importingBookmarks = true },
                categorize: { categorizing = true }
            )
        )
        .fileImporter(isPresented: $importing, allowedContentTypes: [
            .pdf, .html, .plainText, UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
        ], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): Task { await library.importFiles(urls) }
            case let .failure(error): library.error = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !chatting else { return false }
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty {
                Task { await library.importFiles(files) }
            }
            if urls.contains(where: { !$0.isFileURL }) {
                library.error = "Paste web links into Chat to save and summarize them."
            }
            return !files.isEmpty
        }
        .sheet(isPresented: $importingBookmarks) {
            BookmarkImportView(
                library: library,
                onImported: { await loadCategories() },
                categorize: {
                    importingBookmarks = false
                    // Let the import sheet close before presenting the next one.
                    Task { try? await Task.sleep(for: .milliseconds(300)); categorizing = true }
                },
                inference: currentInference
            )
        }
        .sheet(isPresented: $categorizing, onDismiss: { Task { await loadCategories() } }) {
            FilingSuggestionsView(library: library, inference: currentInference)
        }
        .sheet(item: $source) {
            CaptureSourceView(citation: $0, library: library, openDocument: openSavedItem)
        }
        .sheet(item: $library.browserJob) { job in
            if let url = job.request.url, let target = try? MediaTarget.parse(url) {
                SocialBrowserView(job: job, target: target, library: library)
            }
        }
        .sheet(item: $library.audioJob) { AudioOptionsView(job: $0, library: library) }
        .task {
            await library.load()
            guard library.ready else { return }
            library.automations.start()
            library.documentGrid.scope = scope ?? .all
            library.documentGrid.kindFilter = kindFilter
            await library.documentGrid.reloadIfNeeded()
            await atlas.load(from: library.store)
            showInAtlas(scope ?? .all)
            if let initialSelection {
                selection = [initialSelection]; preview.selectedID = initialSelection
                if presentation != .list {
                    atlasItem = initialSelection
                }
            }
            await loadCategories()
            await library.refreshCaptures()
        }
        .task(
            id: "\(library.ready)/\(library.documentGrid.generation)/\(chatting)/\(automating)/\(showingActivity)"
        ) {
            // The map normally owns this load, but Chat and Automations share its sidebar
            // even when no map has been mounted during this launch.
            if library.ready, chatting || automating || showingActivity {
                await atlas.load(from: library.store)
            }
        }
        .onChange(of: kindFilter, initial: true) {
            if scope != .captures, scope != .archived {
                graph.activate(scope: scope ?? .all, kind: kindFilter)
                atlas.activate(scope: scope ?? .all, kind: kindFilter)
            }
            library.documentGrid.kindFilter = kindFilter
            if atlasItem == nil {
                selection = []; preview.selectedID = nil
            }
            page = 0
            if library.ready {
                Task { await library.documentGrid.reloadIfNeeded() }
            }
        }
        .task(id: library.documentGrid.query) {
            guard library.ready else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            await library.documentGrid.reloadIfNeeded()
        }
        .task(
            id: "\(preview.selectedID?.uuidString ?? "")/\(library.documentGrid.generation)/\(preview.showsCapturedSource)"
        ) {
            await library.loadPreview(preview)
            await loadCategories()
            // Dwell before fetching so arrowing through the list doesn't download every page.
            guard preview.coverage == .bookmark, let id = preview.selectedID else { return }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            await library.fetchBookmarkIfNeeded(id)
        }
        // Summaries follow the AI provider: ChatGPT when enabled, else Apple Intelligence.
        .task(id: summarizerKey) {
            guard summarizerKey != "pending" else { return }
            await library.useLinkSummarizer(linkSummarizer())
            library.useLinkJudge(linkJudge())
            library.useFiler(currentInference())
        }
        .task {
            // The chat Writer's own model, asked for when the digest runs: it loads ChatGPT's
            // models if they aren't yet, and says why when ChatGPT can't be used.
            guard let chatGPT = conversation?.chatGPT else { return }
            library.useWriter { try await chatGPT.requestInference() }
        }
        .onChange(of: scope) {
            selection = []; preview.selectedID = nil; page = 0
            library.documentGrid.scope = scope ?? .all
            showInAtlas(scope ?? .all)
            revealPendingSelection()
            if let target = pendingRestore {
                pendingRestore = nil
                restoreAtlas(target)
            }
            Task { await library.documentGrid.reload(); await library.refreshCaptures() }
        }
        .onChange(of: selection) { old, new in
            if let id = new.subtracting(old).first ?? new.first {
                preview.selectedID = id
            } else {
                preview.selectedID = nil
            }
        }
        .onChange(of: library.documentGrid.generation) { page = 0 }
        .onDisappear { library.documentGrid.pause() }
        .onExitCommand { library.documentGrid.query = "" }
        .environment(\.libraryGraphContext, LibraryGraphContext(
            store: library.store, refreshToken: library.documentGrid.generation,
            explore: exploreGraph
        ))
        .environment(\.addToChat, conversation == nil ? nil : addToChat)
        .environment(\.enterReader) { target in
            source = nil
            readerTarget = target
        }
    }

    private func readerPane(_ target: ChatAttachmentTarget) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Exit Reader Mode", systemImage: "arrow.down.right.and.arrow.up.left") {
                    readerTarget = nil
                }.keyboardShortcut(.cancelAction).buttonStyle(.borderless)
            }.padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            switch target {
            case .note:
                DocumentPreview(model: readerPreview)
            case let .source(id):
                SourceReaderView(
                    captureID: id,
                    store: library.store,
                    refreshToken: library.documentGrid.generation
                )
            }
        }
        .environment(\.isReaderMode, true)
        .environment(\.openURL, OpenURLAction { url in
            if let id = NoteLink.id(from: url) {
                openSavedItem(id)
                return .handled
            }
            return .systemAction
        })
        .task(id: "\(target)/\(library.documentGrid.generation)") {
            if case let .note(id) = target {
                readerPreview.selectedID = id
                await readerPreview.load(from: library.store)
            }
        }
    }

    /// Drag the sidebar's edge within this range; double-click it to go back to the default.
    static let sidebarWidths: ClosedRange<Double> = 180 ... 340
    static let defaultSidebarWidth: Double = 220

    /// A few points either side of the divider take the drag, with the system resize cursor.
    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = sidebarDragStart ?? sidebarWidth
                        sidebarDragStart = start
                        sidebarWidth = min(
                            max(start + value.translation.width, Self.sidebarWidths.lowerBound),
                            Self.sidebarWidths.upperBound
                        )
                    }
                    .onEnded { _ in sidebarDragStart = nil }
            )
            .onTapGesture(count: 2) { sidebarWidth = Self.defaultSidebarWidth }
            .accessibilityHidden(true)
    }

    private var main: some View {
        ZStack {
            browsingMain
                .opacity(readerTarget == nil ? 1 : 0)
                .disabled(readerTarget != nil)
                .allowsHitTesting(readerTarget == nil)
                .accessibilityHidden(readerTarget != nil)
            if let readerTarget {
                readerPane(readerTarget)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: readerTarget != nil)
    }

    @ViewBuilder private var browsingMain: some View {
        if chatting, let conversation {
            ConversationView(model: conversation, library: library)
        } else if showingActivity {
            if library.ready {
                ActivityView(store: library.store, open: openSavedItem, openSource: { source = $0 })
            } else {
                ProgressView("Opening activity…")
            }
        } else if automating {
            AutomationsView(model: library.automations, open: openSavedItem)
        } else if scope == .captures || scope == .archived || presentation == .list {
            libraryColumns
        } else if presentation == .graph {
            graphPane
        } else {
            atlasPane
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(id: "navigation", placement: .navigation) {
            HStack(spacing: 0) {
                Button("Toggle Sidebar", systemImage: "sidebar.left") {
                    sidebarVisible.toggle()
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
                if sidebarVisible {
                    // Continues the sidebar's edge through the toolbar, as ChatGPT does.
                    Spacer().frame(width: titleIndent)
                    Divider().frame(height: 22)
                }
                Spacer().frame(width: 14)
                Text(readerTarget != nil ? "Reader" : chatting ? "Chat" : showingActivity ?
                    "Activity" : automating ? "Automations" :
                    scopeTitle)
                    .font(.headline).lineLimit(1)
            }
            .transaction { $0.animation = nil }
        }
        .sharedBackgroundVisibility(.hidden)
        // Chat draws its own More menu; the library and Automations share this one.
        if !chatting {
            ToolbarSpacer(.flexible)
        }
        if !chatting, !automating, !showingActivity, readerTarget == nil, scope == .unfiled {
            ToolbarItem {
                Button { categorizing = true } label: {
                    if library.categorizing {
                        HStack(spacing: 6) {
                            ChatWorkingIndicator(color: .secondary)
                            Text("Review filing…")
                        }
                    } else {
                        Label("Suggest filing…", systemImage: "sparkles")
                    }
                }
                .disabled(!library.ready)
                .help(
                    "Suggest homes in batches, then review before filing. Saved suggestions can be resumed."
                )
            }
        }
        if !chatting, !automating, !showingActivity, readerTarget == nil,
           presentation.showsPicker(
               in: scope,
               hasOpenedItem: atlasItem != nil,
               isEditing: editing != nil
           )
        {
            ToolbarItem(id: "library-presentation") {
                LibraryPresentationPicker(selection: presentationSelection)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if !chatting {
            ToolbarItem(id: "library-more") {
                // Mirrors the File menu, as Finder and Mail do with their toolbar More menus.
                // Plain ellipsis: Liquid Glass already draws the circular button.
                Menu("More", systemImage: "ellipsis") {
                    Button("Attach Documents…", systemImage: "paperclip") { importing = true }
                        .disabled(!library.ready || library.busy)
                    Button("Import Bookmarks…", systemImage: "square.and.arrow.down") {
                        importingBookmarks = true
                    }.disabled(!library.ready || library.busy)
                    Divider()
                    Button("Categorize Unfiled…", systemImage: "wand.and.sparkles") {
                        categorizing = true
                    }.disabled(!library.ready)
                    Divider()
                    SettingsLink { Label("Settings…", systemImage: "gearshape") }
                }
                .menuIndicator(.hidden)
                .help("Import, review filing, and open Settings")
                .accessibilityIdentifier("library-more-menu")
            }
        }
    }

    private var summarizerKey: String {
        guard let chatGPT = conversation?.chatGPT else { return "apple" }
        // Until accounts and models load, `useChatGPT` and the model aren't settled yet.
        guard chatGPT.loaded, !chatGPT.busy else { return "pending" }
        return chatGPT.useChatGPT ? "chatgpt:" + chatGPT.selectedModel : "apple"
    }

    /// ChatGPT when it's enabled, else Apple Intelligence. An enabled ChatGPT that can't be used
    /// fails summaries with its reason rather than quietly switching engines.
    private func linkSummarizer() -> any LinkSummarizing {
        guard let chatGPT = conversation?.chatGPT, chatGPT.useChatGPT else {
            return AppleLinkSummarizer()
        }
        if chatGPT.models.isEmpty {
            return DeferredChatGPTSummarizer(connection: chatGPT)
        }
        do {
            return try chatGPT.inference() as? any LinkSummarizing ?? AppleLinkSummarizer()
        } catch {
            return UnavailableSummarizer(engineName: "ChatGPT", error: error)
        }
    }

    /// The cross-linker's judge follows the provider too. An enabled ChatGPT that can't be used
    /// leaves none, so the automation says so instead of quietly switching to Apple.
    private func linkJudge() -> (any LinkJudging)? {
        guard let chatGPT = conversation?.chatGPT, chatGPT.useChatGPT else {
            return AppleConversationInference()
        }
        return (try? chatGPT.inference()) as? any LinkJudging
    }

    /// ChatGPT's filing model when ChatGPT is connected and enabled; otherwise Apple
    /// Intelligence.
    private func currentInference() -> any ConversationInferring {
        (try? conversation?.chatGPT.filingInference()) ?? AppleConversationInference()
    }

    /// Gap from the toggle to the sidebar's edge, given the toggle's place beside the traffic
    /// lights, so the toolbar divider continues the sidebar's.
    private var titleIndent: CGFloat {
        max(0, sidebarWidth - Self.defaultSidebarWidth + 105)
    }

    @ViewBuilder private var notice: some View {
        if let problem = library.summaryProblem {
            VStack(spacing: 0) {
                summaryProblemNotice(problem)
                Divider()
            }
        }
        if let failure = library.captureFailure {
            VStack(spacing: 0) {
                captureFailureNotice(failure)
                Divider()
            }
        }
        if let error = library.error ?? library.indexingError {
            VStack(spacing: 0) {
                errorNotice(error)
                Divider()
            }
        }
    }

    @ViewBuilder private var libraryColumns: some View {
        if scope == .captures, visibleCaptures.isEmpty {
            // One empty state for the whole area, rather than one per column at different heights.
            ContentUnavailableView(
                "No captures yet",
                systemImage: "tray",
                description: Text("Save a URL in Chat or import a document.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scopeIsEmpty {
            ContentUnavailableView {
                Label(
                    library.documentGrid
                        .loading ? "Loading library…" : scope == .archived ? "Nothing archived" :
                        "No items here",
                    systemImage: scope == .archived ? "archivebox" : "doc.text.magnifyingglass"
                )
            } description: {
                Text(emptyListMessage)
            } actions: {
                if scope == nil || scope == .all {
                    Button("Import Bookmarks…") { importingBookmarks = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            splitColumns
        }
    }

    /// A view with nothing in it and no search to change, so there's no list or item to show.
    private var scopeIsEmpty: Bool {
        let grid = library.documentGrid
        return scope != .captures && editing == nil && grid
            .total == 0 && (!grid.loading || grid.hasLoaded)
            && grid.query.isEmpty && grid.error == nil && kindFilter == .all
    }

    private var splitColumns: some View {
        HSplitView {
            Group {
                if scope == .captures {
                    captureList
                } else {
                    documentList
                }
            }.frame(
                minWidth: 260,
                idealWidth: 330,
                maxWidth: 440,
                maxHeight: .infinity,
                alignment: .top
            )
            Group {
                if scope == .captures {
                    ContentUnavailableView(
                        "Capture recovery",
                        systemImage: "tray.and.arrow.down",
                        description: Text("Retry a failed capture or open what it saved.")
                    )
                } else {
                    detail()
                }
            }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        // A split view centers columns shorter than itself, such as an empty list.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var atlasPane: some View {
        if atlasItem != nil || editing != nil {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button("Atlas", systemImage: "chevron.left") { atlasItem = nil }
                        .buttonStyle(.borderless)
                        .help("Return to the Atlas")
                        .disabled(editing != nil)
                    ForEach(atlasItem.map(atlasLocation(of:)) ?? [], id: \.id) { region in
                        Image(systemName: "chevron.right").font(.caption2)
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                        Button(region.label) {
                            atlasItem = nil
                            atlas.focus(region.id)
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).lineLimit(1)
                        .disabled(editing != nil)
                        .help("Show \(region.label) in the Atlas")
                    }
                    Spacer()
                }.font(.callout).padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
                detail(openDocument: openFromAtlas)
            }
            .onExitCommand {
                if editing == nil {
                    atlasItem = nil
                }
            }
        } else {
            KnowledgeAtlasView(
                atlas: atlas, store: library.store,
                refreshToken: library.documentGrid.generation,
                kindSelection: $kindFilter, openItem: openFromAtlas,
                openCapturedSource: { captureID in
                    Task {
                        do {
                            let id = try await library.store.sourceNoteID(for: captureID)
                            openFromAtlas(id)
                            preview.showsCapturedSource = true
                        } catch { library.error = "This saved source is no longer available." }
                    }
                }
            )
        }
    }

    private var presentationSelection: Binding<LibraryPresentation> {
        Binding(get: { presentation }, set: { newValue in
            atlasItem = nil
            presentation = newValue
            if newValue == .list {
                preview.selectedID = selection.first
            }
        })
    }

    @ViewBuilder private var graphPane: some View {
        if atlasItem != nil || editing != nil {
            VStack(spacing: 0) {
                HStack {
                    Button("Graph", systemImage: "chevron.left") { atlasItem = nil }
                        .buttonStyle(.borderless).disabled(editing != nil)
                    Spacer()
                }.padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
                detail(openDocument: openFromGraph)
            }
        } else {
            LibraryGraphView(
                graph: graph, store: library.store,
                refreshToken: library.documentGrid.generation, scope: scope ?? .all,
                kind: $kindFilter,
                query: Binding(
                    get: { library.documentGrid.query },
                    set: { library.documentGrid.query = $0 }
                ),
                focus: $graph.focus, openNote: openFromGraph, openSource: { source = $0 }
            )
        }
    }

    private func openFromGraph(_ id: UUID) {
        preview.selectedID = id
        atlasItem = id
    }

    private func exploreGraph(_ id: UUID) {
        readerTarget = nil
        chatting = false
        automating = false
        showingActivity = false
        graph.activate(scope: .all, kind: .all)
        graphFocus = id
        atlasItem = nil
        library.documentGrid.query = ""
        kindFilter = .all
        scope = .all
        presentation = .graph
    }

    /// Shows a saved item from anywhere, such as the Captures list. Switching to the full Library
    /// clears the selection, so the item is selected after that, not before.
    private func openSavedItem(_ id: UUID) {
        showSavedItem(id, asSource: false)
    }

    private func openSavedSource(_ id: UUID) {
        showSavedItem(id, asSource: true)
    }

    private func showSavedItem(_ id: UUID, asSource: Bool) {
        pendingSourceMode = asSource
        readerTarget = nil
        chatting = false
        automating = false
        showingActivity = false
        pendingSelection = id
        if scope == .all {
            revealPendingSelection()
        } else {
            scope = .all
        }
    }

    private func revealPendingSelection() {
        guard let id = pendingSelection else { return }
        pendingSelection = nil
        let asSource = pendingSourceMode
        pendingSourceMode = false
        selection = [id]
        preview.selectedID = id
        if presentation == .map {
            openFromAtlas(id)
        } else if presentation == .graph {
            openFromGraph(id)
        }
        preview.showsCapturedSource = asSource
    }

    private func openFromAtlas(_ id: UUID) {
        preview.showsCapturedSource = false
        atlas.selectedID = atlas.layout.tile(.item(id))?.id ?? .item(id)
        preview.selectedID = id
        atlasItem = id
    }

    /// Category labels from the Library down to the item's placement in the Atlas.
    /// The regions from the Library down to the item, each one a way back into the Atlas. A
    /// category's "not in a subcategory" group repeats its parent, so it's left out.
    private func atlasLocation(of id: UUID) -> [(id: AtlasNodeID, label: String)] {
        guard let position = atlas.layout.index[.item(id)] else { return [] }
        return atlas.layout.path(to: position).dropFirst().dropLast()
            .map { atlas.layout.tiles[$0] }
            .filter { $0.node.kind != .direct }
            .map { (id: $0.id, label: $0.node.label) }
    }

    // MARK: History

    private var location: NavigationLocation {
        NavigationLocation(
            chatting: chatting, scope: scope, atlasFocus: atlas.focusID, atlasItem: atlasItem,
            automations: automating, activity: showingActivity, kindFilter: kindFilter,
            presentation: presentation, graphFocus: graphFocus
        )
    }

    private func record(from old: NavigationLocation, to new: NavigationLocation) {
        defer { seenAtlasNavigations = atlas.navigations }
        if let target = restoring {
            history.replace(new)
            if new == target {
                restoring = nil
            }
            return
        }
        var drifted = old
        drifted.atlasFocus = new.atlasFocus
        // Zooming or panning freely moves the Atlas context; that updates where this entry
        // returns to rather than adding one.
        if drifted == new, atlas.navigations == seenAtlasNavigations {
            history.replace(new)
        } else {
            history.visit(new)
        }
    }

    private func goBack() {
        if let target = history.back() {
            restore(target)
        }
    }

    private func goForward() {
        if let target = history.forward() {
            restore(target)
        }
    }

    private func restore(_ target: NavigationLocation) {
        restoring = target
        readerTarget = nil
        kindFilter = target.kindFilter
        atlas.activate(scope: target.scope ?? .all, kind: target.kindFilter)
        chatting = target.chatting
        automating = target.automations
        showingActivity = target.activity
        presentation = target.presentation
        graph.activate(scope: target.scope ?? .all, kind: target.kindFilter)
        graphFocus = target.graphFocus
        if scope != target.scope {
            // The scope change resets the Atlas, so its region and item follow it.
            pendingRestore = target
            scope = target.scope
        } else {
            restoreAtlas(target)
        }
        // A region or item deleted since can't be reached; stop treating changes as the return.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if restoring == target {
                restoring = nil
            }
        }
    }

    private func restoreAtlas(_ target: NavigationLocation) {
        if target.atlasFocus != atlas.focusID {
            atlas.focus(target.atlasFocus)
        }
        if let id = target.atlasItem {
            if target.presentation == .graph {
                openFromGraph(id)
            } else {
                openFromAtlas(id)
            }
        } else {
            atlasItem = nil
        }
    }

    /// Sidebar choices act as shortcuts into the Atlas instead of filtering a list.
    private func showInAtlas(_ scope: LibraryScope) {
        atlasItem = nil
        guard scope != .captures, scope != .archived else { return }
        graph.activate(scope: scope, kind: kindFilter)
        atlas.activate(scope: scope, kind: kindFilter)
        seenAtlasNavigations = atlas.navigations
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            if let conversation {
                HStack {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(nil)))
                    Spacer()
                    if conversation.running {
                        ChatWorkingIndicator(color: sidebarColor(nil))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(conversation.running ? "Working" : "")
                .help(conversation.running ? "Chat is working" : "Chat")
                .tag(SidebarItem.conversation)
            }
            // The agents' scheduled work sits with Chat, above the library's content.
            HStack {
                let color: Color = colorScheme == .dark || (automating && !chatting)
                    ? .white : .black
                Label("Automations", systemImage: "clock.arrow.2.circlepath")
                    .labelStyle(LibrarySidebarLabelStyle(color: color))
                Spacer()
                if library.automations.running != nil {
                    Image(systemName: "progress.indicator")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .font(.caption).foregroundStyle(color.opacity(0.72))
                        .help("An automation is running")
                        .accessibilityLabel("An automation is running")
                }
                if !library.automations.failed.isEmpty {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .help("An automation's last run failed")
                        .accessibilityLabel("An automation's last run failed")
                }
                // Proposals waiting for review, like Captures' count of failures.
                let waiting = library.automations.pendingCount
                if waiting > 0 {
                    Text(waiting.formatted())
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(color.opacity(0.72))
                        .countsOnChange(waiting)
                        .accessibilityLabel(waiting == 1 ? "1 proposal to review"
                            : "\(waiting) proposals to review")
                }
            }.tag(SidebarItem.automations)
            Section {
                DisclosureGroup(isExpanded: $librarySidebarExpanded) {
                    Label("Notes", systemImage: "note.text")
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.notes)))
                        .accessibilityHint("Show notes in Library")
                        .tag(SidebarItem.library(.notes))
                    Label("Sources", systemImage: "doc.text")
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.sources)))
                        .accessibilityHint("Show sources in Library")
                        .tag(SidebarItem.library(.sources))
                    Label("Unfiled", systemImage: "folder.badge.questionmark")
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.unfiled)))
                        .accessibilityHint("Show unfiled items in Library")
                        .tag(SidebarItem.library(.unfiled))
                } label: {
                    // A button still opens all items when this selected row represents a
                    // hidden filter. Re-selecting an already selected List row would not.
                    Button {
                        sidebarSelection.wrappedValue = .library(.all)
                    } label: {
                        HStack(spacing: 8) {
                            Label("Library", systemImage: "books.vertical")
                                .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.all)))
                            Spacer(minLength: 4)
                            if let filter = collapsedLibraryFilter {
                                Text(filter).font(.caption)
                                    .foregroundStyle(sidebarColor(.all).opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show all saved items")
                    .accessibilityLabel("Library")
                    .accessibilityValue(collapsedLibraryFilter ?? "All items")
                    .accessibilityHint("Show all saved items")
                }
                .foregroundStyle(sidebarColor(.all))
                .tag(SidebarItem.library(.all))
            }
            Section {
                HStack {
                    Label("Captures", systemImage: "tray.and.arrow.down")
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.captures)))
                    Spacer()
                    // Only failures are counted, so the badge says so instead of looking like a
                    // total.
                    let issues = library.captureJobs.filter { $0.state == .failed }.count
                    if issues > 0 {
                        Label(issues.formatted(), systemImage: "exclamationmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .countsOnChange(issues)
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.orange)
                            .help(issues == 1 ? "1 capture needs attention"
                                : "\(issues) captures need attention")
                            .accessibilityLabel(issues == 1 ? "1 capture needs attention"
                                : "\(issues) captures need attention")
                    }
                }.foregroundStyle(sidebarColor(.captures)).tag(SidebarItem.library(.captures))
                Label("Activity", systemImage: "clock")
                    .labelStyle(LibrarySidebarLabelStyle(color:
                        colorScheme == .dark || showingActivity ? .white : .black))
                    .tag(SidebarItem.activity)
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.archived)))
                    .tag(SidebarItem.library(.archived))
            }
            Section("Filing") {
                ForEach(CategoryArea.group(categories)) { area in
                    let header = area.categories.first { $0.code == "\(area.digit)0" }
                    let members = area.categories.filter { $0.id != header?.id }
                    if let header, !members.isEmpty {
                        DisclosureGroup(isExpanded: areaExpanded(area.digit)) {
                            ForEach(members) { filingRow($0, icon: nil) }
                        } label: {
                            filingRow(header, icon: header.isInbox ? "tray" : "folder")
                        }
                    } else {
                        ForEach(area.categories) { filingRow($0, icon: "folder") }
                    }
                }
            }
        }.listStyle(.sidebar).foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .accessibilityLabel("Library navigation")
    }

    /// One line per category: an area's `X0` row carries the icon and its members sit beneath it.
    private func filingRow(_ category: DecimalCategory, icon: String?) -> some View {
        let color = sidebarColor(.category(category.id))
        // Dimmed, not removed: the map hides empty categories, but they stay reachable here.
        let hidden = presentation == .map && atlasHidesEmpty
            && atlas.emptyCategoryIDs.contains(category.id)
        // The category's Atlas colour, as on its chips and in the filing inspector.
        let ink = AtlasPalette.ink(
            AtlasHierarchy.hue(for: category.code),
            dark: colorScheme == .dark
        )
        return HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(ink).frame(width: 18)
            } else {
                Circle().fill(ink).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(category.name).foregroundStyle(color).lineLimit(1)
            Spacer(minLength: 4)
            Text(category.code).font(.caption).monospacedDigit()
                .foregroundStyle(color.opacity(0.5))
        }
        .opacity(hidden ? 0.4 : 1)
        .padding(.leading, category.code.contains(".") ? 10 : 0)
        .tag(SidebarItem.library(.category(category.id)))
        .help(hidden ? "\(category.label) is empty and hidden in the map" : category.label)
        .accessibilityElement(children: .combine)
        .accessibilityValue(hidden ? "Empty, hidden in the map" : "")
    }

    private func areaExpanded(_ digit: Int) -> Binding<Bool> {
        Binding {
            !collapsedAreas.split(separator: ",").contains(Substring(String(digit)))
        } set: { expanded in
            var collapsed = Set(collapsedAreas.split(separator: ",").map(String.init))
            if expanded {
                collapsed.remove(String(digit))
            } else {
                collapsed.insert(String(digit))
            }
            collapsedAreas = collapsed.sorted().joined(separator: ",")
        }
    }

    private var sidebarScope: LibraryScope? {
        guard scope == .all else { return scope }
        switch kindFilter {
        case .all: return .all
        case .notes: return .notes
        case .sources: return .sources
        }
    }

    private var collapsedLibraryFilter: String? {
        guard !librarySidebarExpanded, !chatting, !automating, !showingActivity else { return nil }
        switch sidebarScope {
        case .notes?, .sources?, .unfiled?: return scopeTitle
        default: return nil
        }
    }

    private var visibleSidebarScope: LibraryScope? {
        collapsedLibraryFilter == nil ? sidebarScope : .all
    }

    /// Pass nil for the conversation row.
    private func sidebarColor(_ item: LibraryScope?) -> Color {
        let selected = item
            .map { !chatting && !automating && !showingActivity && visibleSidebarScope == $0 } ??
            chatting
        return colorScheme == .dark || selected ? .white : .black
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            chatting ? .conversation : showingActivity ? .activity : automating ? .automations :
                visibleSidebarScope.map(SidebarItem.library)
        } set: { item in
            readerTarget = nil
            switch item {
            case .conversation: chatting = true; automating = false; showingActivity = false
            case .automations: chatting = false; automating = true; showingActivity = false
            case .activity: chatting = false; automating = false; showingActivity = true
            case let .library(scope):
                chatting = false
                automating = false
                showingActivity = false
                switch scope {
                case .notes: kindFilter = .notes; self.scope = .all
                case .sources: kindFilter = .sources; self.scope = .all
                case .all: kindFilter = .all; self.scope = .all
                default: self.scope = scope
                }
            case nil: break
            }
        }
    }

    private func addToChat(_ target: ChatAttachmentTarget) async -> String? {
        guard let conversation else { return "Chat is not available in this window." }
        guard await conversation.addToChat(target) else {
            return conversation.error ?? "Could not add this item. Try again."
        }
        source = nil
        readerTarget = nil
        automating = false
        showingActivity = false
        chatting = true
        return nil
    }

    private func useInConversation(_ ids: [UUID]) {
        guard let conversation else { return }
        Task {
            if await conversation.prepareSources(ids) {
                chatting = true
            } else {
                library.error = conversation.error ?? "Choose up to four available items, then try again."
            }
        }
    }

    private var documentList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(scopeTitle).font(.title3.weight(.semibold))
                    Spacer()
                    Text(kindFilter.countLabel(library.documentGrid.total))
                        .font(.caption.monospacedDigit())
                        .countsOnChange(library.documentGrid.total)
                        .foregroundStyle(.secondary)
                }
                LibraryKindPicker(selection: $kindFilter)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search this view", text: Binding(
                        get: { library.documentGrid.query },
                        set: { library.documentGrid.query = $0 }
                    ))
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search library")
                    if !library.documentGrid.query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") {
                            library.documentGrid.query = ""
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }.padding(8).background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7)
                )
            }.padding(18)
            Divider()
            if let error = library.documentGrid.error {
                ContentUnavailableView(
                    "Search unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                Button("Retry") { Task { await library.documentGrid.reload() } }.padding()
                Spacer()
            } else if library.documentGrid.total == 0 {
                ContentUnavailableView {
                    Label(
                        library.documentGrid.loading ? "Loading library…" : "No items here",
                        systemImage: "doc.text.magnifyingglass"
                    )
                } description: {
                    Text(emptyListMessage)
                } actions: {
                    if kindFilter != .all {
                        Button("Show all types") { kindFilter = .all }
                    } else if !library.documentGrid.loading, scope == nil || scope == .all,
                              library.documentGrid.query.isEmpty
                    {
                        Button("Import Bookmarks…") { importingBookmarks = true }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(pageRange, id: \.self) { index in
                        if let document = library.documentGrid.document(at: index) {
                            LibraryDocumentRow(
                                document: document,
                                activity: library.activity(for: document.id)
                            ).tag(document.id)
                                .contextMenu {
                                    Button("Use in Chat") { useInConversation([document.id]) }
                                    Button("Edit…") {
                                        Task { editing = await library.document(id: document.id) }
                                    }
                                    Button("Delete…", role: .destructive) { delete(document.id) }
                                        .disabled(!library.canDeleteNotes)
                                }
                        } else {
                            Text("Loading…").foregroundStyle(.secondary)
                        }
                    }
                }.listStyle(.inset).accessibilityLabel("Saved library items")
                    .task(id: "\(library.documentGrid.generation)/\(page)") {
                        library.documentGrid.show(indices: Array(pageRange))
                    }
                pagination
            }
            handoff
        }.navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 440)
    }

    private var pagination: some View {
        HStack {
            Text(
                "\(pageRange.lowerBound + 1)–\(pageRange.upperBound) of \(library.documentGrid.total)"
            )
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Previous page", systemImage: "chevron.left") { page -= 1 }
                .disabled(page == 0)
            Button("Next page", systemImage: "chevron.right") { page += 1 }
                .accessibilityIdentifier("library-next-page")
                .disabled(pageRange.upperBound >= library.documentGrid.total)
        }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(.horizontal, 18).padding(
            .vertical,
            10
        )
    }

    private var handoff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if !selection.isEmpty {
                HStack {
                    Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { selection = [] }.buttonStyle(.borderless).font(.caption)
                }
                Button("Use in Chat", systemImage: "bubble.left") {
                    useInConversation(Array(selection).sorted { $0.uuidString < $1.uuidString })
                }
                .disabled(selection.count > 4)
                Text(selection
                    .count > 4 ? "Choose up to 4 items for one request." :
                    "Ask a question or compare these items in chat.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select items to use in Chat. ⌘-click to select more than one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 18).padding(.bottom, 16)
    }

    @ViewBuilder private func detail(openDocument: ((UUID) -> Void)? = nil) -> some View {
        if let editing {
            // The editor stays put while the selection changes, so a draft is never dropped.
            NoteEditor(document: editing, library: library) {
                self.editing = nil
                Task { await library.loadPreview(preview) }
            }
            .id(editing.id)
        } else {
            reading(openDocument: openDocument)
        }
    }

    /// A fetch in progress writes the summary itself once the page arrives.
    private var summaryEnabled: Bool {
        library.canGenerateSummary(for: preview.selectedID)
    }

    /// Only Generate Summary stops from here; stopping a page fetch would discard the page.
    private var summaryCancel: (() -> Void)? {
        guard let id = library.generatingSummaryID, id == preview.selectedID else { return nil }
        return library.cancelSummary
    }

    private func reading(openDocument: ((UUID) -> Void)?) -> some View {
        DocumentPreview(
            model: preview,
            openSource: { source = $0 },
            summaryEnabled: summaryEnabled,
            generatingSummary: preview.selectedID.map(library.summarizing) ?? false,
            generateSummary: { library.generateSummary(for: $0) },
            createAnotherSummary: { library.generateSummary(for: $0, createAnother: true) },
            cancelSummary: summaryCancel,
            showsLibraryDetails: true,
            bookmarkFetch: preview.selectedID.flatMap { library.bookmarkFetch(for: $0)?.progress },
            bookmarkFetchFailure: preview.selectedID
                .flatMap { library.bookmarkFetchFailure(for: $0) }
                .map { $0.error ?? "The page could not be fetched." },
            retryBookmarkFetch: {
                guard let id = preview.selectedID,
                      let failure = library.bookmarkFetchFailure(for: id) else { return }
                Task { await library.retryCapture(failure.id) }
            },
            openDocument: openDocument ?? { id in selection = [id]; preview.selectedID = id },
            editDocument: { editing = $0 },
            archiveDocument: { document, archive in
                Task {
                    await library.setArchived(document.id, archive)
                    await library.loadPreview(preview)
                }
            },
            fileDocument: { _ in withAnimation(.snappy(duration: 0.25)) { showingFiling = true } },
            suggestHome: conversation.map(homeSuggester),
            editHomes: FilingEditor(
                remove: { id, home in
                    let before = try await library.store.removeHome(id, categoryID: home.id)
                    await refreshFiling()
                    return before
                },
                makePrimary: { id, home in
                    let before = try await library.store.makePrimaryHome(id, categoryID: home.id)
                    await refreshFiling()
                    return before
                },
                restore: { id, homes in
                    try await library.store.restoreHomes(id, homes)
                    await refreshFiling()
                }
            ),
            refreshDocument: conversation.map { conversation in
                { document in
                    chatting = true
                    Task { await conversation.refreshDocument(document.id) }
                }
            }
        )
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What you saved yourself, plus anything that failed. Background bookmark fetches report on
    /// their item, so a successful one isn't listed here.
    private var visibleCaptures: [CaptureJob] {
        library.captureJobs.filter { $0.request.replacingNoteID == nil || $0.state == .failed }
    }

    private var captureList: some View {
        let failed = visibleCaptures.filter { $0.state == .failed }
        let others = visibleCaptures.filter { $0.state != .failed }
        // No heading of its own: the toolbar already says Captures.
        return VStack(alignment: .leading, spacing: 0) {
            List {
                // The sidebar badge counts these; the same mark finds them here.
                if !failed.isEmpty {
                    Section {
                        ForEach(failed) { captureRow($0) }
                    } header: {
                        HStack {
                            Text("Needs Attention")
                            Spacer()
                            Button("Clear All") {
                                Task { await library.clearFailedCaptures() }
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                            .help("Forget every failed capture. Saved items aren't affected.")
                        }
                    }
                    Section("Recent") {
                        ForEach(others) { captureRow($0) }
                    }
                } else {
                    ForEach(others) { captureRow($0) }
                }
            }
        }.navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 480)
    }

    private func captureRow(_ job: CaptureJob) -> some View {
        let failed = job.state == .failed
        let presentation = CaptureRowPresentation(job)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if failed {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                } else if !job.state.terminal {
                    // A symbol, not a ProgressView: it sits on the title's baseline like the
                    // attention icon, and its animation follows Reduce Motion.
                    Image(systemName: "progress.indicator")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("In progress")
                }
                CaptureRowHeading(presentation: presentation)
            }
            let status = job.error
                ?? (job.progress.isEmpty ? job.state.rawValue.capitalized : job.progress)
            Text(status)
                .fadesOnChange(status)
                .font(.caption)
                .foregroundStyle(failed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
            HStack {
                if let id = job.noteID {
                    Button("Open saved item") { openSavedItem(id) }
                }
                if job.state == .failed || job.state == .cancelled {
                    if job.recovery == .browser {
                        Button("Open browser") { library.browserJob = job }
                    }
                    if job.recovery == .audio {
                        Button("Audio options") { library.audioJob = job }
                    }
                    Button("Retry") { Task { await library.retryCapture(job.id) } }
                        .disabled(library.busy)
                    if job.state == .failed {
                        Button("Clear") { Task { await library.clearFailedCaptures([job.id]) } }
                            .help("Forget this failed capture")
                    }
                } else if !job.state.terminal {
                    Button("Stop") { Task { await library.cancelCapture(job.id) } }
                }
            }.controlSize(.small)
        }
        .padding(.vertical, 8)
        .contextMenu {
            if let url = presentation.url {
                Button("Copy link", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var pageRange: Range<Int> {
        let start = min(page * DocumentGridModel.pageSize, library.documentGrid.total)
        return start ..< min(start + DocumentGridModel.pageSize, library.documentGrid.total)
    }

    private var emptyListMessage: String {
        if !library.documentGrid.query.isEmpty {
            return "Try another term or choose Library to search more broadly."
        }
        // Empty states keep to one line, so the icon stays put moving between views.
        if scope == .archived {
            return "Archived items stay here, out of search."
        }
        if case .category = scope {
            return "File items here from their details or Chat."
        }
        return "Save a URL in Chat or import a document."
    }

    private var scopeTitle: String {
        switch sidebarScope ?? .all {
        case .all: "Library"
        case .sources: "Sources"
        case .notes: "Notes"
        case .unfiled: "Unfiled"
        case .captures: "Captures"
        case .archived: "Archive"
        case let .category(id): categories.first { $0.id == id }?.label ?? "Filing"
        }
    }

    private func loadCategories() async {
        do { categories = try await library.store.categories() }
        catch { library.error = error.localizedDescription }
    }

    private func delete(_ id: UUID) {
        Task {
            guard let document = await library.document(id: id) else { return }
            DeleteNoteConfirmation.present(document, library: library)
        }
    }

    /// A warning strip: the multicolor triangle and a warm tint read as a problem at a glance,
    /// unlike the neutral control surface used for ordinary notices.
    /// Said once for the whole library: every capture since saved its full text without a summary.
    private func summaryProblemNotice(_ problem: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor).font(.body)
                .accessibilityLabel("Problem")
            VStack(alignment: .leading, spacing: 2) {
                Text("Summaries aren't being written").font(.callout.weight(.medium))
                Text("\(problem) New saves keep their full text until this is fixed.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            SettingsLink { Text("Open Settings…") }
            Button("Dismiss", systemImage: "xmark") { library.dismissSummaryProblem() }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.2 : 0.14))
        .onAppear {
            AccessibilityNotification.Announcement("Summaries aren't being written. \(problem)")
                .post()
        }
    }

    /// Names the source, since the window may have moved on since it was asked for.
    private func captureFailureNotice(_ job: CaptureJob) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor).font(.body)
                .accessibilityLabel("Problem")
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't save “\(job.request.label)”").font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                if let reason = job.error {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button("Show in Captures") {
                library.captureFailure = nil
                chatting = false
                automating = false
                showingActivity = false
                scope = .captures
            }
            Button("Try Again") {
                library.captureFailure = nil
                Task { await library.retryCapture(job.id) }
            }
            .disabled(library.busy)
            Button("Dismiss", systemImage: "xmark") { library.captureFailure = nil }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.2 : 0.14))
        .onAppear {
            AccessibilityNotification.Announcement("Couldn't save \(job.request.label)").post()
        }
    }

    private func errorNotice(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.body)
                .accessibilityLabel("Problem")
            Text(error).font(.callout.weight(.medium)).textSelection(.enabled)
            Spacer()
            if library.indexingError != nil {
                Button("Retry indexing") { library.startIndexing() }.disabled(library.indexing)
            }
            if !library.ready {
                Button("Retry opening") { Task { await library.load() } }
            }
            Button("Dismiss", systemImage: "xmark") {
                library.error = nil; library.indexingError = nil
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.2 : 0.14))
        .onAppear { AccessibilityNotification.Announcement(error).post() }
        .onChange(of: error) { AccessibilityNotification.Announcement(error).post() }
    }

    static let inspectorWidth: CGFloat = 300

    /// Suggest on the info card: the Librarian's answer, filed through reviewable changes so
    /// Undo works; the library and its categories refresh after.
    private func homeSuggester(_ conversation: ConversationModel) -> HomeSuggester {
        HomeSuggester(
            suggest: { try await conversation.suggestHome(for: $0) },
            file: { id, suggestion in
                let ids = try await conversation.fileAsSuggested(id, suggestion)
                await refreshFiling()
                return ids
            },
            undo: { ids in
                try await conversation.undoSuggestedFiling(ids)
                await refreshFiling()
            },
            addHome: { id, home in
                let added = try await conversation.addSuggestedHome(id, home)
                await refreshFiling()
                return added
            },
            removeHome: { id, home in
                try await conversation.removeSuggestedHome(id, home)
                await refreshFiling()
            }
        )
    }

    private func refreshFiling() async {
        await library.refreshConversationChanges()
        await library.loadPreview(preview)
        await loadCategories()
    }

    private func file(_ document: MarkdownDocument, into categoryID: UUID) async {
        do {
            let includesSource = try await library.store.captureID(for: document.id) != nil
            try await library.store.fileNote(
                document.id, categoryID: categoryID, includeSources: includesSource
            )
            await library.refreshConversationChanges()
            await library.loadPreview(preview)
        } catch { library.error = error.localizedDescription }
    }
}

enum LibraryPresentation: String {
    case map, list, graph

    func showsPicker(in scope: LibraryScope?, hasOpenedItem: Bool, isEditing: Bool) -> Bool {
        // These scopes always use columns, regardless of the remembered presentation.
        guard scope != .captures, scope != .archived else { return false }
        // List keeps browsing beside its detail; Map and Graph replace their canvas.
        return self == .list || (!hasOpenedItem && !isEditing)
    }
}

struct LibraryDocumentRow: View {
    let document: DocumentSummary
    /// Background work on this item, such as fetching a bookmark's page or summarizing it.
    var activity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = document.previewImage {
                PagePreviewHeader(id: document.id, data: preview)
            }
            details
        }.padding(.vertical, 7).help(document.name)
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 10) {
            DocumentIdentityMark(isSource: document.kind == "source").padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.name).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 12) {
                    DocumentIdentityLabel(
                        identity: DocumentIdentity(kind: document.kind), showsMark: false
                    )
                    if let host = document.sourceURL?.host {
                        Text(host).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.font(.caption)
                Text(document.filing ?? "Unfiled").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                if let activity {
                    Label {
                        Text(activity).lineLimit(1)
                            .fadesOnChange(activity)
                    } icon: {
                        Image(systemName: "progress.indicator")
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else if let coverage = document.coverage.flatMap(Coverage.init(rawValue:)), [
                    .partial,
                    .abstractOnly,
                    .visibleThread
                ].contains(coverage) {
                    Text(coverage.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A top-aligned crop of the page as it looked when captured, like a link preview's image.
/// It repeats what the title already says, so assistive technologies skip it.
private struct PagePreviewHeader: View {
    static let height: CGFloat = 96
    private static let decoded = NSCache<NSString, NSImage>()

    let id: UUID
    let data: Data
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = Self.image(id: id, data: data) {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            Color.clear.frame(maxWidth: .infinity).frame(height: Self.height)
                .overlay(alignment: .top) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                }
                // Screenshots are captured light; soften them so they do not glare in dark rows.
                .overlay { Color.black.opacity(colorScheme == .dark ? 0.14 : 0) }
                .clipShape(shape)
                .overlay { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
                .accessibilityHidden(true)
        }
    }

    /// Rows re-render on every cache arrival; decode each thumbnail once.
    private static func image(id: UUID, data: Data) -> NSImage? {
        let key = "\(id.uuidString)-\(data.count)" as NSString
        if let cached = decoded.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(data: data) else { return nil }
        decoded.setObject(image, forKey: key)
        return image
    }
}

private struct LibrarySidebarLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(color.opacity(0.72)).frame(width: 18)
            configuration.title.foregroundStyle(color)
        }
    }
}

private enum SidebarItem: Hashable {
    case conversation
    case automations
    case activity
    case library(LibraryScope)
}
