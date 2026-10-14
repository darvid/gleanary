import AppKit
import SwiftUI

/// A zoomable map of the whole Library: Johnny Decimal regions sized by item count, revealing
/// subcategories and then individual items as the user zooms in.
struct KnowledgeAtlasView: View {
    @Bindable var atlas: KnowledgeAtlasModel
    /// Nil for previews, which supply their data through `KnowledgeAtlasModel.apply(_:)`.
    let store: DocumentStore?
    /// Changes whenever the Library's contents may have changed.
    var refreshToken = 0
    let openItem: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @State private var query = ""
    @AppStorage("atlasHidesEmptyCategories") private var hidesEmpty = false
    @State private var hoverPoint: CGPoint?
    @State private var dragStart: AtlasCamera?
    /// The previous click, so a second click on the same tile opens it.
    @State private var lastClick: (id: AtlasNodeID, time: Date)?
    @State private var pinchStart: AtlasCamera?
    @FocusState private var canvasFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = atlas.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    .foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 8)
            }
            if atlas.root.children.isEmpty {
                ContentUnavailableView(
                    atlas.loading ? "Loading library…" : "Nothing to map yet",
                    systemImage: "square.grid.3x3",
                    description: Text(
                        "Save a source in Chat or import a document. Filed items appear here by category."
                    )
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                canvas.padding(.horizontal, 20)
            }
            footer
        }
        .task(id: refreshToken) {
            if let store {
                await atlas.load(from: store)
            }
        }
        .task(id: "\(query)/\(refreshToken)") {
            guard let store else { return }
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
            await atlas.search(query, in: store)
        }
        .onChange(of: reduceMotion, initial: true) { atlas.reduceMotion = reduceMotion }
        .onChange(of: hidesEmpty, initial: true) { atlas.hidesEmptyCategories = hidesEmpty }
    }

    // MARK: Header and footer

    /// One row: the path to the focused region, its title and counts, then search.
    private var header: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                breadcrumb
                if let focus = atlas.focusTile {
                    Text(focus.node.label).font(.title3.weight(.semibold)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(summary(of: focus)).font(.callout).foregroundStyle(.secondary)
                        .fadesOnChange(summary(of: focus))
                        .monospacedDigit().lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            emptyToggle
            searchField
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }

    /// Enclosing regions above the focused one, which the header titles itself.
    private var breadcrumb: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if atlas.canGoBack {
                Button("Back", systemImage: "chevron.left") { atlas.back() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Back to the enclosing category")
            }
            ForEach(Array(atlas.breadcrumb.dropLast().enumerated()), id: \.offset) { _, tile in
                Button(tile.node.label) { atlas.focus(tile.id) }
                    .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        // The header spaces its items 10pt apart, so the last chevron would sit nearer its parent
        // than the title; this evens it out.
        .padding(.trailing, atlas.breadcrumb.count > 1 ? -4 : 0)
        .accessibilityElement(children: .contain).accessibilityLabel("Atlas location")
    }

    /// Empty categories draw as dashed outlines, so the toggle uses the same shape.
    private var emptyToggle: some View {
        let count = atlas.emptyCategoryCount
        return Toggle(isOn: $hidesEmpty) {
            Label(
                hidesEmpty && count > 0 ? "\(count) hidden" : "Hide empty",
                systemImage: "rectangle.dashed"
            )
            .monospacedDigit()
        }
        .toggleStyle(.button).buttonStyle(.borderless).controlSize(.regular)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            hidesEmpty ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .foregroundStyle(hidesEmpty ? Color.accentColor : Color.primary.opacity(0.8))
        .disabled(count == 0 && !hidesEmpty)
        .help(hidesEmpty
            ? "Show \(count == 1 ? "1 empty category" : "\(count) empty categories")"
            : count == 0 ? "No empty categories"
            : "Hide \(count == 1 ? "1 category" : "\(count) categories") with nothing filed")
        .accessibilityLabel("Hide empty categories")
        .accessibilityValue(hidesEmpty ? "\(count) hidden" : "Off")
        .animation(.snappy(duration: 0.2), value: hidesEmpty)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Highlight matches", text: $query)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("Search the atlas")
                .onExitCommand { query = ""; canvasFocused = true }
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: 240)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            selectionSummary
            Spacer(minLength: 12)
            Button("Zoom out", systemImage: "minus") { zoomStep(1 / 1.6) }
                .keyboardShortcut("-", modifiers: .command)
            Slider(value: $atlas.zoomLevel, in: 0 ... 1).frame(width: 110).controlSize(.mini)
                .accessibilityLabel("Zoom")
            Button("Zoom in", systemImage: "plus") { zoomStep(1.6) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Reset") { atlas.reset() }
                .keyboardShortcut("0", modifiers: .command)
                .help("Show the whole library (⌘0)")
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
        // A fixed height: selecting adds a bordered Open button, and a taller footer would
        // shrink the canvas, which re-fits the camera and throws away the user's zoom.
        .frame(height: 24)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    @ViewBuilder private var selectionSummary: some View {
        if let tile = atlas.selectedTile {
            HStack(spacing: 10) {
                Text(tile.node.label).font(.caption.weight(.medium)).lineLimit(1)
                Text(detail(of: tile)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let item = tile.node.item {
                    Button("Open") { openItem(item.id) }.buttonStyle(.bordered)
                        .labelStyle(.titleOnly)
                } else if tile.childCount > 0, tile.id != atlas.focusID {
                    Button("Zoom in") { atlas.activate(tile.id) }.buttonStyle(.bordered)
                        .labelStyle(.titleOnly)
                }
            }
        } else if let root = atlas.layout.root {
            Text(summary(of: root)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func zoomStep(_ factor: CGFloat) {
        atlas.zoom(by: factor, around: CGPoint(
            x: atlas.viewport.width / 2, y: atlas.viewport.height / 2
        ), animated: true)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: atlas.transition == nil)) { timeline in
                let camera = atlas.camera(at: timeline.date)
                Canvas { context, size in
                    AtlasRenderer(
                        layout: atlas.layout, camera: camera,
                        selectedID: atlas.selectedID,
                        hoveredID: atlas.hoveredID, matchCounts: atlas.matchCounts,
                        thumbnails: atlas.thumbnails,
                        dark: colorScheme == .dark, highContrast: contrast == .increased,
                        keyboardFocused: canvasFocused, displayScale: displayScale
                    ).draw(in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .focusable().focusEffectDisabled().focused($canvasFocused)
            // One tap gesture: an exclusive double-tap would hold every single click until the
            // double-click interval passed, delaying selection.
            .gesture(SpatialTapGesture().onEnded { click(at: $0.location) })
            .simultaneousGesture(drag)
            .simultaneousGesture(pinch)
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    hoverPoint = point
                    let hit = dragStart == nil ? atlas.hitTest(point) : nil
                    if hit != atlas.hoveredID {
                        atlas.hoveredID = hit
                    }
                case .ended:
                    hoverPoint = nil; atlas.hoveredID = nil
                }
            }
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .background { AtlasEventMonitor { event, point in handle(event, at: point) } }
            .overlay(alignment: .topLeading) { tooltip(in: geometry.size) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Knowledge Atlas")
            .accessibilityHint(
                "Arrow keys choose a region, Return opens it, Escape goes back. Drag or middle-drag to pan; pinch, scroll or use Command-plus and Command-minus to zoom."
            )
            .accessibilityChildren { accessibilityTiles }
            .accessibilityAction(named: "Back") { atlas.back() }
            .accessibilityAction(named: "Reset view") { atlas.reset() }
            .accessibilityZoomAction { action in
                zoomStep(action.direction == .zoomIn ? 1.6 : 1 / 1.6)
            }
            .onChange(of: geometry.size, initial: true) { atlas.setViewport(geometry.size) }
            .onChange(of: atlas.camera) { atlas.loadVisibleThumbnails() }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = dragStart ?? atlas.camera
                dragStart = start
                atlas.hoveredID = nil
                atlas.setCamera(start.panned(by: value.translation))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? atlas.camera
                pinchStart = start
                atlas.setCamera(start.zoomed(by: value.magnification, around: value.startLocation))
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Trackpad scrolling and middle-button dragging pan, as in other canvases; a mouse wheel,
    /// or scrolling with Command held, zooms toward the pointer.
    private func handle(_ event: NSEvent, at point: CGPoint) -> Bool {
        if event.type == .otherMouseDragged {
            // Mouse deltas grow rightward and downward, like the canvas.
            atlas.pan(by: CGSize(width: event.deltaX, height: event.deltaY))
            hoverPoint = nil; atlas.hoveredID = nil
            return true
        }
        let zooming = !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.command)
        if zooming {
            let rate: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.12
            atlas.zoom(by: exp(event.scrollingDeltaY * rate), around: point)
        } else {
            atlas.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
        hoverPoint = nil; atlas.hoveredID = nil
        return true
    }

    /// Selects on the first click and opens on a second click on the same tile within the
    /// system double-click interval, as Finder does.
    private func click(at point: CGPoint) {
        canvasFocused = true
        let id = atlas.hitTest(point)
        atlas.selectedID = id
        let now = Date()
        if let id, let lastClick, lastClick.id == id,
           now.timeIntervalSince(lastClick.time) <= NSEvent.doubleClickInterval
        {
            self.lastClick = nil
            activate(id)
        } else {
            lastClick = id.map { ($0, now) }
        }
    }

    private func activate(_ id: AtlasNodeID) {
        if case let .open(item) = atlas.activate(id) {
            openItem(item)
        }
    }

    private static let arrows: [KeyEquivalent: KnowledgeAtlasModel.Direction] = [
        .leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down,
    ]

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
            return .ignored
        }
        if let direction = Self.arrows[press.key] {
            atlas.moveSelection(direction)
            return .handled
        }
        switch press.key {
        case .return, .space:
            guard let id = atlas.selectedID else { atlas.moveSelection(.right); return .handled }
            if case let .open(item) = atlas.activate(id) {
                openItem(item)
            }
            return .handled
        case .escape:
            return escape()
        default:
            return zoomKey(press.characters)
        }
    }

    private func zoomKey(_ characters: String) -> KeyPress.Result {
        switch characters {
        case "+", "=": zoomStep(1.6)
        case "-": zoomStep(1 / 1.6)
        case "0": atlas.reset()
        default: return .ignored
        }
        return .handled
    }

    /// Escape clears a selection first, then steps out a level.
    private func escape() -> KeyPress.Result {
        if atlas.selectedID != nil, atlas.selectedID != atlas.focusID {
            atlas.selectedID = nil
        } else if atlas.canGoBack {
            atlas.back()
        } else {
            return .ignored
        }
        return .handled
    }

    // MARK: Hover and accessibility

    @ViewBuilder private func tooltip(in size: CGSize) -> some View {
        if let point = hoverPoint, let id = atlas.hoveredID, let tile = atlas.layout.tile(id) {
            let width: CGFloat = 260
            let flipsLeft = point.x + width + 24 > size.width
            // Snug on one line when it fits, otherwise wrapped at `width`. The bubble draws its
            // own background, so it always grows with its text.
            ViewThatFits(in: .horizontal) {
                tooltipBubble(tile, wrapped: false).fixedSize()
                tooltipBubble(tile, wrapped: true).frame(width: width)
            }
            .frame(width: width, alignment: flipsLeft ? .trailing : .leading)
            .offset(
                x: flipsLeft ? max(0, point.x - width - 8) : point.x + 14,
                y: point.y + 70 > size.height ? max(0, point.y - 58) : point.y + 18
            )
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func tooltipBubble(_ tile: AtlasTile, wrapped: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tile.node.label).font(.callout.weight(.medium)).lineLimit(wrapped ? 2 : 1)
            Text(detail(of: tile)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(wrapped ? 2 : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: wrapped ? .infinity : nil, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5))
    }

    private var accessibilityTiles: some View {
        let camera = atlas.camera
        return ZStack {
            ForEach(atlas.accessibleTiles, id: \.self) { position in
                let tile = atlas.layout.tiles[position]
                let rect = camera.screen(tile.rect)
                Color.clear
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityElement()
                    .accessibilityLabel(tile.node.label)
                    .accessibilityValue(detail(of: tile))
                    .accessibilityAddTraits(atlas.selectedID == tile
                        .id ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(tile.node
                        .item == nil ? "Zooms into this category" : "Opens this item")
                    .accessibilityAction {
                        if case let .open(item) = atlas.activate(tile.id) {
                            openItem(item)
                        }
                    }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Text

    private func summary(of tile: AtlasTile) -> String {
        var parts = [count(tile.node.itemCount)]
        // Uncategorized and direct-item groups are not categories of their own.
        let regions = atlas.layout.children(of: atlas.layout.index[tile.id] ?? 0)
            .filter { [.category, .group].contains(atlas.layout.tiles[$0].node.kind) }.count
        if regions > 0 {
            parts.append(tile.node.kind == .library
                ? "\(regions) \(regions == 1 ? "category" : "categories")"
                : "\(regions) \(regions == 1 ? "subcategory" : "subcategories")")
        }
        if atlas.matches != nil, let position = atlas.layout.index[tile.id] {
            parts.append("\(atlas.matchCounts[position].formatted()) match")
        }
        return parts.joined(separator: " · ")
    }

    private func detail(of tile: AtlasTile) -> String {
        if let item = tile.node.item {
            return [
                item.kindLabel,
                item.host,
                item.updatedAt.formatted(date: .abbreviated, time: .omitted),
            ].compactMap(\.self).joined(separator: " · ")
        }
        var parts = [count(tile.node.itemCount)]
        if tile.node.alsoFiledCount > 0 {
            parts.append("\(tile.node.alsoFiledCount) also filed here")
        }
        if let last = tile.node.lastActivity {
            parts.append("updated \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func count(_ value: Int) -> String {
        value == 1 ? "1 item" : "\(value.formatted()) items"
    }
}

/// Observes scroll-wheel events over one view and reports them in its top-left coordinates.
/// Returning true from the action consumes the event.
/// AppKit events SwiftUI gestures don't deliver: scroll wheels, and the middle button, which
/// DragGesture ignores.
private struct AtlasEventMonitor: NSViewRepresentable {
    let action: @MainActor (NSEvent, CGPoint) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.action = action
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var action: @MainActor (NSEvent, CGPoint) -> Bool
        private var monitor: Any?

        init(action: @escaping @MainActor (NSEvent, CGPoint) -> Bool) {
            self.action = action
        }

        /// A middle-button drag that began on the canvas keeps panning outside it until release.
        private var panning = false

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
            ) { [weak self] event in
                self?.route(event) ?? event
            }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window else { return event }
            let local = view.convert(event.locationInWindow, from: nil)
            let point = view.isFlipped ? local
                : CGPoint(x: local.x, y: view.bounds.height - local.y)
            switch event.type {
            case .scrollWheel:
                guard view.bounds.contains(local) else { return event }
                return action(event, point) ? nil : event
            case .otherMouseDown where event.buttonNumber == 2:
                guard view.bounds.contains(local) else { return event }
                panning = true
                NSCursor.closedHand.push()
                return nil
            case .otherMouseDragged where panning:
                return action(event, point) ? nil : event
            case .otherMouseUp where panning:
                endPanning()
                return nil
            default:
                return event
            }
        }

        private func endPanning() {
            guard panning else { return }
            panning = false
            NSCursor.pop()
        }

        func stop() {
            endPanning()
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

#if DEBUG
    extension AtlasSnapshot {
        /// Synthetic library for previews and tests: uneven regions, subcategories, an empty
        /// category, multi-filed items and unfiled items.
        static func sample(seed: UInt64 = 7) -> AtlasSnapshot {
            var state = seed
            func next(_ bound: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((state >> 33) % UInt64(max(1, bound)))
            }
            let areas = [
                ("10", "Thinking", ["Philosophy", "Mental models", "Decisions"]),
                ("20", "Creating", ["Writing", "Design"]),
                ("30", "People", ["Biographies", "Teams", "Leadership"]),
                ("40", "Society", ["Economics", "Politics", "History", "Cities"]),
                (
                    "50",
                    "Technology",
                    ["Computing", "AI / ML", "Data", "Systems", "Security", "Tools"]
                ),
                ("60", "Nature", ["Biology", "Climate"]),
                ("70", "Work", ["Projects", "Meetings", "Hiring"]),
                ("80", "Health", ["Sleep", "Fitness", "Nutrition"]),
                ("90", "Meta", []),
            ]
            var categories: [DecimalCategory] = []
            for (code, name, subcategories) in areas {
                categories.append(DecimalCategory(id: UUID(), code: code, name: name))
                for (offset, sub) in subcategories.enumerated() {
                    categories.append(DecimalCategory(
                        id: UUID(), code: String(format: "%@.%02d", code, offset + 1), name: sub
                    ))
                }
            }
            let leaves = categories.filter { category in
                !categories.contains { $0.code.hasPrefix(category.code + ".") }
            }
            let kinds = ["source", "source", "source", "summary", "note", "comparison"]
            let hosts = ["arxiv.org", "example.com", "fixture.example", nil]
            var items: [AtlasItem] = []
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            for (offset, leaf) in leaves.enumerated() where leaf.code != "90" {
                let count = offset == 5 ? 140 : 4 + next(offset % 3 == 0 ? 60 : 24)
                for index in 0 ..< count {
                    var memberships = [leaf.id]
                    if next(9) == 0 {
                        memberships.append(leaves[next(leaves.count)].id)
                    }
                    let kind = kinds[next(kinds.count)]
                    items.append(AtlasItem(
                        id: UUID(), title: "\(leaf.name) item \(index + 1)", kind: kind,
                        host: kind == "source" ? hosts[next(hosts.count)] : nil,
                        updatedAt: start.addingTimeInterval(Double(next(400 * 86400))),
                        categoryIDs: memberships
                    ))
                }
            }
            for index in 0 ..< 18 {
                items.append(AtlasItem(
                    id: UUID(), title: "Unfiled item \(index + 1)", kind: "note", host: nil,
                    updatedAt: start.addingTimeInterval(Double(index * 3600))
                ))
            }
            return AtlasSnapshot(categories: categories, items: items)
        }
    }

    #Preview("Knowledge Atlas") {
        KnowledgeAtlasView(
            atlas: KnowledgeAtlasModel(snapshot: .sample()), store: nil, openItem: { _ in }
        )
        .frame(width: 980, height: 680)
    }
#endif
