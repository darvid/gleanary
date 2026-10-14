import CoreGraphics
import Foundation
import Observation

/// Navigation and camera state for the Knowledge Atlas. It lives as long as the Library window,
/// so opening an item and returning keeps the same focus, selection and zoom.
@MainActor @Observable
final class KnowledgeAtlasModel {
    enum Activation: Equatable {
        case focused(AtlasNodeID)
        case open(UUID)
    }

    enum KindFilter: Equatable {
        case all, sources, notes
    }

    enum Direction {
        case left, right, up, down
    }

    struct Transition {
        let from: AtlasCamera
        let start: Date
        let duration: TimeInterval
    }

    /// Zooming steps into a region once its content spans this share of the viewport.
    nonisolated static let contextShare = 0.9
    /// Item tiles narrower than this (in points) are drawn and hit as part of their category.
    nonisolated static let minimumItemSize: CGFloat = 4

    private(set) var root: AtlasNode
    private(set) var layout: AtlasLayout
    private(set) var viewport: CGSize = .zero
    private(set) var camera = AtlasCamera()
    private(set) var transition: Transition?
    private(set) var focusID: AtlasNodeID = .library
    var selectedID: AtlasNodeID?
    var hoveredID: AtlasNodeID?
    private(set) var snapshot: AtlasSnapshot?
    private(set) var loading = false
    var error: String?
    var reduceMotion = false
    var kindFilter = KindFilter.all {
        didSet {
            if kindFilter != oldValue {
                rebuild()
            }
        }
    }

    var hidesEmptyCategories = false {
        didSet {
            if hidesEmptyCategories != oldValue {
                rebuild()
            }
        }
    }

    /// Categories with nothing filed in them, whether or not they are hidden.
    private(set) var emptyCategoryCount = 0
    /// The categories behind `emptyCategoryCount`, for marking them outside the map.
    private(set) var emptyCategoryIDs: Set<UUID> = []

    /// Item IDs matching the current search, or nil when no search is active.
    private(set) var matches: Set<UUID>?
    /// Matching items per tile, aligned with `layout.tiles`; empty without a search.
    private(set) var matchCounts: [Int] = []
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    init(snapshot: AtlasSnapshot? = nil) {
        let root = AtlasHierarchy.project(snapshot ?? AtlasSnapshot(categories: [], items: []))
        self.root = root
        layout = AtlasLayout(root: root, bounds: .zero)
        self.snapshot = snapshot
    }

    // MARK: Data

    func load(from store: DocumentStore) async {
        loading = snapshot == nil
        defer { loading = false }
        do {
            let fresh = try await store.atlasSnapshot()
            guard fresh != snapshot else { return }
            snapshot = fresh
            error = nil
            rebuild()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func search(_ query: String, in store: DocumentStore) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { setMatches(nil); return }
        do { try await setMatches(store.libraryMatches(query: text)) }
        catch { self.error = error.localizedDescription }
    }

    func setMatches(_ ids: Set<UUID>?) {
        matches = ids
        recountMatches()
    }

    /// Replaces the data without touching the database; used by previews and tests.
    func apply(_ snapshot: AtlasSnapshot) {
        self.snapshot = snapshot
        rebuild()
    }

    private func rebuild() {
        var source = snapshot ?? AtlasSnapshot(categories: [], items: [])
        switch kindFilter {
        case .all: break
        case .sources: source.items = source.items.filter { $0.kind == "source" }
        case .notes: source.items = source.items.filter { $0.kind != "source" }
        }
        let projected = AtlasHierarchy.project(source)
        emptyCategoryCount = AtlasHierarchy.emptyCategoryCount(projected)
        emptyCategoryIDs = AtlasHierarchy.emptyCategoryIDs(projected)
        root = hidesEmptyCategories ? AtlasHierarchy.withoutEmptyCategories(projected) : projected
        // Layouts depend only on the hierarchy and viewport, so unchanged regions stay put and
        // the camera can be kept as is.
        layout = AtlasLayout(root: root, bounds: CGRect(origin: .zero, size: viewport))
        if layout.index[focusID] == nil {
            focusID = .library
            fit(focusID, animated: false)
        }
        if let selectedID, layout.index[selectedID] == nil {
            self.selectedID = nil
        }
        if let hoveredID, layout.index[hoveredID] == nil {
            self.hoveredID = nil
        }
        camera = clamp(camera)
        recountMatches()
    }

    private func recountMatches() {
        guard let matches else { matchCounts = []; return }
        var counts = Array(repeating: 0, count: layout.tiles.count)
        for (position, tile) in layout.tiles.enumerated() {
            guard let item = tile.node.item, matches.contains(item.id) else { continue }
            var current: Int? = position
            while let index = current {
                counts[index] += 1
                current = layout.tiles[index].parent
            }
        }
        matchCounts = counts
    }

    // MARK: Viewport and camera

    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewport else { return }
        viewport = size
        layout = AtlasLayout(root: root, bounds: CGRect(origin: .zero, size: size))
        recountMatches()
        fit(focusID, animated: false)
    }

