import Foundation

extension AgentCoordinator {
    /// Existing runs retain their original engine and immutable drafts. New runs use explicit
    /// state.
    func usesEvidenceSeries(_ run: NoteSeries.Run) async throws -> Bool {
        if try await store.researchSeriesState(run) != nil {
            return true
        }
        return try await store.seriesArtifact(run, kind: .brief, as: NoteSeries.Brief.self) == nil
    }

    func continueEvidenceSeries(
        _ run: NoteSeries.Run, model: any EvidenceSeriesInferring,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let researcher = inference as? any WebResearching
        else { throw NoteSeries.Failure.needsChatGPT }
        var state = try await store.researchSeriesState(run)?.value ?? .init()
        if state.revision == 0 {
            try await saveResearchState(run, state: &state)
        }
        do {
            while true {
                try Task.checkCancellation()
                if try await advanceResearchSeries(
                    run,
                    state: &state,
                    model: model,
                    researcher: researcher,
                    changed: changed
                ) {
                    return
                }
            }
        } catch let failure as ResearchSeries.Failure {
            if state.phase != .blocked {
                if case let .stopped(reason) = failure {
                    state.problem = reason
                } else {
                    state.problem = failure.localizedDescription
                }
                state.phase = .blocked
                try await saveResearchState(run, state: &state)
            }
            throw failure
        }
    }

    private func advanceResearchSeries(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State,
        model: any EvidenceSeriesInferring,
        researcher: any WebResearching, changed: @escaping @Sendable () async -> Void
    ) async throws -> Bool {
        switch state.phase {
        case .intent: try await establishResearchIntent(run, state: &state, model: model)
        case .research: try await gatherResearchSources(
                run,
                state: &state,
                researcher: researcher,
                changed: changed
            )
        case .extraction: try await extractResearchEvidence(
                run,
                state: &state,
                model: model,
                changed: changed
            )
        case .planning: try await establishEvidencePlan(run, state: &state, model: model)
        case .reviewingPlan: try await reviewEvidencePlan(run, state: &state, model: model)
        case .drafting: try await writeResearchNotes(
                run,
                state: &state,
                model: model,
                changed: changed
            )
        case .editing: try await editResearchNotes(
                run,
                state: &state,
                model: model,
                changed: changed
            )
        case .ready:
            try await acceptResearchSeries(run, state: state)
            _ = try await store.publishNoteSeries(run)
            await changed()
            return true
        case .blocked: throw ResearchSeries.Failure
            .stopped(state.problem ?? "The saved requirements cannot be satisfied.")
        }
        return false
    }

    private func establishResearchIntent(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State, model: any EvidenceSeriesInferring
    ) async throws {
        if state.intent == nil {
            try await store.reserveSeriesCall(run)
            let intent = try await model.researchSeriesIntent(request: run.request)
            try intent.validate(request: run.request)
            state.intent = intent
            try await saveResearchState(run, state: &state)
        }
        guard let intent = state.intent else { throw ResearchSeries.Failure.invalidIntent }
        let brief = try await store.checkpointSeries(
            run,
            kind: .brief,
            value: intent.brief,
            parents: []
        )
        state.library = try await seriesLibrary(run, brief: brief).value
        try await store.validateSeriesLibrary(state.library)
        state.phase = .research
        try await saveResearchState(run, state: &state)
    }

