import Foundation

extension AgentCoordinator {
    /// Reads these items for entities on this Mac, skipping ones already read at their
    /// current version, with progress on the task.
    func findEntities(
        _ ids: [UUID],
        taskID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> ConversationEntityFinder.Report {
        let pending = try await store.prepareGraphJobs(ids)
        let store = store
        let total = ids.count
        try await store.updateConversationTask(
            taskID, progress: "Reading \(total) item\(total == 1 ? "" : "s") for entities",
            owner: .curator, event: "delegated", onlyWhileRunning: true
        )
        await changed()
        if pending > 0 {
            try await GraphExtractor(store: store, provider: graphProvider).run(only: Set(ids)) {
                let read = await (try? store.graphProgress(ids))?.ready ?? 0
                try? await store.updateConversationTask(
                    taskID, progress: "Reading for entities: \(read) of \(total)",
                    onlyWhileRunning: true
                )
                await changed()
            }
        }
        try Task.checkCancellation()
        let state = try await store.graphProgress(ids)
        try? await store.updateConversationTask(
            taskID, progress: "Thinking", owner: .assistant, onlyWhileRunning: true
        )
        await changed()
        return ConversationEntityFinder.Report(
            read: state.ready, unavailable: state.unavailable, failed: state.failed
        )
    }
}
