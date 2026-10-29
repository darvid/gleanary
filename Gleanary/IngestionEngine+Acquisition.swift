import Foundation

extension IngestionEngine {
    /// Records the links a finished capture contains and how each was judged, then queues
    /// the ones chosen for saving unless the caller defers that. It never fails the capture.
    func followLinks(from job: CaptureJob, noteID: UUID, deferred: Bool) async {
        let hop = job.request.acquisitionHop ?? 0
        // Any capture can be one a candidate is waiting on, including a shared duplicate.
        try? await store.linkAcquiredSource(jobID: job.id, noteID: noteID)
        let code = try? await store.primaryCategoryCode(of: noteID)
        let policy = settings().acquisition(forCategory: code).policy
        // Imports and files are not "something you saved" to explore from.
        guard policy.records, hop < policy.maximumHops, job.request.url != nil,
              job.request.replacingNoteID == nil else { return }
        do {
            let document = try await store.researchSource(noteID: noteID).document
            let links = document.foundLinks(excluding: job.request.identity)
            guard !links.isEmpty else { return }
            let known = try await store.acquisitionContext(identities: links.map(\.identity))
            let sourceURL = document.sourceURL ?? job.request.url
            let closeness = policy.usesRelevance
                ? await relevance(
                    of: links,
                    sourceURL: sourceURL,
                    noteID: noteID,
                    saved: known.saved
                )
                : [:]
            let plans = await AcquisitionPlanner.plan(
                links, sourceURL: sourceURL, policy: policy, hop: hop + 1, relevance: closeness,
                savedToday: known.savedToday, saved: known.saved, muted: known.muted,
                intents: intents(of: links, sourceURL: sourceURL, saved: known.saved),
                savedTodayBySite: known.bySite
            )
            try await store.recordAcquisitions(plans, foundIn: noteID, hop: hop + 1)
            if !deferred {
                _ = try await queueApprovedAcquisitions(foundIn: noteID)
            }
        } catch {}
    }

    /// Judges a chat capture's links again once it is filed, so a category's own level
    /// applies before anything is saved.
    func replanForCategory(foundIn noteID: UUID) async throws {
        let code = try await store.primaryCategoryCode(of: noteID)
        let settings = settings()
        guard settings.acquisition(forCategory: code) != settings.acquisition else { return }
        let candidates = try await store.acquisitionCandidates(foundIn: noteID)
        try await replan(candidates, policy: settings.acquisition(forCategory: code).policy)
    }

    /// The Source explorer's crawl: re-judges the strongest recorded links that are still
    /// open, with today's library for relevance, and queues those that now qualify. Nil when
    /// Source acquisition isn't set to Explore.
    func explore(limit: Int) async throws -> [AcquisitionCandidate]? {
        guard settings().acquisition == .explore else { return nil }
        let policy = SourceAcquisitionLevel.explore.policy
        let frontier = try await store.acquisitionFrontier(
            maximumHop: policy.maximumHops, limit: max(limit * 4, 20)
        )
        let approved = try await replan(frontier, policy: policy, limit: limit)
        var queued: [AcquisitionCandidate] = []
        for candidate in approved {
            try Task.checkCancellation()
            if let next = try await queue(candidate, automatic: true) {
                queued.append(next)
            }
        }
        return queued
    }

