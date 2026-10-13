import Foundation

actor AgentCoordinator {
    let store: DocumentStore
    let ingestion: IngestionEngine
    private(set) var inference: any ConversationInferring
    private let search: SearchEngine
    private var executing = false

    init(
        store: DocumentStore,
        fetcher: any SourceFetching = SourceFetcher(),
        inference: any ConversationInferring = AppleConversationInference()
    ) {
        self.store = store
        self.inference = inference
        ingestion = IngestionEngine(store: store, fetcher: fetcher)
        search = SearchEngine(store: store)
    }

    /// One validated intent plan, at most four capability steps, no recursive model/tool loop.
    /// Models select capabilities; application code owns persistence and review permissions.
    func execute(
        taskID: UUID,
        request: String,
        selected: [UUID],
        existingCaptureID: UUID? = nil,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard !executing else { throw ConversationError.busy }
        executing = true
        defer { executing = false }
        let route = try ConversationRoute(request)
        let context = try await planningContext(taskID: taskID, selected: selected)
        let plan: ConversationPlan
        if existingCaptureID != nil || route.url?.absoluteString == route.text {
            plan = ConversationPlan(steps: [.init(action: .ingest)])
        } else {
            try await store.updateConversationTask(taskID, progress: "Understanding request")
            await changed()
            plan = try await inference.plan(request: route.text, context: context)
        }
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
            var references = selected
            for step in plan.steps {
                try Task.checkCancellation()
                if !step.targets.isEmpty {
                    references = step.targets
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
        try await store.updateConversationTask(
            taskID,
            state: "succeeded",
            progress: "Completed",
            event: "completed"
        )
        await changed()
    }

    func cancelCapture(_ id: UUID) async throws {
        try await ingestion.cancel(id)
    }

    func setInference(_ inference: any ConversationInferring) throws {
        guard !executing else { throw ConversationError.busy }
        self.inference = inference
    }

    private func capture(
        taskID: UUID,
        route: ConversationRoute,
        existingCaptureID: UUID?,
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
        try await ingestion.run(changed: changed)
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
                filingExplanation = options.isEmpty
                    ? " No confident filing home was identified; review the filing categories to choose one."
                    : " No confident filing home was identified; apply one of the suggested homes below or keep it in Inbox."
            }
        }
        let filed = try await store.categories(for: noteID).first?.label ?? "Unfiled"
        try await store.postConversation(
            author: .librarian,
            text: "Saved locally under \(filed). Original and extracted text are retained.\(filingExplanation)",
            references: [noteID],
            taskID: taskID
        )
        await changed()
        if source.document.blocks.allSatisfy({ $0.method == "metadata-only" }) {
            try await store.postConversation(
                author: .researcher,
                text: "The source link is saved, but no authorized transcript was available. There is no source text to summarize.",
                references: [noteID],
                taskID: taskID
            )
            return
        }
        try await research(
            taskID: taskID,
            question: "Summarize this source. " + route.text,
            references: [noteID],
            changed: changed
        )
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
            name: String(text.split(whereSeparator: \.isNewline).first?
                .prefix(80) ?? "Thought"),
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

    private func dispatch(
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
        case .research, .related, .inspect:
            try await readRecords(
                step,
                taskID: taskID,
                request: route.text,
                references: references,
                changed: changed
            )
        case .saveNote:
            try await saveThought(taskID: taskID, step: step)
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

    private func readRecords(
        _ step: ConversationPlan.Step,
        taskID: UUID,
        request: String,
        references: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
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

    private func askForTargets(taskID: UUID) async throws {
        try await store.postConversation(
            author: .assistant,
            text: "Which saved items should I use? Select up to four references or bring items from Library into #general.",
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

    private struct FilingSuggestion {
        let category: DecimalCategory?
        let rationale: String
        let alternatives: [DecimalCategory]
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
            alternatives: plan.steps.dropFirst().compactMap { home($0.categoryID) }
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
        let destination: DecimalCategory? = if step.categoryID.isEmpty {
            try await suggestedFiling(taskID: taskID, ids: references, request: request)?.category
        } else {
            categories.first { $0.id.uuidString == step.categoryID }
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
                rationale: step.argument,
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
        let citedResult = result + "\n\n## Saved sources\n\n" + sources.enumerated().map {
            "- [S\($0.offset + 1): \(Self.markdownLabel($0.element.note.name))](infactory://note/\($0.element.note.id.uuidString))"
        }.joined(separator: "\n")
        let artifact = try await store.saveResearch(
            citedResult,
            name: sources
                .count > 1 ? "Comparison · \(sources[0].note.name)" :
                "Research · \(sources[0].note.name)",
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
        var seen = Set<UUID>()
        let ids = Array(response.matches.map(\.passage.documentID)
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

    private static func markdownLabel(_ title: String) -> String {
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
