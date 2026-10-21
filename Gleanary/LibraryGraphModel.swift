import Foundation
import Observation

@MainActor @Observable final class LibraryGraphModel: GraphCanvasModel {
    private(set) var data = LibraryGraphSnapshot()
    private(set) var inspector = LibraryGraphInspector(data: LibraryGraphSnapshot())
    private(set) var evidence: [LibraryGraphReason] = []
    private(set) var evidenceLoading = false
    private(set) var evidenceHasMore = false
    private(set) var evidenceError: String?
    @ObservationIgnored private var evidenceTask: Task<Void, Never>?
    private(set) var geometry = GraphGeometry()
    private(set) var positions: [String: GraphPosition] = [:] {
        didSet { geometry = GraphGeometry(snapshot: snapshot, positions: positions) }
    }

    var maximumVisibleNodes: Int {
        LibraryGraphRequest.maximumNodes
    }

    private(set) var selectedID: String?
    private(set) var selectedEdgeID: String?
    private(set) var request = LibraryGraphRequest()
    private(set) var loading = false
    private(set) var error: String?
    var reduceMotion = false
    var camera: GraphCamera?
    private(set) var cameraReset = 0
    private(set) var layingOut = false
    private(set) var spacing = GraphSpacing.standard
    @ObservationIgnored private var store: DocumentStore?
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var layoutToken = UUID()
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var spacingTask: Task<Void, Never>?
    @ObservationIgnored private var appliedSpacing: GraphSpacing? = .standard
    private let layout = GraphLayout()

    var snapshot: GraphSnapshot {
        data.graph
    }

    var selection: GraphNode? {
        snapshot.nodes.first { $0.id == selectedID }
    }

    var preparingInitialGraph: Bool {
        false
    }

    var overviewAction: (() -> Void)? {
        nil
    }

    var scopeLabel: String {
        "All connections"
    }

    var visibleLimit: Int {
        request.limit
    }

    var canvasCountLabel: String {
        "\(snapshot.nodes.count) of \(snapshot.totalNodes) nodes"
    }

    var selectedConnections: [LibraryGraphConnection] {
        data.connections.filter {
            if let selectedEdgeID {
                return $0.id == selectedEdgeID
            }
            return $0.edge.source == selectedID || $0.edge.target == selectedID
        }
    }

    func load(from store: DocumentStore, request: LibraryGraphRequest) async {
        let token = UUID()
        loadToken = token
        var previousScope = self.request
        previousScope.limit = request.limit
        let scopeChanged = previousScope != request
        self.store = store
        self.request = request
        loading = true
        error = nil
        defer {
            if token == loadToken {
                loading = false
            }
        }
        do {
            let updated = try await store.libraryGraph(request, includingReasons: false)
            try Task.checkCancellation()
            guard token == loadToken else { return }
            let topologyChanged = snapshot.nodes != updated.graph.nodes || snapshot.edges != updated
                .graph.edges
            data = updated
            inspector = LibraryGraphInspector(data: updated)
            let ids = Set(snapshot.nodes.map(\.id))
            if scopeChanged {
                deselect()
                positions = [:]
                camera = nil
                cameraReset += 1
            } else if let selectedID, !ids.contains(selectedID) {
                deselect()
            } else if let selectedEdgeID,
                      !snapshot.edges.contains(where: { $0.id == selectedEdgeID })
            {
                self.selectedEdgeID = nil
            }
            positions = positions.filter { ids.contains($0.key) }
            if topologyChanged || scopeChanged || positions.count != snapshot.nodes.count {
                startLayout()
            } else if spacing != appliedSpacing {
                finishSpacingChange()
            }
            loadEvidence(reset: true)
        } catch is CancellationError {
        } catch {
            guard token == loadToken else { return }
            // Do not leave the previous note's graph under a new title after a failed load.
            data = LibraryGraphSnapshot()
            inspector = LibraryGraphInspector(data: data)
            positions = [:]
            deselect()
            stop()
            self.error = "Connections could not be loaded. Try again."
        }
    }

