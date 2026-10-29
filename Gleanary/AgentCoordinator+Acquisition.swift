import Foundation

extension AgentCoordinator {
    /// Saves the reading a capture's creator recommends, as chosen by Source acquisition, and
    /// says what was saved.
    func saveRecommendedSources(
        taskID: UUID,
        noteID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        // Filing has happened by now, so a category's own level can apply.
        try await ingestion.replanForCategory(foundIn: noteID)
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
        // Eager saves also take links the creator posted or the source cites.
        let why = queued.allSatisfy { $0.provenance == .creatorRecommendation }
            ? ", which the creator recommends." : " from links in this source."
        try await store.postConversation(
            author: .librarian,
            text: "Also saved \(names)\(why)"
                +
                (missed == 0 ? "" :
                    " \(missed) more couldn't be saved; the capture queue has details."),
            references: saved.map(\.noteID),
            taskID: taskID
        )
        await changed()
    }

    /// Follows a note's links once with Eager rules and waits for the saves.
    func exploreFrom(
        _ noteID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> Int {
        let queued = try await ingestion.exploreFrom(noteID)
        guard !queued.isEmpty else { return 0 }
        await changed()
        try await ingestion.settle(queued.compactMap(\.captureJobID), changed: changed)
        return queued.count
    }

    /// Saves a suggested link you chose, or tries a failed save again.
    func saveAcquisition(_ id: UUID, changed: @escaping @Sendable () async -> Void) async throws {
        if let candidate = try await store.acquisitionCandidate(id: id),
           candidate.state == .queued, let job = candidate.captureJobID
        {
            try await store.retryCapture(job)
            await changed()
            return try await ingestion.settle([job], changed: changed)
        }
        guard let job = try await ingestion.saveAcquisition(id)?.captureJobID else { return }
        await changed()
        try await ingestion.settle([job], changed: changed)
    }
}
