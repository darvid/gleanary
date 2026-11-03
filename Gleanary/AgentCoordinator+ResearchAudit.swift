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
        guard let auditor = inference as? any ResearchAuditing, inference is any WriterInferring,
              !inference.capabilities.local
        else {
            try await store.postConversation(
                author: .researcher,
                text: "Research audits read many items and search your whole library, so they run with ChatGPT. Connect it in Settings and ask again. Nothing was read.",
                taskID: taskID
            )
            return
        }
        try await store.updateConversationTask(
            taskID, progress: "Gathering sources", owner: .curator, event: "delegated"
        )
        await changed()
        let categories = try await store.categories()
        let brief = try await auditor.auditBrief(request: request, categories: categories)
            .validated(request: request, categories: categories)
        try Task.checkCancellation()
        let gathered = try await gather(brief.gatherBrief, selected: selected, excluding: [])
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
        let limit = WriterLimits.maximumScope
        let onTopic = candidates.filter { !$0.offTopic }.map(\.id)
        try await store.beginResearchAudit(ResearchAudit(
            taskID: taskID, request: request, brief: brief, candidates: candidates,
            selection: Array(onTopic.prefix(limit)), scopeLimit: limit, status: .awaiting
        ))
        try await store.postConversation(
            author: .curator,
            text: Self.auditScopeMessage(candidates: candidates, brief: brief),
            taskID: taskID
        )
        try await store.updateConversationTask(
            taskID, state: "awaiting_user", progress: "Waiting for you to confirm the audit"
        )
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
        guard let writer = inference as? any WriterInferring, !inference.capabilities.local
        else { throw WriterError.needsChatGPT }
        let store = store
        let report = try await ResearchAuditPipeline(store: store, search: search, writer: writer)
            .run(audit) { progress, owner in
                try? await store.updateConversationTask(
                    taskID, progress: progress, owner: owner,
                    event: owner == nil ? "progress" : "delegated"
                )
                await changed()
            }
        try Task.checkCancellation()
        try await store.completeResearchAudit(taskID, report: report)
        try await store.postConversation(
            author: .researcher, text: report.summary, taskID: taskID
        )
        try await store.updateConversationTask(
            taskID, state: "succeeded", progress: "Completed", event: "completed"
        )
        await changed()
    }

    static func auditScopeMessage(candidates: [ScopeCandidate], brief: AuditBrief) -> String {
        let suggested = brief.dimensions.count(where: { !$0.fromRequest })
        var text = "Found \(Self.items(candidates.count)) and \(brief.dimensions.count == 1 ? "1 criterion" : "\(brief.dimensions.count) criteria") for this audit."
        if suggested > 0 {
            text += suggested == 1
                ? " 1 criterion is my suggestion rather than something you asked, so it's unchecked."
                : " \(suggested) criteria are my suggestions rather than things you asked, so they're unchecked."
        }
        return text + " Check both lists below; nothing is read until you confirm."
    }
}
