import SwiftUI

struct KnowledgeGraphView<Graph: GraphCanvasModel>: View {
    @Bindable var graph: Graph
    let openNote: (UUID) -> Void
    /// The opening of a saved item's text, for the hover peek.
    var excerpt: ((UUID) async -> String?)?
    var compact = false
    var showsDocumentLegend = false
    var camera: Binding<GraphCamera?>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(GraphMarkStyle.key) private var markStyle = GraphMarkStyle.pages
    @State private var scale = 1.0
    @State private var pan = CGSize.zero
    @State private var dragOrigin: CGSize?
    @State private var draggedNode: String?
    @State private var zoomOrigin: Double?
    @State private var keyboardNode: String?
    @State private var hasFitted = false
    /// Whether you've panned or zoomed, or a remembered camera was restored. Until then the
    /// graph keeps fitting as the canvas settles to its size and the layout finishes.
    @State private var adjusted = false
    @State private var hoveredNode: String?
    /// The node whose peek is showing, after a hover dwell or Space.
    @State private var peekNode: String?
    @State private var hoveringPeek = false
    @State private var peekTimer: Task<Void, Never>?
    @State private var labelCache = GraphLabelCache()
    @FocusState private var focused: Bool

    var body: some View {
        let accessibilityPage = GraphAccessibilityPage(
            nodes: graph.snapshot.nodes,
            selectedID: graph.selectedID ?? keyboardNode
        )
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Canvas { context, size in
                    drawEdges(in: &context, size: size)
                    drawNodes(in: &context, size: size)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location): hoveredNode = hitNode(
                            location,
                            size: geometry.size
                        )?.id
                    case .ended: hoveredNode = nil
                    }
                }
                .onChange(of: hoveredNode) { _, node in
                    hoverChanged(to: node)
                }
                .popover(
                    isPresented: Binding(
                        get: { peekNode != nil },
                        set: {
                            if !$0 {
                                peekNode = nil
                            }
                        }
                    ),
                    attachmentAnchor: .rect(.rect(peekRect(size: geometry.size))),
                    arrowEdge: .bottom
                ) {
                    peek
                }
                .contentShape(Rectangle())
                .focusable().focusEffectDisabled().focused($focused)
                .accessibilityLabel("Knowledge graph")
                .accessibilityHint(
                    "Use arrow keys to choose a node and Return to inspect it. Drag empty space to pan; pinch or use the mouse wheel to zoom."
                )
                .accessibilityValue(accessibilityPage.value)
                .accessibilityChildren {
                    ForEach(accessibilityPage.nodes) { node in
                        Button(graph.accessibilityLabel(for: node)) {
                            selectAccessibleNode(node.id)
                        }
                    }
                    if let previousID = accessibilityPage.previousID {
                        Button("Previous Graph Items") { selectAccessibleNode(previousID) }
                    }
                    if let nextID = accessibilityPage.nextID {
                        Button("Next Graph Items") { selectAccessibleNode(nextID) }
                    }
                }
                // Selection must not wait for the system's double-click timeout.
                .gesture(SpatialTapGesture().onEnded { value in
                    focused = true
                    if let node = hitNode(value.location, size: geometry.size) {
                        keyboardNode = node.id; graph.select(node.id)
                    } else if let edge = hitEdge(value.location, size: geometry.size) {
                        graph.select(edge.source, edgeID: edge.id)
                    } else {
                        keyboardNode = nil; graph.deselect()
                    }
                })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                    if let node = hitNode(value.location, size: geometry.size),
                       let id = node.noteID
                    {
                        openNote(id)
                    }
                })
                .simultaneousGesture(drag(size: geometry.size))
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    hasFitted = true
                    adjusted = true
                    if zoomOrigin == nil {
                        zoomOrigin = scale
                    }
                    scale = min(3, max(0.0001, (zoomOrigin ?? 1) * value.magnification))
                }.onEnded { _ in zoomOrigin = nil })
                .onKeyPress(keys: [
                    .leftArrow,
                    .upArrow,
                    .rightArrow,
                    .downArrow,
                    .return,
                    .escape,
                    .space,
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
                    case .space:
                        peekTimer?.cancel()
                        peekNode = peekNode == nil ? keyboardNode ?? graph.selectedID : nil
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
                if showsDocumentLegend {
                    GraphDocumentLegend(usesFilingColors: graph.usesFilingColors)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(
                            Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .padding(10)
                        .allowsHitTesting(false)
                } else if let overview = graph.overviewAction {
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
                    adjusted = true
                } else if !graph.positions.isEmpty, !graph.layingOut {
                    fit(size: geometry.size)
                    hasFitted = true
                }
            }
            // The peek is anchored where the node was, so moving the canvas closes it.
            .onChange(of: scale) { peekNode = nil; saveCamera() }
            .onChange(of: pan) { peekNode = nil; saveCamera() }
            .onChange(of: graph.cameraReset) {
                if let saved = camera?.wrappedValue {
                    scale = saved.scale
                    pan = saved.pan
                    hasFitted = true
                    adjusted = true
                } else {
                    hasFitted = false
                    adjusted = false
                    fit(size: geometry.size)
                }
            }
            .onChange(of: graph.positions.isEmpty) { _, empty in
                if !empty, !hasFitted, graph.snapshot.nodes.count > 1000 {
                    fit(size: geometry.size)
                    hasFitted = true
                }
            }
            .onChange(of: graph.layingOut) { _, running in
                if !running, !adjusted, dragOrigin == nil {
                    fit(size: geometry.size); hasFitted = true
                }
            }
            // An animated layout starts as a tight cluster and spreads out. Follow it while it
            // settles, so the view eases out with the graph instead of snapping at the end.
            .onChange(of: graph.geometry.bounds) {
                if graph.layingOut, !adjusted, dragOrigin == nil {
                    fit(size: geometry.size); hasFitted = true
                }
            }
            .onChange(of: geometry.size) {
                // The canvas often first lays out narrow while the panes beside it settle.
                if !adjusted, !graph.positions.isEmpty {
                    fit(size: geometry.size)
                    hasFitted = true
                }
            }
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
        graph.geometry.point(for: id).map { viewport(size).screen($0) }
    }

    private func drawEdges(in context: inout GraphicsContext, size: CGSize) {
        let viewport = viewport(size)
        var solid = GraphDrawingBatch(), inferred = GraphDrawingBatch(),
            highlighted = GraphDrawingBatch()
        let arrows = CGMutablePath()
        for index in graph.geometry.visibleEdges(in: viewport.worldBounds()) {
            let segment = graph.geometry.segments[index], edge = segment.edge
            let start = viewport.screen(segment.start), end = viewport.screen(segment.end)
            let selected = edge.id == graph.selectedEdgeID || edge.source == keyboardNode
                || edge.target == keyboardNode || edge.source == hoveredNode || edge
                .target == hoveredNode
            if selected {
                highlighted.line(from: start, to: end)
                if edge.predicate != .relatedTo {
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let tip = CGPoint(x: end.x - cos(angle) * 15, y: end.y - sin(angle) * 15)
                    arrows.move(to: CGPoint(
                        x: tip.x - cos(angle - 0.5) * 9,
                        y: tip.y - sin(angle - 0.5) * 9
                    ))
                    arrows.addLine(to: tip)
                    arrows.addLine(to: CGPoint(
                        x: tip.x - cos(angle + 0.5) * 9,
                        y: tip.y - sin(angle + 0.5) * 9
                    ))
                }
            } else if [GraphPredicate.linksTo, .authoredBy, .relatedTo, .derivedFrom]
                .contains(edge.predicate)
            {
                solid.line(from: start, to: end)
            } else {
                inferred.line(from: start, to: end)
            }
        }
        // Faint enough that a dense graph reads as its nodes; a selection's lines stand out.
        let opacity = contrast == .increased ? 0.9 : (scale < 0.3 ? 0.12 : 0.28)
        let width = contrast == .increased ? 1 : 0.75
        for path in solid.paths {
            context.stroke(
                Path(path),
                with: .color(.secondary.opacity(opacity)),
                lineWidth: width
            )
        }
        for path in inferred.paths {
            context.stroke(
                Path(path),
                with: .color(.secondary.opacity(opacity)),
                style: StrokeStyle(lineWidth: width, dash: [3, 4])
            )
        }
        for path in highlighted.paths {
            context.stroke(
                Path(path),
                with: .color(.accentColor),
                lineWidth: 2
            )
        }
        context.stroke(Path(arrows), with: .color(.accentColor), lineWidth: 2)
    }

    private func drawNodes(in context: inout GraphicsContext, size: CGSize) {
        let nodes = graph.geometry.visibleNodes(in: viewport(size).worldBounds())
            .map { graph.geometry.nodes[$0] }
        if graph.snapshot.nodes.count > 1000 {
            drawNodeBatches(nodes, in: &context, size: size)
            drawLabels(in: &context, size: size, nodes: nodes)
            return
        }
        for node in nodes {
            guard let center = point(node.id, size: size) else { continue }
            let selected = node.id == graph.selectedID || node.id == keyboardNode || node
                .id == hoveredNode
            let matched = graph.snapshot.matchingIDs.contains(node.id)
            let radius = nodeRadius(node.kind)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let color = nodeInk(graph.nodeStyle(for: node))
            if matched {
                context.fill(
                    nodePath(node, in: rect.insetBy(dx: -7, dy: -7)),
                    with: .color(color.opacity(0.2))
                )
            }
            if node.kind == .document {
                GraphDocumentMark(isSource: graph.isSource(node), style: markStyle).draw(
                    in: &context, rect: rect, increasedContrast: contrast == .increased, ink: color
                )
            } else {
                let shape = nodePath(node, in: rect)
                context.fill(shape, with: .color(color))
                if contrast == .increased {
                    context.stroke(shape, with: .color(.primary.opacity(0.8)), lineWidth: 1)
                }
            }
            if selected {
                context.stroke(
                    nodePath(node, in: rect.insetBy(dx: -5, dy: -5)),
                    with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 4
                )
                context.stroke(
                    nodePath(node, in: rect.insetBy(dx: -5, dy: -5)),
                    with: .color(.accentColor),
                    lineWidth: 2
                )
            }
        }
        drawLabels(in: &context, size: size, nodes: nodes)
    }

    private func drawNodeBatches(
        _ nodes: [GraphNode],
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        var shapes: [GraphNodeStyle: GraphDrawingBatch] = [:]
        var folds: [GraphNodeStyle: GraphDrawingBatch] = [:]
        var lines = GraphDrawingBatch()
        for node in nodes {
            guard let center = point(node.id, size: size) else { continue }
            let radius = nodeRadius(node.kind)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let style = graph.nodeStyle(for: node)
            shapes[style, default: GraphDrawingBatch()].append(nodePath(node, in: rect).cgPath)
            if node.kind == .document, radius >= 6 {
                let mark = GraphDocumentMark(isSource: style.isSource, style: markStyle)
                if style.isSource {
                    folds[style, default: GraphDrawingBatch()].append(mark.fold(in: rect).cgPath)
                } else {
                    lines.append(mark.textLines(in: rect).cgPath)
                }
            }
        }
        drawEntityBatches(shapes, in: &context)
        drawDocumentBatches(shapes, folds: folds, lines: lines, in: &context)
        drawNodeHighlights(in: &context, size: size)
    }

    private func drawEntityBatches(
        _ shapes: [GraphNodeStyle: GraphDrawingBatch], in context: inout GraphicsContext
    ) {
        for (style, batch) in shapes.sorted(by: { $0.key < $1.key }) where style.kind != .document {
            for path in batch.paths {
                context.fill(Path(path), with: .color(nodeInk(style)))
                if contrast == .increased {
                    context.stroke(
                        Path(path),
                        with: .color(.primary.opacity(0.8)),
                        lineWidth: 1
                    )
                }
            }
        }
    }

    private func drawDocumentBatches(
        _ shapes: [GraphNodeStyle: GraphDrawingBatch],
        folds: [GraphNodeStyle: GraphDrawingBatch],
        lines: GraphDrawingBatch,
        in context: inout GraphicsContext
    ) {
        let background = Color(nsColor: .windowBackgroundColor)
        for (style, batch) in shapes.sorted(by: { $0.key < $1.key })
            where style.kind == .document && !style.isSource
        {
            for path in batch.paths {
                context.fill(Path(path), with: .color(nodeInk(style)))
            }
        }
        for path in lines.paths {
            context.stroke(
                Path(path),
                with: .color(background),
                style: StrokeStyle(lineWidth: max(1, nodeRadius(.document) * 0.13), lineCap: .round)
            )
        }
        for (style, batch) in shapes.sorted(by: { $0.key < $1.key })
            where style.kind == .document && style.isSource
        {
            let ink = nodeInk(style)
            for path in batch.paths {
                context.fill(Path(path), with: .color(background))
                context.fill(Path(path), with: .color(ink.opacity(0.08)))
                context.stroke(
                    Path(path), with: .color(ink),
                    lineWidth: contrast == .increased ? 2 : 1.5
                )
            }
        }
        for (style, batch) in folds.sorted(by: { $0.key < $1.key }) {
            for path in batch.paths {
                context.stroke(Path(path), with: .color(nodeInk(style)), lineWidth: 1)
            }
        }
    }

    private func drawNodeHighlights(in context: inout GraphicsContext, size: CGSize) {
        var highlighted = graph.snapshot.matchingIDs
        for id in [graph.selectedID, keyboardNode, hoveredNode]
            .compactMap(\.self)
        {
            highlighted.insert(id)
        }
        for id in highlighted {
            guard let node = graph.geometry.node(for: id),
                  let center = point(id, size: size) else { continue }
            let radius = nodeRadius(node.kind) + 5
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.stroke(
                nodePath(node, in: rect),
                with: .color(Color(nsColor: .windowBackgroundColor)),
                lineWidth: 4
            )
            context.stroke(nodePath(node, in: rect), with: .color(.accentColor), lineWidth: 2)
        }
    }

    private func drawLabels(
        in context: inout GraphicsContext, size: CGSize, nodes: [GraphNode]
    ) {
        let budget = GraphViewport.labelBudget(
            count: graph.snapshot.nodes.count,
            scale: scale,
            size: size
        )
        let important = nodes.filter { priority($0) >= 2 }.sorted { priority($0) > priority($1) }
        let ordinary = nodes.lazy.filter { priority($0) < 2 }.prefix(budget)
        let candidates = important + Array(ordinary)
        guard !candidates.isEmpty else { return }
        let obstacles = nodes.compactMap { node -> CGRect? in
            guard let center = point(node.id, size: size) else { return nil }
            let radius = nodeRadius(node.kind) + 4
            return CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
        }
        // Leave the fit/zoom controls unobscured and keep labels inside the viewport.
        var placement = GraphLabelPlacement(
            bounds: CGRect(
                x: 8,
                y: 8,
                width: max(0, size.width - 16),
                height: max(0, size.height - 16)
            ),
            nodes: obstacles + [CGRect(
                x: 0, y: max(0, size.height - 60),
                width: compact ? min(146, size.width) : size.width, height: 60
            )] + (showsDocumentLegend ? [CGRect(x: 0, y: 0, width: 180, height: 44)] : [])
        )
        for node in candidates {
            guard let center = point(node.id, size: size) else { continue }
            let selected = node.id == graph.selectedID || node.id == keyboardNode || node
                .id == hoveredNode
            let entry = labelCache.resolve(
                node.label, selected: selected, emphasized: priority(node) >= 2,
                width: min(240, max(1, size.width - 16)), dark: colorScheme == .dark,
                increasedContrast: contrast == .increased, context: context
            )
            guard let rect = placement.place(
                size: entry.size, near: center, radius: nodeRadius(node.kind)
            ) else { continue }
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -3, dy: -1), cornerRadius: 3),
                with: .color(Color(nsColor: .windowBackgroundColor))
            )
            context.draw(entry.text, at: rect.origin, anchor: .topLeading)
        }
    }

    private func nodeRadius(_ kind: GraphNode.Kind) -> Double {
        let radius: Double = switch kind {
        case .concept: 7
        case .person: 7.5
        case .organization, .tool: 8
        case .document: 10
        }
        return max(1.5, radius * min(1, sqrt(scale)))
    }

    private func viewport(_ size: CGSize) -> GraphViewport {
        GraphViewport(size: size, scale: scale, pan: pan)
    }

    private func nodeInk(_ style: GraphNodeStyle) -> Color {
        if graph.usesFilingColors {
            return style.kind == .document
                ? AtlasPalette.ink(style.filingHue, dark: colorScheme == .dark) : .primary
        }
        return style.kind == .document ? .primary : nodeColor(style.kind)
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

    private func nodePath(_ node: GraphNode, in rect: CGRect) -> Path {
        if markStyle != .pages, node.kind != .document {
            return GraphMarkStyle.triangle(in: rect)
        }
        return switch node.kind {
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
            GraphDocumentMark(isSource: graph.isSource(node), style: markStyle).path(in: rect)
        }
    }

    private func priority(_ node: GraphNode) -> Int {
        if node.id == graph.selectedID || node.id == keyboardNode || node.id == hoveredNode {
            return 3
        }
        if graph.snapshot.matchingIDs.contains(node.id) {
            return 2
        }
        return node.kind == .document ? 1 : 0
    }

    // MARK: Peek

    @ViewBuilder private var peek: some View {
        if let id = peekNode, let node = graph.snapshot.nodes.first(where: { $0.id == id }) {
            ReferencePeek(
                title: node.label, kind: graph.kindLabel(for: node).capitalized, host: nil,
                filing: graph.filings(for: node).first, selected: false,
                load: { [excerpt] in
                    guard let id = node.noteID, let excerpt else { return nil }
                    return await excerpt(id)
                },
                openTitle: node.noteID == nil ? "Show Details" : "Open",
                open: {
                    peekNode = nil
                    if let noteID = node.noteID {
                        openNote(noteID)
                    } else {
                        keyboardNode = node.id; graph.select(node.id)
                    }
                },
                toggleSource: nil,
                chatTarget: node.noteID.map(ChatAttachmentTarget.note),
                addedToChat: { peekNode = nil }
            )
            .onHover { inside in
                hoveringPeek = inside
                if !inside {
                    schedulePeekClose()
                }
            }
        }
    }

    /// Where the peek points: the node's mark on screen.
    private func peekRect(size: CGSize) -> CGRect {
        guard let id = peekNode, let node = graph.geometry.node(for: id),
              let center = point(id, size: size) else { return .zero }
        let radius = nodeRadius(node.kind)
        return CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        )
    }

    private func hoverChanged(to node: String?) {
        peekTimer?.cancel()
        guard let node, draggedNode == nil, dragOrigin == nil else {
            schedulePeekClose()
            return
        }
        guard node != peekNode else { return }
        // Dwell first, so sweeping across the graph doesn't flash previews.
        peekTimer = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled {
                peekNode = node
            }
        }
    }

    /// Leaves time to move the pointer from the node into the peek.
    private func schedulePeekClose() {
        peekTimer?.cancel()
        peekTimer = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled, hoveredNode == nil, !hoveringPeek {
                peekNode = nil
            }
        }
    }

    private func hitNode(_ location: CGPoint, size: CGSize) -> GraphNode? {
        graph.geometry.nearestNode(to: viewport(size).world(location), radius: 24 / scale)
    }

    private func hitEdge(_ location: CGPoint, size: CGSize) -> GraphEdge? {
        graph.geometry.nearestEdge(to: viewport(size).world(location), radius: 6 / scale)
    }

    private func distance(_ left: CGPoint, _ right: CGPoint?) -> Double {
        guard let right else { return .infinity }
        return hypot(left.x - right.x, left.y - right.y)
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5).onChanged { value in
            hasFitted = true
            adjusted = true
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

    private func selectAccessibleNode(_ id: String) {
        keyboardNode = id
        graph.select(id)
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
        let newScale = min(3, max(0.0001, oldScale * exp(boundedDelta * 0.018)))
        guard newScale != oldScale else { return }
        hasFitted = true
        adjusted = true
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
        guard let camera = GraphViewport.fit(
            bounds: graph.geometry.bounds,
            size: size,
            compact: compact
        ) else { return }
        scale = camera.scale
        pan = camera.pan
    }

    private func controlImage(_ symbol: String, label: String) -> Image {
        // macOS segmented controls use the NSImage description, not the Button's AX label.
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            return Image(nsImage: image)
        }
        return Image(systemName: symbol)
    }

    private func controls(size: CGSize) -> some View {
        HStack(spacing: 12) {
            ControlGroup {
                Button {
                    hasFitted = true
                    adjusted = true
                    scale = max(0.0001, scale / 1.25)
                } label: {
                    controlImage("minus", label: "Zoom out")
                }.help("Zoom out")
                Button {
                    hasFitted = true
                    adjusted = false
                    fit(size: size)
                } label: {
                    controlImage("arrow.up.left.and.arrow.down.right", label: "Fit graph")
                }.help("Fit graph")
                Button {
                    hasFitted = true
                    adjusted = true
                    scale = min(3, scale * 1.25)
                } label: {
                    controlImage("plus", label: "Zoom in")
                }.help("Zoom in")
            }.labelStyle(.iconOnly).fixedSize()
            if !compact {
                Text(graph.canvasCountLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !compact, graph.snapshot.nodes.count < graph.snapshot.totalNodes,
               graph.visibleLimit < graph.maximumVisibleNodes
            {
                Button("Show More") { graph.expand() }.controlSize(.small)
            }
            if graph.snapshot.truncatedEdges {
                Text("Connections limited to 1,200").font(.caption)
            }
        }
    }
}
