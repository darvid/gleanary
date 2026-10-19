import Foundation

extension AgentCoordinator {
    struct PreparedSeriesScope: Sendable {
        let outline: NoteSeries.Artifact<NoteSeries.Outline>
        let dossier: NoteSeries.Artifact<NoteSeries.Dossier>
        let bundle: NoteSeries.ScopeBundle?
    }

    /// Restores approved scope changes before loading drafts, including formerly terminal runs.
    func prepareSeriesScopes(
        _ run: NoteSeries.Run,
        original: NoteSeries.Artifact<NoteSeries.Outline>,
        dossier: NoteSeries.Artifact<NoteSeries.Dossier>,
        model: any NoteSeriesInferring,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> PreparedSeriesScope {
        var prepared = PreparedSeriesScope(outline: original, dossier: dossier, bundle: nil)
        if let saved = try await store.latestSeriesArtifact(
            run,
            kind: .scopeBundle,
            as: NoteSeries.ScopeBundle.self
        ) {
            try await validateSeriesScope(run, bundle: saved.value, original: original.value)
            let evidence = try mergeSeriesScopeEvidence(saved.value.evidence, with: dossier.value)
            if evidence == saved.value.evidence {
                prepared = .init(
                    outline: .init(id: saved.id, value: saved.value.outline),
                    dossier: .init(id: saved.id, value: evidence),
                    bundle: saved.value
                )
            } else {
                prepared = try await checkpointSeriesScope(
                    run,
                    original: original,
                    evidence: evidence,
                    changes: saved.value.changes,
                    parents: [
                        saved.id,
                        dossier.id,
                    ]
                )
            }
        } else if !(dossier.value.scopeRecords ?? [:])
            .isEmpty
        {
            throw NoteSeries.Failure.invalidArtifact
        }
        for entry in original.value.entries where entry.existingNoteID == nil {
            guard prepared.bundle?.changes.contains(where: { $0.original.id == entry.id }) != true,
                  let failure = try await store.seriesArtifact(
                      run,
                      kind: .topicExhausted,
                      slot: entry.id.uuidString,
                      as: String.self
                  ) else { continue }
            guard let feedback = try await store.seriesArtifact(
                run,
                kind: .topicRepair,
                slot: entry.id.uuidString,
                as: NoteSeries.DraftFeedback.self
            )
            else { throw NoteSeries.Failure.invalidArtifact }
            try await store.updateConversationTask(
                run.taskID,
                progress: "Checking a supported scope for: \(entry.title)",
                owner: .curator
            )
            await changed()
            prepared = try await narrowSeriesScope(
                run,
                original: original,
                prepared: prepared,
                entry: entry,
                feedback: feedback.value,
                failure: failure.value,
                model: model
            )
        }
        return prepared
    }

    /// One proposal and one independent request/evidence review per note, never a new web pass.
    func narrowSeriesScope(
        _ run: NoteSeries.Run,
        original: NoteSeries.Artifact<NoteSeries.Outline>,
        prepared: PreparedSeriesScope,
        entry: NoteSeries.Entry,
        feedback: NoteSeries.DraftFeedback,
        failure: String,
        model: any NoteSeriesInferring
    ) async throws -> PreparedSeriesScope {
        guard prepared.bundle?.changes.contains(where: { $0.original.id == entry.id }) != true
        else {
            throw NoteSeries.Failure.insufficientTopicEvidence(
                note: entry.title,
                reason: "This note already used its one independently checked scope adjustment."
            )
        }
        let evidence = try await seriesScopeEvidence(
            run,
            entry: entry,
            current: prepared.dossier.value
        )
        let proposal = try await seriesScopeProposal(
            run,
            entry: entry,
            evidence: evidence,
            feedback: feedback,
            failure: failure,
            model: model,
            parent: prepared.dossier.id
        )
        guard proposal.value.possible else {
            throw NoteSeries.Failure.insufficientTopicEvidence(
                note: entry.title,
                reason: proposal.value.reason
            )
        }
        let review = try await seriesScopeReview(
            run,
            entry: entry,
            evidence: evidence,
            proposal: proposal,
            feedback: feedback,
            model: model
        )
        guard review.value.preservesRequest, review.value.supported else {
            throw NoteSeries.Failure.insufficientTopicEvidence(
                note: entry.title,
                reason: review.value.reason
            )
        }
        var selected = evidence
        var scopes = selected.scopeRecords ?? [:]
        scopes[entry.id] = proposal.value.records
        selected.scopeRecords = scopes
        var topics = selected.topicRecords ?? [:]
        if topics[entry.id] == nil {
            topics[entry.id] = proposal.value.records
        }
        selected.topicRecords = topics
        let change = NoteSeries.ScopeChange(
            original: entry,
            proposal: proposal.value,
            review: review.value
        )
        return try await checkpointSeriesScope(
            run,
            original: original,
            evidence: selected,
            changes: (prepared.bundle?.changes ?? []) + [change],
            parents: [
                prepared.outline.id,
                prepared.dossier.id,
                proposal.id,
                review.id,
            ]
        )
    }

    func retainScopedSeriesDraft(
        _ run: NoteSeries.Run, entry: NoteSeries.Entry,
        draft: NoteSeries.Artifact<NoteSeries.Draft>,
        dossier: NoteSeries.Artifact<NoteSeries.Dossier>
    ) async throws -> NoteSeries.Artifact<NoteSeries.Draft> {
        guard dossier.value.scopeRecords?[entry.id] != nil else { return draft }
        let value = NoteSeries.ScopedDraft(entry: entry, draft: draft.value)
        let saved = try await store.checkpointSeries(
            run,
            kind: .scopeDraft,
            slot: entry.id.uuidString + "." + UUID()
                .uuidString,
            value: value,
            parents: [
                draft.id,
                dossier.id,
            ]
        )
        return .init(id: saved.id, value: draft.value)
    }

    private func seriesScopeEvidence(
        _ run: NoteSeries.Run, entry: NoteSeries.Entry, current: NoteSeries.Dossier
    ) async throws -> NoteSeries.Dossier {
        var evidence = current
        if let pending = try await store.seriesArtifact(
            run,
            kind: .topicResearch,
            slot: entry.id.uuidString + ".research",
            as: NoteSeries.Dossier.self
        ) {
            evidence = try mergeSeriesScopeEvidence(current, with: pending.value)
        }
        var searches = 0
        guard let outline = try await store.seriesArtifact(
            run,
            kind: .outline,
            as: NoteSeries.Outline.self
        )
        else { throw NoteSeries.Failure.invalidArtifact }
        for entry in outline.value.entries {
            if let web = try await store.seriesArtifact(
                run,
                kind: .topicSearch,
                slot: entry.id.uuidString,
                as: WebResearchResult.self
            ) {
                searches += web.value.searchCount
            }
        }
        evidence.recoverySearchCount = max(evidence.recoverySearchCount ?? 0, searches)
        try evidence.validateExtending(current)
        return evidence
    }

    private func mergeSeriesScopeEvidence(
        _ original: NoteSeries.Dossier, with incoming: NoteSeries.Dossier
    ) throws -> NoteSeries.Dossier {
        var sources = original.sources
        for source in incoming.sources {
            if let previous = sources.first(where: { $0.id == source.id }) {
                guard previous == source else { throw NoteSeries.Failure.invalidEvidence }
            } else {
                sources.append(source)
            }
        }
        var facts = original.facts
        for fact in incoming.facts {
            if let previous = facts.first(where: { $0.id == fact.id }) {
                guard previous == fact else { throw NoteSeries.Failure.invalidEvidence }
            } else {
                facts.append(fact)
            }
        }
        // Existing selections are immutable. A narrowing has its own independently checked layer.
        var topics = incoming.topicRecords ?? [:]
        for (id, records) in original.topicRecords ?? [:] {
            topics[id] = records
        }
        var scopes = incoming.scopeRecords ?? [:]
        for (id, records) in original.scopeRecords ?? [:] {
            guard scopes[id] == nil || scopes[id] == records
            else { throw NoteSeries.Failure.invalidEvidence }
            scopes[id] = records
        }
        let unavailable = original.unavailableURLs + incoming.unavailableURLs
            .filter { !original.unavailableURLs.contains($0) }
        let merged = NoteSeries.Dossier(
            sources: sources,
            facts: facts,
            unavailableURLs: unavailable,
            topicRecords: topics.isEmpty ? nil : topics,
            recoverySearchCount: max(
                original.recoverySearchCount ?? 0,
                incoming.recoverySearchCount ?? 0
            ),
            scopeRecords: scopes.isEmpty ? nil : scopes
        )
        try merged.validateExtending(original)
        return merged
    }

    private func seriesScopeProposal(
        _ run: NoteSeries.Run, entry: NoteSeries.Entry, evidence: NoteSeries.Dossier,
        feedback: NoteSeries.DraftFeedback, failure: String, model: any NoteSeriesInferring,
        parent: UUID
    ) async throws -> NoteSeries.Artifact<NoteSeries.ScopeProposal> {
        if let saved = try await store.seriesArtifact(
            run,
            kind: .scopeProposal,
            slot: entry.id.uuidString,
            as: NoteSeries.ScopeProposal.self
        ) {
            try saved.value.validate(entry: entry, dossier: evidence)
            return saved
        }
        try await store.reserveSeriesCall(run)
        let value = try await model.proposeSeriesScope(
            entry,
            request: run.request,
            dossier: evidence,
            feedback: feedback,
            failure: failure
        )
        try value.validate(entry: entry, dossier: evidence)
        return try await store.checkpointSeries(
            run,
            kind: .scopeProposal,
            slot: entry.id.uuidString,
            value: value,
            parents: [parent]
        )
    }

    private func seriesScopeReview(
        _ run: NoteSeries.Run, entry: NoteSeries.Entry, evidence: NoteSeries.Dossier,
        proposal: NoteSeries.Artifact<NoteSeries.ScopeProposal>, feedback: NoteSeries.DraftFeedback,
        model: any NoteSeriesInferring
    ) async throws -> NoteSeries.Artifact<NoteSeries.ScopeReview> {
        if let saved = try await store.seriesArtifact(
            run,
            kind: .scopeReview,
            slot: entry.id.uuidString,
            as: NoteSeries.ScopeReview.self
        ) {
            try saved.value.validate()
            return saved
        }
        try await store.reserveSeriesCall(run)
        let value = try await model.reviewSeriesScope(
            proposal.value,
            entry: entry,
            request: run.request,
            dossier: evidence,
            feedback: feedback
        )
        try value.validate()
        return try await store.checkpointSeries(
            run,
            kind: .scopeReview,
            slot: entry.id.uuidString,
            value: value,
            parents: [proposal.id]
        )
    }

    private func checkpointSeriesScope(
        _ run: NoteSeries.Run, original: NoteSeries.Artifact<NoteSeries.Outline>,
        evidence: NoteSeries.Dossier, changes: [NoteSeries.ScopeChange], parents: [UUID]
    ) async throws -> PreparedSeriesScope {
        let outline = try NoteSeries.ScopeBundle.narrowedOutline(original.value, changes: changes)
        let value = NoteSeries.ScopeBundle(outline: outline, evidence: evidence, changes: changes)
        try await validateSeriesScope(run, bundle: value, original: original.value)
        let saved = try await store.checkpointSeries(
            run,
            kind: .scopeBundle,
            slot: UUID().uuidString,
            value: value,
            parents: [original.id] + parents
        )
        return .init(
            outline: .init(id: saved.id, value: outline),
            dossier: .init(id: saved.id, value: evidence),
            bundle: value
        )
    }

    private func validateSeriesScope(
        _ run: NoteSeries.Run,
        bundle: NoteSeries.ScopeBundle,
        original: NoteSeries.Outline
    ) async throws {
        guard let root = try await store.seriesArtifact(
            run,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        )
        else { throw NoteSeries.Failure.invalidArtifact }
        try bundle.validate(original: original, dossier: root.value)
    }
}
