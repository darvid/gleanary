import SwiftUI

/// A contextual, keyboard-accessible alternative to the canvas.
struct LibraryGraphDetails: View {
    let graph: LibraryGraphModel
    var openNote: (UUID) -> Void
    var openSource: (SourceCitation) -> Void
    var compact = false
    var focusNote: ((UUID) -> Void)?
    var close: (() -> Void)?
    @State private var itemQuery = ""
    @State private var extraConnections = 0
    @State private var hoveredConnection: String?

    private var inspector: LibraryGraphInspector {
        LibraryGraphInspector(data: graph.data)
    }

    private var anchor: GraphNode? {
        graph.selection ?? (compact ? graph.snapshot.nodes.first {
            $0.noteID == graph.request.focus
        } : nil)
    }

    private var relationship: LibraryGraphInspector.Neighbor? {
        guard let anchor else { return nil }
        return inspector.neighbors(of: anchor.id).first { $0.id == graph.selectedEdgeID }
    }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    if let anchor {
                        if let relationship {
                            Button("Back to connections", systemImage: "chevron.left") {
                                graph.select(anchor.id)
                            }.buttonStyle(.borderless)
                            evidence(relationship)
                        } else {
                            neighborSections(for: anchor)
                        }
                    }
                }
            } else {
                ZStack {
                    // Keep the native list mounted so its search and scroll survive inspection.
                    browser
                        .opacity(anchor == nil ? 1 : 0)
                        .allowsHitTesting(anchor == nil)
                        .accessibilityHidden(anchor != nil)
                        .disabled(anchor != nil)
                    if let anchor {
                        VStack(spacing: 0) {
                            inspectorHeader(anchor)
                            Divider()
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    if let relationship {
                                        evidence(relationship)
                                    } else {
                                        neighborSections(for: anchor)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                            }.id(graph.selectedEdgeID ?? anchor.id)
                        }
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(compact ? "Note connections" : "Graph inspector")
        .onChange(of: graph.selectedID) { extraConnections = 0 }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Items in this graph").font(.headline)
                Spacer()
                Text(graph.snapshot.nodes.count.formatted()).monospacedDigit()
                    .foregroundStyle(.secondary)
                closeButton
            }.padding(16)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an item", text: $itemQuery).textFieldStyle(.plain)
                    .accessibilityLabel("Find an item in the graph list")
                if !itemQuery.isEmpty {
                    Button("Clear item search", systemImage: "xmark.circle.fill") {
                        itemQuery = ""
                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            let items = inspector.items(matching: itemQuery)
            if items.isEmpty {
                ContentUnavailableView.search(text: itemQuery)
            } else {
                List(selection: Binding<String?>(get: { graph.selectedID }, set: { id in
                    if let id {
                        graph.select(id)
                    }
                })) {
                    ForEach(items) { node in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: inspector.symbol(for: node))
                                .foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(node.label).font(.body.weight(.medium))
                                    .lineLimit(2).foregroundStyle(.primary)
                                Text(
                                    "\(inspector.kind(of: node)) · \(countLabel(inspector.connectionCount(for: node.id)))"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .tag(node.id)
                        .help(node.label)
                        .accessibilityHint("Select to inspect connections")
                    }
                }.listStyle(.inset)
            }
        }
    }

    private func inspectorHeader(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if relationship != nil {
                    Button("Connections", systemImage: "chevron.left") { graph.select(node.id) }
                        .help("Back to connections for \(node.label)")
                } else {
                    Button("All items", systemImage: "chevron.left") { graph.deselect() }
                }
                Spacer()
                closeButton
            }.buttonStyle(.borderless)
            if relationship == nil {
                Text(node.label).font(.headline).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(
                    "\(inspector.kind(of: node)) · \(countLabel(inspector.connectionCount(for: node.id)))"
                )
                .font(.caption).foregroundStyle(.secondary)
                if let id = node.noteID {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { noteActions(id, node: node) }
                        VStack(alignment: .leading, spacing: 8) { noteActions(id, node: node) }
                    }
                }
            } else {
                Text(node.label).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16)
    }

    @ViewBuilder private var closeButton: some View {
        if let close {
            Button("Hide graph inspector", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }

    @ViewBuilder private func noteActions(_ id: UUID, node: GraphNode) -> some View {
        Button("Open \(inspector.kind(of: node).lowercased())", systemImage: "doc.text") {
            openNote(id)
        }
        if let focusNote {
            Button("Focus in graph", systemImage: "scope") { focusNote(id) }
        }
    }

    private func neighborSections(for node: GraphNode) -> some View {
        let neighbors = inspector.neighbors(of: node.id)
        let limit = (compact ? 8 : 40) + extraConnections
        return VStack(alignment: .leading, spacing: 20) {
            if neighbors.isEmpty {
                Text("No connections in this view.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(LibraryGraphInspector.Group.allCases) { group in
                let rows = neighbors.filter { $0.group == group }
                let visible = Array(neighbors.prefix(limit)).filter { $0.group == group }
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(group.rawValue).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(rows.count.formatted()).font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }.accessibilityAddTraits(.isHeader)
                        ForEach(visible) { neighbor in
                            Button {
                                graph.select(node.id, edgeID: neighbor.id)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: inspector.symbol(for: neighbor.node))
                                        .foregroundStyle(.secondary).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(neighbor.node.label).font(.body.weight(.medium))
                                            .foregroundStyle(.primary).lineLimit(2)
                                        Text(neighbor.relationship).font(.caption)
                                            .foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).multilineTextAlignment(.leading)
                            .background(
                                hoveredConnection == neighbor.id ? Color.primary
                                    .opacity(0.06) : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .onHover { hoveredConnection = $0 ? neighbor.id : nil }
                            .help("Inspect connection to \(neighbor.node.label)")
                            .accessibilityHint("Shows why these items are connected")
                            Divider()
                        }
                    }
                }
            }
            if neighbors.count > limit {
                Button("Show more connections") { extraConnections += compact ? 8 : 40 }
            }
        }
    }

    private func evidence(_ neighbor: LibraryGraphInspector.Neighbor) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(neighbor.node.label).font(.headline).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(neighbor.relationship).font(.callout).foregroundStyle(.secondary)
            if let id = neighbor.node.noteID {
                HStack(spacing: 8) {
                    Button(
                        "Open \(inspector.kind(of: neighbor.node).lowercased())",
                        systemImage: "doc.text"
                    ) { openNote(id) }
                    Button("Select in graph", systemImage: "scope") {
                        graph.select(neighbor.node.id)
                    }
                    .labelStyle(.iconOnly).help("Select \(neighbor.node.label) in graph")
                }
            }
            Divider()
            Text("Why they’re connected").font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let reason = neighbor.connection.reasons.first {
                reasonRow(reason)
                if neighbor.connection.reasons.count > 1 {
                    DisclosureGroup(
                        "\(neighbor.connection.reasons.count - 1) more supporting \(neighbor.connection.reasons.count == 2 ? "entry" : "entries")"
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(neighbor.connection.reasons.dropFirst()) { reason in
                                reasonRow(reason)
                            }
                        }.padding(.top, 8)
                    }.font(.callout)
                }
            } else {
                Text("Evidence is outside this view’s limit. Narrow the graph to inspect it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if graph.data.truncatedReasons {
                Text("Evidence is limited to 2,400 entries. Narrow the graph to inspect more.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reasonRow(_ reason: LibraryGraphReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason.text).font(.callout).textSelection(.enabled)
            Text(reason.label).font(.caption).foregroundStyle(.secondary)
            if let citation = reason.citation {
                Button("View evidence") { openSource(citation) }.controlSize(.small)
            } else if let id = reason.noteID {
                Button("View evidence") { openNote(id) }.controlSize(.small)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countLabel(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "connection" : "connections")"
    }
}