    var scaleRange: ClosedRange<CGFloat> {
        let smallest = layout.smallestItemSize.map { max($0.width, .ulpOfOne) } ?? 200
        return 0.8 ... max(4, min(2000, 220 / smallest))
    }

    /// 0 at the overview through 1 at the deepest useful zoom, on a logarithmic scale.
    var zoomLevel: Double {
        get {
            let range = scaleRange
            let span = log(range.upperBound) - log(1)
            return span > 0 ? Double(max(0, log(camera.scale)) / span) : 0
        }
        set {
            let target = exp(CGFloat(newValue) * log(scaleRange.upperBound))
            zoom(by: target / camera.scale, around: viewportCenter, animated: false)
        }
    }

    func camera(at date: Date) -> AtlasCamera {
        guard let transition else { return camera }
        let raw = date.timeIntervalSince(transition.start) / transition.duration
        guard raw < 1 else { return camera }
        let eased = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2
        return AtlasCamera.interpolate(
            from: transition.from, to: camera, progress: eased, viewport: viewport
        )
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint, animated: Bool = false) {
        guard factor.isFinite, factor > 0 else { return }
        move(to: camera.zoomed(by: factor, around: anchor), animated: animated)
        updateContext()
    }

    func pan(by delta: CGSize) {
        move(to: camera.panned(by: delta), animated: false)
        updateContext()
    }

    /// Sets the camera directly, as gestures do with their own starting camera.
    func setCamera(_ camera: AtlasCamera) {
        move(to: camera, animated: false)
        updateContext()
    }

    private var viewportCenter: CGPoint {
        CGPoint(x: viewport.width / 2, y: viewport.height / 2)
    }

    private func clamp(_ camera: AtlasCamera) -> AtlasCamera {
        guard viewport.width > 0 else { return camera }
        return camera.clamped(to: layout.bounds, viewport: viewport, scales: scaleRange)
    }

