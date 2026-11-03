import Foundation

/// The bookmark fetcher, failed-capture retry, unfiled filer and weekly digest. Fetches and
/// retries go through the capture queue like anything you save; the filer only proposes; the
/// digest writes one new note and never edits another.
extension AutomationEngine {
    /// Waits before each automatic retry of a failed capture; after the last, it stays in
    /// Activity for you.
    static let retryWaits: [TimeInterval] = [60 * 60, 24 * 60 * 60, 7 * 24 * 60 * 60]
    static let retryWaitLabels = ["an hour", "a day", "a week"]
    /// How long a run waits for one capture before moving on; the capture carries on in
    /// Activity and the run reports it as still fetching.
    static let longestCapture: Duration = .seconds(2 * 60)
    static let digestSpan: TimeInterval = 7 * 24 * 60 * 60

    // MARK: Bookmark fetcher

    func fetchBookmarks(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        // On-device only keeps ChatGPT from summarizing these pages; they're still fetched.
        var summarize = dependencies.capturesSummarize()
        if summarize, !config.cloudAllowed {
            summarize = await dependencies.summarizerIsLocal()
        }
        var budget = try await remainingCalls(config)
        let retried = try await store.automationConfigs()
            .first { $0.kind == .captureRetry }?.enabled ?? false
        var sites = Set<String>()
        let candidates = try await store.bookmarkFetchCandidates(limit: config.batchLimit)
        for (index, candidate) in candidates.enumerated() {
            guard try await proceed(&run) else { return }
            await report("Fetching \(index + 1) of \(candidates.count): "
                + (candidate.url.host() ?? candidate.title))
            if summarize, budget <= 0 {
                return outOfBudget(&run)
            }
            // Pages come one at a time; a site already fetched this run waits a moment first.
            if !sites.insert(candidate.url.host()?.lowercased() ?? "").inserted {
                try await Task.sleep(for: dependencies.politeness)
            }
            guard let before = try await store.document(id: candidate.id),
                  let jobID = try await dependencies.fetchBookmark(candidate.id, summarize)
            else { continue }
            run.examined += 1
            let job = try await finishCapture(jobID, for: run.id)
            if summarize, job?.state == .ready {
                budget -= 1
                run.calls += 1
            }
            try await recordFetch(candidate, before: before, job: job, retried: retried, &run)
        }
    }

    private func recordFetch(
        _ candidate: (id: UUID, url: URL, title: String),
        before: MarkdownDocument,
        job: CaptureJob?,
        retried: Bool,
        _ run: inout AutomationRun
    ) async throws {
        let (id, title, now) = (candidate.id, candidate.title, dependencies.now())
        switch job?.state {
        case .ready:
            try await store.recordCheck(id, kind: Self.fetchCheck, at: now, state: "done")
            run.changed += 1
            guard job?.noteID == id, let after = try await store.document(id: id),
                  after.revision != before.revision
            else {
                return run.note(.changed, job?.noteID, title, "The page is saved as another item.")
            }
            try await store.recordAppliedChange(
                AgentChangeDraft(
                    kind: .summary, noteID: id, before: before.markdown, after: after.markdown,
                    reason: "Fetched by the bookmark fetcher.", baseRevision: before.revision
                ),
                appliedRevision: after.revision,
                runID: run.id
            )
            let unsummarized = job?.progress.hasPrefix("Saved full text without a summary")
            run.note(
                .changed,
                id,
                after.name,
                unsummarized == true
                    ? "Fetched the page. \(job?.progress ?? "")" : "Fetched the page."
            )
        case .failed:
            try await store.recordCheck(
                id, kind: Self.fetchCheck, at: now, state: "failed", failed: true,
                detail: job?.error
            )
            run.skipped += 1
            let reason = job?.error ?? "The page couldn't be fetched."
            if job?.retryable == true, retried {
                run.note(.retry, id, title, "\(reason) The failed-capture retry tries again.")
            } else {
                run.note(.skipped, id, title, "\(reason) Try Again is on the item.")
            }
        case .cancelled:
            // Stopped by hand, so not fetched again unasked.
            try await store.recordCheck(id, kind: Self.fetchCheck, at: now, state: "cancelled")
            run.skipped += 1
            run.note(.skipped, id, title, "Stopped in Activity.")
        case nil:
            run.skipped += 1
            run.note(.skipped, id, title, "The fetch was removed from Activity.")
        default:
            run.skipped += 1
            run.note(.skipped, id, title, "Still fetching; it carries on in Activity.")
        }
    }

