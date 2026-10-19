import SwiftUI

struct KnowledgeGraphView<Graph: GraphCanvasModel>: View {
    @Bindable var graph: Graph
    let openNote: (UUID) -> Void
    var compact = false
    var camera: Binding<GraphCamera?>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var scale = 1.0
    @State private var pan = CGSize.zero
    @State private var dragOrigin: CGSize?
    @State private var draggedNode: String?
    @State private var zoomOrigin: Double?
    @State private var keyboardNode: String?
    @State private var hasFitted = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Canvas { context, size in
                    drawEdges(in: &context, size: size)
                    drawNodes(in: &context, size: size)
                }
                .contentShape(Rectangle())
                .focusable().focusEffectDisabled().focused($focused)
                .accessibilityLabel("Knowledge graph")
                .accessibilityHint(
                    "Use arrow keys to choose a node and Return to inspect it. Drag empty space to pan; pinch or use the mouse wheel to zoom."
                )
                .accessibilityChildren {
                    ForEach(graph.snapshot.nodes) { node in
                        Button("\(node.label), \(node.kind.rawValue)") { graph.select(node.id) }
                    }
                }
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    if let node = hitNode(value.location, size: geometry.size),
                       let id = node.noteID
                    {
                        openNote(id)
                    }
                }.exclusively(before: SpatialTapGesture().onEnded { value in
                    focused = true
                    if let node = hitNode(value.location, size: geometry.size) {
                        keyboardNode = node.id; graph.select(node.id)
                    } else if let edge = hitEdge(value.location, size: geometry.size) {
                        graph.select(edge.source, edgeID: edge.id)
                    } else {
                        keyboardNode = nil; graph.deselect()
                    }
                }))
                .simultaneousGesture(drag(size: geometry.size))
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if zoomOrigin == nil {
                        zoomOrigin = scale
                    }
                    scale = min(3, max(0.15, (zoomOrigin ?? 1) * value.magnification))
                }.onEnded { _ in zoomOrigin = nil })
                .onKeyPress(keys: [
                    .leftArrow,
                    .upArrow,
                    .rightArrow,
                    .downArrow,
                    .return,
                    .escape,
                ]) { press in
                    // Modified Return belongs to Save/Search, even when the canvas has focus.
                    guard press.modifiers.isEmpty else { return .ignored }
                    switch press.key {
                    case .return:
                        if let id = keyboardNode ?? graph.snapshot.nodes.first?
                            .id
                        {
                            graph.select(id)
                        }
                    case .escape: keyboardNode = nil; graph.deselect()
                    case .leftArrow, .upArrow: navigate(-1)
                    default: navigate(1)
                    }
                    return .handled
                }
            }
            .background {
                if !compact {
                    MouseWheelZoom { delta, location in
                        zoom(by: delta, around: location, size: geometry.size)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .topLeading) {
                if let overview = graph.overviewAction {
                    Button(
                        graph.scopeLabel,
                        systemImage: "arrow.left"
                    ) { overview() }
                        .lineLimit(1).frame(maxWidth: 400, alignment: .leading).padding(18)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !graph.preparingInitialGraph, !graph.snapshot.nodes.isEmpty {
                    controls(size: geometry.size).padding(18)
                }
            }
            .onAppear {
                if let saved = camera?.wrappedValue {
                    scale = saved.scale
                    pan = saved.pan
                    hasFitted = true
                } else if !graph.positions.isEmpty, !graph.layingOut {
                    fit(size: geometry.size)
                    hasFitted = true
                }
            }
            .onChange(of: scale) { saveCamera() }
            .onChange(of: pan) { saveCamera() }
            .onChange(of: graph.cameraReset) { hasFitted = false; fit(size: geometry.size) }
            .onChange(of: graph.layingOut) { _, running in
                if !running, !hasFitted,
                   dragOrigin == nil
                {
                    fit(size: geometry.size); hasFitted = true
                }
            }
            .onChange(of: geometry.size) { fit(size: geometry.size) }
            .onChange(of: reduceMotion, initial: true) {
                graph.reduceMotion = reduceMotion
                if reduceMotion, graph.layingOut {
                    graph.startLayout()
                }
            }
        }
    }

    private func saveCamera() {
        camera?.wrappedValue = GraphCamera(scale: scale, pan: pan)
    }

    private func point(_ id: String, size: CGSize) -> CGPoint? {
        guard let position = graph.positions[id] else { return nil }
        return CGPoint(
            x: size.width / 2 + position.x * scale + pan.width,
            y: size.height / 2 + position.y * scale + pan.height
        )
    }

    private func drawEdges(in context: inout GraphicsContext, size: CGSize) {
        for edge in graph.snapshot.edges {
            guard let start = point(edge.source, size: size), let end = point(
                edge.target,
                size: size
            ) else { continue }
            let highlighted = edge.id == graph.selectedEdgeID || edge.source == keyboardNode || edge
                .target == keyboardNode
            let inferred = ![GraphPredicate.linksTo, .authoredBy, .relatedTo, .derivedFrom]
                .contains(edge.predicate)
            var path = Path(); path.move(to: start); path.addLine(to: end)
            context.stroke(
                path,
                with: .color(highlighted ? .accentColor : .secondary
                    .opacity(contrast == .increased ? 0.9 : 0.5)),
                style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: inferred ? [4, 4] : [])
            )
            if highlighted, edge.predicate != .relatedTo {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let tip = CGPoint(x: end.x - cos(angle) * 15, y: end.y - sin(angle) * 15)
                var arrow = Path(); arrow.move(to: CGPoint(
                    x: tip.x - cos(angle - 0.5) * 9,
                    y: tip.y - sin(angle - 0.5) * 9
                ))
                arrow.addLine(to: tip); arrow.addLine(to: CGPoint(
                    x: tip.x - cos(angle + 0.5) * 9,
                    y: tip.y - sin(angle + 0.5) * 9
                ))
                context.stroke(arrow, with: .color(.accentColor), lineWidth: 2)
            }
        }
    }

    private func drawNodes(in context: inout GraphicsContext, size: CGSize) {
        var labelRects: [CGRect] = []
        // Important labels reserve their space before peripheral labels.
        let nodes = graph.snapshot.nodes.sorted { priority($0) > priority($1) }
        for node in nodes {
            guard let center = point(node.id, size: size) else { continue }
            let selected = node.id == graph.selectedID || node.id == keyboardNode
            let matched = graph.snapshot.matchingIDs.contains(node.id)
            let radius = nodeRadius(node.kind)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let color = nodeColor(node.kind)
            if matched {
                context.fill(
                    nodePath(node.kind, in: rect.insetBy(dx: -7, dy: -7)),
                    with: .color(color.opacity(0.2))
                )
            }
            let shape = nodePath(node.kind, in: rect)
            context.fill(shape, with: .color(color))
            if contrast == .increased {
                context.stroke(shape, with: .color(.primary.opacity(0.8)), lineWidth: 1)
            }
            if selected {
                context.stroke(
                    nodePath(node.kind, in: rect.insetBy(dx: -5, dy: -5)),
                    with: .color(.accentColor),
                    lineWidth: 2
                )
            }
            let label = String(node.label.prefix(38)) + (node.label.count > 38 ? "…" : "")
            let text = context.resolve(Text(label).font(.system(
                size: selected ? 13 : 12,
                weight: selected || matched ? .semibold : .regular
            )).foregroundStyle(.primary))
            let measured = text.measure(in: CGSize(width: 240, height: 40))
            let labelRect = CGRect(
                x: center.x - measured.width / 2,
                y: center.y + 16,
                width: measured.width,
                height: measured.height
            )
            if selected || matched || !labelRects.contains(where: { $0.intersects(labelRect.insetBy(
                dx: -5,
                dy: -3
            )) }) {
                context.fill(
                    Path(roundedRect: labelRect.insetBy(dx: -3, dy: -1), cornerRadius: 3),
                    with: .color(Color(nsColor: .windowBackgroundColor))
                )
                context.draw(text, at: CGPoint(x: center.x, y: center.y + 16), anchor: .top)
                labelRects.append(labelRect)
            }
        }
    }

    private func nodeRadius(_ kind: GraphNode.Kind) -> Double {
        switch kind {
        case .concept: 7
        case .person: 7.5
        case .organization, .tool: 8
        case .document: 10
        }
    }

    private func nodeColor(_ kind: GraphNode.Kind) -> Color {
        switch (kind, colorScheme) {
        case (.concept, .light): Color(red: 57 / 255, green: 115 / 255, blue: 198 / 255)
        case (.concept, .dark): Color(red: 110 / 255, green: 168 / 255, blue: 247 / 255)
        case (.person, .light): Color(red: 184 / 255, green: 100 / 255, blue: 34 / 255)
        case (.person, .dark): Color(red: 232 / 255, green: 154 / 255, blue: 85 / 255)
        case (.organization, .light): Color(red: 22 / 255, green: 133 / 255, blue: 120 / 255)
        case (.organization, .dark): Color(red: 85 / 255, green: 194 / 255, blue: 179 / 255)
        case (.tool, .light): Color(red: 118 / 255, green: 86 / 255, blue: 181 / 255)
        case (.tool, .dark): Color(red: 169 / 255, green: 138 / 255, blue: 229 / 255)
        case (.document, _): .secondary
        @unknown default: .secondary
        }
    }

    private func nodePath(_ kind: GraphNode.Kind, in rect: CGRect) -> Path {
        switch kind {
        case .concept:
            Path(ellipseIn: rect)
        case .person:
            Path(roundedRect: rect, cornerRadius: rect.width * 0.35)
        case .organization:
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.25))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.25))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.25))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25))
                path.closeSubpath()
            }
        case .tool:
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.closeSubpath()
            }
        case .document:
            Path(roundedRect: rect, cornerRadius: 3)
        }
    }

    private func priority(_ node: GraphNode) -> Int {
        if node.id == graph.selectedID || node.id == keyboardNode {
            return 3
        }
        if graph.snapshot.matchingIDs.contains(node.id) {
            return 2
        }
        return node.kind == .document ? 1 : 0
    }

    private func hitNode(_ location: CGPoint, size: CGSize) -> GraphNode? {
        graph.snapshot.nodes.min { left, right in
            distance(location, point(left.id, size: size)) < distance(
                location,
                point(right.id, size: size)
            )
        }.flatMap { distance(location, point($0.id, size: size)) <= 24 ? $0 : nil }
    }

    private func hitEdge(_ location: CGPoint, size: CGSize) -> GraphEdge? {
        graph.snapshot.edges.first { edge in
            guard let start = point(edge.source, size: size), let end = point(
                edge.target,
                size: size
            ) else { return false }
            let dx = end.x - start.x, dy = end.y - start.y
            let length = dx * dx + dy * dy
            guard length > 0 else { return false }
            let fraction = min(
                1,
                max(0, ((location.x - start.x) * dx + (location.y - start.y) * dy) / length)
            )
            return distance(
                location,
                CGPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
            ) < 6
        }
    }

    private func distance(_ left: CGPoint, _ right: CGPoint?) -> Double {
        guard let right else { return .infinity }
        return hypot(left.x - right.x, left.y - right.y)
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5).onChanged { value in
            if dragOrigin == nil {
                dragOrigin = pan
                draggedNode = hitNode(value.startLocation, size: size)?.id
            }
            if let id = draggedNode {
                graph.move(
                    id,
                    to: GraphPosition(
                        x: (value.location.x - size.width / 2 - pan.width) / scale,
                        y: (value.location.y - size.height / 2 - pan
                            .height) / scale
                    )
                )
            } else {
                pan = CGSize(
                    width: (dragOrigin?.width ?? 0) + value.translation.width,
                    height: (dragOrigin?.height ?? 0) + value.translation.height
                )
            }
        }.onEnded { _ in
            if let id = draggedNode {
                graph.persistPosition(id)
            }
            dragOrigin = nil; draggedNode = nil
        }
    }

    private func navigate(_ step: Int) {
        let nodes = graph.snapshot.nodes
        guard !nodes.isEmpty else { return }
        let current = nodes.firstIndex { $0.id == keyboardNode } ?? (step > 0 ? -1 : 0)
        keyboardNode = nodes[(current + step + nodes.count) % nodes.count].id
    }

    private func zoom(by delta: CGFloat, around location: CGPoint, size: CGSize) {
        guard CGRect(origin: .zero, size: size).contains(location) else { return }
        let oldScale = scale
        let boundedDelta = min(12, max(-12, Double(delta)))
        let newScale = min(3, max(0.15, oldScale * exp(boundedDelta * 0.018)))
        guard newScale != oldScale else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let worldX = (location.x - center.x - pan.width) / oldScale
        let worldY = (location.y - center.y - pan.height) / oldScale
        pan = CGSize(
            width: location.x - center.x - worldX * newScale,
            height: location.y - center.y - worldY * newScale
        )
        scale = newScale
    }

    private func fit(size: CGSize) {
        let points = graph.positions.values
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        scale = min(
            1.3,
            max(
                0.15,
                min(
                    max(40, size.width - (compact ? 100 : 220)) / max(1, maxX - minX),
                    max(40, size.height - (compact ? 100 : 150)) / max(1, maxY - minY)
                )
            )
        )
        pan = CGSize(width: -(minX + maxX) / 2 * scale, height: -(minY + maxY) / 2 * scale)
    }

    private func controls(size: CGSize) -> some View {
        HStack(spacing: 12) {
            ControlGroup {
                Button("Zoom out", systemImage: "minus") { scale = max(0.15, scale / 1.25) }
                Button("Fit graph", systemImage: "arrow.up.left.and.arrow.down.right") {
                    fit(size: size)
                }
                Button("Zoom in", systemImage: "plus") { scale = min(3, scale * 1.25) }
            }.labelStyle(.iconOnly).fixedSize()
            if !compact {
                Text(graph.canvasCountLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !compact, graph.snapshot.nodes.count < graph.snapshot.totalNodes,
               graph.visibleLimit < 500
            {
                Button("Show more") { graph.expand() }.controlSize(.small)
            }
            if graph.snapshot.truncatedEdges {
                Text("Connections limited to 1,200").font(.caption)
            }
        }
    }
}
