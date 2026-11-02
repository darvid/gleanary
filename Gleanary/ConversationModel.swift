import Foundation
import Observation

@MainActor @Observable
final class ConversationModel {
    let store: DocumentStore
    let coordinator: AgentCoordinator
    let providers: InferenceProviders
    var chatGPT: ChatGPTConnection {
        providers.chatGPT
    }

    @ObservationIgnored private let customCoordinator: Bool
    var messages: [ConversationMessage] = []
    var tasks: [ConversationTask] = []
    var proposals: [KnowledgeProposal] = []
    /// Changesets from the library agent, grouped by the task that proposed them.
    var agentChanges: [UUID: [AgentChange]] = [:]
    /// Writer scopes waiting for confirmation, by task.
    var writerScopes: [UUID: WriterRequest] = [:]
    var categories: [DecimalCategory] = []
    var seriesFiling: [UUID: SeriesFiling.Status] = [:]
    var selectedSources: [UUID] = []
    var titles: [UUID: String] = [:]
    var referenceDetails: [UUID: ConversationReference] = [:]
    /// What pasted links became, by capture identity.
    var capturedLinks: [String: CapturedLink] = [:]
    /// Links found inside referenced sources that are suggested or being saved, by source.
    var acquisitionSuggestions: [UUID: [AcquisitionCandidate]] = [:]
    private(set) var savingAcquisitions = Set<UUID>()
    private(set) var exploringNotes = Set<UUID>()
    /// Reply text a provider is still generating, by task. Display only; never persisted.
    private(set) var replyDrafts: [UUID: ReplyDraft] = [:]
    var composer = ""
    /// A saved document someone asked to open beside Chat, such as from the command palette.
    var documentRequest: UUID?
    private(set) var composerFocusRequest = UUID()
    var error: String?
    var ready = false
    var hasOlderMessages = true
    private(set) var clearingConversation = false
    @ObservationIgnored private var conversationEpoch = UUID()
    private var submitting = false
    private(set) var running = false
    /// Queued requests left from an earlier launch wait for Resume rather than starting alone.
    private(set) var queuePaused = false
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
        providers = InferenceProviders(chatGPT: chatGPT ?? ChatGPTConnection())
        customCoordinator = coordinator != nil
        self.coordinator = coordinator ??
            AgentCoordinator(
                store: store, screenshotter: WebPageScreenshotter(),
                pageRenderer: WebKitPageRenderer(),
                captureSettings: CaptureSettings.current,
                writingStyles: { WritingStyleChoice.current() }
            )
    }

    var activeTask: ConversationTask? {
        tasks.first { $0.id == activeID && $0.active }
    }

    /// Requests waiting their turn, next first.
    var queue: [ConversationTask] {
        tasks.filter(\.isQueued)
            .sorted { ($0.queueOrder ?? .infinity) < ($1.queueOrder ?? .infinity) }
    }

    func isWorking(on taskID: UUID) -> Bool {
        running && activeID == taskID
    }

    /// How long Chat waits after the last message before offering a new topic.
    static let topicGap: TimeInterval = 6 * 60 * 60

    /// A new topic needs something before it, and waits for work in flight, which was asked
    /// with the earlier context.
    var canStartTopic: Bool {
        ready && !running && queue.isEmpty && !clearingConversation
            && messages.last.map { !$0.isTopicBoundary } == true
    }

    /// Whether to offer a new topic: it's been a while since the last message.
    func offersNewTopic(at now: Date) -> Bool {
        guard canStartTopic, let last = messages.last else { return false }
        return now.timeIntervalSince(last.createdAt) >= Self.topicGap
    }

    func startTopic() async {
        guard canStartTopic else { return }
        do {
            try await store.startConversationTopic()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func saveAcquisition(_ candidate: AcquisitionCandidate) async {
        savingAcquisitions.insert(candidate.id)
        defer { savingAcquisitions.remove(candidate.id) }
        let changed: @Sendable () async -> Void = { [weak self] in await self?.refresh() }
        do {
            try await coordinator.saveAcquisition(candidate.id, changed: changed)
        } catch { self.error = error.localizedDescription }
        await refresh()
        await didMutate?()
    }

    /// Follows a note's links once with Eager rules, whatever the overall level.
    func exploreFrom(_ noteID: UUID) async {
        exploringNotes.insert(noteID)
        defer { exploringNotes.remove(noteID) }
        let changed: @Sendable () async -> Void = { [weak self] in await self?.refresh() }
        do {
            _ = try await coordinator.exploreFrom(noteID, changed: changed)
        } catch { self.error = error.localizedDescription }
        await refresh()
        await didMutate?()
    }

    /// Stops suggesting and saving links from this site.
    func muteAcquisitionHost(_ host: String) async {
        do {
            try await store.muteAcquisitionHost(host)
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func dismissAcquisition(_ candidate: AcquisitionCandidate) async {
        do {
            try await store.dismissAcquisition(candidate.id)
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    /// Empty text withdraws the draft, as when the model turns to tools instead of replying.
    func streamReply(_ text: String, taskID: UUID) {
        guard isWorking(on: taskID) else { return }
        guard !text.isEmpty else {
            replyDrafts[taskID] = nil
            return
        }
        replyDrafts[taskID, default: ReplyDraft(after: messages.last?.sequence ?? 0)].text = text
    }

    private var connectionReady: Bool {
        customCoordinator || !providers.busy
    }

    private func configureInference() async throws {
        if !customCoordinator {
            try await coordinator.setInference(
                providers.requestInference(),
                filing: providers.filingInference()
            )
        }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            _ = try await store.open(loadDocuments: false)
            try await store.recoverConversation()
            await refresh()
            queuePaused = !queue.isEmpty
            if !customCoordinator {
                await providers.load()
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
            let updatedFiling = try await store.publishedSeriesFiling()
            let updatedScopes = try await Dictionary(
                store.awaitingWriterRequests().map { ($0.taskID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var updatedTitles = titles
            let referenceIDs = Set(updatedMessages
                .flatMap(\.references) + selectedSources + updatedProposals
                .flatMap { [
                    $0.left,
                    $0.right,
                ] } + updatedChanges.values.joined().flatMap { [$0.noteID, $0.targetID] }
                .compactMap(\.self))
            let updatedReferences = try await store.conversationReferences(referenceIDs)
            let updatedSuggestions = try await store.acquisitionSuggestions(
                foundIn: Set(updatedMessages.filter { $0.author != "user" }.flatMap(\.references))
            )
            let linkIdentities = Set(updatedMessages.filter { $0.author == "user" }
                .flatMap { PastedLinks.urls(in: $0.text) }.compactMap(PastedLinks.identity))
                .union(updatedSuggestions.values.joined().map(\.identity))
            let updatedLinks = try await store.capturedLinks(identities: linkIdentities)
            for id in referenceIDs {
                updatedTitles[id] = updatedReferences[id]?.title ?? "Deleted document"
            }
            guard conversationEpoch == epoch, !clearingConversation else { return }
            messages = updatedMessages
            tasks = updatedTasks
            proposals = updatedProposals
            agentChanges = updatedChanges
            categories = updatedCategories
            seriesFiling = updatedFiling
            writerScopes = updatedScopes
            titles = updatedTitles
            referenceDetails = updatedReferences
            capturedLinks = updatedLinks
            acquisitionSuggestions = updatedSuggestions
        } catch { self.error = error.localizedDescription }
    }

    func undoSeriesFiling(_ status: SeriesFiling.Status) async {
        do {
            for batch in status.batches {
                _ = try await store.undoFilingSuggestions(
                    batch: batch,
                    noteIDs: Set(status.noteIDs),
                    includeSources: false
                )
            }
            await refresh()
            await didMutate?()
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
        // Sent while another request runs, this waits its turn instead of cancelling it.
        let queues = running
        let request = submittedRequest ?? retry?.request ?? composer
        // Several pasted links are saved one at a time, each as its own request.
        let links = PastedLinks.isOnlyLinks(request) ? PastedLinks.urls(in: request) : []
        if links.count > 1, retry == nil, captureID == nil, sources == nil {
            await enqueue(links.map(\.absoluteString), startFirst: !queues)
            return
        }
        do {
            // A queued request picks up the current provider when it starts; the running task
            // keeps the one it began with.
            if !queues {
                try await configureInference()
            }
            if let retry, try await store.noteSeriesRun(taskID: retry.id) != nil {
                guard !queues else {
                    error = "Retry this series once the current request finishes."
                    return
                }
                try await store.retryNoteSeries(taskID: retry.id)
                error = nil
                await refresh()
                let coordinator = coordinator
                let changed: @Sendable () async -> Void = { [weak self] in await self?.refresh() }
                run(retry.id) {
                    try await coordinator.execute(
                        taskID: retry.id,
                        request: request,
                        selected: retry.sources,
                        changed: changed
                    )
                }
                return
            }
            let toolDriven = await coordinator.usesConversationTools
            let route = try ConversationRoute(request, detectsURL: !toolDriven)
            let capturing = route.url != nil || captureID != nil || retry?.captureID != nil
            // History remains conversational context, not invisible draft attachments.
            let context = capturing ? [] : sources ?? retry?.sources ?? selectedSources
            let userSelected = !capturing && retry == nil
                && (sources != nil || !selectedSources.isEmpty)
            let id = try await store.beginConversation(
                request,
                owner: route.roles[0],
                captureID: captureID ?? retry?.captureID,
                sources: context,
                queued: queues
            )
            if submittedRequest == nil, retry == nil {
                composer = ""
                if !capturing, sources == nil {
                    selectedSources.removeAll { context.contains($0) }
                }
            }
            error = nil
            guard !queues else {
                await refresh()
                return
            }
            activeID = id
            await refresh()
            start(
                id, request: request, context: context, userSelected: userSelected,
                captureID: captureID ?? retry?.captureID
            )
        } catch { self.error = error.localizedDescription }
    }

    /// Queues each link as its own request, starting the first when nothing is running.
    private func enqueue(_ requests: [String], startFirst: Bool) async {
        do {
            let toolDriven = await coordinator.usesConversationTools
            for request in requests {
                let route = try ConversationRoute(request, detectsURL: !toolDriven)
                _ = try await store.beginConversation(
                    request, owner: route.roles[0], queued: true
                )
            }
            composer = ""
            error = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
        if startFirst {
            await startNextQueued()
        }
    }

    private func start(
        _ id: UUID, request: String, context: [UUID], userSelected: Bool, captureID: UUID?
    ) {
        let coordinator = coordinator
        let changed: @Sendable () async -> Void = { [weak self] in await self?.refresh() }
        run(id) {
            try await coordinator.execute(
                taskID: id,
                request: request,
                selected: context,
                userSelected: userSelected,
                existingCaptureID: captureID,
                changed: changed,
                streamed: { [weak self] text in await self?.streamReply(text, taskID: id) }
            )
        }
    }

    // MARK: Queue

    /// Starts the next waiting request, unless something is running or the queue is paused.
    func startNextQueued() async {
        guard ready, !running, !clearingConversation, !queuePaused else { return }
        await refresh()
        guard let next = queue.first else { return }
        do {
            guard try await store.startQueuedConversationTask(next.id) else {
                await startNextQueued()
                return
            }
            try await configureInference()
            let toolDriven = await coordinator.usesConversationTools
            let route = try ConversationRoute(next.request, detectsURL: !toolDriven)
            let capturing = route.url != nil || next.captureID != nil
            activeID = next.id
            await refresh()
            start(
                next.id, request: next.request, context: capturing ? [] : next.sources,
                userSelected: !capturing && !next.sources.isEmpty, captureID: next.captureID
            )
        } catch {
            await finish(next.id, state: "failed", progress: error.localizedDescription)
            await refresh()
            await startNextQueued()
        }
    }

    /// Runs the queue left from an earlier launch.
    func resumeQueue() async {
        queuePaused = false
        await startNextQueued()
    }

    func removeFromQueue(_ id: UUID) async {
        await finish(id, state: "cancelled", progress: Self.removedProgress)
        await refresh()
        if queue.isEmpty {
            queuePaused = false
        }
    }

    func clearQueue() async {
        for task in queue {
            await finish(task.id, state: "cancelled", progress: Self.removedProgress)
        }
        queuePaused = false
        await refresh()
    }

    /// Moves a waiting request earlier (negative) or later (positive) in the queue.
    func moveInQueue(_ id: UUID, by offset: Int) async {
        var ids = queue.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = min(max(index + offset, 0), ids.count - 1)
        guard target != index else { return }
        ids.remove(at: index)
        ids.insert(id, at: target)
        do { try await store.reorderConversationQueue(ids) }
        catch { self.error = error.localizedDescription }
        await refresh()
    }

    private static let removedProgress = "Removed from the queue"

    /// Runs a task's work in the background, recording cancellation or failure on the task.
    private func run(_ id: UUID, operation: @escaping @Sendable () async throws -> Void) {
        activeID = id
        running = true
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
            running = false
            replyDrafts[id] = nil
            // Whether it finished, failed or was stopped, the next request takes its turn.
            await startNextQueued()
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

    @discardableResult
    func clearConversation(discardDraft: Bool = false) async -> Bool {
        guard ready, !submitting else { return false }
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
            queuePaused = false
            selectedSources = []
            if discardDraft {
                composer = ""
            }
            titles = [:]
            referenceDetails = [:]
            capturedLinks = [:]
            acquisitionSuggestions = [:]
            hasOlderMessages = true
            error = nil
            clearingConversation = false
            await refresh()
            composerFocusRequest = UUID()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func select(_ id: UUID) {
        if selectedSources.contains(id) {
            selectedSources.removeAll { $0 == id }
        } else if selectedSources.count < 4 {
            selectedSources.append(id)
        }
    }

    /// Detail actions append context without toggling existing attachments or sending.
    func addToChat(_ target: ChatAttachmentTarget) async -> Bool {
        if !ready {
            await load()
        }
        guard ready, !submitting, !clearingConversation else {
            error = "Chat is busy. Try adding the item again in a moment."
            return false
        }
        let epoch = conversationEpoch
        do {
            let id: UUID = switch target {
            case let .note(id): id
            case let .source(captureID): try await store.sourceNoteID(for: captureID)
            }
            guard try await store.document(id: id) != nil else {
                error = "This item was deleted and cannot be added to Chat."
                return false
            }
            guard conversationEpoch == epoch, !submitting, !clearingConversation else {
                return false
            }
            if !selectedSources.contains(id) {
                guard selectedSources.count < 4 else {
                    error = "Chat already has four attachments. Remove one before adding another."
                    return false
                }
                selectedSources.append(id)
            }
            await refresh()
            guard conversationEpoch == epoch, !clearingConversation else { return false }
            error = nil
            composerFocusRequest = UUID()
            return true
        } catch { self.error = error.localizedDescription; return false }
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

/// A reply still being generated. Messages after `after` belong to the finished turn.
struct ReplyDraft: Equatable {
    let after: Int64
    var text = ""
}
