import Foundation
import Observation

enum KnowledgeCanvasMode: String, CaseIterable {
    case mindMap = "Mind Map"
    case graph = "Graph"
}

@MainActor @Observable
final class KnowledgeGraphModel {
    var snapshot = GraphSnapshot()
    var mindMap = MindMapSnapshot()
    var mindMaps: [MindMapSummary] = []
    var selectedMindMapNoteID: UUID?
    var canvasMode: KnowledgeCanvasMode = .graph
    var selectedMapNodeID: String?
    var mapEvidence: [MindMapEvidence] = []
    var positions: [String: GraphPosition] = [:]
    var jobs: [GraphJob] = []
    var selectedID: String?
    var selectedEdgeID: String?
    var evidence: [GraphEvidence] = []
    var evidenceLimit = 100
    var focusID: String?
    var searchQuery = ""
    var visibleLimit = 200
    var error: String?
    var extracting = false
    var preparingInitialGraph = false
    var layingOut = false
    var reduceMotion = false
    var cameraReset = 0
    private var ready = false
    private var hasPublishedGraph = false
    private var searchNotes: [UUID] = []
    private var refreshToken = UUID()
    private var layoutToken = UUID()
    private var runAgain = false
    private var choseCanvasMode = false
    private let store: DocumentStore
    private let extractor: GraphExtractor
    private let layout = GraphLayout()
    @ObservationIgnored private(set) var extractionTask: Task<Void, Never>?
    @ObservationIgnored private(set) var layoutTask: Task<Void, Never>?

    init(store: DocumentStore, provider: any GraphExtracting = AppleGraphExtractor()) {
        self.store = store
        extractor = GraphExtractor(store: store, provider: provider)
    }

    var hasScopedView: Bool {
        focusID != nil || !searchQuery.isEmpty || !searchNotes.isEmpty
    }

    var scopeLabel: String {
        searchQuery.isEmpty ? "Back to overview" : "Search: \(searchQuery)"
    }

    var selection: GraphNode? {
        snapshot.nodes.first { $0.id == selectedID }
    }

    var displayedEvidence: [GraphEvidence] {
        selectedEdgeID.map { id in evidence.filter { $0.edge.id == id } } ?? evidence
    }

    var initialBuildProgress: Double? {
        let active = jobs.filter { ["queued", "running", "curating"].contains($0.state) }
        guard !active.contains(where: { $0.state == "curating" }) else { return nil }
        let completed = active.reduce(0) { $0 + $1.completed }
        let total = active.reduce(0) { $0 + $1.total }
        return total > 0 ? Double(completed) / Double(total) : nil
    }

    var initialBuildStatus: String {
        if layingOut {
            return "Arranging connections"
        }
        let active = jobs.filter { ["queued", "running", "curating"].contains($0.state) }
        if active.contains(where: { $0.state == "curating" }) {
            return "Selecting the most important connections"
        }
        let completed = active.reduce(0) { $0 + $1.completed }
        let total = active.reduce(0) { $0 + $1.total }
        if total > 0 {
            return "Finding connections, \(completed) of \(total) sections"
        }
        let count = active.count
        return "Analyzing \(count) \(count == 1 ? "note" : "notes")"
    }

    var progress: String {
        if preparingInitialGraph {
            return initialBuildStatus
        }
        if let job = jobs.first(where: { ["running", "curating"].contains($0.state) }) {
            return "Finding connections · \(job.completed)/\(job.total) sections · \(job.name)"
        }
        let waiting = jobs.filter { ["failed", "paused", "unavailable"].contains($0.state) }.count
        if waiting >
            0
        {
            return "Graph · \(waiting) \(waiting == 1 ? "note needs" : "notes need") attention"
        }
        let pending = jobs.filter { ["queued", "curating"].contains($0.state) }.count
        if pending > 0 {
            return "Graph · \(pending) notes queued"
        }
        return "\(snapshot.totalNodes) knowledge nodes"
    }

    func load() async throws {
        guard !ready else { return }
        try await store.recoverGraph()
        ready = true
        jobs = try await store.graphJobs()
        let hasPendingWork = jobs.contains {
            ["queued", "running", "curating"].contains($0.state)
        }
        let hasCompletedWork = jobs.contains { $0.state == "ready" }
        preparingInitialGraph = hasPendingWork && !hasCompletedWork
        if !preparingInitialGraph {
            await refresh()
        }
        startExtraction()
    }