    private func move(to target: AtlasCamera, animated: Bool, duration: TimeInterval = 0.45) {
        let current = camera(at: .now)
        camera = clamp(target)
        transitionTask?.cancel()
        guard animated, !reduceMotion, current != camera else { transition = nil; return }
        transition = Transition(from: current, start: .now, duration: duration)
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.transition = nil
        }
    }

    private func fit(_ id: AtlasNodeID, animated: Bool) {
        guard viewport.width > 0, let tile = layout.tile(id) else { return }
        let target = tile.node.kind == .library
            ? AtlasCamera.fitting(layout.bounds, in: viewport)
            // The whole region, so its title stays in view above its contents.
            : AtlasCamera.fitting(tile.rect, in: viewport, margin: 12)
        move(to: target, animated: animated)
    }

    /// After free zooming or panning, the context follows the camera with some hysteresis: it
    /// steps out once its region no longer contains the viewport centre or shrinks below half the
    /// viewport, and steps into a child that fills one dimension and half the other.
    private func updateContext() {
        guard !layout.tiles.isEmpty else { return }
        let center = camera.logical(viewportCenter)
        // Fully zoomed out is always the library. No other scale shortcut: a tall region framed
        // with its title can sit below 1×, and the rules below step out as the view zooms out.
        guard camera.scale > scaleRange.lowerBound * 1.001 else {
            if focusID != .library {
                focusID = .library
            }
            return
        }
        func fill(_ position: Int) -> (major: CGFloat, minor: CGFloat) {
            // Whole regions, matching `fit`, which frames a region with its title.
            let screen = camera.screen(layout.tiles[position].rect)
            let width = screen.width / viewport.width
            let height = screen.height / viewport.height
            return (max(width, height), min(width, height))
        }
        var current = layout.index[focusID] ?? 0
        while current != 0, let parent = layout.tiles[current].parent,
              !layout.tiles[current].rect.contains(center) || fill(current).major < 0.5
        {
            current = parent
        }
        while let next = layout.children(of: current).first(where: { position in
            let tile = layout.tiles[position]
            // A category's own items are part of it, not a context of their own.
            guard tile.node.kind != .item, tile.node.kind != .direct, tile.childCount > 0,
                  tile.rect.contains(center) else { return false }
            let share = fill(position)
            return share.major >= Self.contextShare && share.minor >= 0.5
        }) {
            current = next
        }
        let context = layout.tiles[current].id
        if context != focusID {
            focusID = context
        }
    }

    // MARK: Navigation

    var focusTile: AtlasTile? {
        layout.tile(focusID)
    }

    var selectedTile: AtlasTile? {
        selectedID.flatMap(layout.tile)
    }

    var breadcrumb: [AtlasTile] {
        guard let position = layout.index[focusID] else { return [] }
        return layout.path(to: position).map { layout.tiles[$0] }
    }

    func focus(_ id: AtlasNodeID, animated: Bool = true) {
        guard let tile = layout.tile(id), tile.node.kind != .item else { return }
        focusID = id
        fit(id, animated: animated)
    }

    @discardableResult
    func activate(_ id: AtlasNodeID) -> Activation? {
        guard let tile = layout.tile(id) else { return nil }
        if let item = tile.node.item {
            selectedID = id
            return .open(item.id)
        }
        // A region with no children has nothing more to reveal; select it instead.
        guard tile.childCount > 0 else { selectedID = id; return nil }
        focus(id)
        return .focused(id)
    }

    /// Steps out one level, selecting the region just left so the user keeps their bearings.
    func back() {
        guard let position = layout.index[focusID], let parent = layout.tiles[position].parent
        else { return }
        selectedID = focusID
        focus(layout.tiles[parent].id)
    }

    func reset() {
        focus(.library)
    }

    var canGoBack: Bool {
        focusID != .library
    }

    // MARK: Hit testing and keyboard

    /// The deepest region or item under a view-space point, using the same level of detail as
    /// rendering: items too small to see resolve to their category.
    func hitTest(_ point: CGPoint) -> AtlasNodeID? {
        guard !layout.tiles.isEmpty else { return nil }
        let current = camera(at: .now)
        let target = current.logical(point)
        var position = 0
        var hit: AtlasNodeID?
        while true {
            let next = layout.children(of: position).first { child in
                let tile = layout.tiles[child]
                guard tile.rect.contains(target) else { return false }
                let screen = current.screen(tile.rect)
                let minimum = tile.node.kind == .item ? Self.minimumItemSize : 2
                return min(screen.width, screen.height) >= minimum
            }
            guard let next else { return hit }
            position = next
            // A category's own items have no box to select; clicks reach the items or category.
            if layout.tiles[next].node.kind != .direct {
                hit = layout.tiles[next].id
            }
        }
    }

    /// Moves the selection to the nearest sibling in a direction, starting inside the current
    /// context when nothing in it is selected.
    func moveSelection(_ direction: Direction) {
        guard let focusPosition = layout.index[focusID] else { return }
        guard let selectedID, let position = layout.index[selectedID],
              let parent = layout.tiles[position].parent,
              layout.path(to: position).contains(focusPosition)
        else {
            selectedID = layout.children(of: focusPosition).first.map { layout.tiles[$0].id }
            return
        }
        let origin = layout.tiles[position].rect
        let candidates = layout.children(of: parent).filter { $0 != position }.compactMap {
            candidate -> (Int, CGFloat)? in
            let rect = layout.tiles[candidate].rect
            let dx = rect.midX - origin.midX
            let dy = rect.midY - origin.midY
            let ahead = switch direction {
            case .left: dx < -1 && abs(dy) <= abs(dx) * 2 + origin.height / 2
            case .right: dx > 1 && abs(dy) <= abs(dx) * 2 + origin.height / 2
            case .up: dy < -1 && abs(dx) <= abs(dy) * 2 + origin.width / 2
            case .down: dy > 1 && abs(dx) <= abs(dy) * 2 + origin.width / 2
            }
            return ahead ? (candidate, dx * dx + dy * dy) : nil
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }) else { return }
        self.selectedID = layout.tiles[best.0].id
        revealSelection()
    }

    /// Keeps keyboard selection on screen by refocusing its parent when it scrolls out of view.
    private func revealSelection() {
        guard let tile = selectedTile, let parent = tile.parent else { return }
        let screen = camera.screen(tile.rect)
        let visible = CGRect(origin: .zero, size: viewport)
        guard !visible.contains(screen) || min(screen.width, screen.height) < 12 else { return }
        focus(layout.tiles[parent].id)
    }

    /// Regions and items exposed to VoiceOver: the children of the current context.
    var accessibleTiles: [Int] {
        guard let position = layout.index[focusID] else { return [] }
        return Array(layout.children(of: position).prefix(400))
    }
}
