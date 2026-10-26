import Foundation

extension AgentCoordinator {
    /// Normal conversation has no intent classifier or canned read-result renderer. The model
    /// chooses tools and sees their results before writing its answer.
    func converseWithTools(
        taskID: UUID,
        request: String,
        selected: [UUID],
        model: any AgentResponding,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard selected.count <= 4, Set(selected).count == selected.count else {
            throw ConversationError.invalidPlan
        }
        let route = try ConversationRoute(request, detectsURL: false)
        let before = try await store.conversationRequestSequence(taskID: taskID)
        let messages = try await store.conversationMessages(before: before, limit: 60)
        let current = try await store.conversationMessages(limit: 60)
        let history = ConversationChatContext.history(current, before: taskID)
        var seen = Set<UUID>()
        let recentItems = Array(messages.suffix(12).flatMap(\.references)
            .filter { seen.insert($0).inserted }.prefix(40))
        try await store.updateConversationTask(taskID, progress: "Thinking", event: "delegated")
        await changed()
        let toolbox = AgentToolbox(store: store, search: search, conversationBefore: before)
        let workflows = ConversationWorkflows { [self] arguments, ids in
            try await runConversationWorkflow(
                arguments,
                ids: ids,
                taskID: taskID,
                request: request,
                toolbox: toolbox,
                changed: changed
            )
        }
        let captures = ConversationSourceCaptures { [self] candidates in
            try await captureConversationSources(candidates, taskID: taskID, changed: changed)
        }
        let agent = LibraryAgent(
            model: model,
            toolbox: toolbox,
            workflows: workflows,
            sourceCaptures: captures
        )
        let store = store
        let outcome = try await agent.run(
            request: route.text,
            history: history,
            selected: selected,
            recentItems: recentItems
        ) { progress in
            try? await store.updateConversationTask(
                taskID,
                progress: progress,
                onlyWhileRunning: true
            )
            await changed()
        }
        try Task.checkCancellation()
        try await store.saveAgentChanges(outcome.changes, taskID: taskID)
        try await store.postConversation(
            author: route.roles[0],
            text: outcome.reply,
            references: Array(outcome.touched.prefix(4)),
            taskID: taskID,
            isToolOutcome: true
        )
        let workflowFailure = await workflows.failure
        let captureFailure = await captures.failure
        if let failure = workflowFailure ?? captureFailure {
            try await store.updateConversationTask(
                taskID,
                state: "failed",
                progress: failure,
                event: "failed"
            )
        } else if try await store.writerRequest(taskID: taskID)?.status != .awaiting {
            try await store.updateConversationTask(
                taskID,
                state: "succeeded",
                progress: "Completed",
                event: "completed"
            )
        }
        await changed()
    }

    /// Validate the selected source, not the meaning of the user's question. Retrieved
    /// links and prefixes of user-supplied URLs must not authorize an unrelated fetch.
    static func authorizedCaptureRoute(
        _ value: String,
        request: String
    ) throws -> ConversationRoute {
        guard let url = URL(string: value) else { throw ConversationError.invalidPlan }
        let canonical = try CaptureRequest.canonicalURL(url)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let supplied = detector.matches(
            in: request,
            range: NSRange(request.startIndex..., in: request)
        )
        .compactMap(\.url).compactMap { try? CaptureRequest.canonicalURL($0) }
        guard supplied.contains(canonical) else { throw ConversationError.invalidPlan }
        return try ConversationRoute(request, captureURL: url)
    }

    private func runConversationWorkflow(
        _ arguments: ConversationWorkflows.Request,
        ids: [UUID],
        taskID: UUID,
        request: String,
        toolbox: AgentToolbox,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> ConversationWorkflows.Result {
        try Task.checkCancellation()
        let previous = try await store.conversationMessages(limit: 200).last?.sequence ?? 0
        let route = try ConversationRoute(request, detectsURL: false)
        let action: ConversationPlan.Action
        var created: [UUID] = []
        switch arguments.workflow {
        case .capture:
            try await capture(
                taskID: taskID,
                route: Self.authorizedCaptureRoute(arguments.url, request: request),
                existingCaptureID: nil,
                postsAcknowledgement: false,
                changed: changed
            )
            action = .ingest
        case .saveNote:
            let note = try await store.saveResearch(
                arguments.content,
                name: Self.savedNoteTitle(from: arguments.content),
                sources: [],
                taskID: taskID,
                provider: "user",
                kind: "note"
            )
            created.append(note.id)
            action = .saveNote
        case .research: action = .research
        case .webResearch: action = .webResearch
        case .compose: action = .compose
        case .refresh: action = .refresh
        case .researchSeries: action = .researchSeries
        }
        if action != .ingest, action != .saveNote {
            var references = ids
            try await dispatch(
                .init(action: action, targets: ids, argument: route.text),
                taskID: taskID,
                route: route,
                references: &references,
                changed: changed
            )
        }
        try Task.checkCancellation()
        let messages = try await store.conversationMessages(limit: 200).filter {
            $0.taskID == taskID && $0.sequence > previous && $0.author != "user"
        }
        var seen = Set<UUID>()
        let references = (created + messages.flatMap(\.references))
            .filter { seen.insert($0).inserted }
        let awaiting = try await store.writerRequest(taskID: taskID)?.status == .awaiting
        return await ConversationWorkflows.Result(
            status: awaiting ? "awaiting_user" : "completed",
            messages: messages
                .map { .init(
                    author: $0.author,
                    text: String($0.text.prefix(12000)),
                    truncated: $0.text.count > 12000
                ) },
            items: toolbox.describeResult(references)
        )
    }
}