    // MARK: Source explorer

    /// Saves the most promising links found in your sources, one page at a time, when Source
    /// acquisition is set to Explore. Saves skip summaries; probation archives unused ones.
    func exploreSources(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        guard let queued = try await dependencies.explore(config.batchLimit) else {
            return run.report.append(
                "Source acquisition isn't set to Explore in Capture settings, so nothing was followed."
            )
        }
        guard !queued.isEmpty else {
            return run.report.append("No recorded link qualifies today.")
        }
        for (index, candidate) in queued.enumerated() {
            guard try await proceed(&run), let jobID = candidate.captureJobID else { return }
            await report("Saving \(index + 1) of \(queued.count): \(candidate.host)")
            if index > 0 {
                try await Task.sleep(for: dependencies.politeness)
            }
            run.examined += 1
            let job = try await finishCapture(jobID, for: run.id)
            switch job?.state {
            case .ready:
                run.changed += 1
                var title = candidate.host
                if let id = job?.noteID, let note = try await store.document(id: id) {
                    title = note.name
                }
                run.note(.changed, job?.noteID, title, "\(candidate.reason) (\(candidate.host)).")
            case .failed:
                run.skipped += 1
                run.note(.skipped, nil, candidate.host, job?.error ?? "The page couldn't be saved.")
            default:
                run.skipped += 1
                run.note(.skipped, nil, candidate.host, "Still saving; it carries on in Activity.")
            }
        }
    }

    /// Starts a capture this automation queued and waits for it, checking for Stop as it
    /// goes. Gives up waiting after a while, returning the capture still running. What the
    /// capture changed is filed in Activity under the run.
    private func finishCapture(_ id: UUID, for runID: UUID) async throws -> CaptureJob? {
        await dependencies.startCapture(id)
        let deadline = ContinuousClock.now + Self.longestCapture
        while true {
            guard let job = try await store.captureJob(id: id) else { return nil }
            if job.state.terminal || ContinuousClock.now >= deadline {
                try await store.attributeCaptureActivity(id, toRun: runID)
                return job
            }
            try await Task.sleep(for: dependencies.capturePoll)
        }
    }

    // MARK: Failed-capture retry

    /// Tries failed captures again when the failure may pass, waiting longer after each, and
    /// never ones that need you: a login, a browser, or a choice of audio.
    func retryCaptures(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        let jobs = try await store.captureRetryCandidates(
            limit: config.batchLimit, now: dependencies.now(),
            firstWait: Self.retryWaits[0], maxRetries: Self.retryWaits.count
        )
        let runID = run.id
        for (index, job) in jobs.enumerated() {
            guard try await proceed(&run) else { return }
            await report("Retrying \(index + 1) of \(jobs.count): \(job.request.label)")
            guard try await store.retryCaptureAutomatically(
                job.id, maxRetries: Self.retryWaits.count
            ) else { continue }
            run.examined += 1
            try await recordRetry(
                job, attempt: job.autoRetries + 1, result: finishCapture(job.id, for: runID), &run
            )
        }
    }

    private func recordRetry(
        _ job: CaptureJob,
        attempt: Int,
        result: CaptureJob?,
        _ run: inout AutomationRun
    ) async throws {
        let title = job.request.label
        let item = job.request.replacingNoteID
        let tries = "try \(attempt) of \(Self.retryWaits.count)"
        switch result?.state {
        case .ready:
            run.changed += 1
            run.note(.changed, result?.noteID ?? item, title, "Saved on automatic \(tries).")
        case .failed:
            run.skipped += 1
            let reason = result?.error ?? "It failed again."
            guard result?.retryable == true else {
                return run.note(.skipped, item, title, "\(reason) Left in Activity for you.")
            }
            guard attempt < Self.retryWaits.count else {
                return run.note(
                    .skipped, item, title, "\(reason) Failed every try; left in Activity for you."
                )
            }
            try await store.scheduleCaptureRetry(
                job.id, at: dependencies.now().addingTimeInterval(Self.retryWaits[attempt])
            )
            run.note(
                .retry, item, title,
                "\(reason) Failed \(tries); trying again in \(Self.retryWaitLabels[attempt])."
            )
        case .cancelled:
            run.skipped += 1
            run.note(.skipped, item, title, "Stopped in Activity.")
        case nil:
            run.skipped += 1
            run.note(.skipped, item, title, "Removed from Activity.")
        default:
            run.skipped += 1
            run.note(.skipped, item, title, "Still running; it carries on in Activity.")
        }
    }

