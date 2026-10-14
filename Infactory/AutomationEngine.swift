import Foundation

/// Runs built-in automations. Items come from fixed store selectors, never from a model, and
/// what a run may change is decided here: only the inbox summarizer applies anything; the
/// link checker and cross-linker can only propose changes for review.
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
        /// A pause between link checks, so no site sees a burst of requests.
        var politeness: Duration = .milliseconds(500)
    }

    static let accessCheck = "access"
    static let linksCheck = "links"
    static let summaryCheck = "summary"
    /// Failed link checks needed, at least `archiveSpan` apart, before archiving is proposed.
    static let archiveFailures = 3
    static let archiveSpan: TimeInterval = 7 * 24 * 60 * 60
    static let recheckAfter: TimeInterval = 30 * 24 * 60 * 60
    static let retryAfter: TimeInterval = 24 * 60 * 60

    let store: DocumentStore
    let dependencies: Dependencies

    init(store: DocumentStore, dependencies: Dependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    func run(_ config: AutomationConfig) async -> AutomationRun {
        let started = dependencies.now()
        let runID = await (try? store.beginAutomationRun(config.kind, at: started)) ?? UUID()
        var run = AutomationRun(id: runID, kind: config.kind, startedAt: started)
        do {
            switch config.kind {
            case .inboxSummarizer: try await summarizeInbox(config, &run)
            case .linkChecker: try await checkLinks(config, &run)
            case .crossLinker: try await crossLink(config, &run)
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
        if run.report.isEmpty {
            run.report.append("Nothing needed doing.")
        }
        run.endedAt = dependencies.now()
        try? await store.finishAutomationRun(run)
        return run
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
                run.report.append("Summarized “\(document.name)”.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await store.recordCheck(
                    id, kind: Self.summaryCheck, at: dependencies.now(), state: "failed",
                    failed: true, detail: error.localizedDescription
                )
                run.skipped += 1
                run.report.append("Skipped “\(document.name)”: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Link checker

    private struct LinkTally {
        var reachable = 0, restricted = 0, transient = 0
    }

    private func checkLinks(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        let now = dependencies.now()
        let candidates = try await store.linkCheckCandidates(
            limit: config.batchLimit,
            checkedBefore: now.addingTimeInterval(-Self.recheckAfter),
            retryBefore: now.addingTimeInterval(-Self.retryAfter)
        )
        var proposals: [AgentChangeDraft] = []
        var tally = LinkTally()
        for (index, candidate) in candidates.enumerated() {
            guard try await proceed(&run) else { break }
            if index > 0 {
                try await Task.sleep(for: dependencies.politeness)
            }
            run.examined += 1
            if let proposal = try await checkLink(candidate, tally: &tally, run: &run) {
                proposals.append(proposal)
            }
        }
        // The only change this automation can make is a proposal; nothing is archived here.
        try await store.saveAgentChanges(proposals, taskID: run.id)
        run.proposed = proposals.count
        report(tally, proposals: proposals.count, in: &run)
    }

    /// Records one link's check, returning an archive proposal once it has stayed gone.
    private func checkLink(
        _ candidate: (id: UUID, url: URL, title: String),
        tally: inout LinkTally,
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
        switch await dependencies.probe.probe(candidate.url) {
        case .reachable:
            tally.reachable += 1
            _ = try await record("ok", nil)
        case let .moved(destination):
            _ = try await record("moved", destination?.absoluteString)
            run.report.append(destination
                .map { "“\(candidate.title)” has moved to \($0.absoluteString)." }
                ?? "“\(candidate.title)” has moved permanently.")
        case let .restricted(status):
            tally.restricted += 1
            _ = try await record("restricted", "HTTP \(status)")
        case let .transient(reason):
            tally.transient += 1
            _ = try await record("transient", reason)
        case let .gone(reason):
            let check = try await record("gone", failed: true, reason)
            if let proposal = try await archiveProposal(candidate, check: check, reason: reason) {
                return proposal
            }
            run.report.append(
                "“\(candidate.title)” is unreachable (\(reason)); check \(check.failures) of \(Self.archiveFailures)."
            )
        }
        return nil
    }

    private func report(_ tally: LinkTally, proposals: Int, in run: inout AutomationRun) {
        if proposals > 0 {
            run.report.append(
                "Proposed archiving \(proposals) item\(proposals == 1 ? "" : "s") whose links stayed gone."
            )
        }
        if tally.reachable > 0 {
            run.report
                .append("\(tally.reachable) link\(tally.reachable == 1 ? "" : "s") still work.")
        }
        if tally.restricted > 0 {
            run.report.append(
                "\(tally.restricted) need a login or refused the check; they won't be archived for that."
            )
        }
        if tally.transient > 0 {
            run.report.append(
                "\(tally.transient) didn't answer properly and will be checked again tomorrow."
            )
        }
    }

    /// Archiving is proposed only once a link has failed repeatedly over a week, never for a
    /// site's bad day.
    private func archiveProposal(
        _ candidate: (id: UUID, url: URL, title: String),
        check: ItemCheck,
        reason: String
    ) async throws -> AgentChangeDraft? {
        guard check.failures >= Self.archiveFailures, let first = check.firstFailureAt,
              dependencies.now().timeIntervalSince(first) >= Self.archiveSpan,
              try await !store.archiveConsidered(candidate.id)
        else { return nil }
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
            limit: config.batchLimit,
            checkedBefore: dependencies.now().addingTimeInterval(-Self.recheckAfter)
        )
        var proposals: [AgentChangeDraft] = []
        var pairs = Set<[UUID]>()
        for id in ids {
            guard try await proceed(&run) else { break }
            guard budget > 0 else { outOfBudget(&run); break }
            guard let document = try await store.document(id: id) else { continue }
            run.examined += 1
            let others = try await linkCandidates(for: document, excluding: pairs)
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
                }
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
        run.report.append(proposals.isEmpty
            ? "Looked at \(run.examined) item\(run.examined == 1 ? "" : "s"); found no links worth proposing."
            :
            "Proposed \(proposals.count) link\(proposals.count == 1 ? "" : "s") across \(run.examined) item\(run.examined == 1 ? "" : "s").")
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

    private func remainingCalls(_ config: AutomationConfig) async throws -> Int {
        let start = Calendar.current.startOfDay(for: dependencies.now())
        return try await max(
            0,
            config.dailyCalls - store.automationCalls(config.kind, since: start)
        )
    }

    private func outOfBudget(_ run: inout AutomationRun) {
        run.status = .partial
        run.report.append("Stopped at today's limit of model calls; the rest wait for tomorrow.")
    }

    /// Stops between items for cancellation, and yields to the person's own work.
    private func proceed(_ run: inout AutomationRun) async throws -> Bool {
        try Task.checkCancellation()
        guard await !dependencies.shouldYield() else {
            run.status = .partial
            run.report.append("Paused while the library was busy; the rest wait for the next run.")
            return false
        }
        return true
    }
}