    /// "Explore from here": follows this note's links once with Eager rules, whatever the
    /// overall level, recording links first if they never were. The caller runs the queue.
    func exploreFrom(_ noteID: UUID) async throws -> [AcquisitionCandidate] {
        let hop = try await store.acquisitionHop(of: noteID) + 1
        let source = try? await store.researchSource(noteID: noteID)
        let document: CapturedDocument
        if let source {
            document = source.document
        } else if let note = try await store.document(id: noteID) {
            document = CapturedDocument(title: note.name, coverage: .note, blocks: [ContentBlock(
                kind: .paragraph, markdown: note.markdown, text: note.markdown
            )])
        } else {
            return []
        }
        let identity = document.sourceURL.flatMap { try? CaptureRequest.webLink($0).identity } ?? ""
        let links = document.foundLinks(excluding: identity)
        let policy = SourceAcquisitionLevel.eager.policy
        let known = try await store.acquisitionContext(identities: links.map(\.identity))
        let closeness = await relevance(
            of: links, sourceURL: document.sourceURL, noteID: noteID, saved: known.saved
        )
        try await store.recordAcquisitions(
            AcquisitionPlanner.plan(
                links, sourceURL: document.sourceURL, policy: policy, hop: hop,
                relevance: closeness, savedToday: known.savedToday, saved: known.saved,
                muted: known.muted,
                intents: intents(of: links, sourceURL: document.sourceURL, saved: known.saved),
                savedTodayBySite: known.bySite
            ),
            foundIn: noteID, hop: hop
        )
        let approved = try await replan(
            store.acquisitionCandidates(foundIn: noteID),
            policy: policy
        )
        var queued: [AcquisitionCandidate] = []
        for candidate in approved {
            if let next = try await queue(candidate, automatic: true) {
                queued.append(next)
            }
        }
        return queued
    }

    /// Scores open candidates again under a policy, source by source so each keeps its own
    /// budget, and returns those now approved.
    @discardableResult
    private func replan(
        _ candidates: [AcquisitionCandidate],
        policy: AcquisitionPolicy,
        limit: Int = .max
    ) async throws -> [AcquisitionCandidate] {
        let open = candidates.filter { [.noticed, .suggested, .approved].contains($0.state) }
        guard !open.isEmpty else { return [] }
        let known = try await store.acquisitionContext(identities: open.map(\.identity))
        var savedToday = known.savedToday
        var updates: [(UUID, AcquisitionPlanner.Plan)] = []
        var approved: [AcquisitionCandidate] = []
        for (noteID, group) in Dictionary(grouping: open, by: \.foundInNoteID) {
            let links = group.map(\.foundLink)
            let sourceURL = try? await store.researchSource(noteID: noteID).document.sourceURL
            let closeness = policy.usesRelevance
                ? await relevance(
                    of: links,
                    sourceURL: sourceURL,
                    noteID: noteID,
                    saved: known.saved
                )
                : [:]
            // Candidates from one source share a hop.
            // Judged wording is kept, so re-judging costs no model call.
            var judged = Dictionary(uniqueKeysWithValues: group.compactMap { candidate in
                candidate.intent.map { (candidate.identity, $0) }
            })
            if judged.isEmpty {
                judged = await intents(of: links, sourceURL: sourceURL, saved: known.saved)
            }
            let plans = AcquisitionPlanner.plan(
                links, sourceURL: sourceURL, policy: policy, hop: group[0].hop,
                relevance: closeness, savedToday: savedToday, saved: known.saved,
                muted: known.muted, intents: judged, savedTodayBySite: known.bySite
            )
            for (candidate, var plan) in zip(group, plans) {
                // Past this run's limit, a qualifying link waits as a suggestion.
                if plan.state == .approved, approved.count >= limit {
                    plan = AcquisitionPlanner.Plan(
                        link: plan.link, score: plan.score, state: .suggested, reason: plan.reason
                    )
                }
                updates.append((candidate.id, plan))
                if plan.state == .approved {
                    var next = candidate
                    next.state = .approved
                    approved.append(next)
                    savedToday += 1
                }
            }
        }
        try await store.replanAcquisitions(updates)
        return approved
    }

