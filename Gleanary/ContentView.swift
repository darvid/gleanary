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
    @State private var showingTasks = false
    @State private var showingEntities = false
    /// The entity an entity link asked Entities to show.
    @State private var entityFocus: EntityFocus?
    @State private var taskView = WorkspaceTaskView.inbox
    @State private var showingTemplates = false
    @State private var editingProfile: NoteProfile?
    @State private var openingTask: WorkspaceTask?
    @State private var pendingTemplate: NoteTemplate?
    @State private var replacingDraft = false
    @State private var readerTarget: ChatAttachmentTarget?
    var initialSelection: UUID?
    /// Whether this is the main window, which reopens where it was last left.
    private let restoresWindow: Bool
    /// The window as the previous launch left it.
    private let savedWindow: SavedLibraryWindow?
    @State private var scope: LibraryScope? = .all
    @AppStorage("libraryKindFilter") private var kindFilter = LibraryKindFilter.all
    @State private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = ContentView.defaultSidebarWidth
    @Environment(\.displayScale) private var displayScale
    @State private var sidebarHeight: CGFloat = 0
    @AppStorage(LibraryModel.backgroundEntitiesKey) private var readEntitiesInBackground = false
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
    @AppStorage(LibraryPresentation.key) private var presentation = LibraryPresentation.map
    /// Area digits folded in the sidebar's Filing section, comma-separated.
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
    @State private var readerPreview = DocumentPreviewModel()
    @State private var showingPalette = false
    @State private var tasksDueToday = 0
    @State private var atlasQuery = ""
    @Environment(\.openSettings) private var openSettings
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
        self.initialSelection = initialSelection
        restoresWindow = conversation != nil && initialSelection == nil
        savedWindow = restoresWindow ? SavedLibraryWindow.load() : nil
        let destination = savedWindow?.destination ?? (initialSelection == nil ? .chat : .library)
        _chatting = State(initialValue: conversation != nil && destination == .chat)
        _automating = State(initialValue: destination == .automations)
        _showingActivity = State(initialValue: destination == .activity)
        _showingTasks = State(initialValue: destination == .tasks)
        _showingEntities = State(initialValue: destination == .entities)
        _scope = State(initialValue: savedWindow.map(\.scope) ?? .all)
        _preview = State(initialValue: previewModel ?? DocumentPreviewModel())
        let atlas = atlasModel ?? KnowledgeAtlasModel()
        // Before anything loads, so the map's first paint is the saved view rather than a fit
        // it then jumps away from.
        if let savedWindow, let view = savedWindow.atlas {
            atlas.restore(view, scope: savedWindow.scope ?? .all, kind: savedWindow.kindFilter)
        }
        _atlas = State(initialValue: atlas)
        let graph = graphModel ?? LibraryGraphModel()
        if restoresWindow {
            graph.remembersInspector(in: .standard)
        }
        _graph = State(initialValue: graph)
    }

    var body: some View {
        windowContent
            .disclosureGroupStyle(FullRowDisclosureStyle())
            .environment(\.commandPaletteOpen, showingPalette)
            .environment(\.showCategory) { sidebarSelection.wrappedValue = .library(.category($0)) }
            .focusedSceneValue(\.commandActions, commandActions)
            .overlay { commandPalette }
    }

    private var windowContent: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                fadedSidebar.frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                // Above the content, so the handle's right half isn't covered by it.
                Color.clear.frame(width: 1).overlay { sidebarResizeHandle }.zIndex(1)
            }
            contentPanel
        }
        .overlay(alignment: .topLeading) { sidebarToggle }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: sidebarVisible)
        // The panel rises beside the traffic lights, so nothing keeps clear of the titlebar.
        .ignoresSafeArea(edges: .top)
        // Never drawn in this window style; it names the window for the Window menu and VoiceOver.
        .navigationTitle(location.windowTitle(
            libraryTitle: scopeTitle,
            showingReader: readerTarget != nil
        ))
        .background {
            MouseNavigationMonitor(back: goBack, forward: goForward)
        }
        .focusedSceneValue(\.navigationActions, NavigationActions(
            canGoBack: history.canGoBack, canGoForward: history.canGoForward,
            back: goBack, forward: goForward
        ))

        .onChange(of: location, initial: true) { old, new in record(from: old, to: new) }
        // The window itself is the sidebar's surface; only the content panel is solid.
        .background { WindowSurface().ignoresSafeArea() }
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
        .environment(\.noteWorkspace, library.workspace)
        .sheet(isPresented: $showingTemplates) {
            NoteTemplatesView(workspace: library.workspace, current: preview.document) {
                requestDraft($0)
            }
        }
        .sheet(item: $openingTask) { WorkspaceTaskEditor(workspace: library.workspace, task: $0) }
        .confirmationDialog("Replace the open draft?", isPresented: $replacingDraft) {
            Button("Discard Draft and Create Note", role: .destructive) {
                startDraft(pendingTemplate)
            }
        } message: { Text("Unsaved changes in the open editor will be discarded.") }
        .onChange(of: library.workspace.noteGeneration) {
            Task { await library.refreshWorkspacePresentation() }
        }
        .environment(\.openURL, OpenURLAction { url in
            if handleTaskURL(url) {
                return .handled
            }
            if let id = NoteLink.id(from: url) {
                selection = [id]; preview.selectedID = id
                return .handled
            }
            if let entity = EntityLink.target(from: url) {
                showEntity(entity)
                return .handled
            }
            return .systemAction
        })
        // The conversation publishes its own actions while it is showing.
        .focusedSceneValue(
            \.gleanaryActions,
            chatting && readerTarget == nil ? nil : GleanaryActions(
                enabled: library.ready && !library.busy,
                newItem: { requestDraft(nil) },
                attach: { importing = true }, focus: { searchFocused = true },
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
            } else if let url = job.request.url {
                PageBrowserView(job: job, url: url, library: library)
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
            // A category deleted since the last launch can't be reopened.
            if case let .category(id) = scope, !categories.contains(where: { $0.id == id }) {
                scope = .all
            }
            await library.refreshCaptures()
        }
        .task(id: windowState) {
            guard restoresWindow else { return }
            // Pans and zooms change this every frame; write once they settle.
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            windowState.save()
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
            id: "\(preview.selectedID?.uuidString ?? "")/\(library.documentGrid.generation)/\(preview.showsCapturedSource)/\(library.workspace.noteGeneration)"
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
            library.useRecommendationJudge(linkJudge() as? any RecommendationJudging)
            library.useGraphExtractor(
                currentInference() as? any GraphExtracting ?? AppleGraphExtractor()
            )
            library.useFiler(currentInference())
        }
        .task {
            // The chat Writer's own model, asked for when the digest runs: it loads ChatGPT's
            // models if they aren't yet, and says why when ChatGPT can't be used.
            guard let providers = conversation?.providers else { return }
            library.useWriter { try await providers.requestInference() }
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

    /// The reading view: the text with the panel to itself. The item page keeps everything else.
    private func readerPane(_ target: ChatAttachmentTarget) -> some View {
        VStack(spacing: 0) {
            PageBar {
                Button("Exit Reader Mode", systemImage: "chevron.left") { readerTarget = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PageIconButtonStyle())
                    .help("Exit Reader Mode")
            }
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
            if handleTaskURL(url) {
                return .handled
            }
            if let id = NoteLink.id(from: url) {
                openSavedItem(id)
                return .handled
            }
            if let entity = EntityLink.target(from: url) {
                showEntity(entity)
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
    private static let panelInset: CGFloat = 8
    /// The row that holds the traffic lights and sidebar toggle.
    private static let chromeHeight: CGFloat = 46
    private static let panelRadius: CGFloat = 12
    private static let sidebarFade: CGFloat = 12
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
        .environment(\.pageMenu, AnyView(moreMenu))
        .environment(\.openCommandPalette) {
            withAnimation(.snappy(duration: 0.15)) { showingPalette = true }
        }
    }

    private var browsingMain: some View {
        browsingContent
            .onChange(of: readEntitiesInBackground) { _, enabled in
                Task { await library.setBackgroundEntityReading(enabled) }
            }
    }

    @ViewBuilder private var browsingContent: some View {
        if chatting, let conversation {
            ConversationView(
                model: conversation, library: library, openInLibrary: openSavedItem
            )
        } else if showingEntities {
            if library.ready {
                EntitiesView(
                    store: library.store,
                    judge: currentInference() as? any EntityMatchJudging,
                    focus: entityFocus,
                    open: openSavedItem
                )
            } else {
                WorkingProgress("Opening entities…")
            }
        } else if showingTasks {
            if library.ready {
                WorkspaceTasksView(
                    workspace: library.workspace,
                    openNote: openSavedItem,
                    selection: $taskView
                )
            } else {
                WorkingProgress("Opening tasks…")
            }
        } else if showingActivity {
            if library.ready {
                ActivityView(
                    store: library.store,
                    open: openSavedItem,
                    openSource: { source = $0 },
                    pendingReviews: library.automations.pendingCount,
                    reviewChanges: { sidebarSelection.wrappedValue = .automations },
                    undoRun: { await library.automations.undoRun($0) },
                    intakeCount: intakeCaptures.count
                ) { captureIntake }
            } else {
                WorkingProgress("Opening activity…")
            }
        } else if automating {
            AutomationsView(model: library.automations, open: openSavedItem)
        } else {
            VStack(spacing: 0) {
                libraryBar
                if scope == .archived || presentation == .list {
                    libraryColumns
                } else if presentation == .graph {
                    graphPane
                } else {
                    atlasPane
                }
            }
        }
    }

    /// Stays beside the traffic lights whether or not the sidebar is showing.
    private var sidebarToggle: some View {
        // The shortcut lives on View › Toggle Sidebar, so Settings › Keyboard can change it.
        let shortcut = ShortcutSettings.shared.shortcut(for: "toggle-sidebar")
            .map { " (\($0.display))" } ?? ""
        return Button("Toggle Sidebar", systemImage: "sidebar.left") {
            sidebarVisible.toggle()
        }
        .buttonStyle(PageIconButtonStyle())
        .help((sidebarVisible ? "Hide sidebar" : "Show sidebar") + shortcut)
        .padding(.leading, 72).padding(.top, 2)
    }

    /// Ends every page's bar, in the same place. Chat puts its own menu in this slot.
    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis") {
            Button("Note Templates…", systemImage: "doc.badge.plus") {
                showingTemplates = true
            }
            .disabled(!library.ready || library.busy)
            Divider()
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
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
        }
        .menuIndicator(.hidden).menuStyle(.button)
        .buttonStyle(PageIconButtonStyle())
        .help("Templates, import, filing review, and Settings")
        .accessibilityIdentifier("library-more-menu")
    }

    private var libraryTab: Binding<LibraryTab> {
        Binding {
            scope == .archived ? .archived : LibraryTab(kindFilter)
        } set: { tab in
            if let kind = tab.kind {
                if scope == .archived {
                    sidebarSelection.wrappedValue = .library(.all)
                }
                kindFilter = kind
            } else {
                sidebarSelection.wrappedValue = .library(.archived)
            }
        }
    }

    private var showsPresentations: Bool {
        presentation.showsPicker(
            in: scope,
            hasOpenedItem: atlasItem != nil,
            isEditing: editing != nil
        )
    }

    /// Map highlights matches in place; List and Graph narrow to them.
    private var librarySearch: PageSearch? {
        // Nothing to search yet: Search falls back to the command palette.
        guard !scopeIsEmpty else { return nil }
        let map = presentation == .map && scope != .archived
        return PageSearch(
            prompt: map ? "Highlight matches" : "Search this view",
            label: map ? "Search the atlas" : "Search library",
            query: map ? $atlasQuery : Binding(
                get: { library.documentGrid.query },
                set: { library.documentGrid.query = $0 }
            ),
            focus: $searchFocused
        )
    }

    /// The way back from an open item: to the Map's regions, or to the Graph.
    private var itemBreadcrumb: some View {
        HStack(spacing: 6) {
            Button("Back", systemImage: "chevron.left") { atlasItem = nil }
                .buttonStyle(PageIconButtonStyle())
                .help(presentation == .graph ? "Return to the Graph" : "Return to the Atlas")
                .disabled(editing != nil)
            if presentation != .graph {
                ForEach(atlasItem.map(atlasLocation(of:)) ?? [], id: \.id) { region in
                    Button(region.label) {
                        atlasItem = nil
                        atlas.focus(region.id)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).lineLimit(1)
                    .disabled(editing != nil)
                    .help("Show \(region.label) in the Atlas")
                    Text("/").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            Text(preview.document?.name ?? "").lineLimit(1)
        }
    }

    private var libraryBar: some View {
        PageBar(search: librarySearch) {
            if atlasItem != nil || (editing != nil && presentation != .list) {
                itemBreadcrumb
            } else {
                PageTabs(
                    label: "Item type",
                    items: LibraryTab.allCases.map { ($0, $0.title) },
                    selection: libraryTab
                )
            }
        } accessory: {
            if scope == .unfiled, editing == nil {
                Button { categorizing = true } label: {
                    if library.categorizing {
                        HStack(spacing: 6) {
                            ChatWorkingIndicator(color: .secondary)
                            Text("Review filing…")
                        }
                    } else {
                        Text("Suggest filing…")
                    }
                }
                .disabled(!library.ready)
                .help(
                    "Suggest homes in batches, then review before filing. Saved suggestions can be resumed."
                )
            }
            if showsPresentations {
                LibraryPresentationPicker(selection: presentationSelection)
                Divider().frame(height: 16).padding(.horizontal, 4)
            }
        }
    }

    private var summarizerKey: String {
        // Until accounts, keys and models load, the provider and model aren't settled yet.
        conversation?.providers.engineKey ?? "apple"
    }

    /// The chosen hosted provider, else Apple Intelligence. A hosted provider that can't be used
    /// fails summaries with its reason rather than quietly switching engines.
    private func linkSummarizer() -> any LinkSummarizing {
        guard let providers = conversation?.providers, providers.selected != .apple else {
            return AppleLinkSummarizer()
        }
        let name = providers.selected.name
        if providers.needsModels {
            return DeferredHostedSummarizer(engineName: name, providers: providers)
        }
        do {
            return try providers.inference() as? any LinkSummarizing ?? AppleLinkSummarizer()
        } catch {
            return UnavailableSummarizer(engineName: name, error: error)
        }
    }

    /// The cross-linker's judge follows the provider too. A hosted provider that can't be used
    /// leaves none, so the automation says so instead of quietly switching to Apple.
    private func linkJudge() -> (any LinkJudging)? {
        guard let providers = conversation?.providers, providers.selected != .apple else {
            return AppleConversationInference()
        }
        return (try? providers.inference()) as? any LinkJudging
    }

    /// The hosted provider's filing model when one is chosen; otherwise Apple Intelligence.
    private func currentInference() -> any ConversationInferring {
        (try? conversation?.providers.filingInference()) ?? AppleConversationInference()
    }

    /// A rounded panel set into the window, concentric with its lower corners.
    private var contentPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous)
        return HStack(spacing: 0) {
            // Stacked, not a safe-area inset, so columns can't draw under the banner.
            VStack(spacing: 0) {
                notice
                main.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A plain trailing column like the sidebar: SwiftUI's `.inspector` claims the window
            // toolbar, which pulls content under this window's custom titlebar.
            if showingFiling, !chatting, !showingActivity, !showingTasks, !showingEntities,
               readerTarget == nil
            {
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
                .background(PanelSurface.color)
                .transition(.move(edge: .trailing))
            }
        }
        .background(PanelSurface.color)
        .clipShape(shape)
        // One device pixel: a fixed 0.5pt straddles pixels at 1x, stepping where curve meets edge.
        .overlay { shape.strokeBorder(.separator, lineWidth: 1 / displayScale) }
        .padding(.leading, sidebarVisible ? 0 : Self.panelInset)
        .padding([.trailing, .bottom], Self.panelInset)
        // Without the sidebar, the panel keeps clear of the traffic lights and toggle.
        .padding(.top, sidebarVisible ? Self.panelInset : Self.chromeHeight)
    }

    /// The sidebar's rows stop level with the content panel and fade into its edges.
    private var fadedSidebar: some View {
        let fade = Self.sidebarFade / max(1, sidebarHeight)
        return sidebar
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { sidebarHeight = $0 }
            .mask {
                // Rows fade; the scroller beside them stays whole, so it ends where the panel does.
                HStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: fade),
                            .init(color: .black, location: 1 - fade),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Color.black.frame(width: SlimScrollers.width)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
            .padding(.top, Self.chromeHeight)
            .padding(.bottom, Self.panelInset)
    }

    private var sidebarFooter: some View {
        HStack {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
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
        if scopeIsEmpty {
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
        ListDetailColumns { documentList } detail: { detail() }
    }

    @ViewBuilder private var atlasPane: some View {
        if atlasItem != nil || editing != nil {
            detail(openDocument: openFromAtlas)
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
                },
                search: $atlasQuery,
                suggestFiling: { categorizing = true }
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
            detail(openDocument: openFromGraph)
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

    private func requestDraft(_ template: NoteTemplate?) {
        pendingTemplate = template
        if editing != nil {
            replacingDraft = true
        } else {
            startDraft(template)
        }
    }

    private func startDraft(_ template: NoteTemplate?) {
        readerTarget = nil
        chatting = false
        automating = false
        showingActivity = false
        showingTasks = false
        showingEntities = false
        scope = .all
        if kindFilter == .sources {
            kindFilter = .notes
        }
        if let template {
            let (document, profile) = template.draft()
            editingProfile = profile
            editing = document
        } else {
            editingProfile = NoteProfile()
            editing = MarkdownDocument(name: "Untitled", markdown: "")
        }
        pendingTemplate = nil
    }

    private func handleTaskURL(_ url: URL) -> Bool {
        guard url.scheme == "gleanary", url.host == "task" else { return false }
        guard let id = UUID(uuidString: url.lastPathComponent) else { return true }
        Task {
            do {
                if let task = try await library.store.workspaceTask(id) {
                    openingTask = task
                } else {
                    library.error = "This task is no longer available."
                }
            } catch { library.error = "Could not open this task. Try finding it in Tasks." }
        }
        return true
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
        showingTasks = false
        showingEntities = false
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
        showingTasks = false
        showingEntities = false
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

    private var windowState: SavedLibraryWindow {
        let destination: SavedLibraryWindow.Destination =
            chatting ? .chat : showingTasks ? .tasks : showingEntities ? .entities :
            showingActivity ? .activity : automating ? .automations : .library
        var state = SavedLibraryWindow(
            destination: destination, scope: scope, kindFilter: kindFilter,
            atlas: atlas.savedView
        )
        // Until the Atlas has been shown this launch, keep the view saved for this collection.
        if state.atlas == nil, let savedWindow, savedWindow.scope == scope,
           savedWindow.kindFilter == kindFilter
        {
            state.atlas = savedWindow.atlas
        }
        return state
    }

    // MARK: Command palette

    /// What this window can run by command id, for menus, shortcuts and the palette.
    private var commandActions: [String: () -> Void] {
        var actions: [String: () -> Void] = [
            "palette": { withAnimation(.snappy(duration: 0.15)) { showingPalette = true } },
            "settings": { openSettings() },
            "toggle-sidebar": { sidebarVisible.toggle() },
            "go-library": { sidebarSelection.wrappedValue = .library(.all) },
            "go-tasks": { sidebarSelection.wrappedValue = .tasks },
            "go-entities": { sidebarSelection.wrappedValue = .entities },
            "go-activity": { sidebarSelection.wrappedValue = .activity },
            "go-automations": { sidebarSelection.wrappedValue = .automations },
            "show-map": { showLibrary(as: .map) },
            "show-list": { showLibrary(as: .list) },
            "show-graph": { showLibrary(as: .graph) },
        ]
        if conversation != nil {
            actions["go-chat"] = { sidebarSelection.wrappedValue = .conversation }
        }
        return actions
    }

    /// An entity link from the reader: leaves the reader for Entities, on that entity.
    private func showEntity(_ entity: EntityFocus) {
        readerTarget = nil
        chatting = false
        automating = false
        showingActivity = false
        showingTasks = false
        entityFocus = entity
        showingEntities = true
    }

    /// Leaves Chat or another screen for the Library, in the chosen presentation.
    private func showLibrary(as newPresentation: LibraryPresentation) {
        readerTarget = nil
        chatting = false
        automating = false
        showingActivity = false
        showingTasks = false
        showingEntities = false
        presentation = newPresentation
    }

    @ViewBuilder private var commandPalette: some View {
        if showingPalette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { showingPalette = false }
                    .accessibilityHidden(true)
                FocusedActionsReader { focusedActions in
                    CommandPaletteView(
                        items: paletteItems(focusedActions: focusedActions),
                        suggested: ["go-library", "new-item", "attach", "show-graph"],
                        recent: { await paletteDocuments("", limit: 5, section: .recent) },
                        documents: { await paletteDocuments($0, limit: 40, section: .documents) },
                        ask: paletteAsk,
                        close: { showingPalette = false }
                    )
                }
                .padding(.top, 72)
            }
            .transition(.opacity)
        }
    }

    private func paletteItems(focusedActions: GleanaryActions?) -> [PaletteItem] {
        let shortcuts = ShortcutSettings.shared
        var items: [PaletteItem] = []
        let places: [(String, String, SidebarItem)] = [
            ("Library", "books.vertical", .library(.all)),
            ("Notes", "note.text", .library(.notes)),
            ("Sources", "doc.text", .library(.sources)),
            ("Unfiled", "folder.badge.questionmark", .library(.unfiled)),
            ("Archived", "archivebox", .library(.archived)),
            ("Tasks", "checklist", .tasks),
            ("Entities", "person.2", .entities),
            ("Activity", "clock", .activity),
            ("Automations", "gearshape.2", .automations),
        ] + (conversation == nil ? [] : [("Chat", "bubble.left", .conversation)])
        for (title, symbol, destination) in places {
            items.append(PaletteItem(
                id: "place-\(title)", section: .places, title: title, subtitle: "Go to",
                symbol: symbol,
                run: { sidebarSelection.wrappedValue = destination }
            ))
        }
        for category in categories {
            items.append(PaletteItem(
                id: "category-\(category.id)", section: .categories, title: category.label,
                subtitle: "Show in Library", symbol: "number",
                run: { sidebarSelection.wrappedValue = .library(.category(category.id)) }
            ))
        }
        let window = commandActions
        for command in AppCommand.all where !["palette", "stop"].contains(command.id) {
            guard let action = CommandRouter.action(
                command.id, window: window, actions: focusedActions,
                navigation: NavigationActions(
                    canGoBack: history.canGoBack, canGoForward: history.canGoForward,
                    back: goBack, forward: goForward
                ),
                paneSearch: nil
            ) else { continue }
            let title = command.id == "new-item" ? (focusedActions?.newItemTitle ?? "New Note")
                : command.title
            items.append(PaletteItem(
                id: "command-\(command.id)", section: .commands, title: title,
                symbol: command.symbol, shortcut: shortcuts.shortcut(for: command),
                keywords: command.keywords, run: action
            ))
        }
        return items
    }

    private func paletteDocuments(
        _ query: String, limit: Int, section: PaletteItem.Section
    ) async -> [PaletteItem] {
        guard let page = try? await library.store.documentPage(query: query, limit: limit)
        else { return [] }
        return page.documents.map { document in
            let host = document.sourceURL?.host()
                .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            return PaletteItem(
                id: "document-\(document.id)", section: section, title: document.name,
                subtitle: [document.kindLabel, host].compactMap(\.self).joined(separator: " · "),
                symbol: document.kind == "source" ? "doc.text" : "note.text",
                filing: document.filing,
                run: { openSavedItem(document.id) },
                runBeside: conversation.map { conversation in
                    {
                        sidebarSelection.wrappedValue = .conversation
                        conversation.documentRequest = document.id
                    }
                }
            )
        }
    }

    /// Free text goes to Chat; links are saved, each queued behind whatever is running.
    private func paletteAsk(_ text: String) -> PaletteItem? {
        guard let conversation else { return nil }
        let links = PastedLinks.isOnlyLinks(text) ? PastedLinks.urls(in: text) : []
        let title = links.count > 1 ? "Save \(links.count) links"
            : links.count == 1 ? "Save link" : "Ask Gleanary “\(text)”"
        let subtitle = links.count > 1 ? "Each one waits its turn in Chat"
            : links.first.map(\.absoluteString) ?? "Sends to Chat"
        return PaletteItem(
            id: "ask", section: .ask, title: title, subtitle: subtitle,
            symbol: links.isEmpty ? "bubble.left" : "plus",
            run: {
                sidebarSelection.wrappedValue = .conversation
                conversation.composer = text
                Task { await conversation.send() }
            }
        )
    }

    // MARK: History

    private var location: NavigationLocation {
        NavigationLocation(
            chatting: chatting, scope: scope, atlasFocus: atlas.focusID, atlasItem: atlasItem,
            automations: automating, activity: showingActivity, tasks: showingTasks,
            entities: showingEntities,
            kindFilter: kindFilter,
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
        showingTasks = target.tasks
        showingEntities = target.entities
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
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor))
                    Spacer()
                    if conversation.running {
                        ChatWorkingIndicator(color: sidebarColor)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(conversation.running ? "Working" : "")
                .help(conversation.running ? "Chat is working" : "Chat")
                .tag(SidebarItem.conversation)
            }
            Section {
                Label("Library", systemImage: "books.vertical")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor))
                    .tag(SidebarItem.library(.all))
                // What you browse and work on sits with the library; housekeeping follows.
                Label("Entities", systemImage: "person.2")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor))
                    .tag(SidebarItem.entities)
                HStack {
                    Label("Tasks", systemImage: "checklist")
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor))
                    Spacer()
                    if tasksDueToday > 0 {
                        Text(tasksDueToday.formatted())
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(sidebarColor.opacity(0.72))
                            .countsOnChange(tasksDueToday)
                            .accessibilityLabel(tasksDueToday == 1 ? "1 task for today"
                                : "\(tasksDueToday) tasks for today")
                    }
                }
                .tag(SidebarItem.tasks)
                .task(id: library.workspace.generation) {
                    let page = try? await library.store.workspaceTasks(view: .today, limit: 200)
                    tasksDueToday = page?.tasks.count ?? 0
                }
            }
            // Upkeep: Activity first, as the overview of the queues beneath it. It holds
            // captures too, so its only badge is the failures that need you.
            Section {
                HStack {
                    Label("Activity", systemImage: "clock")
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor))
                    Spacer()
                    // Only failures are counted, so the badge says so instead of looking like a
                    // total.
                    let issues = intakeCaptures.count { $0.state == .failed }
                    if issues > 0 {
                        // Not a Label: the sidebar sizes label icons like row icons.
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.circle.fill").imageScale(.small)
                            Text(issues.formatted())
                        }
                        .countsOnChange(issues)
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.orange)
                        .help(issues == 1 ? "1 capture needs attention"
                            : "\(issues) captures need attention")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(issues == 1 ? "1 capture needs attention"
                            : "\(issues) captures need attention")
                    }
                }.tag(SidebarItem.activity)
                HStack {
                    let color = sidebarColor
                    Label("Automations", systemImage: "clock.arrow.2.circlepath")
                        .labelStyle(LibrarySidebarLabelStyle(color: color))
                    Spacer()
                    if library.automations.running != nil {
                        WorkingProgress(color: color.opacity(0.72))
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
            }
            Section("Filing") {
                // The items with no home, ahead of the homes.
                HStack(spacing: 8) {
                    Circle().fill(.secondary).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text("Unfiled").foregroundStyle(sidebarColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Show unfiled items in Library")
                .tag(SidebarItem.library(.unfiled))
                // Flat, in code order: the codes already show which area each home belongs to.
                ForEach(CategoryArea.group(categories).flatMap(\.categories)) { filingRow($0) }
            }
        }.listStyle(.sidebar).scrollContentBackground(.hidden)
            // A sidebar's sections are disclosure groups too, and these stay plain headings.
            .disclosureGroupStyle(.automatic)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .accessibilityLabel("Library navigation")
    }

    /// One line per category, led by its Atlas colour.
    private func filingRow(_ category: DecimalCategory) -> some View {
        let color = sidebarColor
        // Dimmed, not removed: the map hides empty categories, but they stay reachable here.
        let hidden = presentation == .map && atlasHidesEmpty
            && atlas.emptyCategoryIDs.contains(category.id)
        // The category's Atlas colour, as on its chips and in the filing inspector.
        let mark = AtlasPalette.mark(
            AtlasHierarchy.hue(for: category.code),
            dark: colorScheme == .dark
        )
        return HStack(spacing: 8) {
            Circle().fill(mark).frame(width: 7, height: 7).accessibilityHidden(true)
            // Leading, as Johnny Decimal writes it: a trailing number reads as a count.
            Text(category.code).font(.caption).monospacedDigit()
                .foregroundStyle(color.opacity(0.5))
            Text(category.name).foregroundStyle(color).lineLimit(1)
            Spacer(minLength: 4)
            // Nil until the Atlas has loaded.
            if let count = atlas.layout.tile(.category(category.id))?.node.itemCount, count > 0 {
                Text(count.formatted()).font(.caption).monospacedDigit()
                    .foregroundStyle(color.opacity(0.5))
            }
        }
        .opacity(hidden ? 0.4 : 1)
        .padding(.leading, category.code.contains(".") ? 10 : 0)
        .tag(SidebarItem.library(.category(category.id)))
        .help(hidden ? "\(category.label) is empty and hidden in the map" : category.label)
        .accessibilityElement(children: .combine)
        .accessibilityValue(hidden ? "Empty, hidden in the map" : "")
    }

    private var sidebarScope: LibraryScope? {
        guard scope == .all else { return scope }
        switch kindFilter {
        case .all: return .all
        case .notes: return .notes
        case .sources: return .sources
        }
    }

    /// Selected rows keep this too: the sidebar's selection is a neutral fill, not an accent.
    private var sidebarColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            chatting ? .conversation : showingTasks ? .tasks : showingEntities ? .entities :
                showingActivity ? .activity :
                automating ? .automations :
                scope.map(SidebarItem.library)
        } set: { item in
            readerTarget = nil
            showingTasks = item == .tasks
            showingEntities = item == .entities
            switch item {
            case .conversation: chatting = true; automating = false; showingActivity = false
            case .automations: chatting = false; automating = true; showingActivity = false
            case .activity: chatting = false; automating = false; showingActivity = true
            case .tasks, .entities: chatting = false; automating = false; showingActivity = false
            case let .library(scope):
                chatting = false
                automating = false
                showingActivity = false
                switch scope {
                case .notes: kindFilter = .notes; self.scope = .all
                case .sources: kindFilter = .sources; self.scope = .all
                // Library keeps its picker's remembered type.
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
        showingTasks = false
        showingEntities = false
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
                        Button("Show All Types") { kindFilter = .all }
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
                }.listStyle(.inset).scrollContentBackground(.hidden)
                    .accessibilityLabel("Saved library items")
                    .task(id: "\(library.documentGrid.generation)/\(page)") {
                        library.documentGrid.show(indices: Array(pageRange))
                    }
                pagination
            }
            handoff
        }.navigationSplitViewColumnWidth(
            min: ListColumn.minWidth, ideal: ListColumn.idealWidth, max: ListColumn.maxWidth
        )
    }

    private var pagination: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(
                    "\(pageRange.lowerBound + 1)–\(pageRange.upperBound) of \(library.documentGrid.total)"
                )
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Previous Page", systemImage: "chevron.left") { page -= 1 }
                    .disabled(page == 0)
                Button("Next Page", systemImage: "chevron.right") { page += 1 }
                    .accessibilityIdentifier("library-next-page")
                    .disabled(pageRange.upperBound >= library.documentGrid.total)
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .padding(.horizontal, ListColumn.inset).padding(.vertical, 7)
        }
    }

    /// Appears with the selection, so an unselected list has no chrome beneath it.
    @ViewBuilder private var handoff: some View {
        if !selection.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.horizontal, -ListColumn.inset)
                HStack(spacing: 10) {
                    Text("\(selection.count) selected")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Clear") { selection = [] }.buttonStyle(.borderless).font(.caption)
                    Spacer()
                    Button("Use in Chat", systemImage: "bubble.left") {
                        useInConversation(Array(selection).sorted { $0.uuidString < $1.uuidString })
                    }
                    .disabled(selection.count > 4)
                }
                Text(selection.count > 4 ? "Choose up to 4 items for one request."
                    : "⌘-click to choose more, up to 4.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, ListColumn.inset).padding(.bottom, 10)
        }
    }

    @ViewBuilder private func detail(openDocument: ((UUID) -> Void)? = nil) -> some View {
        if let editing {
            // The editor stays put while the selection changes, so a draft is never dropped.
            NoteEditor(
                document: editing,
                library: library,
                profile: editingProfile,
                didSave: openSavedItem
            ) {
                self.editing = nil
                editingProfile = nil
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

    /// Captures still being saved, or failed and waiting for you; finished ones are in
    /// Activity's timeline.
    private var intakeCaptures: [CaptureJob] {
        visibleCaptures.filter { $0.state == .failed || !$0.state.terminal }
    }

    /// Activity's pinned sections: failures first, since they need you, then what's saving.
    @ViewBuilder private var captureIntake: some View {
        let failed = intakeCaptures.filter { $0.state == .failed }
        let saving = intakeCaptures.filter { $0.state != .failed }
        if !failed.isEmpty {
            Section {
                ForEach(failed) { captureRow($0) }
            } header: {
                HStack {
                    // The sidebar badge counts these; the same mark finds them here.
                    Text("Needs Attention")
                    Spacer()
                    Button("Clear All") {
                        Task { await library.clearFailedCaptures() }
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Forget every failed capture. Saved items aren't affected.")
                }
            }
        }
        if !saving.isEmpty {
            Section("Saving") {
                ForEach(saving) { captureRow($0) }
            }
        }
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
                    // The app's working dot, which holds still with Reduce Motion.
                    WorkingProgress()
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
                    Button("Open Saved Item") { openSavedItem(id) }
                }
                if job.state == .failed || job.state == .cancelled {
                    if job.recovery == .browser {
                        Button("Open Browser") { library.browserJob = job }
                    }
                    if job.recovery == .audio {
                        Button("Audio Options") { library.audioJob = job }
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
                Button("Copy Link", systemImage: "doc.on.doc") {
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
            Button("Show in Activity") {
                library.captureFailure = nil
                sidebarSelection.wrappedValue = .activity
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
                Button("Retry Indexing") { library.startIndexing() }.disabled(library.indexing)
            }
            if !library.ready {
                Button("Retry Opening") { Task { await library.load() } }
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

    static let key = "libraryPresentation"

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
    @Environment(\.colorScheme) private var colorScheme

    private var identity: DocumentIdentity {
        DocumentIdentity(kind: document.kind)
    }

    private var host: String? {
        document.sourceURL?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.name).font(.body.weight(.medium)).lineLimit(2)
                metadata
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let preview = document.previewImage {
                PagePreviewThumbnail(id: document.id, data: preview)
            }
        }
        .padding(.vertical, 5).help(document.name)
    }

    /// One line: the mark says source or note, so words go to where it's from and where it lives.
    private var metadata: some View {
        HStack(spacing: 5) {
            DocumentIdentityMark(isSource: identity.isSource, ink: .secondary, size: 14)
            Text(host ?? identity.subtype ?? identity.label).lineLimit(1)
            if let filing = document.filing {
                Circle().fill(filingMark(filing)).frame(width: 6, height: 6).padding(.leading, 4)
                Text(filing).lineLimit(1).layoutPriority(1)
            } else {
                Text("Unfiled").lineLimit(1).padding(.leading, 4).layoutPriority(1)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [identity.text, host, document.filing ?? "Unfiled"].compactMap(\.self)
                .joined(separator: ", ")
        )
    }

    @ViewBuilder private var status: some View {
        if let activity {
            Label {
                Text(activity).lineLimit(1).fadesOnChange(activity)
            } icon: {
                ChatWorkingIndicator(color: .secondary)
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

    /// `filing` reads "20.01 Name", the code first, as in the sidebar.
    private func filingMark(_ filing: String) -> Color {
        let code = filing.prefix { !$0.isWhitespace }
        return AtlasPalette.mark(AtlasHierarchy.hue(for: String(code)), dark: colorScheme == .dark)
    }
}

/// A top-aligned crop of the page as it looked when captured, like a link preview's image.
/// It repeats what the title already says, so assistive technologies skip it.
private struct PagePreviewThumbnail: View {
    private static let decoded = NSCache<NSString, NSImage>()

    let id: UUID
    let data: Data
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = Self.image(id: id, data: data) {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            Color.clear.frame(width: 64, height: 48)
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
    case tasks
    case entities
    case library(LibraryScope)
}

/// Reads the focused screen's actions for the palette alone. ContentView reading them itself
/// would re-render the whole window each time Chat republishes them, which is every token.
private struct FocusedActionsReader<Content: View>: View {
    @FocusedValue(\.gleanaryActions) private var actions
    @ViewBuilder let content: (GleanaryActions?) -> Content

    var body: some View {
        content(actions)
    }
}
