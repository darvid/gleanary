import Foundation

extension AgentCoordinator {
    /// Retain real Sources through the established durable capture queue. Reading links never
    /// invokes this method; a separate model tool call follows the user's capture request.
    func captureConversationSources(
        _ candidates: [ConversationSourceCaptures.Candidate],
        taskID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> [ConversationSourceCaptures.Outcome] {
        var jobs: [(ConversationSourceCaptures.Candidate, UUID)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let job = try await ingestion.enqueue(
                candidate.link.url.absoluteString,
                summarizeLink: false,
                referencing: candidate.origin
            )
            jobs.append((candidate, job))
        }
        try await store.updateConversationTask(
            taskID,
            progress: "Capturing \(jobs.count) sources",
            onlyWhileRunning: true
        )
        await changed()
        try await ingestion.run(changed: changed)
        try Task.checkCancellation()
        var outcomes: [ConversationSourceCaptures.Outcome] = []
        for (candidate, id) in jobs {
            let job = try await store.captureJob(id: id)
            outcomes.append(.init(
                source: candidate.handle,
                job: id,
                state: job?.state.rawValue ?? "missing",
                noteID: job?.state == .ready ? job?.noteID : nil,
                error: job?.error
            ))
        }
        return outcomes
    }
}