    private func gatherResearchSources(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State, researcher: any WebResearching,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let intent = state.intent else { throw ResearchSeries.Failure.invalidIntent }
        try await store.validateSeriesLibrary(state.library)
        if intent.brief
            .mode == .libraryOnly ||
            (intent.brief.mode == .fillGaps && !state.library.isEmpty && state.planAttempts == 0)
        {
            state.phase = .extraction
            try await saveResearchState(run, state: &state)
            return
        }
        let web: NoteSeries.Artifact<WebResearchResult>
        if let saved = try await store.seriesArtifact(
            run,
            kind: .webSearch,
            as: WebResearchResult.self
        ) {
            web = saved
        } else {
            guard !state.searchStarted else { throw ResearchSeries.Failure.interruptedSearch }
            state.searchStarted = true
            try await saveResearchState(run, state: &state)
            try await store.reserveSeriesCall(run)
            let domains = intent.preferredDomains.joined(separator: ", ")
            let result = try await researcher.researchWeb(
                question: "Research \(intent.brief.query). Find complementary substantive primary documentation covering the principal concepts. Prefer official documentation from \(domains.isEmpty ? "the original publishers" : domains). Cite up to \(NoteSeries.maximumWebSources) distinct useful pages. Preserve dates and distinguish current recommendations from historical material.",
                sources: []
            ) { _ in await changed() }
            _ = try result.markdown()
            web = try await store.checkpointSeries(
                run,
                kind: .webSearch,
                value: result,
                parents: []
            )
        }
        if state.sources.isEmpty {
            var seen = Set<URL>()
            state.sources = web.value.passages.flatMap(\.citations).map(\.url)
                .filter { seen.insert($0).inserted }.prefix(NoteSeries.maximumWebSources)
                .map { .init(url: $0) }
            try await saveResearchState(run, state: &state)
        }
        for index in state.sources.indices {
            try await readResearchSource(
                run,
                state: &state,
                index: index,
                parent: web.id,
                changed: changed
            )
        }
        guard state.sources.contains(where: { $0.source != nil }) else {
            throw ResearchSeries.Failure
                .stopped(
                    "No researched page could be read. Search summaries were not used as evidence."
                )
        }
        state.phase = .extraction
        try await saveResearchState(run, state: &state)
    }

    private func readResearchSource(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State, index: Int, parent: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        let job = state.sources[index]
        guard job.status == .pending || job.status == .fetching else { return }
        try await seriesProgress(
            run,
            "Reading source \(index + 1) of \(state.sources.count)",
            owner: .researcher,
            changed: changed
        )
        if job.status == .fetching {
            let cached = try await store.seriesArtifact(
                run,
                kind: .webSource,
                slot: ContentHash.of(job.url.absoluteString),
                as: NoteSeries.Source.self
            )
            state.sources[index].source = cached?.value
            state.sources[index].status = cached == nil ? .unavailable : .read
        } else {
            state.sources[index].status = .fetching
            try await saveResearchState(run, state: &state)
            do {
                let source = try await seriesWebSource(
                    run,
                    url: job.url,
                    parent: parent,
                    attemptPrefix: nil
                )
                state.sources[index].source = source.value
                state.sources[index].status = .read
            } catch is CancellationError { throw CancellationError() }
            catch let failure as NoteSeries.Failure { throw failure }
            catch { state.sources[index].status = .unavailable }
        }
        try await saveResearchState(run, state: &state)
    }

    private func extractResearchEvidence(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State,
        model: any EvidenceSeriesInferring,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let intent = state.intent else { throw ResearchSeries.Failure.invalidIntent }
        var hashes = Set<String>()
        let webSources = state.sources.compactMap(\.source)
            .filter { hashes.insert($0.contentHash).inserted }
        // A saved note and freshly read documentation have different provenance even if their text
        // matches.
        let sources = state.library + webSources
        var records: [NoteSeries.Fact] = []
        for (index, source) in sources.enumerated() {
            try await seriesProgress(
                run,
                "Checking evidence \(index + 1) of \(sources.count)",
                owner: .researcher,
                changed: changed
            )
            let facts = try await seriesFacts(
                run,
                source: source,
                fields: intent.fields,
                extractor: model,
                parents: []
            )
            records += facts.value.enumerated().map { offset, fact in
                .init(
                    id: "E\(index + 1)R\(offset + 1)",
                    sourceID: source.id,
                    field: fact.field,
                    value: fact.value,
                    quote: fact.quote
                )
            }
        }
        state.evidence = .init(
            sources: sources,
            facts: records,
            unavailableURLs: state.sources.filter { $0.status == .unavailable }.map(\.url)
        )
        try state.evidence?.validate()
        state.phase = .planning
        try await saveResearchState(run, state: &state)
    }

