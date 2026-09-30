import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var library: LibraryModel
    @State private var importing = false
    @State private var preview: MarkdownDocument?
    @State private var source: SourceCitation?
    @State private var searchDetails = false
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        knowledgeCanvas
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("Sink")
            .focusedSceneValue(\.sinkActions, SinkActions(
                enabled: library.ready && !library.busy,
                newNote: { preview = MarkdownDocument(
                    name: "Untitled.md",
                    markdown: ""
                ) },
                attach: { importing = true },
                focus: { inputFocused = true }
            ))
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                if !files.isEmpty {
                    Task { await library.importFiles(files) }
                }
                let links = urls.filter { !$0.isFileURL }
                if let link = links
                    .first
                {
                    library.query = link.absoluteString; inputFocused = true
                }
                if links
                    .count >
                    1
                {
                    library
                        .error = "Drop one web link at a time. The first link is in the input box."
                }
                return !urls.isEmpty
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [
                .pdf, .html, .plainText, UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "markdown") ?? .plainText,
            ], allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls): Task { await library.importFiles(urls) }
                case let .failure(error): library.error = error.localizedDescription
                }
            }
            .sheet(item: $preview) { NoteEditor(document: $0, library: library) }
            .sheet(item: $source) { CaptureSourceView(citation: $0, library: library) }
            .sheet(item: $library.browserJob) { job in
                if let url = job.request.url, let target = try? MediaTarget.parse(url) {
                    SocialBrowserView(job: job, target: target, library: library)
                }
            }
            .sheet(item: $library.audioJob) { AudioOptionsView(job: $0, library: library) }
            .task { await library.load(); inputFocused = true }
            .task(id: library.captureNotice?.id) {
                guard let notice = library.captureNotice else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, library.captureNotice?.id == notice.id else { return }
                while library.graph.jobs.contains(where: {
                    $0.noteID == notice.noteID && $0.state != "ready"
                }) {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, library.captureNotice?.id == notice.id else { return }
                }
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled, library.captureNotice?.id == notice.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { library.captureNotice = nil }
            }
            .onExitCommand {
                if library.graph.canvasMode == .mindMap,
                   library.graph.selectedMapNodeID != nil
                {
                    library.graph.deselectMapNode()
                } else if library.graph.selection == nil {
                    library.graph.overview()
                } else {
                    library.graph.deselect()
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    library.refreshIntelligence()
                }
            }
    }

    private var knowledgeCanvas: some View {
        Group {
            if library.graph.canvasMode == .mindMap, !library.graph.mindMap.nodes.isEmpty {
                MindMapView(graph: library.graph)
            } else {
                KnowledgeGraphView(graph: library.graph, openNote: openNote)
            }
        }
        .overlay {
            GeometryReader { geometry in
                Group {
                    if library.graph.canvasMode == .mindMap {
                        MindMapInspector(
                            library: library,
                            openNote: openNote,
                            openSource: { source = $0 }
                        )
                    } else {
                        GraphInspector(
                            library: library,
                            openNote: openNote,
                            openSource: { source = $0 }
                        )
                    }
                }
                .frame(maxHeight: max(180, geometry.size.height - 32), alignment: .top)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .overlay(alignment: .top) {
            if !library.graph.mindMap.nodes.isEmpty {
                Picker("Knowledge view", selection: Binding(
                    get: { library.graph.canvasMode },
                    set: { library.graph.showCanvas($0) }
                )) {
                    ForEach(KnowledgeCanvasMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 12)
            }
        }
    }

    private func openNote(_ id: UUID) {
        preview = library.documents.first { $0.id == id }
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if let error = library.error ?? library.indexingError ?? library.graph.error {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small).foregroundStyle(.secondary)
                    Text(error).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if library.indexingError != nil {
                        Button("Retry indexing") { library.startIndexing() }
                            .buttonStyle(.bordered).controlSize(.small).disabled(library.indexing)
                    } else if let job = failedCapture {
                        Button("Retry") { Task { await library.retryCapture(job.id) } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Button("Dismiss error", systemImage: "xmark") {
                        library.error = nil; library.indexingError = nil; library.graph.error = nil
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 18, height: 18)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
            }
            HStack(alignment: .center, spacing: 10) {
                Button("Attach documents", systemImage: "paperclip") { importing = true }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(!library.ready || library.busy)
                    .help("Attach PDF, HTML, Markdown, or text · ⌘O")
                TextField(
                    "Save a link or thought. Ask your library a question.",
                    text: $library.query
                )
                .textFieldStyle(.plain).font(.body)
                .focused($inputFocused)
                .accessibilityLabel("Capture or search input")
                .accessibilityHint(
                    "Return ingests links and searches other text. Command Return saves. Command Shift Return searches."
                )
                .onSubmit { submitInput() }
                .onChange(of: library.query) { library.clearResults() }
                if library.hasSearched {
                    Button("\(library.matches.count) passage matches") { searchDetails.toggle() }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                        .popover(isPresented: $searchDetails) {
                            GraphSearchResults(
                                library: library,
                                focusNote: { id in
                                    searchDetails = false; library.graph.focus(noteID: id)
                                },
                                openNote: { id in searchDetails = false; openNote(id) },
                                openSource: { citation in
                                    searchDetails = false; source = citation
                                }
                            )
                        }
                }
                if let captureProgressText {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.to.line")
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        Text(captureProgressText)
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .transition(.opacity)
                }
                Button("Search", systemImage: "magnifyingglass") {
                    Task { await library.search() }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(inputDisabled || library.documents.isEmpty)
                .help("Search · ⌘⇧Return")
                Button("Save to Sink", systemImage: "arrow.down.to.line") {
                    Task { await library.captureInput() }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .foregroundStyle(inputDisabled ? Color.secondary : Color.accentColor)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(inputDisabled)
                .help("Save to Sink · Return")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 46)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                inputFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.09),
                lineWidth: 1
            ))
            if !library.ready {
                Button("Retry opening library") { Task { await library.load() } }
                    .controlSize(.small).disabled(library.busy)
            }
        }
        .frame(maxWidth: 760).padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .top) {
            if let job = activeGraphJob {
                graphProgress(job).offset(y: -52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = library.captureNotice {
                captureNotice(notice).offset(y: -52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: activeGraphJob?.id)
        .animation(.easeOut(duration: 0.2), value: library.captureNotice?.id)
        .animation(.easeOut(duration: 0.15), value: captureProgressText)
    }

    private var activeGraphJob: GraphJob? {
        library.graph.jobs.first {
            ["queued", "running", "curating"].contains($0.state)
        }
    }

    private func graphProgress(_ job: GraphJob) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .imageScale(.small).foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text("Building graph for \(job.name)").font(.callout.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: 240, alignment: .leading)
            if job.total > 0, job.state != "curating" {
                ProgressView(value: Double(job.completed), total: Double(job.total))
                    .progressViewStyle(.linear).frame(width: 110)
            } else {
                ProgressView().progressViewStyle(.linear).frame(width: 110)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .help(job.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Building graph for \(job.name)")
        .accessibilityValue(library.graph.initialBuildStatus)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }

    private func captureNotice(_ notice: CaptureNotice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.small).foregroundStyle(.secondary)
            Text(notice.title).font(.callout.weight(.semibold)).lineLimit(1)
            Button("Open") {
                library.captureNotice = nil
                openNote(notice.noteID)
            }
            .buttonStyle(.borderless).controlSize(.small)
            Button("Dismiss", systemImage: "xmark") { library.captureNotice = nil }
                .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 18, height: 18)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .help(notice.noteName)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
        .accessibilityElement(children: .contain)
    }

    private func submitInput() {
        guard !inputDisabled else { return }
        Task { await library.submitInput() }
    }

    private var captureProgressText: String? {
        guard let job = library.captureJobs.first(where: { !$0.state.terminal }) else { return nil }
        return switch job.state {
        case .queued: "Starting…"
        case .fetching: "Fetching…"
        case .extracting: "Processing…"
        default: nil
        }
    }

    private var failedCapture: CaptureJob? {
        library.captureJobs.first { $0.state == .failed && $0.recovery == nil }
    }

    private var inputDisabled: Bool {
        library.busy || !library.ready || library.query
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
