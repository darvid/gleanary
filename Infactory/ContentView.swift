import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var library: LibraryModel
    /// The #general conversation shown beside the shared sidebar; nil in library-only hosts.
    var conversation: ConversationModel?
    @State private var chatting: Bool
    var initialSelection: UUID?
    @State private var scope: LibraryScope? = .all
    @State private var sidebarVisible = true
    @State private var selection: Set<UUID> = []
    @State private var page = 0
    @State private var categories: [DecimalCategory] = []
    @State private var importing = false
    @State private var editing: MarkdownDocument?
    @State private var filing: MarkdownDocument?
    @State private var preview = DocumentPreviewModel()
    @State private var source: SourceCitation?
    @AppStorage("libraryPresentation") private var presentation = LibraryPresentation.map
    @State private var atlas = KnowledgeAtlasModel()
    /// The item opened from the Atlas; the Atlas keeps its own state underneath.
    @State private var atlasItem: UUID?
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
                sidebar.frame(width: Self.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            main.frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { notice }
        }
        // A solid titlebar like ChatGPT's: content scrolls under it but never shows through.
        .safeAreaInset(edge: .top, spacing: 0) {
            Divider().background(alignment: .bottom) {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea(edges: .top)
            }
        }
        .toolbar { toolbar }
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
            newNote: { editing = MarkdownDocument(name: "Untitled", markdown: "") },
            attach: { importing = true }, focus: { searchFocused = true }
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
                library.error = "Paste web links into #general to save and summarize them."
            }
            return !files.isEmpty
        }
        .sheet(item: $editing) { NoteEditor(document: $0, library: library) }
        .sheet(item: $filing) { document in filingSheet(document) }
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
        }
        .onChange(of: scope) {
            selection = []; preview.selectedID = nil; page = 0
            library.documentGrid.scope = scope ?? .all
            if presentation == .map {
                showInAtlas(scope ?? .all)
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

    static let sidebarWidth: CGFloat = 220

    @ViewBuilder private var main: some View {
        if chatting, let conversation {
            ConversationView(model: conversation, library: library)
        } else if presentation == .list || scope == .captures {
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
                    Spacer().frame(width: Self.titleIndent)
                    Divider().frame(height: 22)
                }
                Spacer().frame(width: 14)
                Text(chatting ? "#general" : scopeTitle).font(.headline).lineLimit(1)
            }
        }
        .sharedBackgroundVisibility(.hidden)
        if !chatting {
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
        }
    }

    /// Gap from the toggle to the sidebar's edge, given the toggle's place beside the traffic
    /// lights.
    static let titleIndent: CGFloat = 105

    @ViewBuilder private var notice: some View {
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
            }.frame(minWidth: 260, idealWidth: 330, maxWidth: 440)
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
            }.frame(minWidth: 320, maxWidth: .infinity)
        }
    }

    @ViewBuilder private var atlasPane: some View {
        if let atlasItem {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button("Atlas", systemImage: "chevron.left") { self.atlasItem = nil }
                        .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command)
                        .help("Return to the Atlas (⌘[)")
                    ForEach(atlasLocation(of: atlasItem), id: \.self) { label in
                        Image(systemName: "chevron.right").font(.caption2)
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text(label).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }.font(.callout).padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
                detail(openDocument: openFromAtlas)
            }
            .onExitCommand { self.atlasItem = nil }
        } else {
            KnowledgeAtlasView(
                atlas: atlas, store: library.store,
                refreshToken: library.documentGrid.generation, openItem: openFromAtlas
            )
        }
    }

    private func openFromAtlas(_ id: UUID) {
        atlas.selectedID = .item(id)
        preview.selectedID = id
        atlasItem = id
    }

    /// Category labels from the Library down to the item's placement in the Atlas.
    private func atlasLocation(of id: UUID) -> [String] {
        guard let position = atlas.layout.index[.item(id)] else { return [] }
        return atlas.layout.path(to: position).dropFirst().dropLast()
            .map { atlas.layout.tiles[$0].node.label }
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
        case .captures: break
        default: atlas.reset()
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            if conversation != nil {
                Label("#general", systemImage: "bubble.left.and.text.bubble.right")
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
                    let issues = library.captureJobs.filter { $0.state == .failed }.count
                    if issues >
                        0
                    {
                        Text(issues.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }.foregroundStyle(sidebarColor(.captures)).tag(SidebarItem.library(.captures))
            }
            Section("Filing") {
                ForEach(categories) { category in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name).lineLimit(1)
                            Text(category.code).font(.caption)
                                .foregroundStyle(sidebarColor(.category(category.id)).opacity(0.72))
                        }
                    } icon: { Image(systemName: "folder") }
                        .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.category(category
                                .id))))
                        .tag(SidebarItem.library(.category(category.id)))
                        .foregroundStyle(sidebarColor(.category(category.id)))
                        .padding(.leading, category.code.contains(".") ? 10 : 0)
                        .help(category.label)
                }
            }
        }.listStyle(.sidebar).foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .accessibilityLabel("Library navigation")
    }

    /// Pass nil for the conversation row.
    private func sidebarColor(_ item: LibraryScope?) -> Color {
        let selected = item.map { !chatting && scope == $0 } ?? chatting
        return colorScheme == .dark || selected ? .white : .black
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            chatting ? .conversation : scope.map(SidebarItem.library)
        } set: { item in
            switch item {
            case .conversation: chatting = true
            case let .library(scope):
                chatting = false
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
            } else if library.documentGrid.total == 0 {
                ContentUnavailableView(
                    library.documentGrid.loading ? "Loading library…" : "No items here",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(library.documentGrid.query
                        .isEmpty ?
                        "Save a source in #general or import a document. Unfiled items can be assigned a filing home." :
                        "Try another term or choose All items to search more broadly.")
                )
            } else {
                List(selection: $selection) {
                    ForEach(pageRange, id: \.self) { index in
                        if let document = library.documentGrid.document(at: index) {
                            LibraryDocumentRow(document: document).tag(document.id)
                                .contextMenu {
                                    Button("Use in #general") { useInConversation([document.id]) }
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
                Button("Use in #general", systemImage: "bubble.left") {
                    useInConversation(Array(selection).sorted { $0.uuidString < $1.uuidString })
                }
                .disabled(selection.count > 4)
                Text(selection
                    .count > 4 ? "Choose up to 4 items for one request." :
                    "Ask a question or compare these items in chat.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select items to use in #general. ⌘-click to select more than one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 18).padding(.bottom, 16)
    }

    private func detail(openDocument: ((UUID) -> Void)? = nil) -> some View {
        DocumentPreview(
            model: preview,
            openSource: { source = $0 },
            summaryEnabled: library.canGenerateSummaries,
            generatingSummary: library.generatingSummaryID != nil,
            generateSummary: { library.generateSummary(for: $0) },
            cancelSummary: library.cancelSummary,
            showsLibraryDetails: true,
            openDocument: openDocument ?? { id in selection = [id]; preview.selectedID = id },
            editDocument: { editing = $0 },
            fileDocument: { filing = $0 }, showsSummaryActions: false
        )
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Captures").font(.title3.weight(.semibold)).padding(18)
            Divider()
            if library.captureJobs.isEmpty {
                ContentUnavailableView(
                    "No captures yet",
                    systemImage: "tray",
                    description: Text("Save a URL in #general or import a document.")
                )
            } else {
                List(library.captureJobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.request.label).font(.headline).lineLimit(2)
                        Text(job
                            .error ??
                            (job.progress.isEmpty ? job.state.rawValue.capitalized : job.progress))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            if let id = job.noteID {
                                Button("Open saved item") {
                                    scope = .all; Task {
                                        await Task.yield(); selection = [id]; preview
                                            .selectedID = id
                                    }
                                }
                            }
                            if job.state == .failed || job.state == .cancelled {
                                if job
                                    .recovery ==
                                    .browser
                                {
                                    Button("Open browser") { library.browserJob = job }
                                }
                                if job
                                    .recovery ==
                                    .audio
                                {
                                    Button("Audio options") { library.audioJob = job }
                                }
                                Button("Retry") { Task { await library.retryCapture(job.id) } }
                                    .disabled(library.busy)
                            } else if !job.state.terminal {
                                Button("Stop") { Task { await library.cancelCapture(job.id) } }
                            }
                        }.controlSize(.small)
                    }.padding(.vertical, 8)
                }
            }
        }.navigationSplitViewColumnWidth(min: 260, ideal: 360, max: 480)
    }

    private var pageRange: Range<Int> {
        let start = min(page * DocumentGridModel.pageSize, library.documentGrid.total)
        return start ..< min(start + DocumentGridModel.pageSize, library.documentGrid.total)
    }

    private var scopeTitle: String {
        switch scope ?? .all {
        case .all: "All items"
        case .sources: "Sources"
        case .notes: "Notes"
        case .unfiled: "Unfiled"
        case .captures: "Captures"
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

    private func errorNotice(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(error).font(.callout).textSelection(.enabled)
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
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
    }

    private func filingSheet(_ document: MarkdownDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File item").font(.title2.weight(.semibold))
            Text(document.name).foregroundStyle(.secondary).lineLimit(2)
            List(categories) { category in
                Button(category.label) {
                    Task {
                        do {
                            let includesSource = try await library.store
                                .captureID(for: document.id) != nil
                            try await library.store.fileNote(
                                document.id,
                                categoryID: category.id,
                                includeSources: includesSource
                            )
                            filing = nil
                            await library.refreshConversationChanges()
                        } catch { library.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderless)
            }
            Text("Changes the item's primary filing home. Existing secondary memberships are kept.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { filing = nil }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 420, height: 380)
    }
}

enum LibraryPresentation: String {
    case map, list
}

private struct LibraryDocumentRow: View {
    let document: DocumentSummary

    var body: some View {
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
                if let coverage = document.coverage.flatMap(Coverage.init(rawValue:)), [
                    .partial,
                    .abstractOnly,
                    .visibleThread
                ].contains(coverage) {
                    Text(coverage.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 7).help(document.name)
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
    case library(LibraryScope)
}