    func startExtraction() {
        guard ready else { return }
        guard extractionTask == nil else { runAgain = true; return }
        extracting = true
        extractionTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                runAgain = false
                do { try await extractor.run { [weak self] in await self?.refresh() } }
                catch is CancellationError { break }
                catch {
                    self.error = error.localizedDescription
                    preparingInitialGraph = false
                    await refresh()
                    break
                }
            } while runAgain
            extracting = false
            extractionTask = nil
            if Task.isCancelled,
               jobs.contains(where: { ["queued", "curating"].contains($0.state) })
            {
                startExtraction()
            }
        }
    }

    func refresh() async {
        guard ready else { return }
        let token = UUID(); refreshToken = token
        do {
            let updatedJobs = try await store.graphJobs()
            guard token == refreshToken else { return }
            jobs = updatedJobs
            if !hasPublishedGraph,
               updatedJobs.contains(where: {
                   ["queued", "running", "curating"].contains($0.state)
               })
            {
                preparingInitialGraph = true
            }
            if isWaitingForInitialWork(updatedJobs) {
                return
            }
            let updated = try await store.graphSnapshot(
                focus: focusID,
                query: searchQuery,
                noteIDs: searchNotes,
                limit: visibleLimit
            )
            let saved = try await store.graphPositions(updated.nodes.map(\.id))
            guard token == refreshToken else { return }
            try await applySnapshot(updated, savedPositions: saved, token: token)
            try await refreshMindMap(token: token)
        } catch {
            if token == refreshToken {
                self.error = error.localizedDescription
            }
        }
    }

    private func applySnapshot(
        _ updated: GraphSnapshot,
        savedPositions: [String: GraphPosition],
        token: UUID
    ) async throws {
        let topologyChanged = snapshot.nodes.map(\.id) != updated.nodes.map(\.id) || snapshot
            .edges != updated.edges
        snapshot = updated
        if !updated.nodes.isEmpty {
            hasPublishedGraph = true
        }
        let ids = Set(updated.nodes.map(\.id))
        positions = positions.filter { ids.contains($0.key) }
        for (id, point) in savedPositions where positions[id] == nil {
            positions[id] = point
        }
        if let selectedID, !ids.contains(selectedID) {
            self.selectedID = nil; selectedEdgeID = nil; evidence = []
            if focusID == selectedID {
                focusID = nil
                await refresh()
                return
            }
        }
        if topologyChanged {
            startLayout()
        }
        finishInitialPreparationIfPossible(topologyChanged: topologyChanged)
        if let selectedID {
            let loaded = try await store.graphEvidence(nodeID: selectedID, limit: evidenceLimit)
            guard token == refreshToken else { return }
            evidence = loaded
        }
    }

    private func isWaitingForInitialWork(_ updatedJobs: [GraphJob]) -> Bool {
        preparingInitialGraph && updatedJobs.contains {
            ["queued", "running", "curating"].contains($0.state)
        }
    }

    private func finishInitialPreparationIfPossible(topologyChanged: Bool) {
        guard preparingInitialGraph, !topologyChanged, !layingOut else { return }
        preparingInitialGraph = false
    }

    func search(_ query: String, notes: [UUID]) async {
        searchQuery = query; searchNotes = notes; focusID = nil
        selectedID = nil; selectedEdgeID = nil; evidence = []; cameraReset += 1
        await refresh()
    }

    func clearSearch() {
        guard !searchQuery.isEmpty || !searchNotes.isEmpty else { return }
        searchQuery = ""; searchNotes = []
        Task { await refresh() }
    }

    private func refreshMindMap(token: UUID) async throws {
        let available = try await store.mindMapSummaries()
        let availableIDs = Set(available.map(\.id))
        let requested = selectedMindMapNoteID.flatMap { availableIDs.contains($0) ? $0 : nil }
            ?? mindMap.noteID.flatMap { availableIDs.contains($0) ? $0 : nil }
            ?? available.first?.id
        let updated = try await store.mindMapSnapshot(noteID: requested)
        guard token == refreshToken else { return }
        mindMaps = available
        selectedMindMapNoteID = updated.noteID
        mindMap = updated
        if !choseCanvasMode, !updated.nodes.isEmpty {
            canvasMode = .mindMap
        }
        if let selectedMapNodeID,
           !updated.nodes.contains(where: { $0.id == selectedMapNodeID })
        {
            self.selectedMapNodeID = nil
            mapEvidence = []
        } else if let selectedMapNodeID {
            mapEvidence = try await store.mindMapEvidence(nodeID: selectedMapNodeID)
        }
    }

    func showCanvas(_ mode: KnowledgeCanvasMode) {
        choseCanvasMode = true
        canvasMode = mode
        if mode == .graph {
            selectedMapNodeID = nil
            mapEvidence = []
        } else {
            deselect()
        }
    }

    func selectMapNode(_ id: String) {
        selectedMapNodeID = id
        selectedID = nil
        selectedEdgeID = nil
        evidence = []
        Task {
            do { mapEvidence = try await store.mindMapEvidence(nodeID: id) }
            catch { self.error = error.localizedDescription }
        }
    }

    func deselectMapNode() {
        selectedMapNodeID = nil
        mapEvidence = []
    }

    func selectMindMap(_ noteID: UUID) {
        guard noteID != selectedMindMapNoteID else { return }
        selectedMindMapNoteID = noteID
        selectedMapNodeID = nil
        mapEvidence = []
        Task { await refresh() }
    }

    func toggleMapNode(_ id: String) {
        guard let index = mindMap.nodes.firstIndex(where: { $0.id == id }),
              mindMap.nodes.contains(where: { $0.parentID == id }),
              let noteID = mindMap.noteID else { return }
        let collapsed = !mindMap.nodes[index].collapsed
        mindMap.nodes[index].collapsed = collapsed
        Task {
            do { try await store.setMindMapCollapsed(id, noteID: noteID, collapsed: collapsed) }
            catch { self.error = error.localizedDescription }
        }
    }

    func select(_ id: String, edgeID: String? = nil) {
        selectedID = id; selectedEdgeID = edgeID; evidence = []; evidenceLimit = 100
        Task { await refresh() }
    }

    func deselect() {
        selectedID = nil; selectedEdgeID = nil; evidence = []
    }

    func focus(noteID: UUID) {
        selectedID = nil; selectedEdgeID = nil; evidence = []
        selectedMindMapNoteID = noteID
        selectedMapNodeID = nil; mapEvidence = []
        focusID = nil; searchQuery = ""; searchNotes = [noteID]; cameraReset += 1
        Task { await refresh() }
    }

    func overview() {
        selectedID = nil; selectedEdgeID = nil; focusID = nil; evidence = []
        selectedMapNodeID = nil; mapEvidence = []
        searchQuery = ""; searchNotes = []
        visibleLimit = 200; cameraReset += 1
        Task { await refresh() }
    }

    func expand() {
        visibleLimit = min(500, visibleLimit + 100)
        Task { await refresh() }
    }

    func moreEvidence() {
        evidenceLimit = min(1000, evidenceLimit + 100)
        Task { await refresh() }
    }

    func retry(_ id: UUID, rebuild: Bool = false) async {
        do { try await store.retryGraph(id, rebuild: rebuild); await refresh(); startExtraction() }
        catch { self.error = error.localizedDescription }
    }

    func pause(_ id: UUID) async {
        do {
            try await store.pauseGraph(id)
            // Cancel the inference itself as well as revoking its publication token.
            if jobs
                .contains(where: {
                    $0.noteID == id && ["running", "curating"].contains($0.state)
                })
            {
                extractionTask?.cancel()
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func startLayout() {
        layoutTask?.cancel()
        let token = UUID(); layoutToken = token
        layingOut = !snapshot.nodes.isEmpty
        let snapshot = snapshot, initial = positions, animate = !reduceMotion
        layoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await layout
                    .settle(snapshot, positions: initial, animate: animate) { [weak self] next in
                        await self?.acceptLayout(next, token: token)
                    }
                try Task.checkCancellation()
                guard token == layoutToken else { return }
                layingOut = false
                preparingInitialGraph = false
                try await store.saveGraphPositions(positions)
            } catch is CancellationError {} catch {
                preparingInitialGraph = false
                self.error = error.localizedDescription
            }
        }
    }

    private func acceptLayout(_ next: [String: GraphPosition], token: UUID) {
        guard token == layoutToken else { return }
        positions = next
    }

    func move(_ id: String, to position: GraphPosition) {
        layoutTask?.cancel(); layoutToken = UUID(); layingOut = false
        positions[id] = position
    }

    func persistPosition(_ id: String) {
        guard let point = positions[id] else { return }
        Task {
            do { try await store.saveGraphPositions([id: point]); startLayout() }
            catch { self.error = error.localizedDescription }
        }
    }
}