    private func establishEvidencePlan(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State, model: any EvidenceSeriesInferring
    ) async throws {
        guard let intent = state.intent,
              let evidence = state.evidence else { throw ResearchSeries.Failure.invalidPlan }
        guard state.planAttempts < 3
        else {
            throw ResearchSeries.Failure
                .stopped(state
                    .problem ?? "An evidence-backed plan could not satisfy the request.")
        }
        state.planAttempts += 1
        try await saveResearchState(run, state: &state)
        try await store.reserveSeriesCall(run)
        do {
            let plan = try await model.evidenceSeriesPlan(
                request: run.request,
                intent: intent,
                evidence: evidence,
                previous: state.plan,
                feedback: state.problem
            )
            state.plan = plan
            state.planReview = nil
            try plan.validate(intent: intent, evidence: evidence)
            state.phase = .reviewingPlan
        } catch let failure as ResearchSeries
            .Failure { state.problem = failure.localizedDescription }
        catch let failure as NoteSeries.Failure { state.problem = failure.localizedDescription }
        if state.phase == .planning, intent.brief.mode == .fillGaps,
           !state.searchStarted
        {
            state.phase = .research
        }
        try await saveResearchState(run, state: &state)
    }

    private func reviewEvidencePlan(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State, model: any EvidenceSeriesInferring
    ) async throws {
        guard let intent = state.intent, let evidence = state.evidence, let plan = state.plan
        else { throw ResearchSeries.Failure.invalidPlan }
        try await store.reserveSeriesCall(run)
        let review = try await model.reviewEvidenceSeriesPlan(
            request: run.request,
            intent: intent,
            plan: plan,
            evidence: evidence
        )
        guard NoteSeries.plain(review.reason, limit: 1000)
        else { throw ResearchSeries.Failure.invalidReview }
        state.planReview = review
        state.problem = review.valid ? nil : review.reason
        guard review.valid else {
            state.phase = intent.brief.mode == .fillGaps && !state
                .searchStarted ? .research : .planning
            try await saveResearchState(run, state: &state)
            return
        }
        let assigned = plan.assignedEvidence(evidence)
        try await store.checkpointSeries(run, kind: .outline, value: plan.outline, parents: [])
        try await store.checkpointSeries(run, kind: .dossier, value: assigned, parents: [])
        state.notes = plan.contracts.filter { $0.entry.existingNoteID == nil }
            .map { .init(id: $0.entry.id) }
        state.phase = .drafting
        try await saveResearchState(run, state: &state)
    }

    private func writeResearchNotes(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State,
        model: any EvidenceSeriesInferring,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let plan = state.plan,
              let evidence = state.evidence else { throw ResearchSeries.Failure.invalidPlan }
        try await store.validateSeriesLibrary(state.library)
        let assigned = plan.assignedEvidence(evidence)
        for index in state.notes.indices where !state.notes[index].accepted {
            guard let contract = plan.contracts
                .first(where: { $0.entry.id == state.notes[index].id })
            else { throw ResearchSeries.Failure.invalidPlan }
            try await seriesProgress(
                run,
                "Writing \(contract.entry.title)",
                owner: .writer,
                changed: changed
            )
            try await writeResearchNote(
                run,
                state: &state,
                index: index,
                contract: contract,
                evidence: assigned,
                model: model
            )
        }
        state.phase = .editing
        try await saveResearchState(run, state: &state)
    }

    private func writeResearchNote(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State, index: Int,
        contract: ResearchSeries.Contract,
        evidence: NoteSeries.Dossier, model: any EvidenceSeriesInferring
    ) async throws {
        guard let plan = state.plan else { throw ResearchSeries.Failure.invalidPlan }
        while !state.notes[index].accepted {
            if state.notes[index].draft == nil {
                guard state.notes[index].attempts < ResearchSeries.draftLimit else {
                    throw ResearchSeries.Failure
                        .stopped(
                            "\(contract.entry.title): \(state.notes[index].feedback ?? "The bounded drafting attempts were exhausted.")"
                        )
                }
                state.notes[index].attempts += 1
                try await saveResearchState(run, state: &state)
                try await store.reserveSeriesCall(run)
                let draft = try await model.writeEvidenceSeriesNote(
                    request: run.request,
                    contract: contract,
                    plan: plan,
                    evidence: evidence,
                    style: run.style,
                    feedback: state.notes[index].feedback
                )
                if let issue = draft.validationIssue(
                    entry: contract.entry,
                    dossier: evidence,
                    minimumParagraphs: 1
                ) {
                    state.notes[index].feedback = issue.message
                } else {
                    state.notes[index].draft = draft
                }
                try await saveResearchState(run, state: &state)
            }
            guard let draft = state.notes[index].draft else { continue }
            try await store.reserveSeriesCall(run)
            let reviews = try await model.verifySeriesDraft(
                draft,
                entry: contract.entry,
                dossier: evidence
            )
            state.notes[index].reviews = reviews
            if let issue = draft.verificationIssue(reviews: reviews) {
                state.notes[index].feedback = try issue.message + " Previous draft: " + SeriesJSON
                    .encode(draft)
                state.notes[index].draft = nil
            } else {
                state.notes[index].accepted = true
            }
            try await saveResearchState(run, state: &state)
        }
    }