    // MARK: Unfiled filer

    /// Asks the filing model for a home per unfiled item, in the batches Categorize Unfiled
    /// uses and with its saved answers, and proposes the existing category it chose.
    func fileUnfiled(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        guard let inference = await dependencies.filer() else {
            return run.report
                .append("Skipped: needs Apple Intelligence or ChatGPT to suggest homes.")
        }
        if !config.cloudAllowed, !inference.capabilities.local {
            return run.report
                .append(
                    "Skipped: this automation is on-device only and ChatGPT would suggest homes."
                )
        }
        let categorizer = BookmarkCategorizer(store: store, inference: inference)
        let taxonomy: BookmarkCategorizer.Taxonomy
        do { taxonomy = try await categorizer.taxonomy() } catch CategorizationError.noCategories {
            return run.report.append("Skipped: there are no categories to file into yet.")
        }
        var budget = try await remainingCalls(config)
        let now = dependencies.now()
        let candidates = try await store.unfiledCandidates(
            limit: Self.plannedBatch(config, backlog: backlog(config)),
            checkedBefore: now.addingTimeInterval(-config.recheck),
            retryBefore: now.addingTimeInterval(-Self.retryAfter)
        )
        let engine = inference.capabilities.local ? "Apple Intelligence" : "ChatGPT"
        var proposals: [AgentChangeDraft] = []
        let size = inference.classificationBatchSize
        for start in stride(from: 0, to: candidates.count, by: size) {
            guard try await proceed(&run) else { break }
            guard budget > 0 else { outOfBudget(&run); break }
            let batch = Array(candidates[start ..< min(start + size, candidates.count)])
            let found = try await categorizer.answers(batch, taxonomy: taxonomy)
            if found.called {
                budget -= 1
                run.calls += 1
            }
            run.examined += batch.count
            for (index, candidate) in batch.enumerated() {
                if let proposal = try await recordFiling(
                    candidate, found.answers[index], taxonomy: taxonomy, engine: engine, &run
                ) {
                    proposals.append(proposal)
                }
            }
        }
        // The only change this automation makes is a proposal; nothing is filed here.
        try await store.saveAgentChanges(proposals, taskID: run.id)
        run.proposed = proposals.count
    }

    private func recordFiling(
        _ candidate: FilingCandidate,
        _ answer: CachedClassification?,
        taxonomy: BookmarkCategorizer.Taxonomy,
        engine: String,
        _ run: inout AutomationRun
    ) async throws -> AgentChangeDraft? {
        let (id, title, now) = (candidate.id, candidate.title, dependencies.now())
        guard let answer else {
            try await store.recordCheck(
                id, kind: Self.filingCheck, at: now, state: "failed", failed: true
            )
            run.skipped += 1
            run.note(
                .skipped,
                id,
                title,
                "The model's answer couldn't be used. Tried again tomorrow."
            )
            return nil
        }
        try await store.recordCheck(id, kind: Self.filingCheck, at: now, state: "done")
        guard let category = BookmarkClassification.choices(taxonomy.categories)
            .first(where: { $0.code == answer.code })
        else {
            if let name = answer.newCategory {
                run.skipped += 1
                run.note(
                    .skipped, id, title,
                    "No category fits; a new one, “\(name)”, might. Categorize Unfiled can create it."
                )
            } else {
                run.fine += 1
            }
            return nil
        }
        // Proposed, applied or turned down before: not asked again.
        guard try await !store.filingConsidered(id, code: category.code) else {
            run.fine += 1
            return nil
        }
        let unsure = answer.confident ? "" : " It wasn't sure between homes."
        run.note(.proposed, id, title, "File in \(category.label)?\(unsure)")
        return AgentChangeDraft(
            kind: .filing, noteID: id, code: category.code, before: "Unfiled",
            after: category.label,
            reason: "Suggested by \(engine) from the item's title and opening.\(unsure)",
            baseRevision: candidate.revision
        )
    }

