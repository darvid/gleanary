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
    /// Writer scopes waiting for confirmation, by task.
    var writerScopes: [UUID: WriterRequest] = [:]
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
                captureSettings: CaptureSettings.current,
                writingStyles: { WritingStyleChoice.current() }
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
            let updatedScopes = try await Dictionary(
                store.awaitingWriterRequests().map { ($0.taskID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
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
            writerScopes = updatedScopes
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
        submittedRequest: String? = nil,
        sources: [UUID]? = nil
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
            let context = capturing ? [] : sources ?? retry?
                .sources ??
                (selectedSources.isEmpty ? Array(lastSources.prefix(4)) : selectedSources)
            let userSelected = !capturing && retry == nil
                && (sources != nil || !selectedSources.isEmpty)
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
            let coordinator = coordinator
            let changed: @Sendable () async -> Void = { [weak self] in await self?.refresh() }
            run(id) {
                try await coordinator.execute(
                    taskID: id,
                    request: request,
                    selected: context,
                    userSelected: userSelected,
                    existingCaptureID: captureID ?? retry?.captureID,
                    changed: changed
                )
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Runs a task's work in the background, recording cancellation or failure on the task.
    private func run(_ id: UUID, operation: @escaping @Sendable () async throws -> Void) {
        activeID = id
        worker = Task { [weak self] in
            do {
                try await operation()
            } catch is CancellationError {
                await self?.finish(id, state: "cancelled", progress: Self.cancelledProgress)
            } catch {
                await self?.finish(id, state: "failed", progress: error.localizedDescription)
            }
            guard let self else { return }
            await refresh()
            await didMutate?()
            worker = nil
            activeID = nil
        }
    }

    private static let cancelledProgress = "Cancelled; saved content is retained"

    private func finish(_ id: UUID, state: String, progress: String) async {
        do {
            try await store.updateConversationTask(
                id, state: state, progress: progress, event: state
            )
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Suggested filing

    /// Asks the Librarian where one item belongs, with the current AI provider.
    func suggestHome(for id: UUID) async throws -> HomeSuggestion? {
        if !running {
            try? await configureInference()
        }
        return try await coordinator.suggestHome(for: id)
    }

    /// Files the item where the Librarian suggested, creating a new category first if that was
    /// the suggestion. Returns the changes, so Undo can put the old filing back.
    func fileAsSuggested(_ id: UUID, _ suggestion: HomeSuggestion) async throws -> [UUID] {
        guard let home = suggestion.category else { return [] }
        let previous = try await store.categories(for: id).first?.label ?? "Unfiled"
        var drafts = [AgentChangeDraft(
            kind: .filing, noteID: id, code: home.code, before: previous, after: home.label,
            reason: suggestion.rationale
        )]
        if suggestion.isNew {
            drafts.insert(AgentChangeDraft(
                kind: .category, code: home.code, before: "", after: home.name,
                reason: suggestion.rationale
            ), at: 0)
        }
        let batch = UUID()
        try await store.saveAgentChanges(drafts, taskID: batch)
        let ids = try await store.agentChanges(taskID: batch).map(\.id)
        let report = try await store.applyAgentChanges(ids)
        guard report.stale == 0 else {
            _ = try await store.undoAgentChanges(ids)
            throw ConversationError.staleProposal
        }
        await refresh()
        return ids
    }

    /// Adds one of the Librarian's "also fits" homes as a secondary home.
    func addSuggestedHome(_ id: UUID, _ home: DecimalCategory) async throws -> Bool {
        let added = try await store.addSecondaryHome(id, categoryID: home.id)
        await refresh()
        return added
    }

    func removeSuggestedHome(_ id: UUID, _ home: DecimalCategory) async throws {
        try await store.removeSecondaryHome(id, categoryID: home.id)
        await refresh()
    }

    func undoSuggestedFiling(_ ids: [UUID]) async throws {
        _ = try await store.undoAgentChanges(ids)
        await refresh()
    }

    // MARK: Writer

    /// Confirms a gathered scope and resumes its task: extract, write and save.
    func confirmScope(
        _ taskID: UUID,
        selection: [UUID],
        style: WritingStyle,
        generalKnowledge: Bool
    ) async {
        guard ready, !submitting, !running else {
            error = "Finish or stop the current task before confirming the scope."
            return
        }
        do {
            try await configureInference()
            try await store.confirmWriterScope(
                taskID: taskID, selection: selection, style: style,
                generalKnowledge: generalKnowledge
            )
            error = nil
            await refresh()
            let coordinator = coordinator
            let changed: @Sendable () async -> Void = { [weak self] in await self?.refresh() }
            run(taskID) { try await coordinator.continueCompose(taskID: taskID, changed: changed) }
        } catch { self.error = error.localizedDescription }
    }

    /// Dismisses a gathered scope; nothing was read or saved.
    func cancelScope(_ taskID: UUID) async {
        do {
            try await store.setWriterRequestStatus(taskID, .cancelled)
            try await store.updateConversationTask(
                taskID, state: "cancelled", progress: "Cancelled before anything was read",
                event: "cancelled"
            )
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    /// Re-runs a composed document's request in chat; its changes come back for review.
    func refreshDocument(_ id: UUID) async {
        var title = titles[id]
        if title == nil {
            title = try? await store.document(id: id)?.name
        }
        await send(submittedRequest: "@writer refresh “\(title ?? "this document")”", sources: [id])
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
        // Marked first: a save that lands after this finds the task cancelled and writes nothing.
        do {
            try await store.updateConversationTask(
                id,
                state: "cancelled",
                progress: Self.cancelledProgress,
                event: "cancelled"
            )
        } catch { self.error = error.localizedDescription }
        worker.cancel()
        do {
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