    private func editResearchNotes(
        _ run: NoteSeries.Run, state: inout ResearchSeries.State,
        model: any EvidenceSeriesInferring,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let intent = state.intent, let plan = state.plan,
              let evidence = state.evidence else { throw ResearchSeries.Failure.invalidPlan }
        try await seriesProgress(
            run,
            "Reviewing coverage and conceptual relationships",
            owner: .curator,
            changed: changed
        )
        guard state.editorialAttempts < 1 + ResearchSeries
            .revisionLimit * max(1, state.notes.count)
        else {
            throw ResearchSeries.Failure
                .stopped(state
                    .problem ?? "The editorial review could not converge within its budget.")
        }
        state.editorialAttempts += 1
        try await saveResearchState(run, state: &state)
        try await store.reserveSeriesCall(run)
        do {
            let review = try await model.editEvidenceSeries(
                request: run.request,
                intent: intent,
                plan: plan,
                drafts: state.drafts,
                evidence: evidence,
                feedback: state.problem
            )
            try review.validate(
                plan: plan,
                drafts: state.drafts,
                evidence: evidence,
                connected: intent.connected
            )
            state.editorial = review
            state.problem = nil
            if review.issues.isEmpty {
                state.phase = .ready
            } else {
                try applyResearchEdits(state: &state, review: review)
                state.phase = .drafting
            }
        } catch let failure as ResearchSeries.Failure {
            if case .stopped = failure {
                throw failure
            }
            state.problem = failure.localizedDescription
        } catch let failure as NoteSeries.Failure { state.problem = failure.localizedDescription }
        try await saveResearchState(run, state: &state)
    }

    private func applyResearchEdits(
        state: inout ResearchSeries.State,
        review: ResearchSeries.EditorialReview
    ) throws {
        for issue in review.issues {
            guard let index = state.notes.firstIndex(where: { $0.id == issue.noteID })
            else { throw ResearchSeries.Failure.invalidReview }
            guard state.notes[index].revisions < ResearchSeries.revisionLimit else {
                throw ResearchSeries.Failure.stopped(issue.reason)
            }
            let comparison = try issue.comparisonID.flatMap { state.drafts[$0] }
                .map(SeriesJSON.encode) ?? "See the read-only evidence/library snapshot."
            state.notes[index].feedback = try SeriesJSON
                .encode(issue) + " Comparison: " + comparison + " Previous draft: " + SeriesJSON
                .encode(state.notes[index].draft)
            state.notes[index].draft = nil
            state.notes[index].reviews = []
            state.notes[index].accepted = false
            state.notes[index].revisions += 1
        }
    }

    private func acceptResearchSeries(
        _ run: NoteSeries.Run,
        state: ResearchSeries.State
    ) async throws {
        guard let intent = state.intent, let plan = state.plan, let evidence = state.evidence,
              let planReview = state.planReview,
              let editorial = state.editorial else { throw ResearchSeries.Failure.invalidReview }
        let accepted = ResearchSeries.Accepted(
            request: run.request,
            intent: intent,
            plan: plan,
            planReview: planReview,
            notes: state.notes,
            editorial: editorial
        )
        let reviewed = NoteSeries.ReviewedSeries(
            drafts: state.drafts,
            curation: .init(
                distinct: true,
                links: editorial.links
            ),
            requirements: plan.requiredCuration,
            evidence: plan.assignedEvidence(evidence),
            workflow: accepted
        )
        try reviewed.validate(outline: plan.outline, dossier: plan.assignedEvidence(evidence))
        try await store.checkpointSeries(run, kind: .reviewedSeries, value: reviewed, parents: [])
    }

    private func saveResearchState(
        _ run: NoteSeries.Run,
        state: inout ResearchSeries.State
    ) async throws {
        let parent = try await store.researchSeriesState(run)?.id
        state.revision += 1
        try await store.checkpointSeries(
            run,
            kind: .workflow,
            slot: String(format: "%06d", state.revision),
            value: state,
            parents: parent.map { [$0] } ?? []
        )
    }
}
