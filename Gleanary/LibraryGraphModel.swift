import Foundation
import Observation

@MainActor @Observable final class LibraryGraphModel: GraphCanvasModel {
    private(set) var data = LibraryGraphSnapshot()
    private(set) var positions: [String: GraphPosition] = [:]
    private(set) var selectedID: String?
    private(set) var selectedEdgeID: String?
    private(set) var request = LibraryGraphRequest()
    private(set) var loading = false
    private(set) var error: String?
    var reduceMotion = false
    var camera: GraphCamera?
    private(set) var cameraReset = 0
    private(set) var layingOut = false
    @ObservationIgnored private var store: DocumentStore?
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var layoutToken = UUID()
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
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
            let updated = try await store.libraryGraph(request)
            try Task.checkCancellation()
            guard token == loadToken else { return }
            let topologyChanged = snapshot.nodes != updated.graph.nodes || snapshot.edges != updated
                .graph.edges
            data = updated
            let ids = Set(snapshot.nodes.map(\.id))
            if scopeChanged {
                deselect()
                positions = [:]
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
                camera = nil
                cameraReset += 1
                startLayout()
            }
        } catch is CancellationError {
        } catch {
            guard token == loadToken else { return }
            // Do not leave the previous note's graph under a new title after a failed load.
            data = LibraryGraphSnapshot()
            deselect()
            stop()
            self.error = "Connections could not be loaded. Try again."
        }
    }

    func select(_ id: String, edgeID: String? = nil) {
        selectedID = id
        selectedEdgeID = edgeID
    }

    func deselect() {
        selectedID = nil
        selectedEdgeID = nil
    }

    func expand() {
        guard let store else { return }
        var expanded = request
        expanded.limit = min(500, request.limit + 100)
        Task { await load(from: store, request: expanded) }
    }

    func startLayout() {
        layoutTask?.cancel()
        let token = UUID()
        layoutToken = token
        layingOut = !snapshot.nodes.isEmpty
        let snapshot = snapshot, initial = positions,
            animate = !reduceMotion && request.focus == nil
        layoutTask = Task { [weak self, layout] in
            do {
                try await layout
                    .settle(snapshot, positions: initial, animate: animate) { [weak self] next in
                        await self?.acceptLayout(next, token: token)
                    }
                guard let self, !Task.isCancelled, token == layoutToken else { return }
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
        layoutTask?.cancel()
        layoutTask = nil
        layoutToken = UUID()
        layingOut = false
    }
}