    func isSource(_ node: GraphNode) -> Bool {
        node.kind == .document && data.sourceNodeIDs.contains(node.id)
    }

    func select(_ id: String, edgeID: String? = nil) {
        selectedID = id
        selectedEdgeID = edgeID
        loadEvidence(reset: true)
    }

    func deselect() {
        selectedID = nil
        selectedEdgeID = nil
        evidenceTask?.cancel()
        evidence = []
        evidenceLoading = false
        evidenceHasMore = false
        evidenceError = nil
    }

    func loadEvidence(reset: Bool = false) {
        evidenceTask?.cancel()
        if reset {
            evidence = []
            evidenceHasMore = false
        }
        evidenceError = nil
        guard let store, let edge = snapshot.edges.first(where: { $0.id == selectedEdgeID }) else {
            evidenceLoading = false
            return
        }
        let request = request, token = loadToken, offset = evidence.count
        evidenceLoading = true
        evidenceTask = Task { [weak self] in
            do {
                let reasons = try await store.libraryGraphReasons(
                    for: edge,
                    request: request,
                    offset: offset
                )
                try Task.checkCancellation()
                guard let self, token == loadToken, selectedEdgeID == edge.id else { return }
                evidence += reasons.prefix(80)
                evidenceHasMore = reasons.count > 80
                evidenceLoading = false
            } catch is CancellationError {
            } catch {
                guard let self, token == loadToken, selectedEdgeID == edge.id else { return }
                evidenceLoading = false
                evidenceError = "Evidence could not be loaded. Try again."
            }
        }
    }

    func expand() {
        guard let store else { return }
        var expanded = request
        expanded.limit = min(maximumVisibleNodes, max(1000, request.limit * 2))
        Task { await load(from: store, request: expanded) }
    }

    func setSpacing(_ value: Double) {
        let next = GraphSpacing(value)
        guard next != spacing else { return }
        stop()
        spacing = next
        spacingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard let self else { return }
            spacingTask = nil
            beginLayout(animate: false, anchorID: selectedID)
        }
    }

    func finishSpacingChange() {
        spacingTask?.cancel()
        spacingTask = nil
        guard spacing != appliedSpacing else { return }
        beginLayout(animate: !reduceMotion, anchorID: selectedID)
    }

    func resetSpacing() {
        setSpacing(GraphSpacing.standard.value)
        finishSpacingChange()
    }

    func startLayout() {
        spacingTask?.cancel()
        spacingTask = nil
        beginLayout(animate: !reduceMotion && request.focus == nil)
    }

    private func beginLayout(animate: Bool, anchorID: String? = nil) {
        layoutTask?.cancel()
        let token = UUID()
        layoutToken = token
        layingOut = !snapshot.nodes.isEmpty
        let snapshot = snapshot, initial = positions, spacing = spacing
        appliedSpacing = nil
        layoutTask = Task { [weak self, layout] in
            do {
                try await layout
                    .settle(
                        snapshot, positions: initial, animate: animate,
                        spacing: spacing, anchorID: anchorID
                    ) { [weak self] next in
                        await self?.acceptLayout(next, token: token)
                    }
                guard let self, !Task.isCancelled, token == layoutToken else { return }
                appliedSpacing = spacing
                layingOut = false
            } catch is CancellationError {
            } catch {
                guard let self, token == layoutToken else { return }
                layingOut = false
                self.error = "The graph could not be arranged. Try again."
            }
        }
    }

    private func acceptLayout(_ next: [String: GraphPosition], token: UUID) {
        guard token == layoutToken else { return }
        positions = next
    }

    func move(_ id: String, to position: GraphPosition) {
        stop()
        positions[id] = position
    }

    func persistPosition(_: String) {
        // Positions are local to this surface; embedded graphs never overwrite the Library layout.
    }

    func stop() {
        spacingTask?.cancel()
        spacingTask = nil
        layoutTask?.cancel()
        layoutTask = nil
        layoutToken = UUID()
        layingOut = false
    }
}