    // MARK: Weekly digest

    /// One new note listing what was saved since the last digest, at most a week back. An
    /// empty week writes nothing.
    func writeDigest(_ config: AutomationConfig, _ run: inout AutomationRun) async throws {
        let now = dependencies.now()
        let start = try await digestStart(now)
        let total = try await store.digestBacklog(from: start, to: now)
        guard total > 0 else {
            return run.report.append(start > now.addingTimeInterval(-Self.digestSpan)
                ? "Nothing saved since the last digest, so no new one."
                : "Nothing saved in the last 7 days, so no digest.")
        }
        try Task.checkCancellation()
        let items = try await store.digestItems(from: start, to: now, limit: config.batchLimit)
        run.examined = items.count
        let written = config.usesWriter
            ? try await writtenDigest(items, total: total, from: start, to: now, config, &run)
            : nil
        var document = written?.document
            ?? DigestNote.document(items, total: total, from: start, to: now)
        let found = try await store.acquisitionDigest(from: start, to: now)
        document.markdown += DigestNote.foundForYou(found.saved, expired: found.expired)
        let note = try await store.writeAutomationNote(
            document,
            reason: "Written by the weekly digest.",
            runID: run.id,
            at: now
        )
        run.changed = 1
        run.note(
            .changed,
            note.id,
            note.name,
            written.map { "Written up by the Writer from \(Self.itemCount($0.covered))." }
                ?? ((items.count == total
                        ? "Lists \(Self.itemCount(total))."
                        :
                        "Lists the newest \(items.count.formatted()) of \(Self.itemCount(total)).")
                    + (config.usesWriter ? run.report.last { $0.hasPrefix(Self.writerSkipped) }
                        .map { " " + $0 } ?? "" : ""))
        )
    }

    /// Starts the reason a digest set to be written up was listed instead.
    static let writerSkipped = "The Writer didn't write this one: "

    /// The week written up by the Writer from the newest items it can take, with any others
    /// listed after. Nil, with the reason in the report, when it can't run; the digest is then
    /// the usual list, so a week is never skipped for want of a model.
    func writtenDigest(
        _ items: [DigestItem],
        total: Int,
        from start: Date,
        to end: Date,
        _ config: AutomationConfig,
        _ run: inout AutomationRun
    ) async throws -> (document: MarkdownDocument, covered: Int)? {
        func listInstead(_ reason: String) -> (document: MarkdownDocument, covered: Int)? {
            run.report.append(Self.writerSkipped + reason)
            return nil
        }
        let found: (any ConversationInferring)?
        do { found = try await dependencies.writer() } catch {
            return listInstead("ChatGPT isn't available (\(error.localizedDescription))")
        }
        guard let inference = found else {
            return listInstead("the Writer needs Apple Intelligence or ChatGPT.")
        }
        if !config.cloudAllowed, !inference.capabilities.local {
            return listInstead("this automation is on-device only, and ChatGPT is the AI provider.")
        }
        let covered = Array(items.prefix(WriterLimits.maximumScope))
        guard WriterPipeline.canWrite(covered.count, with: inference) else {
            return listInstead(
                "writing up more than \(WriterLimits.localScope) items needs ChatGPT."
            )
        }
        // At least a call per item and a few for writing; cached items cost less.
        guard try await remainingCalls(config) >= covered.count + 4 else {
            return listInstead("today's model calls would run out first.")
        }
        let style = dependencies.writingStyle()
        let range = DigestNote.range(start, end)
        let request = WriterRequest(
            taskID: run.id, noteID: nil, kind: .compose, request: DigestNote.request(range),
            style: style, brief: DigestNote.brief, generalKnowledge: false,
            scopeLimit: covered.count, candidates: [], selection: covered.map(\.id),
            excluded: [], sources: [], status: .writing, personal: true
        )
        do {
            let composition = try await WriterPipeline(store: store, inference: inference)
                .produce(request) { step, _ in await self.report(step) }
            run.calls += composition.calls
            return (
                DigestNote.written(
                    composition.rendered, rest: Array(items.dropFirst(covered.count)),
                    listed: items.count, total: total, range: range
                ),
                covered.count
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return listInstead("the Writer couldn't finish (\(error.localizedDescription))")
        }
    }

    /// Where the next digest starts: the last one still standing, or a week back.
    func digestStart(_ now: Date) async throws -> Date {
        let weekAgo = now.addingTimeInterval(-Self.digestSpan)
        // A second of slack: a stored time can read back a hair later than it was written.
        guard let last = try await store.lastDigestAt(), last > weekAgo,
              last <= now.addingTimeInterval(1)
        else { return weekAgo }
        return min(last, now)
    }

    static func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }
}

