import Foundation
import Observation

@MainActor @Observable
final class ConversationModel {
    let store: DocumentStore
    let coordinator: AgentCoordinator
    let chatGPT: ChatGPTConnection
    @ObservationIgnored private let customCoordinator: Bool
    var messages: [ConversationMessage] = []
    var tasks: [ConversationTask] = []
    var proposals: [KnowledgeProposal] = []
    /// Changesets from the library agent, grouped by the task that proposed them.
    var agentChanges: [UUID: [AgentChange]] = [:]
    var categories: [DecimalCategory] = []
    var selectedSources: [UUID] = []
    var titles: [UUID: String] = [:]
    var composer = ""
    var error: String?
    var ready = false
    var hasOlderMessages = true
    private(set) var clearingConversation = false
    @ObservationIgnored private var conversationEpoch = UUID()
    private var submitting = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored var didMutate: (@MainActor () async -> Void)?

    init(
        store: DocumentStore,
        coordinator: AgentCoordinator? = nil,
        chatGPT: ChatGPTConnection? = nil
    ) {
        self.store = store
        self.chatGPT = chatGPT ?? ChatGPTConnection()
        customCoordinator = coordinator != nil
        self.coordinator = coordinator ??
            AgentCoordinator(
                store: store, screenshotter: WebPageScreenshotter(),
                captureSettings: CaptureSettings.current
            )
    }

    var activeTask: ConversationTask? {
        tasks.first { $0.id == activeID && $0.active }
    }

    var running: Bool {
        worker != nil
    }

    private var connectionReady: Bool {
        customCoordinator || (!chatGPT.busy && !chatGPT.signingIn)
    }

