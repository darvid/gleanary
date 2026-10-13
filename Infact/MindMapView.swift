import SwiftUI

struct MindMapView: View {
    @Bindable var graph: KnowledgeGraphModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale = 1.0
    @State private var pan = CGSize.zero
    @State private var dragOrigin: CGSize?
    @State private var zoomOrigin: Double?
    @State private var showingMapPicker = false
    @State private var mapQuery = ""

    var body: some View {
        GeometryReader { geometry in
            let layout = MindMapLayout(snapshot: graph.mindMap)
            ZStack {
                Color.black
                Canvas { context, size in
                    for edge in layout.edges {
                        guard let source = layout.positions[edge.0],
                              let target = layout.positions[edge.1] else { continue }
                        let start = point(source, size: size)
                        let end = point(target, size: size)
                        var path = Path()
                        path.move(to: CGPoint(x: start.x + 108 * scale, y: start.y))
                        let finish = CGPoint(x: end.x - 108 * scale, y: end.y)
                        let middle = (start.x + finish.x) / 2
                        path.addCurve(
                            to: finish,
                            control1: CGPoint(x: middle, y: start.y),
                            control2: CGPoint(x: middle, y: finish.y)
                        )
                        let selected = edge.0 == graph.selectedMapNodeID ||
                            edge.1 == graph.selectedMapNodeID
                        context.stroke(
                            path,
                            with: .color(selected ? .accentColor : .secondary.opacity(0.42)),
                            lineWidth: selected ? 2 : 1
                        )
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    if dragOrigin == nil {
                        dragOrigin = pan
                    }
                    let origin = dragOrigin ?? .zero
                    pan = CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    )
                }.onEnded { _ in dragOrigin = nil })
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if zoomOrigin == nil {
                        zoomOrigin = scale
                    }
                    scale = min(2.2, max(0.35, (zoomOrigin ?? 1) * value.magnification))
                }.onEnded { _ in zoomOrigin = nil })
                .onTapGesture { graph.deselectMapNode() }

