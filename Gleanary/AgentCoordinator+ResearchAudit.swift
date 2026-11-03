import Foundation

/// A research audit as stages of one conversation task, like the Writer's compose: plan and
/// gather (Curator), the person confirms items and criteria, then read and search (Researcher).
/// Stopping at any stage saves no report.
extension AgentCoordinator {
    func auditResearch(
        taskID: UUID,
        request: String,
        selected: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let auditor = inference as? any ResearchAuditing, inference is any WriterInferring
        else {
            try await store.postConversation(
                author: .researcher,
                text: "The model chosen in Settings can't run research audits. Choose another and ask again. Nothing was read.",
                taskID: taskID
            )
            return
        }
        try await store.updateConversationTask(
            taskID, progress: "Gathering sources", owner: .curator, event: "delegated"
        )
        await changed()
        // The same question asked again reuses the earlier audit's criteria and checks, so
        // the two reports compare; nothing is planned again.
        let previous = try await store.previousAudit(question: request)
        var brief: AuditBrief
        if let previous {
            brief = previous.brief
            brief.dimensions.removeAll { $0.note != nil }
        } else {
            let categories = try await store.categories()
            brief = try await auditor.auditBrief(request: request, categories: categories)
                .validated(request: request, categories: categories)
        }
        try Task.checkCancellation()
        let gathered = try await gather(
            brief.gatherBrief, selected: selected + (previous?.selection ?? []), excluding: []
        )
        // Model-written items aren't evidence, so they're never offered for an audit.
        let auditable = try await store.auditableItems(gathered.candidates.map(\.id))
        let candidates = gathered.candidates.filter { auditable[$0.id] != nil }
        guard !candidates.isEmpty else {
            try await store.postConversation(
                author: .curator,
                text: "No saved sources or notes match this question, so there's nothing to audit. Save some sources first, or select items and ask again.",
                taskID: taskID
            )
            return
        }
        let questions = try await store.auditQuestions(
            in: candidates.map(\.id), limit: AuditLimits.maximumQuestions
        )
        let checkedBefore = Set(previous?.brief.dimensions.filter(\.accepted).map(\.origin) ?? [])
        brief.dimensions += questions.enumerated().map { index, found in
            var question = AuditDimension.question(
                found.question, note: found.note, title: found.title, index: index + 1
            )
            question.accepted = checkedBefore.contains(found.question)
            return question
        }
        let local = inference.capabilities.local
        let limit = local ? WriterLimits.localScope : WriterLimits.maximumScope
        let ids = candidates.map(\.id)
        let earlier = previous?.selection.filter(ids.contains) ?? []
        let onTopic = earlier.isEmpty ? candidates.filter { !$0.offTopic }.map(\.id) : earlier
        try await store.beginResearchAudit(ResearchAudit(
            taskID: taskID, request: request, brief: brief, candidates: candidates,
            selection: Array(onTopic.prefix(limit)), scopeLimit: limit, status: .awaiting
        ))
        try await store.postConversation(
            author: .curator,
            text: (previous == nil ? ""
                : "Using the criteria and items from your earlier audit of this question. ")
                + Self.auditScopeMessage(candidates: candidates, brief: brief),
            taskID: taskID
        )
        if local, onTopic.count > limit {
            try await store.postConversation(
                author: .researcher,
                text: "On this Mac an audit reads up to \(limit) items, so the first \(limit) are checked below; change which if you like. A hosted model in Settings can read up to \(WriterLimits.maximumScope).",
                taskID: taskID
            )
        }
        try await store.updateConversationTask(
            taskID, state: "awaiting_user", progress: "Waiting for you to confirm the audit"
        )
    }

    /// "@researcher audit …" starts an audit directly, with any model: the app routes the
    /// command, so it doesn't depend on a model choosing the audit, or on the on-device tool
    /// prompt having room to offer it.
    static func isAuditCommand(_ request: String) -> Bool {
        guard let route = try? ConversationRoute(request, detectsURL: false),
              route.roles == [.researcher]
        else { return false }
        let text = route.text.lowercased()
        return text == "audit" || text.hasPrefix("audit ") || text.hasPrefix("audit:")
    }

    func runAuditCommand(
        taskID: UUID,
        request: String,
        selected: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        try await store.updateConversationTask(
            taskID, progress: "Working", owner: .researcher, event: "delegated"
        )
        await changed()
        try await auditResearch(
            taskID: taskID, request: request, selected: selected, changed: changed
        )
        try Task.checkCancellation()
        if try await !store.awaitsConfirmation(taskID) {
            try await store.updateConversationTask(
                taskID, state: "succeeded", progress: "Completed", event: "completed"
            )
        }
        await changed()
    }

    /// Picks up a confirmed audit: reads, searches and saves the report.
    func continueAudit(
        taskID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard !executing else { throw ConversationError.busy }
        executing = true
        defer { executing = false }
        guard let audit = try await store.researchAudit(taskID: taskID),
              audit.status == .auditing
        else { throw WriterError.scopeChanged }
        guard let writer = inference as? any WriterInferring,
              let auditor = inference as? any ResearchAuditing
        else { throw WriterError.needsChatGPT }
        let store = store
        let report = try await ResearchAuditPipeline(
            store: store, search: search, writer: writer, auditor: auditor
        )
        .run(audit) { progress, owner in
            try? await store.updateConversationTask(
                taskID, progress: progress, owner: owner,
                event: owner == nil ? "progress" : "delegated"
            )
            await changed()
        }
        try Task.checkCancellation()
        let kept = try await store.applyEarlierDismissals(report, request: audit.request)
        try await store.completeResearchAudit(taskID, report: kept)
        // The coordinating reply, so the result reads as the answer rather than activity.
        try await store.postConversation(
            author: .assistant, text: kept.summary, taskID: taskID
        )
        try await store.updateConversationTask(
            taskID, state: "succeeded", progress: "Completed", event: "completed"
        )
        await changed()
    }

    static func auditScopeMessage(candidates: [ScopeCandidate], brief: AuditBrief) -> String {
        let suggested = brief.dimensions.count(where: \.suggested)
        let questions = brief.dimensions.count(where: { $0.note != nil })
        let planned = brief.dimensions.count - questions
        var text = "Found \(Self.items(candidates.count)) and \(planned == 1 ? "1 criterion" : "\(planned) criteria") for this audit."
        if suggested > 0 {
            text += suggested == 1
                ? " 1 criterion is my suggestion rather than something you asked, so it's unchecked."
                : " \(suggested) criteria are my suggestions rather than things you asked, so they're unchecked."
        }
        if questions > 0 {
            text += questions == 1
                ? " 1 question from your notes is listed too, unchecked; check it to audit it."
                : " \(questions) questions from your notes are listed too, unchecked; check the ones to audit."
        }
        return text + " Check both lists below; nothing is read until you confirm."
    }
}
