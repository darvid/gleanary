import Foundation

actor AgentCoordinator {
    /// Reads items for entities when you ask in chat.
    let graphProvider: any GraphExtracting
    let store: DocumentStore
    let ingestion: IngestionEngine
    private(set) var inference: any ConversationInferring
    private(set) var filingInference: (any ConversationInferring)?
    let search: SearchEngine
    let researchFetcher: any SourceFetching
    let writingStyles: @Sendable () -> WritingStyleChoice
    /// One task runs at a time; the Writer's confirmed scope resumes under the same guard.
    var executing = false

    init(
        store: DocumentStore,
        fetcher: any SourceFetching = SourceFetcher(),
        inference: any ConversationInferring = AppleConversationInference(),
        screenshotter: (any PageScreenshotting)? = nil,
        youtube: any YouTubeProviding = NativeYouTubeProvider(),
        graphProvider: any GraphExtracting = AppleGraphExtractor(),
        captureSettings: @escaping @Sendable () -> CaptureSettings = { CaptureSettings() },
        writingStyles: @escaping @Sendable () -> WritingStyleChoice = { WritingStyleChoice() }
    ) {
        self.store = store
        researchFetcher = fetcher
        self.inference = inference
        self.writingStyles = writingStyles
        self.graphProvider = graphProvider
        ingestion = IngestionEngine(
            store: store, fetcher: fetcher, youtube: youtube, screenshotter: screenshotter,
            settings: captureSettings,
            recommendationJudge: inference as? any RecommendationJudging
        )
        search = SearchEngine(store: store)
    }

    /// Tool-capable providers reason over actual tool results. Explicit capture retries and
    /// providers without tool turns retain the bounded workflow adapter below. Application
    /// code owns persistence, evidence verification and review permissions.
    /// `userSelected` is true when the user picked `selected` themselves, rather than it being
    /// inferred from the last agent message.
    func execute(
        taskID: UUID,
        request: String,
        selected: [UUID],
        userSelected: Bool = false,
        existingCaptureID: UUID? = nil,
        changed: @escaping @Sendable () async -> Void,
        streamed: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws {
        guard !executing else { throw ConversationError.busy }
        executing = true
        defer { executing = false }
        if let run = try await store.noteSeriesRun(taskID: taskID) {
            try await continueNoteSeries(run, changed: changed)
            return
        }
        if let model = toolResponder(forCaptureRetry: existingCaptureID) {
            try await converseWithTools(
                taskID: taskID,
                request: request,
                selected: selected,
                model: model,
                changed: changed,
                streamed: streamed
            )
            return
        }
        let route = try ConversationRoute(request)
        let context = try await planningContext(taskID: taskID, selected: selected)
        let plan = try await workflowAdapterPlan(
            taskID: taskID,
            route: route,
            context: context,
            selected: selected,
            existingCaptureID: existingCaptureID,
            changed: changed
        )
        try plan.validate(context: context, hasURL: route.url != nil || existingCaptureID != nil)
        try Task.checkCancellation()
        let owner = plan.steps.first?.action == .chat ? route.roles.first : plan.steps.first?.action
            .owner
        try await store.updateConversationTask(
            taskID,
            progress: "Working",
            owner: owner,
            event: "delegated"
        )
        if plan.steps.first?.action == .ingest {
            try await capture(
                taskID: taskID,
                route: route,
                existingCaptureID: existingCaptureID,
                changed: changed
            )
        } else {
            // Composing gathers its own scope; only items the person picked join it, not the
            // follow-up context from the last reply.
            var references = Self.composes(plan) && !userSelected ? [] : selected
            for (index, step) in plan.steps.enumerated() {
                try Task.checkCancellation()
                if !step.targets.isEmpty {
                    references = step.targets
                } else if step.action == .file, index > 0, plan.steps[index - 1].action == .search {
                    // "File my X under Y" files the best match, not every search hit.
                    references = Array(references.prefix(1))
                }
                // Follow-up context can hold several items (e.g. a capture and a related document).
                // Filing them all on an unnamed "this" would guess, so ask which one instead.
                if step.action == .file, step.targets.isEmpty, !userSelected,
                   references == selected, references.count > 1
                {
                    try await askWhichToFile(taskID: taskID, candidates: references)
                    continue
                }
                try await dispatch(
                    step,
                    taskID: taskID,
                    route: route,
                    references: &references,
                    changed: changed
                )
            }
        }
        try Task.checkCancellation()
        // A gathered scope waits for the person; confirming it resumes this same task.
        if plan.steps.first?.action == .compose,
           try await store.writerRequest(taskID: taskID)?.status == .awaiting
        {
            await changed()
            return
        }
        try await store.updateConversationTask(
            taskID,
            state: "succeeded",
            progress: "Completed",
            event: "completed"
        )
        await changed()
    }

    private func workflowAdapterPlan(
        taskID: UUID, route: ConversationRoute, context: ConversationPlanningContext,
        selected: [UUID], existingCaptureID: UUID?,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> ConversationPlan {
        if existingCaptureID != nil || route.url?.absoluteString == route.text {
            return ConversationPlan(steps: [.init(action: .ingest)])
        }
        if Self.isRefresh(route, selected: selected) {
            return ConversationPlan(steps: [.init(action: .refresh)])
        }
        try await store.updateConversationTask(taskID, progress: "Understanding request")
        await changed()
        return try await inference.plan(request: route.text, context: context)
    }

    private static func composes(_ plan: ConversationPlan) -> Bool {
        plan.steps.first?.action == .compose || plan.steps.first?.action == .researchSeries
    }

    /// "@writer refresh" with one document selected re-runs that document's request directly.
    private static func isRefresh(_ route: ConversationRoute, selected: [UUID]) -> Bool {
        route.roles == [.writer] && selected.count == 1
            && route.text.lowercased().hasPrefix("refresh")
    }

    func cancelCapture(_ id: UUID) async throws {
        try await ingestion.cancel(id)
    }

    func setInference(
        _ inference: any ConversationInferring,
        filing: (any ConversationInferring)? = nil
    ) async throws {
        guard !executing else { throw ConversationError.busy }
        self.inference = inference
        filingInference = filing
        // Captures made from Chat summarize with the same provider.
        await ingestion.useSummarizer(inference as? any LinkSummarizing ?? AppleLinkSummarizer())
        await ingestion.useRecommendationJudge(inference as? any RecommendationJudging)
    }

    private func toolResponder(forCaptureRetry captureID: UUID?) -> (any AgentResponding)? {
        guard captureID == nil else { return nil }
        return inference as? any AgentResponding
    }

    var usesConversationTools: Bool {
        inference is any AgentResponding
    }

    func capture(
        taskID: UUID,
        route: ConversationRoute,
        existingCaptureID: UUID?,
        postsAcknowledgement: Bool = true,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        let captureID: UUID
        if let existingCaptureID, let job = try await store.captureJob(id: existingCaptureID) {
            if job.state != .ready {
                try await store.retryCapture(existingCaptureID)
            }
            captureID = existingCaptureID
        } else {
            guard let url = route.url else { throw ConversationError.missingSource }
            captureID = try await ingestion.enqueue(url.absoluteString, summarizeLink: false)
        }
        try await store.updateConversationTask(
            taskID,
            progress: "Retaining and extracting source",
            captureID: captureID
        )
        await changed()
        // Recommended sources are saved after this capture's own reply.
        try await ingestion.run(changed: changed, deferAcquisition: true)
        try Task.checkCancellation()
        guard let job = try await store.captureJob(id: captureID), let noteID = job.noteID,
              job.state == .ready
        else {
            let job = try await store.captureJob(id: captureID)
            throw CaptureTaskFailure(message: job?
                .error ??
                "Capture did not complete. Retry or use Library to inspect the retained original.")
        }
        let source = try await store.researchSource(noteID: noteID)
        // Only previously unfiled captures receive automatic filing; a duplicate does not move
        // existing knowledge.
        let previouslyUnfiled = try await store.categories(for: noteID).isEmpty
        var filingExplanation = ""
        if previouslyUnfiled {
            let suggestion = try await suggestedFiling(
                taskID: taskID,
                ids: [noteID],
                request: route.text
            )
            if let category = suggestion?.category {
                // Filed through an applied proposal so the reason and Undo stay on the card.
                let proposal = try await store.proposeFiling(
                    noteID: noteID,
                    category: category,
                    rationale: suggestion?.rationale ?? "",
                    taskID: taskID
                )
                try await store.reviewProposal(proposal, action: "apply")
            } else {
                let inbox = try await store.categories().first { $0.code == "10" }
                if let inbox {
                    try await store.fileNote(
                        noteID,
                        categoryID: inbox.id,
                        includeSources: true
                    )
                }
                let options = (suggestion?.alternatives ?? []).filter { $0.id != inbox?.id }
                for category in options {
                    _ = try await store.proposeFiling(
                        noteID: noteID,
                        category: category,
                        rationale: suggestion?.rationale ?? "",
                        taskID: taskID
                    )
                }
                if let created = suggestion?.newCategory {
                    _ = try await store.proposeFiling(
                        noteID: noteID,
                        category: created,
                        rationale: suggestion?.rationale ?? "",
                        taskID: taskID,
                        creating: true
                    )
                    filingExplanation = " There's no \(created.name) category yet; apply the card below to create \(created.label) and file it there."
                } else {
                    filingExplanation = options.isEmpty
                        ? " No confident filing home was identified; review the filing categories to choose one."
                        : " No confident filing home was identified; apply one of the suggested homes below or keep it in Inbox."
                }
            }
        }
        try await acknowledgeCapture(
            taskID: taskID,
            noteID: noteID,
            explanation: filingExplanation,
            enabled: postsAcknowledgement
        )
        await changed()
        if source.document.evidenceBlocks.allSatisfy({ $0.method == "metadata-only" }) {
            try await store.postConversation(
                author: .researcher,
                text: "The source link is saved, but no authorized transcript was available. There is no source text to summarize.",
                references: [noteID],
                taskID: taskID
            )
            try await saveRecommendedSources(taskID: taskID, noteID: noteID, changed: changed)
            return
        }
        try await research(
            taskID: taskID,
            question: "Summarize this source. " + route.text,
            references: [noteID],
            changed: changed
        )
        try await suggestCaptureLinks(
            taskID: taskID,
            source: source,
            enabled: postsAcknowledgement,
            changed: changed
        )
        try await saveRecommendedSources(taskID: taskID, noteID: noteID, changed: changed)
    }

    private func acknowledgeCapture(
        taskID: UUID,
        noteID: UUID,
        explanation: String,
        enabled: Bool
    ) async throws {
        guard enabled else { return }
        let filed = try await store.categories(for: noteID).first?.label ?? "Unfiled"
        try await store.postConversation(
            author: .librarian,
            text: "Saved locally under \(filed). Original and extracted text are retained.\(explanation)",
            references: [noteID],
            taskID: taskID
        )
    }

    private func suggestCaptureLinks(
        taskID: UUID, source: ResearchSource, enabled: Bool,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard enabled else { return }
        try await related(
            taskID: taskID,
            note: source.note,
            query: source.document.title,
            changed: changed
        )
    }

    private func saveThought(taskID: UUID, step: ConversationPlan.Step) async throws {
        let text = step.argument
        let note = try await store.saveResearch(
            text,
            name: Self.savedNoteTitle(from: text),
            sources: [],
            taskID: taskID,
            provider: "user",
            kind: "note"
        )
        let category = try await store.categories().first { $0.id.uuidString == step.categoryID }
        if let category {
            try await store.fileNote(note.id, categoryID: category.id)
        }
        try await store.postConversation(
            author: .librarian,
            text: "Saved your note" +
                (category.map { " under \($0.label)." } ?? ". It is unfiled."),
            references: [note.id],
            taskID: taskID
        )
    }

    static func savedNoteTitle(from markdown: String) -> String {
        let firstLine = markdown.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let line = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try? AttributedString(markdown: line)
        let title = (parsed.map { String($0.characters) } ?? line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Thought" : String(title.prefix(80))
    }

    func dispatch(
        _ step: ConversationPlan.Step,
        taskID: UUID,
        route: ConversationRoute,
        references: inout [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        switch step.action {
        case .chat:
            for role in route.roles {
                try await converse(
                    taskID: taskID,
                    role: role,
                    question: route.text,
                    changed: changed
                )
            }
        case .clarify:
            try await store.postConversation(
                author: .assistant,
                text: step.argument,
                taskID: taskID
            )
        case .search:
            references = try await retrieve(
                taskID: taskID,
                query: step.argument,
                author: .curator,
                changed: changed
            )
        case .research, .webResearch, .related, .inspect:
            try await readRecords(
                step,
                taskID: taskID,
                request: route.text,
                references: references,
                changed: changed
            )
        case .saveNote, .organize, .compose, .refresh, .researchSeries:
            try await write(
                step,
                taskID: taskID,
                route: route,
                references: references,
                changed: changed
            )
        case .categories, .review, .unsupported:
            try await explainOperation(step.action, taskID: taskID)
        case .file:
            try await proposeFiling(
                taskID: taskID,
                step: step,
                references: references,
                request: route.text
            )
        case .link:
            try await proposeConnection(step, taskID: taskID, references: references)
        case .ingest:
            throw ConversationError.invalidPlan
        }
        await changed()
    }

    /// The Writer composes from gathered sources, or refreshes the one selected document.
    private func writer(
        _ step: ConversationPlan.Step,
        taskID: UUID,
        route: ConversationRoute,
        references: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard step.action == .refresh else {
            return try await compose(
                taskID: taskID, request: route.text, selected: references, changed: changed
            )
        }
        guard references.count == 1, let id = references.first else {
            return try await askForTargets(taskID: taskID)
        }
        try await refresh(taskID: taskID, noteID: id, changed: changed)
    }

    private func readRecords(
        _ step: ConversationPlan.Step,
        taskID: UUID,
        request: String,
        references: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        if step.action == .webResearch {
            return try await researchWeb(
                taskID: taskID, question: step.argument,
                references: step.targets, changed: changed
            )
        }
        guard !references.isEmpty else { try await askForTargets(taskID: taskID); return }
        switch step.action {
        case .research:
            try await research(
                taskID: taskID,
                question: step.argument.isEmpty ? request : step.argument,
                references: references,
                changed: changed
            )
        case .related:
            try await curate(taskID: taskID, references: references, changed: changed)
        case .inspect:
            for id in references {
                let source = try await store.researchSource(noteID: id)
                let homes = try await store.categories(for: id).map(\.label).joined(separator: "; ")
                try await store.postConversation(
                    author: .librarian,
                    text: "## \(source.note.name)\n\nFiling: \(homes.isEmpty ? "Unfiled" : homes)\n\n" +
                        String(source.note.markdown.prefix(5000)),
                    references: [id],
                    taskID: taskID
                )
            }
        default: throw ConversationError.invalidPlan
        }
    }

    private func write(
        _ step: ConversationPlan.Step,
        taskID: UUID,
        route: ConversationRoute,
        references: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        switch step.action {
        case .organize:
            try await organize(
                taskID: taskID, request: route.text, selected: references, changed: changed
            )
        case .researchSeries:
            try await startNoteSeries(
                taskID: taskID,
                request: route.text,
                selected: references,
                changed: changed
            )
        case .compose, .refresh:
            try await writer(
                step, taskID: taskID, route: route, references: references, changed: changed
            )
        default:
            try await saveThought(taskID: taskID, step: step)
        }
    }

    /// Runs the library agent. It reads freely but only proposes; the changes land on a review
    /// card in chat and nothing is applied until someone approves them there.
    private func organize(
        taskID: UUID,
        request: String,
        selected: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let model = inference as? any AgentResponding else {
            try await store.postConversation(
                author: .librarian,
                text: "Changes across many items run with ChatGPT. Connect it in Settings, or edit items one at a time in Library. Nothing was changed.",
                taskID: taskID
            )
            return
        }
        let history = try await ConversationChatContext.history(
            store.conversationMessages(limit: 60), before: taskID
        )
        let agent = LibraryAgent(
            model: model, toolbox: AgentToolbox(store: store, search: search)
        )
        let store = store
        let outcome = try await agent.run(
            request: request, history: history, selected: selected
        ) { progress in
            try? await store.updateConversationTask(taskID, progress: progress)
            await changed()
        }
        try Task.checkCancellation()
        try await store.saveAgentChanges(outcome.changes, taskID: taskID)
        try await store.postConversation(
            author: .librarian,
            text: outcome.reply,
            references: Array(outcome.touched.prefix(4)),
            taskID: taskID
        )
    }

    private func explainOperation(_ action: ConversationPlan.Action, taskID: UUID) async throws {
        switch action {
        case .categories:
            let categories = try await store.categories()
            try await store.postConversation(
                author: .librarian,
                text: "Filing categories:\n\n" + categories
                    .map { "- " + $0.label }.joined(separator: "\n"),
                taskID: taskID
            )
        case .review:
            let pending = try await store.proposals().filter { $0.status == "pending" }
            try await store.postConversation(
                author: .assistant,
                text: pending
                    .isEmpty ? "There are no pending changes to review." :
                    "Use the Apply, Reject or Undo controls on the proposal cards. Chat replies cannot authorize a change.",
                taskID: taskID
            )
        case .unsupported:
            try await store.postConversation(
                author: .assistant,
                text: "That operation is not available through chat yet. Nothing was changed. You can edit or delete an individual item in Library, or manage filing categories in Settings.",
                taskID: taskID
            )
        default: throw ConversationError.invalidPlan
        }
    }

    private func proposeConnection(
        _ step: ConversationPlan.Step,
        taskID: UUID,
        references: [UUID]
    ) async throws {
        guard references.count == 2, let left = try await store.document(id: references[0]),
              let right = try await store.document(id: references[1])
        else {
            try await askForTargets(taskID: taskID); return
        }
        _ = try await store.proposeLink(
            left,
            right,
            rationale: "Requested connection. " + step.argument,
            taskID: taskID
        )
        try await store.postConversation(
            author: .curator,
            text: "Review the proposed connection below. Nothing has been linked yet.",
            references: references,
            taskID: taskID
        )
    }

    private func askWhichToFile(taskID: UUID, candidates: [UUID]) async throws {
        var titles: [String] = []
        for id in candidates {
            try await titles.append("“" + (store.document(id: id)?.name ?? "Untitled") + "”")
        }
        try await store.postConversation(
            author: .librarian,
            text: "Which should I file: \(titles.joined(separator: " or "))? Say which one, or select it with Use as source. Nothing has changed.",
            references: candidates,
            taskID: taskID
        )
    }

    private func askForTargets(taskID: UUID) async throws {
        try await store.postConversation(
            author: .assistant,
            text: "Which saved items should I use? Select up to four references or bring items from Library into Chat.",
            taskID: taskID
        )
    }

    private func planningContext(
        taskID: UUID,
        selected: [UUID],
        purpose: String = "request"
    ) async throws -> ConversationPlanningContext {
        guard selected.count <= 4,
              Set(selected).count == selected.count else { throw ConversationError.invalidPlan }
        var records: [ConversationPlanningContext.Record] = []
        for id in selected {
            guard let note = try await store.document(id: id)
            else { throw ConversationError.missingSource }
            try await records.append(.init(
                id: id,
                title: String(note.name.prefix(200)),
                excerpt: String(note.markdown.prefix(1800)),
                filing: store.categories(for: id).map(\.label)
            ))
        }
        let history = try await ConversationChatContext.history(
            store.conversationMessages(limit: 60),
            before: taskID
        )
        return try await ConversationPlanningContext(
            purpose: purpose,
            history: history,
            records: records,
            categories: store.categories()
        )
    }

    /// The Librarian's suggested home for one item, asked from the item's info card rather
    /// than chat. Nothing is applied; nil when no model can be asked.
    func suggestHome(for id: UUID) async throws -> HomeSuggestion? {
        let suggestion = try await suggestedFiling(
            taskID: UUID(), ids: [id],
            request: "Suggest the best home for this item, a more specific one if it fits better than where it is now."
        )
        return suggestion.map { found in
            let home = found.newCategory ?? found.category
            return HomeSuggestion(
                category: home, isNew: found.newCategory != nil, rationale: found.rationale,
                alsoFits: found.alternatives.filter { $0.id != home?.id }
            )
        }
    }

    private struct FilingSuggestion {
        let category: DecimalCategory?
        let rationale: String
        let alternatives: [DecimalCategory]
        /// A user-named home that doesn't exist yet; only ever proposed, never created directly.
        let newCategory: DecimalCategory?
    }

    /// Nil when no model is available; otherwise a validated decision plus alternative homes.
    private func suggestedFiling(
        taskID: UUID,
        ids: [UUID],
        request: String
    ) async throws -> FilingSuggestion? {
        let context = try await planningContext(
            taskID: taskID,
            selected: ids,
            purpose: "classification"
        )
        let plan: ConversationPlan
        do { plan = try await inference.plan(request: request, context: context) }
        catch LinkSummaryError.unavailable { return nil }
        try plan.validate(context: context, hasURL: false)
        guard let step = plan.steps.first, plan.steps.count <= 3,
              plan.steps.allSatisfy({ $0.action == .file }),
              plan.steps.dropFirst().allSatisfy({ !$0.categoryID.isEmpty })
        else { throw ConversationError.invalidPlan }
        let home = { (id: String) in context.categories.first { $0.id.uuidString == id } }
        return FilingSuggestion(
            category: home(step.categoryID),
            rationale: step.argument.trimmingCharacters(in: .whitespacesAndNewlines),
            alternatives: plan.steps.dropFirst().compactMap { home($0.categoryID) },
            newCategory: step.newCategory.map {
                DecimalCategory(id: UUID(), code: $0.code, name: $0.name)
            }
        )
    }

    private func proposeFiling(
        taskID: UUID,
        step: ConversationPlan.Step,
        references: [UUID],
        request: String
    ) async throws {
        guard !references.isEmpty else { try await askForTargets(taskID: taskID); return }
        let categories = try await store.categories()
        // The planner only routes the request; the classifier reads the items and the taxonomy,
        // so its decision and rationale win. The planner's choice is the fallback without a model.
        let suggestion = try await suggestedFiling(
            taskID: taskID,
            ids: references,
            request: request
        )
        let rationale = suggestion.map(\.rationale).flatMap { $0.isEmpty ? nil : $0 }
            ?? step.argument
        if let created = suggestion?.newCategory {
            for id in references {
                _ = try await store.proposeFiling(
                    noteID: id,
                    category: created,
                    rationale: rationale,
                    taskID: taskID,
                    creating: true
                )
            }
            try await store.postConversation(
                author: .librarian,
                text: "There's no \(created.name) category yet. Proposed creating \(created.label) and filing there. Review and apply below; nothing has changed yet.",
                references: references,
                taskID: taskID
            )
            return
        }
        let destination = suggestion?.category ?? categories.first {
            $0.id.uuidString == step.categoryID
        }
        guard let destination else {
            try await store.postConversation(
                author: .librarian,
                text: "I couldn't choose a confident home in the current filing scheme. Choose an existing category:\n\n" +
                    categories.map { "- " + $0.label }
                    .joined(separator: "\n"),
                references: references,
                taskID: taskID
            )
            return
        }
        for id in references {
            _ = try await store.proposeFiling(
                noteID: id,
                category: destination,
                rationale: rationale,
                taskID: taskID
            )
        }
        try await store.postConversation(
            author: .librarian,
            text: "Proposed filing under \(destination.label). Review and apply below; nothing has moved yet.",
            references: references,
            taskID: taskID
        )
    }

    private func converse(
        taskID: UUID,
        role: AgentRole,
        question: String,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        let messages = try await store.conversationMessages(limit: 60)
        let history = ConversationChatContext.history(messages, before: taskID)
        var result: String?
        for try await event in inference.reply(question: question, role: role, history: history) {
            try Task.checkCancellation()
            switch event {
            case let .progress(text): try await store.updateConversationTask(taskID, progress: text)
            case let .result(text): result = text
            }
            await changed()
        }
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.count <= 16000 else { throw ConversationError.invalidReply }
        try Task.checkCancellation()
        try await store.postConversation(author: role, text: result, taskID: taskID)
    }

    private func curate(
        taskID: UUID,
        references: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        var id = references.first
        if id == nil {
            id = try await store.documentPage(limit: 1).documents.first?.id
        }
        guard let id, let note = try await store.document(id: id) else {
            try await store.postConversation(
                author: .curator,
                text: "Save a source or note before looking for overlaps.",
                taskID: taskID
            )
            return
        }
        let proposed = try await related(
            taskID: taskID,
            note: note,
            query: note.name + " " + String(note.markdown.prefix(1000)),
            changed: changed
        )
        if !proposed {
            try await store.postConversation(
                author: .curator,
                text: "No sufficiently related saved source was found for this document. No changes proposed.",
                references: [id],
                taskID: taskID
            )
        }
    }

    private func research(
        taskID: UUID,
        question: String,
        references: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        let ids = Array(references.prefix(4))
        guard !ids.isEmpty else { throw ConversationError.missingSource }
        var sources: [ResearchSource] = []
        for id in ids {
            try await sources.append(store.researchSource(noteID: id))
        }
        try await store.updateConversationTask(
            taskID,
            progress: "Reading \(sources.count) saved sources",
            event: "delegated"
        )
        await changed()
        var result: String?
        var lastProgress = ""
        for try await event in inference.research(question: question, sources: sources) {
            try Task.checkCancellation()
            switch event {
            case let .progress(text):
                guard text != lastProgress else { continue }
                lastProgress = text
                try await store.updateConversationTask(taskID, progress: text)
            case let .result(text): result = text
            }
            await changed()
        }
        guard let result else { throw ConversationError.invalidOutput }
        try await store.updateConversationTask(taskID, progress: "Naming the research note")
        await changed()
        let title = try await inference.researchTitle(for: result)
        try Task.checkCancellation()
        let citedResult = result + "\n\n## Saved sources\n\n" + sources.enumerated().map {
            "- [S\($0.offset + 1): \(Self.markdownLabel($0.element.note.name))](gleanary://note/\($0.element.note.id.uuidString))"
        }.joined(separator: "\n")
        let artifact = try await store.saveResearch(
            citedResult,
            name: title,
            sources: sources,
            taskID: taskID,
            provider: inference.capabilities.identifier,
            kind: sources.count > 1 ? "comparison" : "summary"
        )
        if let category = try await suggestedFiling(
            taskID: taskID,
            ids: [artifact.id],
            request: question
        )?.category {
            try await store.fileNote(artifact.id, categoryID: category.id)
        }
        await changed()
    }

    @discardableResult
    private func retrieve(
        taskID: UUID,
        query: String,
        author: AgentRole,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> [UUID] {
        try await store.updateConversationTask(taskID, progress: "Searching library…")
        await changed()
        let response = try await search.search(query, limit: 20)
        // Meaning-only matches always fill the list, however weak. When the words themselves
        // appear somewhere, those documents are the answer and the near-misses are noise.
        let worded = response.matches.filter { $0.keywordRank != nil }
        var seen = Set<UUID>()
        let ids = Array((worded.isEmpty ? response.matches : worded).map(\.passage.documentID)
            .filter { seen.insert($0).inserted }.prefix(4))
        try await store.postConversation(
            author: author,
            text: ids.isEmpty
                ? "No saved material matched. Try a distinctive term from the title or source text, or paste a URL to save it."
                :
                "Found \(ids.count) saved document\(ids.count == 1 ? "" : "s"). Open a reference below or select sources for a follow-up.",
            references: ids,
            taskID: taskID
        )
        return ids
    }

    @discardableResult
    private func related(
        taskID: UUID,
        note: MarkdownDocument,
        query: String,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> Bool {
        let stop: Set = [
            "source",
            "saved",
            "notes",
            "research",
            "summary",
            "https",
            "http",
            "with",
            "this",
            "that",
            "from",
            "have",
            "about",
            "which",
            "their",
            "there",
            "these",
            "they",
            "first",
            "second",
        ]
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 4 && !stop.contains($0.lowercased()) }.prefix(6)
        let origin = try await store.researchSource(noteID: note.id)
        var matches: [UUID: SearchMatch] = [:]
        var terms: [UUID: Set<String>] = [:]
        for word in words {
            let response = try await search.search(String(word), limit: 20)
            for match in response.matches
                where match.passage.documentID != note.id && match.keywordRank != nil
            {
                let id = match.passage.documentID
                matches[id] = match
                terms[id, default: []].insert(word.lowercased())
            }
        }
        for id in terms.keys.sorted(by: { (terms[$0]?.count ?? 0) > (terms[$1]?.count ?? 0) }) {
            guard (terms[id]?.count ?? 0) >= 2, let match = matches[id],
                  let other = try await store.document(id: id) else { continue }
            let target = try await store.researchSource(noteID: other.id)
            guard Set(origin.sourceIDs).isDisjoint(with: target.sourceIDs) else { continue }
            let shared = (terms[id] ?? []).sorted().joined(separator: ", ")
            let rationale = "These saved documents share the terms \(shared). Review the excerpt before linking them: “\(String(match.passage.text.prefix(240)))”. This is a suggested connection, not a verified equivalence."
            _ = try await store.proposeLink(note, other, rationale: rationale, taskID: taskID)
            try await store.postConversation(
                author: .curator,
                text: rationale,
                references: [note.id, other.id],
                taskID: taskID
            )
            await changed()
            return true
        }
        return false
    }

    static func markdownLabel(_ title: String) -> String {
        title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private struct CaptureTaskFailure: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

/// Where the Librarian would file an item, and why. A new category is only created if the
/// person accepts it.
struct HomeSuggestion: Sendable, Equatable {
    /// Nil when no home fits.
    let category: DecimalCategory?
    let isNew: Bool
    let rationale: String
    /// Other existing homes that could hold it too, offered as extra (secondary) homes.
    var alsoFits: [DecimalCategory] = []
}