                ForEach(layout.nodes) { node in
                    if let position = layout.positions[node.id] {
                        mapNode(
                            node,
                            childCount: graph.mindMap.nodes.count { $0.parentID == node.id }
                        )
                        .frame(width: 216)
                        .scaleEffect(scale)
                        .position(point(position, size: geometry.size))
                    }
                }
            }
            .background {
                MouseWheelZoom { delta, location in
                    zoom(by: delta, around: location, size: geometry.size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topLeading) {
                if !graph.mindMap.title.isEmpty {
                    mindMapPicker
                        .padding(12)
                        .frame(
                            maxWidth: max(220, geometry.size.width / 2 - 180),
                            alignment: .leading
                        )
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 12) {
                    Button("Fit map", systemImage: "arrow.up.left.and.arrow.down.right") {
                        fit(layout: layout, size: geometry.size)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Fit map")
                    Button("Zoom out", systemImage: "minus") { scale = max(0.35, scale * 0.82) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    Text("\(Int(scale * 100))%").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 42)
                    Button("Zoom in", systemImage: "plus") { scale = min(2.2, scale * 1.18) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(18)
            }
            .onChange(of: graph.mindMap.noteID, initial: true) {
                if reduceMotion {
                    fit(layout: layout, size: geometry.size)
                } else {
                    withAnimation(.easeOut(duration: 0.24)) {
                        fit(layout: layout, size: geometry.size)
                    }
                }
            }
        }
    }

    private var filteredMindMaps: [MindMapSummary] {
        let query = mapQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return graph.mindMaps }
        return graph.mindMaps.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var mindMapPicker: some View {
        Button {
            showingMapPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(graph.mindMap.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(
                        "\(graph.mindMaps.count) \(graph.mindMaps.count == 1 ? "mind map" : "mind maps")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose mind map. Current source: \(graph.mindMap.title)")
        .popover(isPresented: $showingMapPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find a source", text: $mapQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredMindMaps.isEmpty {
                            Text("No matching sources")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                        ForEach(filteredMindMaps) { map in
                            Button {
                                graph.selectMindMap(map.id)
                                showingMapPicker = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: map.id == graph.mindMap.noteID
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(map.id == graph.mindMap.noteID
                                            ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(map.title).lineLimit(2)
                                        Text(map.generatedAt, style: .relative)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            .padding(12)
            .frame(width: 360)
        }
        .onChange(of: showingMapPicker) {
            if !showingMapPicker {
                mapQuery = ""
            }
        }
    }

    private func mapNode(_ node: MindMapNode, childCount: Int) -> some View {
        let selected = node.id == graph.selectedMapNodeID
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(roleColor(node.role)).frame(width: 8, height: 8)
                Text(node.title).font(node.depth == 0 ? .headline : .callout.weight(.semibold))
                    .lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 2)
                if childCount > 0 {
                    Button { graph.toggleMapNode(node.id) } label: {
                        HStack(spacing: 4) {
                            Text("\(childCount)").font(.caption.monospacedDigit())
                            Image(systemName: node.collapsed ? "chevron.right" : "chevron.down")
                                .imageScale(.small)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        "\(node.collapsed ? "Expand" : "Collapse") branch, \(childCount) topics"
                    )
                    .help(
                        "\(node.collapsed ? "Expand" : "Collapse") \(childCount) " +
                            "\(childCount == 1 ? "topic" : "topics")"
                    )
                }
            }
            Text(node.summary).font(.caption).foregroundStyle(.secondary)
                .lineLimit(selected ? 5 : 3).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(
            Color(nsColor: selected ? .selectedContentBackgroundColor : .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(
                selected ? Color.accentColor : roleColor(node.role).opacity(0.36),
                lineWidth: selected ? 2 : 1
            )
        }
        .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { graph.selectMapNode(node.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.title). \(node.summary)")
        .accessibilityHint(childCount > 0 ?
            "Select for evidence. Branch can be expanded or collapsed." : "Select for evidence.")
    }

    private func roleColor(_ role: MindMapRole) -> Color {
        switch role {
        case .subject: .accentColor
        case .question: .orange
        case .theme: .blue
        case .mechanism: .purple
        case .evidence: .teal
        case .finding: .green
        case .tradeoff: .yellow
        case .limitation: .red
        case .application: .indigo
        }
    }

    private func point(_ position: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + position.x * scale + pan.width,
            y: size.height / 2 + position.y * scale + pan.height
        )
    }

    private func fit(layout: MindMapLayout, size: CGSize) {
        guard let bounds = layout.bounds else { return }
        let horizontal = max(1, bounds.width + 260)
        let vertical = max(1, bounds.height + 180)
        let availableHeight = max(1, size.height - 90)
        let fittedScale = min(size.width / horizontal, availableHeight / vertical)
        scale = min(1.25, max(0.6, fittedScale))
        let verticalPan = fittedScale < 0.6
            ? 55 - size.height / 2 - bounds.minY * scale
            : -(bounds.midY * scale) + 38
        pan = CGSize(width: -(bounds.midX * scale), height: verticalPan)
    }

    private func zoom(by delta: Double, around location: CGPoint, size: CGSize) {
        let old = scale
        let next = min(2.2, max(0.35, old * exp(delta * 0.002)))
        guard next != old else { return }
        let center = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        let factor = next / old
        pan.width += (location.x - center.x) * (1 - factor)
        pan.height += (location.y - center.y) * (1 - factor)
        scale = next
    }
}

private struct MindMapLayout {
    let nodes: [MindMapNode]
    let positions: [String: CGPoint]
    let edges: [(String, String)]
    let bounds: CGRect?

    init(snapshot: MindMapSnapshot) {
        let byParent = Dictionary(grouping: snapshot.nodes.compactMap { node in
            node.parentID.map { ($0, node) }
        }, by: \.0).mapValues { $0.map(\.1).sorted { $0.ordinal < $1.ordinal } }
        let collapsed = Set(snapshot.nodes.filter(\.collapsed).map(\.id))
        guard let root = snapshot.nodes.first(where: { $0.parentID == nil }) else {
            nodes = []; positions = [:]; edges = []; bounds = nil
            return
        }
        var visible: [MindMapNode] = []
        func collect(_ node: MindMapNode) {
            visible.append(node)
            guard !collapsed.contains(node.id) else { return }
            for child in byParent[node.id] ?? [] {
                collect(child)
            }
        }
        collect(root)
        var nextLeaf = 0.0
        var located: [String: CGPoint] = [:]
        @discardableResult func place(_ node: MindMapNode) -> Double {
            let children = collapsed.contains(node.id) ? [] : byParent[node.id] ?? []
            let y: Double
            if children.isEmpty {
                y = nextLeaf * 128
                nextLeaf += 1
            } else {
                let values = children.map(place)
                y = ((values.first ?? 0) + (values.last ?? 0)) / 2
            }
            located[node.id] = CGPoint(x: Double(node.depth) * 310, y: y)
            return y
        }
        _ = place(root)
        let minimumY = located.values.map(\.y).min() ?? 0
        let maximumY = located.values.map(\.y).max() ?? 0
        let centerY = (minimumY + maximumY) / 2
        located = located.mapValues { CGPoint(x: $0.x, y: $0.y - centerY) }
        nodes = visible
        positions = located
        edges = visible.compactMap { node in node.parentID.map { ($0, node.id) } }
        if let minX = located.values.map(\.x).min(), let maxX = located.values.map(\.x).max(),
           let minY = located.values.map(\.y).min(), let maxY = located.values.map(\.y).max()
        {
            bounds = CGRect(
                x: minX - 110,
                y: minY - 60,
                width: maxX - minX + 220,
                height: maxY - minY + 120
            )
        } else {
            bounds = nil
        }
    }
}
