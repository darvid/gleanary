import Foundation

extension AgentCoordinator {
    /// Saves the reading a capture's creator recommends, as chosen by Source acquisition, and
    /// says what was saved.
    func saveRecommendedSources(
        taskID: UUID,
        noteID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        let queued = try await ingestion.queueApprovedAcquisitions(foundIn: noteID)
        guard !queued.isEmpty else { return }
        try await store.updateConversationTask(
            taskID,
            progress: "Saving \(queued.count) recommended source\(queued.count == 1 ? "" : "s")",
            owner: .librarian,
            event: "delegated",
            onlyWhileRunning: true
        )
        await changed()
        try await ingestion.settle(queued.compactMap(\.captureJobID), changed: changed)
        try Task.checkCancellation()
        let captured = try await store.capturedLinks(identities: Set(queued.map(\.identity)))
        let saved = queued.compactMap { captured[$0.identity] }
        guard !saved.isEmpty else { return }
        let names = saved.map { "**\($0.title.replacingOccurrences(of: "*", with: ""))**" }
            .formatted(.list(type: .and))
        let missed = queued.count - saved.count
        try await store.postConversation(
            author: .librarian,
            text: "Also saved \(names), which the creator recommends."
                +
                (missed == 0 ? "" :
                    " \(missed) more couldn't be saved; the capture queue has details."),
            references: saved.map(\.noteID),
            taskID: taskID
        )
        await changed()
    }

    /// Saves a suggested link you chose.
    func saveAcquisition(_ id: UUID, changed: @escaping @Sendable () async -> Void) async throws {
        guard let job = try await ingestion.saveAcquisition(id)?.captureJobID else { return }
        await changed()
        try await ingestion.settle([job], changed: changed)
    }
}
