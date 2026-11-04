import SwiftUI

struct LibraryGraphView: View {
    @Bindable var graph: LibraryGraphModel
    let store: DocumentStore
    let refreshToken: Int
    let scope: LibraryScope
    @Binding var kind: LibraryKindFilter
    @Binding var query: String
    @Binding var focus: UUID?
    var openNote: (UUID) -> Void
    var openSource: (SourceCitation) -> Void
    @State private var retry = 0
    private static let inspectorWidth: CGFloat = 300

    private var request: LibraryGraphRequest {
        LibraryGraphRequest(
            scope: scope,
            kind: kind,
            query: query,
            focus: focus,
            depth: graph.depth,
            includesConcepts: graph.includesConcepts,
            limit: max(
                200,
                graph.visibleLimit
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = graph.error {
                ContentUnavailableView {
                    Label("Connections unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { retry += 1 }
                }
            } else if graph.loading, graph.snapshot.nodes.isEmpty {
                WorkingProgress("Loading connections…").frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            } else if graph.snapshot.nodes.isEmpty {
                ContentUnavailableView(
                    "No items in this graph",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Change the search or Library scope to see more items.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                KnowledgeGraphView(
                    graph: graph, openNote: openNote,
                    excerpt: { id in
                        guard let document = try? await store.document(id: id)
                        else { return nil }
                        return ReferencePeek.excerpt(from: document.markdown)
                    },
                    showsDocumentLegend: true, camera: $graph.camera
                )
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                // The graph fits itself to what's left, so the inspector can't cover any of it.
                .padding(.trailing, graph.inspectorVisible ? Self.inspectorWidth + 24 : 0)
                .overlay(alignment: .topLeading) { controls.padding(12) }
                .overlay(alignment: .trailing) { inspector }
            }
        }
        .task(id: LibraryGraphLoadKey(request: request, revision: refreshToken, retry: retry)) {
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            await graph.load(from: store, request: request)
        }
        .onDisappear { graph.stop() }
        .onExitCommand { query = "" }
    }
}

private extension LibraryGraphView {
    /// Floats over the canvas, so the graph keeps the whole panel.
    var controls: some View {
        HStack(spacing: 12) {
            if focus != nil {
                Button("All Connections", systemImage: "arrow.left") { focus = nil }
                    .buttonStyle(.borderless)
                Picker("Neighborhood", selection: $graph.depth) {
                    Text("Direct").tag(1)
                    Text("2 hops").tag(2)
                }.pickerStyle(.segmented).fixedSize()
            }
            Toggle("Entities", isOn: $graph.includesConcepts).toggleStyle(.switch)
                .controlSize(.small)
                .help("Include saved, evidence-backed entities. No analysis is started.")
            GraphArrangementControl(graph: graph)
            Button(
                graph.inspectorVisible ? "Hide graph inspector" : "Show graph inspector",
                systemImage: graph.inspectorVisible
                    ? "rectangle.righthalf.inset.filled" : "sidebar.right"
            ) {
                graph.inspectorVisible.toggle()
            }
            .buttonStyle(PageIconButtonStyle())
            .help(graph.inspectorVisible ? "Hide graph inspector" : "Show graph inspector")
            .accessibilityValue(graph.inspectorVisible ? "Shown" : "Hidden")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder var inspector: some View {
        if graph.inspectorVisible {
            LibraryGraphDetails(
                graph: graph, openNote: openNote, openSource: openSource,
                focusNote: { focus = $0 }, close: { graph.inspectorVisible = false }
            )
            .frame(width: Self.inspectorWidth)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1 / 2)
            }
            .padding(12)
        }
    }
}

private struct LibraryGraphLoadKey: Equatable {
    let request: LibraryGraphRequest
    let revision: Int
    let retry: Int
}

struct NoteConnectionsView: View {
    let noteID: UUID
    let store: DocumentStore
    let refreshToken: Int
    var explore: ((UUID) -> Void)?
    var openNote: (UUID) -> Void
    var openSource: (SourceCitation) -> Void
    @State private var graph = LibraryGraphModel()
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Connections").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if let explore {
                    Button(
                        "Explore in Graph",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    ) { explore(noteID) }
                        .buttonStyle(.borderless)
                }
            }
            if let error = graph.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button("Retry") { retry += 1 }
            } else if graph.loading, graph.snapshot.nodes.isEmpty {
                WorkingProgress("Loading connections…")
            } else {
                if !graph.snapshot.edges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Graph").font(.subheadline.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            GraphArrangementControl(graph: graph)
                        }.padding(.horizontal, 10)
                        KnowledgeGraphView(
                            graph: graph,
                            openNote: openNote,
                            compact: true,
                            camera: $graph.camera
                        )
                        .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
                        GraphDocumentLegend()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Connection graph")
                }
                LibraryGraphDetails(
                    graph: graph,
                    openNote: openNote,
                    openSource: openSource,
                    compact: true
                )
                if graph.snapshot.nodes.count < graph.snapshot.totalNodes {
                    Text(
                        "Showing \(graph.snapshot.nodes.count) of \(graph.snapshot.totalNodes) connected items. Explore in Graph to expand."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(noteID)/\(refreshToken)/\(retry)") {
            await graph.load(from: store, request: LibraryGraphRequest(focus: noteID, limit: 30))
        }
        .onDisappear { graph.stop() }
    }
}
