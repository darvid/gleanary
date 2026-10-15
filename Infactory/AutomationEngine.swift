import Foundation

/// Runs built-in automations. Items come from fixed store selectors, never from a model, and
/// what a run may change is decided here: the inbox summarizer, bookmark fetcher, failed-capture
/// retry and weekly digest apply their work; the link checker, cross-linker and unfiled filer
/// can only propose changes for review.
actor AutomationEngine {
    struct Dependencies: Sendable {
        /// Writes the summary for an item, returning the summarized note.
        var summarize: @Sendable (MarkdownDocument) async throws -> MarkdownDocument
        /// Whether summaries stay on the Mac with the current AI provider.
        var summarizerIsLocal: @Sendable () async -> Bool
        var probe: any LinkProbing
        var archive: any ArchiveLookup
        /// The model that judges link candidates, when one is available.
        var judge: @Sendable () async -> (any LinkJudging)?
        /// Items similar to this one, best first.
        var similar: @Sendable (MarkdownDocument, Int) async throws -> [UUID]
        var now: @Sendable () -> Date = { Date() }
        /// True when people are using the library, so the run should stop between items.
        var shouldYield: @Sendable () async -> Bool = { false }
        /// A pause between link checks or page fetches, so no site sees a burst of requests.
        var politeness: Duration = .milliseconds(500)
        /// Queues the page fetch for an imported bookmark through the capture path, returning
        /// its capture job, or nil when it's no longer an unfetched bookmark. False skips the
        /// summary Capture settings would write.
        var fetchBookmark: @Sendable (UUID, Bool) async throws -> UUID? = { _, _ in nil }
        /// Whether Capture settings write a summary for each fetched page.
        var capturesSummarize: @Sendable () -> Bool = { false }
        /// Starts the capture queue for a job this automation queued; the run reports how it
        /// went, so the window doesn't announce it.
        var startCapture: @Sendable (UUID) async -> Void = { _ in }
        /// How often to look whether a queued capture has finished.
        var capturePoll: Duration = .seconds(1)
        /// The model that suggests homes for unfiled items, when one is available.
        var filer: @Sendable () async -> (any ConversationInferring)? = { nil }
        /// The model the Writer uses for a written-up digest, when one is available.
        /// Throws when the AI provider is ChatGPT but it can't be used right now.
        var writer: @Sendable () async throws -> (any ConversationInferring)? = { nil }
        /// The default writing style, read when a digest is written up.
        var writingStyle: @Sendable () -> WritingStyle = { .plain }
    }

    static let accessCheck = "access"
    static let linksCheck = "links"
    static let summaryCheck = "summary"
    static let fetchCheck = "fetch"
    static let filingCheck = "filing"
    /// Failed link checks needed, at least `archiveSpan` apart, before archiving is proposed.
    static let archiveFailures = 3
    static let archiveSpan: TimeInterval = 7 * 24 * 60 * 60
    static let retryAfter: TimeInterval = 24 * 60 * 60

    let store: DocumentStore
    let dependencies: Dependencies
    /// Where the current run says what it's doing, such as "Fetching 2 of 5: example.com".
    private var progress: @Sendable (String) async -> Void = { _ in }

    init(store: DocumentStore, dependencies: Dependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    func run(
        _ config: AutomationConfig,
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> AutomationRun {
        self.progress = progress
        defer { self.progress = { _ in } }
        let started = dependencies.now()
        let runID = await (try? store.beginAutomationRun(config.kind, at: started)) ?? UUID()
        var run = AutomationRun(id: runID, kind: config.kind, startedAt: started)
        do {
            switch config.kind {
            case .inboxSummarizer: try await summarizeInbox(config, &run)
            case .linkChecker: try await checkLinks(config, &run)
            case .crossLinker: try await crossLink(config, &run)
            case .bookmarkFetcher: try await fetchBookmarks(config, &run)
            case .unfiledFiler: try await fileUnfiled(config, &run)
            case .captureRetry: try await retryCaptures(config, &run)
            case .weeklyDigest: try await writeDigest(config, &run)
            }
            if run.status == .running {
                run.status = .succeeded
            }
        } catch is CancellationError {
            run.status = .cancelled
            run.report.append("Stopped.")
        } catch {
            run.status = .failed
            run.report.append("Failed: \(error.localizedDescription)")
        }
        run.endedAt = dependencies.now()
        try? await store.finishAutomationRun(run)
        return run
    }

    /// How many items are due now, past this run's batch included. New items are never
    /// checked or summarized yet, so they always count here and come first.
    func backlog(_ config: AutomationConfig) async throws -> Int {
        let now = dependencies.now()
        return switch config.kind {
        case .inboxSummarizer:
            try await store.inboxSummaryBacklog(
                retryBefore: now.addingTimeInterval(-Self.retryAfter)
            )
        case .linkChecker:
            try await store.linkCheckBacklog(
                checkedBefore: now.addingTimeInterval(-config.recheck),
                retryBefore: now.addingTimeInterval(-Self.retryAfter)
            )
        case .crossLinker:
            try await store.crossLinkBacklog(
                checkedBefore: now.addingTimeInterval(-config.recheck)
            )
        case .bookmarkFetcher:
            try await store.bookmarkFetchBacklog()
        case .unfiledFiler:
            try await store.unfiledBacklog(
                checkedBefore: now.addingTimeInterval(-config.recheck),
                retryBefore: now.addingTimeInterval(-Self.retryAfter)
            )
        case .captureRetry:
            try await store.captureRetryBacklog(
                now: now, firstWait: Self.retryWaits[0], maxRetries: Self.retryWaits.count
            )
        case .weeklyDigest:
            try await store.digestBacklog(from: digestStart(now), to: now)
        }
    }

    /// The most a run takes, so a large library isn't left half-checked.
    static let largestBatch = 1000

    /// How many items a run takes. Checks repeat every `config.recheck`, so a run takes at
    /// least enough to get through what's due within that at this schedule, and never fewer
    /// than the batch you set. Work that doesn't repeat keeps to your batch; the daily model
    /// budget limits summaries.
    static func plannedBatch(_ config: AutomationConfig, backlog: Int) -> Int {
        guard config.kind.rechecks else { return config.batchLimit }
        let runsPerCycle = max(1, Int(config.recheck / max(config.interval, 60)))
        let needed = (backlog + runsPerCycle - 1) / runsPerCycle
        return min(largestBatch, max(config.batchLimit, needed))
    }

    // MARK: Inbox summarizer

    private func summarizeInbox(
        _ config: AutomationConfig,
        _ run: inout AutomationRun
    ) async throws {
        if !config.cloudAllowed, await !dependencies.summarizerIsLocal() {
            run.report
                .append("Skipped: this automation is on-device only and ChatGPT writes summaries.")
            return
        }
        var budget = try await remainingCalls(config)
        let ids = try await store.inboxSummaryCandidates(
            limit: config.batchLimit,
            retryBefore: dependencies.now().addingTimeInterval(-Self.retryAfter)
        )
        for id in ids {
            guard try await proceed(&run) else { return }
            guard budget > 0 else { return outOfBudget(&run) }
            guard let document = try await store.document(id: id) else { continue }
            run.examined += 1
            budget -= 1
            run.calls += 1
            do {
                let summarized = try await dependencies.summarize(document)
                try await store.recordAppliedChange(
                    AgentChangeDraft(
                        kind: .summary, noteID: id, before: document.markdown,
                        after: summarized.markdown, reason: "Summarized by the inbox summarizer.",
                        baseRevision: document.revision
                    ),
                    appliedRevision: summarized.revision,
                    runID: run.id
                )
                try await store.recordCheck(
                    id, kind: Self.summaryCheck, at: dependencies.now(), state: "done"
                )
                run.changed += 1
                run.note(.changed, id, document.name, "Wrote a summary.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await store.recordCheck(
                    id, kind: Self.summaryCheck, at: dependencies.now(), state: "failed",
                    failed: true, detail: error.localizedDescription
                )
                run.skipped += 1
                run.note(
                    .skipped, id, document.name,
                    "\(error.localizedDescription) Tried again tomorrow."
                )
            }
        }
    }

    // MARK: Link checker

    private func checkLinks(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        let now = dependencies.now()
        let candidates = try await store.linkCheckCandidates(
            limit: Self.plannedBatch(config, backlog: backlog(config)),
            checkedBefore: now.addingTimeInterval(-config.recheck),
            retryBefore: now.addingTimeInterval(-Self.retryAfter)
        )
        let (probes, yielded) = try await probeAll(candidates)
        var proposals: [AgentChangeDraft] = []
        // Recorded in the order they were chosen, whichever site answered first.
        for (index, candidate) in candidates.enumerated() {
            guard let result = probes[index] else { continue }
            run.examined += 1
            if let proposal = try await recordLink(
                candidate, result, archives: config.archivesDeadLinks, run: &run
            ) {
                proposals.append(proposal)
            }
        }
        if yielded {
            run.status = .partial
            run.report.append("Paused while the library was busy; the rest wait for the next run.")
        }
        // Links are only ever proposed; archives too, unless dead links archive themselves.
        try await store.saveAgentChanges(proposals, taskID: run.id)
        run.proposed = proposals.count
    }

    typealias LinkCandidate = (id: UUID, url: URL, title: String)

    /// Sites checked at once. Each site's links are checked one at a time with a pause
    /// between, so no site sees a burst; different sites don't wait on each other.
    static let concurrentSites = 6

    /// Probes every candidate, keyed by its position. Stops starting new checks when the
    /// library gets busy, reporting that it yielded.
    private func probeAll(_ candidates: [LinkCandidate]) async throws
        -> (results: [Int: LinkProbe], yielded: Bool)
    {
        let sites = Dictionary(grouping: candidates.indices) {
            candidates[$0].url.host()?.lowercased() ?? ""
        }.values.sorted { $0[0] < $1[0] }
        let (probe, pause, shouldYield) = (
            dependencies.probe, dependencies.politeness, dependencies.shouldYield
        )
        return try await withThrowingTaskGroup(of: ([(Int, LinkProbe)], Bool).self) { group in
            var next = 0
            func start(_ group: inout ThrowingTaskGroup<([(Int, LinkProbe)], Bool), Error>) {
                guard next < sites.count else { return }
                let indices = sites[next]
                next += 1
                group.addTask {
                    var done: [(Int, LinkProbe)] = []
                    for (position, index) in indices.enumerated() {
                        try Task.checkCancellation()
                        if await shouldYield() {
                            return (done, true)
                        }
                        if position > 0 {
                            try await Task.sleep(for: pause)
                        }
                        await done.append((index, probe.probe(candidates[index].url)))
                    }
                    return (done, false)
                }
            }
            for _ in 0 ..< Self.concurrentSites {
                start(&group)
            }
            var results: [Int: LinkProbe] = [:]
            var yielded = false
            while let (done, stopped) = try await group.next() {
                for (index, result) in done {
                    results[index] = result
                }
                yielded = yielded || stopped
                if !yielded {
                    start(&group)
                }
            }
            return (results, yielded)
        }
    }

    /// Records one link's check, returning a proposal to update a moved link or archive one
    /// that stayed gone. With `archives`, a link that stayed gone is archived here instead.
    private func recordLink(
        _ candidate: LinkCandidate,
        _ result: LinkProbe,
        archives: Bool,
        run: inout AutomationRun
    ) async throws -> AgentChangeDraft? {
        let checked = dependencies.now()
        func record(_ state: String, failed: Bool = false, _ detail: String?) async throws
            -> ItemCheck
        {
            try await store.recordCheck(
                candidate.id, kind: Self.accessCheck, at: checked, state: state,
                failed: failed, detail: detail
            )
        }
        let (id, title) = (candidate.id, candidate.title)
        switch result {
        case .reachable:
            run.fine += 1
            _ = try await record("ok", nil)
        case let .moved(destination):
            _ = try await record("moved", destination?.absoluteString)
            guard let destination else {
                run.note(.moved, id, title, "Moved permanently without saying where.")
                return nil
            }
            guard try await !store.relinkConsidered(id, to: destination) else {
                run.note(
                    .moved,
                    id,
                    title,
                    "Moved to \(destination.absoluteString). Already proposed."
                )
                return nil
            }
            run.note(
                .proposed,
                id,
                title,
                "Moved to \(destination.absoluteString). Update the link?"
            )
            return AgentChangeDraft(
                kind: .relink, noteID: id, before: candidate.url.absoluteString,
                after: destination.absoluteString,
                reason: "The original link redirects permanently to this address."
            )
        case let .restricted(status):
            _ = try await record("restricted", "HTTP \(status)")
            run.note(
                .restricted, id, title,
                "Needs a login or refused the check (HTTP \(status)). Never archived for that."
            )
        case .refused:
            _ = try await record("refused", nil)
            run.note(
                .restricted, id, title,
                "Infactory doesn't check local or private addresses. Never archived for that."
            )
        case let .transient(reason):
            _ = try await record("transient", reason)
            run.note(.retry, id, title, "\(reason). Checked again tomorrow.")
        case let .gone(reason):
            let check = try await record("gone", failed: true, reason)
            if archives, try await archiveAutomatically(
                candidate, check: check, reason: reason, run: &run
            ) {
                return nil
            }
            if let proposal = try await archiveProposal(candidate, check: check, reason: reason) {
                run.note(.proposed, id, title, "\(reason). Archive it?")
                return proposal
            }
            let next = archives ? "it's archived" : "archiving is proposed"
            run.note(
                .unreachable, id, title,
                "\(reason). Failed \(check.failures) of \(Self.archiveFailures) checks before \(next); checking again tomorrow."
            )
        }
        return nil
    }

    /// Whether a gone link has failed often enough, over long enough, to archive.
    private func staysGone(_ check: ItemCheck) -> Bool {
        guard check.failures >= Self.archiveFailures, let first = check.firstFailureAt else {
            return false
        }
        return dependencies.now().timeIntervalSince(first) >= Self.archiveSpan
    }

    /// Archives a link that stayed gone, with Undo, when archiving it was never proposed or
    /// done before; anything you decided on, or haven't yet, is left to the review sheet.
    /// False hands the link back to the usual proposal.
    private func archiveAutomatically(
        _ candidate: LinkCandidate,
        check: ItemCheck,
        reason: String,
        run: inout AutomationRun
    ) async throws -> Bool {
        guard staysGone(check), try await !store.archiveEverConsidered(candidate.id),
              let draft = await archiveDraft(candidate, check: check, reason: reason),
              try await store.archiveAutomatically(draft, runID: run.id, at: dependencies.now())
        else { return false }
        run.changed += 1
        run.note(.changed, candidate.id, candidate.title, "Archived. \(draft.reason)")
        return true
    }

    /// Archiving is proposed only once a link has failed repeatedly over a week, never for a
    /// site's bad day.
    private func archiveProposal(
        _ candidate: LinkCandidate,
        check: ItemCheck,
        reason: String
    ) async throws -> AgentChangeDraft? {
        guard staysGone(check), try await !store.archiveConsidered(candidate.id) else {
            return nil
        }
        return await archiveDraft(candidate, check: check, reason: reason)
    }

    private func archiveDraft(
        _ candidate: LinkCandidate,
        check: ItemCheck,
        reason: String
    ) async -> AgentChangeDraft? {
        guard let first = check.firstFailureAt else { return nil }
        let since = first.formatted(date: .abbreviated, time: .omitted)
        var detail = "\(reason). Checked \(check.failures) times since \(since). Your saved copy is intact."
        if let snapshot = await dependencies.archive.snapshot(of: candidate.url) {
            detail += " Wayback Machine copy: \(snapshot.absoluteString)"
        }
        return AgentChangeDraft(
            kind: .archive, noteID: candidate.id, before: "",
            after: "Original link unreachable since \(since)", reason: detail
        )
    }

    // MARK: Cross-linker

    private func crossLink(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        guard let judge = await dependencies.judge() else {
            run.report.append("Skipped: needs Apple Intelligence or ChatGPT to judge links.")
            return
        }
        if !config.cloudAllowed, !judge.local {
            run.report
                .append("Skipped: this automation is on-device only and ChatGPT would judge links.")
            return
        }
        var budget = try await remainingCalls(config)
        let ids = try await store.crossLinkCandidates(
            limit: Self.plannedBatch(config, backlog: backlog(config)),
            checkedBefore: dependencies.now().addingTimeInterval(-config.recheck)
        )
        var proposals: [AgentChangeDraft] = []
        var pairs = Set<[UUID]>()
        for id in ids {
            guard try await proceed(&run) else { break }
            guard budget > 0 else { outOfBudget(&run); break }
            guard let document = try await store.document(id: id) else { continue }
            run.examined += 1
            let others = try await linkCandidates(for: document, excluding: pairs)
            var found = 0
            if !others.isEmpty {
                let candidates = others.enumerated().map { Self.judgementItem($1, number: $0 + 1) }
                budget -= 1
                run.calls += 1
                let answers = try await judge.judgeLinks(
                    Self.judgementItem(document, number: 0), candidates: candidates
                )
                for answer in answers where answer.related {
                    let other = others[answer.item - 1]
                    pairs.insert([id, other.id].sorted { $0.uuidString < $1.uuidString })
                    proposals.append(AgentChangeDraft(
                        kind: .link, noteID: id, targetID: other.id, before: "",
                        after: other.name, reason: answer.reason
                    ))
                    run.note(
                        .proposed,
                        id,
                        document.name,
                        "Link to “\(other.name)”: \(answer.reason)"
                    )
                    found += 1
                }
            }
            if found == 0 {
                run.fine += 1
            }
            try await store.recordCheck(
                id,
                kind: Self.linksCheck,
                at: dependencies.now(),
                state: "done"
            )
        }
        try await store.saveAgentChanges(proposals, taskID: run.id)
        run.proposed = proposals.count
    }

    /// Up to six similar items not already linked, proposed or archived.
    private func linkCandidates(
        for document: MarkdownDocument,
        excluding pairs: Set<[UUID]>
    ) async throws -> [MarkdownDocument] {
        var others: [MarkdownDocument] = []
        for other in try await dependencies.similar(document, 12) where other != document.id {
            let pair = [document.id, other].sorted { $0.uuidString < $1.uuidString }
            guard !pairs.contains(pair), try await !store.linkConsidered(document.id, other),
                  try await !store.isArchived(other),
                  let candidate = try await store.document(id: other) else { continue }
            others.append(candidate)
            if others.count == 6 {
                break
            }
        }
        return others
    }

    private static func judgementItem(_ document: MarkdownDocument, number: Int) -> LinkJudgement
        .Item
    {
        LinkJudgement.Item(
            number: number,
            title: String(document.name.prefix(160)),
            excerpt: String(document.markdown.prefix(700))
        )
    }

    // MARK: Shared

    func report(_ step: String) async {
        await progress(step)
    }

    func remainingCalls(_ config: AutomationConfig) async throws -> Int {
        let start = Calendar.current.startOfDay(for: dependencies.now())
        return try await max(
            0,
            config.dailyCalls - store.automationCalls(config.kind, since: start)
        )
    }

    func outOfBudget(_ run: inout AutomationRun) {
        run.status = .partial
        run.report.append("Stopped at today's limit of model calls; the rest wait for tomorrow.")
    }

    /// Stops between items for cancellation, and yields to the person's own work.
    func proceed(_ run: inout AutomationRun) async throws -> Bool {
        try Task.checkCancellation()
        guard await !dependencies.shouldYield() else {
            run.status = .partial
            run.report.append("Paused while the library was busy; the rest wait for the next run.")
            return false
        }
        return true
    }
}
