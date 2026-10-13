import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var library: LibraryModel
    var returnToConversation: () -> Void = {}
    var useInConversation: ([UUID]) -> Void = { _ in }
    var initialSelection: UUID?
    @State private var scope: LibraryScope? = .all
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var selection: Set<UUID> = []
    @State private var page = 0
    @State private var categories: [DecimalCategory] = []
    @State private var importing = false
    @State private var editing: MarkdownDocument?
    @State private var filing: MarkdownDocument?
    @State private var preview = DocumentPreviewModel()
    @State private var source: SourceCitation?
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        library: LibraryModel,
        returnToConversation: @escaping () -> Void = {},
        useInConversation: @escaping ([UUID]) -> Void = { _ in },
        initialSelection: UUID? = nil,
        previewModel: DocumentPreviewModel? = nil
    ) {
        self.library = library
        self.returnToConversation = returnToConversation
        self.useInConversation = useInConversation
        self.initialSelection = initialSelection
        _preview = State(initialValue: previewModel ?? DocumentPreviewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = library.error ?? library.indexingError {
                errorNotice(error)
            }
            NavigationSplitView(columnVisibility: $columns) {
                sidebar.navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
            } content: {
                if scope == .captures {
                    captureList
                } else {
                    documentList
                }
            } detail: {
                if scope == .captures {
                    ContentUnavailableView(
                        "Capture recovery",
                        systemImage: "tray.and.arrow.down",
                        description: Text(
                            "Retry failed captures or inspect their saved documents. Retained originals are reused where available."
                        )
                    )
                } else {
                    detail
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
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
        .focusedSceneValue(\.infactoryActions, InfactoryActions(
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
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: returnToConversation) { Label("#general", systemImage: "chevron.left") }
                .buttonStyle(.borderless).help("Return to the conversation")
            Divider().frame(height: 18)
            Text("Library").font(.headline)
            Spacer()
            Button("New note", systemImage: "square.and.pencil") {
                editing = MarkdownDocument(name: "Untitled", markdown: "")
            }.disabled(!library.ready || library.busy)
            Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                .disabled(!library.ready || library.busy)
        }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var sidebar: some View {
        List(selection: $scope) {
            Section("Library") {
                Label("All items", systemImage: "tray.full")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.all)))
                    .tag(LibraryScope.all)
                Label("Sources", systemImage: "doc.text")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.sources)))
                    .tag(LibraryScope.sources)
                Label("Notes", systemImage: "note.text")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.notes)))
                    .tag(LibraryScope.notes)
                Label("Unfiled", systemImage: "folder.badge.questionmark")
                    .labelStyle(LibrarySidebarLabelStyle(color: sidebarColor(.unfiled)))
                    .tag(LibraryScope.unfiled)
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
                }.foregroundStyle(sidebarColor(.captures)).tag(LibraryScope.captures)
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
                        .tag(LibraryScope.category(category.id))
                        .foregroundStyle(sidebarColor(.category(category.id)))
                        .padding(.leading, category.code.contains(".") ? 10 : 0)
                        .help(category.label)
                }
            }
        }.listStyle(.sidebar).foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .accessibilityLabel("Library navigation")
    }

    private func sidebarColor(_ item: LibraryScope) -> Color {
        colorScheme == .dark || scope == item ? .white : .black
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

    private var detail: some View {
        DocumentPreview(
            model: preview,
            openSource: { source = $0 },
            summaryEnabled: library.canGenerateSummaries,
            generatingSummary: library.generatingSummaryID != nil,
            generateSummary: { library.generateSummary(for: $0) },
            cancelSummary: library.cancelSummary,
            showsLibraryDetails: true,
            openDocument: { id in selection = [id]; preview.selectedID = id },
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