/// The digest's text: items grouped under their primary home in code order, unfiled ones
/// last, each linking back to the item.
enum DigestNote {
    static func document(
        _ items: [DigestItem],
        total: Int,
        from start: Date,
        to end: Date
    ) -> MarkdownDocument {
        let range = Self.range(start, end)
        var groups: [String: [DigestItem]] = [:]
        for item in items {
            groups[item.code.map { "\($0) \(item.category ?? "")" } ?? "", default: []]
                .append(item)
        }
        // Unfiled sorts last.
        let headings = groups.keys.sorted { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }
        var lines = [
            "Saved \(range): \(AutomationEngine.itemCount(total)), grouped by category."
                + (items.count < total ? " The newest \(items.count.formatted()) are listed." : ""),
        ]
        for heading in headings {
            lines.append("## \(heading.isEmpty ? "Unfiled" : heading)")
            lines.append(list(groups[heading] ?? []))
        }
        return MarkdownDocument(
            name: "Weekly digest: \(range)",
            markdown: lines.joined(separator: "\n\n")
        )
    }

    /// Sources saved automatically this period, each with where it was found.
    static func foundForYou(_ items: [AcquisitionDigestItem], expired: Int) -> String {
        guard !items.isEmpty || expired > 0 else { return "" }
        func link(_ title: String, _ id: UUID) -> String {
            "[\(AgentCoordinator.markdownLabel(title))](gleanary://note/\(id.uuidString))"
        }
        var lines = ["\n\n## Found for you"]
        if !items.isEmpty {
            lines.append(items.map {
                "- \(link($0.title, $0.noteID)): \($0.reason.lowercased()) in \(link($0.originTitle, $0.originID))"
            }.joined(separator: "\n"))
        }
        if expired > 0 {
            lines.append(
                "Archived \(AutomationEngine.itemCount(expired)) saved automatically but never opened."
            )
        }
        return lines.joined(separator: "\n\n")
    }

    static func range(_ start: Date, _ end: Date) -> String {
        (start ..< end).formatted(date: .abbreviated, time: .omitted)
    }

    private static func list(_ items: [DigestItem]) -> String {
        items.map { item in
            let link = "[\(AgentCoordinator.markdownLabel(item.title))](gleanary://note/\(item.id.uuidString))"
            return "- \(link)" + (item.host.map { " (\($0))" } ?? "")
        }.joined(separator: "\n")
    }

    // MARK: Written up by the Writer

    /// The same facts from every item, so a week's records are reused by the next digest.
    static let brief = WriterBrief(
        query: "", categoryCodes: [], fields: ["what it covers", "key points"],
        generalKnowledge: false
    )

    static func request(_ range: String) -> String {
        "Write my weekly digest of what I saved \(range), as my own notes. Group the items by topic under headings, say what each covers and its key points, and point out threads that connect several. Mention every item."
    }

    /// The Writer's text under a one-line intro, with items it didn't take listed before the
    /// sources.
    static func written(
        _ rendered: WriterDocument.Rendered,
        rest: [DigestItem],
        listed: Int,
        total: Int,
        range: String
    ) -> MarkdownDocument {
        var body = rendered.markdown
        if !rest.isEmpty {
            let also = "## Also saved\n\n" + list(rest)
            let parts = body.components(separatedBy: "\n\n## Sources\n\n")
            body = parts.count == 2 ? parts[0] + "\n\n" + also + "\n\n## Sources\n\n" + parts[1]
                : body + "\n\n" + also
        }
        // More saved than listed: say so plainly, as the listed digest does.
        if listed < total {
            body += "\n\nThe newest \(listed.formatted()) of \(AutomationEngine.itemCount(total)) are here."
        }
        return MarkdownDocument(name: "Weekly digest: \(range)", markdown: body)
    }
}