    private func configureInference() async throws {
        if !customCoordinator {
            try await coordinator.setInference(chatGPT.requestInference())
        }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            _ = try await store.open(loadDocuments: false)
            try await store.recoverConversation()
            await refresh()
            if !customCoordinator {
                await chatGPT.load()
            }
            ready = true
        } catch { self.error = error.localizedDescription; loaded = false }
    }

    func refresh() async {
        guard !clearingConversation else { return }
        let epoch = conversationEpoch
        do {
            let latest = try await store.conversationMessages(limit: 200)
            let latestIDs = Set(latest.map(\.id))
            let updatedMessages = (messages.filter { !latestIDs.contains($0.id) } + latest)
                .sorted { $0.sequence < $1.sequence }
            let updatedTasks = try await store.conversationTasks()
            let updatedProposals = try await store.proposals()
            let updatedChanges = try await Dictionary(grouping: store.agentChanges(), by: \.taskID)
            let updatedCategories = try await store.categories()
            var updatedTitles = titles
            for id in Set(updatedMessages.flatMap(\.references) + selectedSources + updatedProposals
                .flatMap { [
                    $0.left,
                    $0.right,
                ] } + updatedChanges.values.joined().flatMap { [$0.noteID, $0.targetID] }
                .compactMap(\.self))
            {
                updatedTitles[id] = try await store.document(id: id)?.name ?? "Deleted document"
            }
            guard conversationEpoch == epoch, !clearingConversation else { return }
            messages = updatedMessages
            tasks = updatedTasks
            proposals = updatedProposals
            agentChanges = updatedChanges
            categories = updatedCategories
            titles = updatedTitles
        } catch { self.error = error.localizedDescription }
    }

    func loadOlder() async {
        guard !clearingConversation else { return }
        let epoch = conversationEpoch
        do {
            let older = try await store.conversationMessages(
                before: messages.first?.sequence,
                limit: 200
            )
            guard conversationEpoch == epoch, !clearingConversation else { return }
            let ids = Set(messages.map(\.id))
            messages.insert(contentsOf: older.filter { !ids.contains($0.id) }, at: 0)
            hasOlderMessages = older.count == 200
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func send(
        retry: ConversationTask? = nil,
        captureID: UUID? = nil,
        submittedRequest: String? = nil
    ) async {
        guard ready, !submitting else { return }
        guard connectionReady else {
            error = "Finish or cancel the ChatGPT connection before starting a task."
            return
        }
        submitting = true
        defer { submitting = false }
        if running {
            await cancel()
        }
        let request = submittedRequest ?? retry?.request ?? composer
        do {
            try await configureInference()
            let route = try ConversationRoute(request)
            let last = messages.last(where: { $0.author != "user" && !$0.references.isEmpty })
            let lastSources = last?
                .author == "researcher" ? Array(last?.references.dropFirst() ?? []) : last?
                .references ?? []
            let capturing = route.url != nil || captureID != nil || retry?.captureID != nil
            let context = capturing ? [] : retry?
                .sources ??
                (selectedSources.isEmpty ? Array(lastSources.prefix(4)) : selectedSources)
            let userSelected = !capturing && retry == nil && !selectedSources.isEmpty
            let id = try await store.beginConversation(
                request,
                owner: route.roles[0],
                captureID: captureID ?? retry?.captureID,
                sources: context
            )
            if submittedRequest == nil {
                composer = ""
            }
            error = nil
            activeID = id
            await refresh()
            worker = Task { [weak self] in
                guard let self else { return }
                do {
                    try await coordinator.execute(
                        taskID: id,
                        request: request,
                        selected: context,
                        userSelected: userSelected,
                        existingCaptureID: captureID ?? retry?
                            .captureID
                    ) { [weak self] in
                        await self?.refresh()
                    }
                } catch is CancellationError {
                    do { try await store.updateConversationTask(
                        id,
                        state: "cancelled",
                        progress: "Cancelled; saved content is retained",
                        event: "cancelled"
                    ) } catch { self.error = error.localizedDescription }
                } catch {
                    let message = error.localizedDescription
                    do { try await store.updateConversationTask(
                        id,
                        state: "failed",
                        progress: message,
                        event: "failed"
                    ) } catch { self.error = error.localizedDescription }
                }
                await refresh()
                await didMutate?()
                worker = nil
                activeID = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    func importFile(_ url: URL) async {
        do {
            let capture = try await coordinator.ingestion.enqueueFile(url)
            await send(
                captureID: capture,
                submittedRequest: "@librarian summarize imported document: \(url.lastPathComponent)"
            )
        } catch { self.error = error.localizedDescription }
    }

    func cancel() async {
        guard let id = activeID, let worker else { return }
        worker.cancel()
        do {
            try await store.updateConversationTask(
                id,
                state: "cancelled",
                progress: "Cancelled; saved content is retained",
                event: "cancelled"
            )
            if let capture = activeTask?.captureID {
                try await coordinator.cancelCapture(capture)
            }
        } catch { self.error = error.localizedDescription }
        await worker.value
        await refresh()
    }

    func clearConversation() async {
        guard ready, !submitting else { return }
        submitting = true
        clearingConversation = true
        conversationEpoch = UUID()
        defer { submitting = false; clearingConversation = false }
        await cancel()
        do {
            try await store.clearConversation()
            conversationEpoch = UUID()
            messages = []
            tasks = []
            selectedSources = []
            titles = [:]
            hasOlderMessages = true
            error = nil
            clearingConversation = false
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func select(_ id: UUID) {
        if selectedSources.contains(id) {
            selectedSources.removeAll { $0 == id }
        } else if selectedSources.count < 4 {
            selectedSources.append(id)
        }
    }

    /// Library selection prepares evidence; it never sends a message or overwrites a draft.
    func prepareSources(_ ids: [UUID]) async -> Bool {
        guard ready, !submitting, !clearingConversation, !ids.isEmpty, ids.count <= 4,
              Set(ids).count == ids.count else { return false }
        do {
            for id in ids {
                guard try await store.document(id: id) != nil else {
                    error = "A selected item was deleted. Select the remaining items in Library again."
                    return false
                }
            }
            guard !submitting, !clearingConversation else { return false }
            selectedSources = ids
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func completeMention(_ role: AgentRole) {
        guard let range = ConversationRoute.mentionRange(in: composer) else { return }
        composer.replaceSubrange(range, with: "@\(role.rawValue) ")
    }

    func review(_ proposal: KnowledgeProposal, action: String) async {
        do { try await store.reviewProposal(proposal.id, action: action) }
        catch { self.error = error.localizedDescription }
        await refresh()
        await didMutate?()
    }

    /// Applies the chosen changes and rejects the rest of the changeset.
    func applyAgentChanges(_ ids: Set<UUID>, of changeset: [AgentChange]) async {
        let pending = changeset.filter { $0.status == "pending" }
        do {
            let report = try await store
                .applyAgentChanges(pending.filter { ids.contains($0.id) }.map(\.id))
            try await store.rejectAgentChanges(pending.filter { !ids.contains($0.id) }.map(\.id))
            if report.stale > 0 {
                error = "\(report.stale) change\(report.stale == 1 ? " was" : "s were") skipped because the item changed since it was proposed."
            }
        } catch { self.error = error.localizedDescription }
        await refresh()
        await didMutate?()
    }

    func rejectAgentChanges(_ changeset: [AgentChange]) async {
        do {
            try await store
                .rejectAgentChanges(changeset.filter { $0.status == "pending" }.map(\.id))
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func undoAgentChanges(_ changeset: [AgentChange]) async {
        let applied = changeset.filter { $0.status == "applied" }
        do {
            let undone = try await store.undoAgentChanges(applied.map(\.id))
            if undone < applied.count {
                error = "\(applied.count - undone) change\(applied.count - undone == 1 ? " was" : "s were") kept because the item was edited again since."
            }
        } catch { self.error = error.localizedDescription }
        await refresh()
        await didMutate?()
    }

    func saveCategory(id: UUID = UUID(), code: String, name: String) async {
        do { try await store.saveCategory(id: id, code: code, name: name) }
        catch { self.error = error.localizedDescription }
        await refresh()
    }
}
