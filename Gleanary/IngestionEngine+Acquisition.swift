import Foundation

extension IngestionEngine {
    /// Records the links a finished capture contains and how each was judged, then queues
    /// the ones chosen for saving unless the caller defers that. It never fails the capture.
    func followLinks(from job: CaptureJob, noteID: UUID, deferred: Bool) async {
        let hop = job.request.acquisitionHop ?? 0
        // Any capture can be one a candidate is waiting on, including a shared duplicate.
        try? await store.linkAcquiredSource(jobID: job.id, noteID: noteID)
        let policy = settings().acquisition.policy
        // Imports and files are not "something you saved" to explore from.
        guard policy.records, hop < policy.maximumHops, job.request.url != nil,
              job.request.replacingNoteID == nil else { return }
        do {
            let document = try await store.researchSource(noteID: noteID).document
            let links = document.foundLinks(excluding: job.request.identity)
            guard !links.isEmpty else { return }
            let known = try await store.acquisitionContext(identities: links.map(\.identity))
            let plans = AcquisitionPlanner.plan(
                links, sourceURL: document.sourceURL ?? job.request.url, policy: policy,
                savedToday: known.savedToday, saved: known.saved
            )
            try await store.recordAcquisitions(plans, foundIn: noteID, hop: hop + 1)
            if !deferred {
                _ = try await queueApprovedAcquisitions(foundIn: noteID)
            }
        } catch {}
    }

    /// Queues captures for links chosen for saving. The caller runs the queue.
    func queueApprovedAcquisitions(foundIn noteID: UUID?) async throws -> [AcquisitionCandidate] {
        var queued: [AcquisitionCandidate] = []
        for candidate in try await store.approvedAcquisitions(foundIn: noteID) {
            try await queued.append(queue(candidate))
        }
        return queued
    }

    /// Runs the queue, then waits for these captures to finish even when another engine, such
    /// as the library's, claimed them first.
    func settle(_ jobIDs: [UUID], changed: @escaping @Sendable () async -> Void) async throws {
        try await run(changed: changed)
        for _ in 0 ..< 600 {
            try Task.checkCancellation()
            var pending = false
            for id in jobIDs {
                if let state = try await store.captureJob(id: id)?.state,
                   [.queued, .fetching, .extracting].contains(state)
                {
                    pending = true
                }
            }
            guard pending else { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Saves a suggestion you chose. The caller runs the queue.
    func saveAcquisition(_ id: UUID) async throws -> AcquisitionCandidate? {
        guard let candidate = try await store.acquisitionCandidate(id: id),
              [.suggested, .approved, .noticed].contains(candidate.state) else { return nil }
        return try await queue(candidate)
    }

    private func queue(_ candidate: AcquisitionCandidate) async throws -> AcquisitionCandidate {
        // The link back carries the candidate's provenance; see `linkAcquiredSource`.
        var request = try CaptureRequest.webLink(candidate.url)
        // Automatic saves cost no AI calls until someone asks for a summary.
        request.summarizeLink = false
        request.acquisitionHop = candidate.hop
        let job = try await store.enqueueCapture(request)
        try await store.markAcquisitionQueued(candidate.id, jobID: job)
        var queued = candidate
        queued.state = .queued
        queued.captureJobID = job
        return queued
    }
}
