import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var library: LibraryModel
    /// The Chat conversation shown beside the shared sidebar; nil in library-only hosts.
    var conversation: ConversationModel?
    @State private var chatting: Bool
    /// The Automations screen, in place of the library; Chat still takes precedence.
    @State private var automating = false
    var initialSelection: UUID?
    @State private var scope: LibraryScope? = .all
    @State private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = ContentView.defaultSidebarWidth
    @State private var sidebarDragStart: Double?
    @State private var selection: Set<UUID> = []
    @State private var page = 0
    @State private var categories: [DecimalCategory] = []
    @State private var importing = false
    @State private var importingBookmarks = false
    @State private var categorizing = false
    /// An item to select once a scope change has cleared the old selection.
    @State private var pendingSelection: UUID?
    @State private var editing: MarkdownDocument?
    /// The filing inspector beside the selected item.
    @State private var showingFiling = false
    @State private var preview = DocumentPreviewModel()
    @State private var source: SourceCitation?
    @AppStorage("libraryPresentation") private var presentation = LibraryPresentation.map
    /// Area digits folded in the sidebar's Filing section, comma-separated.
    @AppStorage("collapsedFilingAreas") private var collapsedAreas = ""
    @State private var atlas = KnowledgeAtlasModel()
    /// Shared with the map's Hide empty toggle.
    @AppStorage("atlasHidesEmptyCategories") private var atlasHidesEmpty = false
    /// The item opened from the Atlas; the Atlas keeps its own state underneath.
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

    init(
        library: LibraryModel,
        conversation: ConversationModel? = nil,
        initialSelection: UUID? = nil,
        previewModel: DocumentPreviewModel? = nil
    ) {
        self.library = library
        self.conversation = conversation
        _chatting = State(initialValue: conversation != nil && initialSelection == nil)
        self.initialSelection = initialSelection
        _preview = State(initialValue: previewModel ?? DocumentPreviewModel())
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
            if showingFiling, !chatting {
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
        // A solid titlebar like ChatGPT's: content scrolls under it but never shows through.
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
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "infactory", url.host == "note",
               let id = UUID(uuidString: url.lastPathComponent)
            {
                selection = [id]; preview.selectedID = id
                return .handled
            }
            return .systemAction
        })
        // The conversation publishes its own actions while it is showing.
        .focusedSceneValue(\.infactoryActions, chatting ? nil : InfactoryActions(
            enabled: library.ready && !library.busy,
            newNote: {
                // Captures has no reading pane to edit in.
                if scope == .captures {
                    scope = .all
                }
                editing = MarkdownDocument(name: "Untitled", markdown: "")
            },
            attach: { importing = true }, focus: { searchFocused = true },
            importBookmarks: { importingBookmarks = true },
            categorize: { categorizing = true }
        ))
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
        .sheet(item: $source) { CaptureSourceView(citation: $0, library: library) }
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
            await library.documentGrid.reloadIfNeeded()
            if let initialSelection {
                selection = [initialSelection]; preview.selectedID = initialSelection
                if presentation == .map {
                    atlasItem = initialSelection
                }
            }
            await loadCategories()
            await library.refreshCaptures()
        }
        .task(id: library.documentGrid.query) {
            guard library.ready else { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            await library.documentGrid.reloadIfNeeded()
        }
        .task(id: "\(preview.selectedID?.uuidString ?? "")/\(library.documentGrid.generation)") {
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
        }
        .onChange(of: scope) {
            selection = []; preview.selectedID = nil; page = 0
            library.documentGrid.scope = scope ?? .all
            if presentation == .map {
                showInAtlas(scope ?? .all)
            }
            revealPendingSelection()
            if let target = pendingRestore {
                pendingRestore = nil
                restoreAtlas(target)
            }
            Task { await library.documentGrid.reload(); await library.refreshCaptures() }
        }
        .onChange(of: presentation) {
            atlasItem = nil
            if presentation == .map {
                showInAtlas(scope ?? .all)
            } else if let id = selection.first {
                preview.selectedID = id
            }
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

    @ViewBuilder private var main: some View {
        if chatting, let conversation {
            ConversationView(model: conversation, library: library)
        } else if automating {
            AutomationsView(model: library.automations)
        } else if presentation == .list || scope == .captures || scope == .archived {
            libraryColumns
        } else {
            atlasPane
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 0) {
                Button("Toggle Sidebar", systemImage: "sidebar.left") {
                    withAnimation(.snappy(duration: 0.25)) { sidebarVisible.toggle() }
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
                Text(chatting ? "Chat" : automating ? "Automations" : scopeTitle)
                    .font(.headline).lineLimit(1)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        if !chatting, !automating {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Picker("Presentation", selection: $presentation) {
                    Label("Map", systemImage: "square.grid.2x2").tag(LibraryPresentation.map)
                    Label("List", systemImage: "list.bullet").tag(LibraryPresentation.list)
                }
                .pickerStyle(.segmented).labelStyle(.iconOnly).fixedSize()
                .help("Browse the library as a map or a list")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem {
                // Mirrors the File menu, as Finder and Mail do with their toolbar More menus.
                // Plain ellipsis: Liquid Glass already draws the circular button.
                Menu("More", systemImage: "ellipsis") {
                    Button("Attach Documents…", systemImage: "paperclip") { importing = true }
                    Button("Import Bookmarks…", systemImage: "square.and.arrow.down") {
                        importingBookmarks = true
                    }
                    Divider()
                    Button("Categorize Unfiled…", systemImage: "wand.and.sparkles") {
                        categorizing = true
                    }
                    Divider()
                    SettingsLink { Label("Settings…", systemImage: "gearshape") }
                }
                .menuIndicator(.hidden)
                .disabled(!library.ready || library.busy)
                .help("Import and organize")
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

    private var libraryColumns: some View {
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
                        description: Text(
                            "Retry failed captures or inspect their saved documents. Retained originals are reused where available."
                        )
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
                refreshToken: library.documentGrid.generation, openItem: openFromAtlas
            )
        }
    }

    /// Shows a saved item from anywhere, such as the Captures list. Switching to All items
    /// clears the selection, so the item is selected after that, not before.
    private func openSavedItem(_ id: UUID) {
        chatting = false
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
        selection = [id]
        preview.selectedID = id
        if presentation == .map {
            openFromAtlas(id)
        }
    }

    private func openFromAtlas(_ id: UUID) {
        atlas.selectedID = .item(id)
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
            automations: automating
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
        chatting = target.chatting
        automating = target.automations
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
            openFromAtlas(id)
        } else {
            atlasItem = nil
        }
    }

    /// Sidebar choices act as shortcuts into the Atlas instead of filtering a list.
    private func showInAtlas(_ scope: LibraryScope) {
        atlasItem = nil
        atlas.kindFilter = switch scope {
        case .sources: .sources
        case .notes: .notes
        default: .all
        }
        switch scope {
        case .unfiled: atlas.focus(.uncategorized)
        case let .category(id): atlas.focus(.category(id))
        case .captures, .archived: break
        default: atlas.reset()
        }
        seenAtlasNavigations = atlas.navigations
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            if conversation != nil {
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(nil)))
                    .tag(SidebarItem.conversation)
            }
            Section("Library") {
                Label("All items", systemImage: "tray.full")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.all)))
                    .tag(SidebarItem.library(.all))
                Label("Sources", systemImage: "doc.text")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.sources)))
                    .tag(SidebarItem.library(.sources))
                Label("Notes", systemImage: "note.text")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.notes)))
                    .tag(SidebarItem.library(.notes))
                Label("Unfiled", systemImage: "folder.badge.questionmark")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.unfiled)))
                    .tag(SidebarItem.library(.unfiled))
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
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.archived)))
                    .tag(SidebarItem.library(.archived))
                HStack {
                    let color: Color = colorScheme == .dark || (automating && !chatting)
                        ? .white : .black
                    Label("Automations", systemImage: "clock.arrow.2.circlepath")
                        .labelStyle(LibrarySidebarLabelStyle(color: color))
                    Spacer()
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
        let hidden = !chatting && presentation == .map && atlasHidesEmpty
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
        .help(hidden ? "\(category.label) · Empty · hidden in the map" : category.label)
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

    /// Pass nil for the conversation row.
    private func sidebarColor(_ item: LibraryScope?) -> Color {
        let selected = item.map { !chatting && !automating && scope == $0 } ?? chatting
        return colorScheme == .dark || selected ? .white : .black
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            chatting ? .conversation : automating ? .automations : scope.map(SidebarItem.library)
        } set: { item in
            switch item {
            case .conversation: chatting = true; automating = false
            case .automations: chatting = false; automating = true
            case let .library(scope):
                chatting = false
                automating = false
                self.scope = scope
            case nil: break
            }
        }
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
                    Text(library.documentGrid.total.formatted()).font(.caption.monospacedDigit())
                        .countsOnChange(library.documentGrid.total)
                        .foregroundStyle(.secondary)
                }
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
                    if !library.documentGrid.loading, scope == nil || scope == .all,
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
        guard let id = preview.selectedID else { return library.canGenerateSummaries }
        return library.canGenerateSummaries && library.bookmarkFetch(for: id) == nil
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
            fileDocument: { _ in withAnimation(.snappy(duration: 0.25)) { showingFiling = true } }
        )
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureList: some View {
        let failed = library.captureJobs.filter { $0.state == .failed }
        let others = library.captureJobs.filter { $0.state != .failed }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Captures").font(.title3.weight(.semibold)).padding(18)
            Divider()
            if library.captureJobs.isEmpty {
                ContentUnavailableView(
                    "No captures yet",
                    systemImage: "tray",
                    description: Text("Save a URL in Chat or import a document.")
                )
            } else {
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
            }
        }.navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 480)
    }

    private func captureRow(_ job: CaptureJob) -> some View {
        let failed = job.state == .failed
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
                Text(job.request.label).font(.headline).lineLimit(2)
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
        .accessibilityElement(children: .contain)
    }

    private var pageRange: Range<Int> {
        let start = min(page * DocumentGridModel.pageSize, library.documentGrid.total)
        return start ..< min(start + DocumentGridModel.pageSize, library.documentGrid.total)
    }

    private var emptyListMessage: String {
        if !library.documentGrid.query.isEmpty {
            return "Try another term or choose All items to search more broadly."
        }
        if case .category = scope {
            return "Nothing is filed in \(scopeTitle) yet. File an item from its detail pane, or ask the librarian in Chat."
        }
        return "Save a source in Chat or import a document. Unfiled items can be assigned a filing home."
    }

    private var scopeTitle: String {
        switch scope ?? .all {
        case .all: "All items"
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
    case map, list
}

private struct LibraryDocumentRow: View {
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
            Image(systemName: document.kind == "source" ? "doc.text" : "note.text")
                .foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.name).font(.body.weight(.medium)).lineLimit(2)
                Text([document.kindLabel, document.sourceURL?.host].compactMap(\.self)
                    .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
    case library(LibraryScope)
}