    /// A model's reading of the wording around the strongest links, in one call. Empty, so
    /// cue phrases decide, when no model is set or it fails.
    private func intents(
        of links: [FoundLink],
        sourceURL: URL?,
        saved: Set<String>
    ) async -> [String: LinkIntent] {
        guard let judge = recommendationJudge else { return [:] }
        let scored: [(link: FoundLink, score: AcquisitionScorer.Score)] = links
            .filter { !saved.contains($0.identity) }
            .map { ($0, AcquisitionScorer.score($0, sourceURL: sourceURL)) }
        // Addresses filtered by site, like social profiles, need no reading.
        let readable = scored
            .filter { $0.score.filtered == nil || $0.score.filtered == "Self-promotion" }
        let ranked = readable.sorted { $0.score.value > $1.score.value }
        let strongest = ranked.prefix(RecommendationJudgement.batch).map(\.link)
        guard !strongest.isEmpty else { return [:] }
        let items = RecommendationJudgement.items(strongest)
        guard let answers = try? await judge.judgeIntents(items) else { return [:] }
        var intents: [String: LinkIntent] = [:]
        for (item, link) in zip(items, strongest) {
            intents[link.identity] = answers[item.number]
        }
        return intents
    }

    /// Judges closeness only for the strongest links, since each one is a library search.
    private func relevance(
        of links: [FoundLink],
        sourceURL: URL?,
        noteID: UUID,
        saved: Set<String>
    ) async -> [String: Double] {
        let strongest = links
            .filter { !saved.contains($0.identity) }
            .map { ($0, AcquisitionScorer.score($0, sourceURL: sourceURL)) }
            .filter { $0.1.filtered == nil }
            .sorted { $0.1.value > $1.1.value }
            .prefix(15)
        var closeness: [String: Double] = [:]
        for (link, _) in strongest {
            closeness[link.identity] = await relevance.relevance(of: link, excluding: noteID)
        }
        return closeness
    }

    /// Reads the titles of new suggestions, a few small requests at a time, so they show as
    /// titles rather than addresses. These fetches are automatic, so they respect robots.txt
    /// and each site's spacing. Returns how many titles were found.
    func titleSuggestions(limit: Int = 10) async -> Int {
        guard let untitled = try? await store.untitledSuggestions(limit: limit) else { return 0 }
        let reader = (fetcher as? SourceFetcher)?.limitingBytes(to: 262_144) ?? fetcher
        var found = 0
        for candidate in untitled {
            guard !Task.isCancelled else { break }
            var title: String?
            let address = PageTitle.oEmbedURL(for: candidate.url) ?? candidate.url
            if await robots.rules(for: address).allows(address) {
                await spaceAutomaticFetch(address)
                if let page = try? await reader.fetch(address) {
                    if address != candidate.url {
                        title = PageTitle.read(oEmbed: page.data)
                    } else if page.mime.map({ $0.lowercased().contains("html") }) ?? true {
                        title = PageTitle.read(html: String(decoding: page.data, as: UTF8.self))
                    }
                }
            }
            try? await store.setAcquisitionPageTitle(candidate.id, title)
            found += title == nil ? 0 : 1
        }
        return found
    }

    /// Queues captures for links chosen for saving. The caller runs the queue.
    func queueApprovedAcquisitions(foundIn noteID: UUID?) async throws -> [AcquisitionCandidate] {
        var queued: [AcquisitionCandidate] = []
        for candidate in try await store.approvedAcquisitions(foundIn: noteID) {
            if let next = try await queue(candidate, automatic: true) {
                queued.append(next)
            }
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
        return try await queue(candidate, automatic: false)
    }

    /// Automatic saves respect the site's robots.txt; one you chose acts for you.
    private func queue(
        _ candidate: AcquisitionCandidate,
        automatic: Bool
    ) async throws -> AcquisitionCandidate? {
        if automatic, await !robots.rules(for: candidate.url).allows(candidate.url) {
            try await store.filterAcquisition(
                candidate.id, reason: "The site's robots.txt asks not to fetch this"
            )
            return nil
        }
        // The link back carries the candidate's provenance; see `linkAcquiredSource`.
        var request = try CaptureRequest.webLink(candidate.url)
        // Automatic saves cost no AI calls until someone asks for a summary.
        request.summarizeLink = false
        request.acquisitionHop = candidate.hop
        request.automatic = automatic ? true : nil
        let job = try await store.enqueueCapture(request)
        try await store.markAcquisitionQueued(candidate.id, jobID: job)
        var queued = candidate
        queued.state = .queued
        queued.captureJobID = job
        return queued
    }
}
