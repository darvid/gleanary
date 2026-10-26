import Foundation

/// The Writer's compose workflow (SPEC §7.6) as stages of one conversation task: Gather
/// (Curator), the person confirms the scope, Extract (Researcher), Write (Writer) and Save.
/// Cancelling at any stage saves nothing: the document is written in one transaction at the
/// end, and only while the task is still running.
extension AgentCoordinator {
    /// A semantic match weaker than this, with no matching words, is marked possibly off-topic.
    static let meaningThreshold: Float = 0.5

    // MARK: Gather

    /// Gathers candidates and leaves the task waiting for the person to confirm them. Nothing
    /// is extracted until they do.
    func compose(
        taskID: UUID,
        request: String,
        selected: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let writer = inference as? any WriterInferring else { throw WriterError.needsChatGPT }
        try await store.updateConversationTask(
            taskID, progress: "Gathering sources", owner: .curator, event: "delegated"
        )
        await changed()
        let categories = try await store.categories()
        let brief = try await writer.brief(request: request, categories: categories)
            .validated(categories: categories)
        try Task.checkCancellation()
        let gathered = try await gather(brief, selected: selected, excluding: [])
        guard !gathered.candidates.isEmpty else {
            try await store.postConversation(
                author: .curator,
                text: "No saved items match this request, so there's nothing to compose from. Try naming a category or a distinctive term, or select items and ask again.",
                taskID: taskID
            )
            return
        }
        let local = inference.capabilities.local
        let limit = local ? WriterLimits.localScope : WriterLimits.maximumScope
        let onTopic = gathered.candidates.filter { !$0.offTopic }.map(\.id)
        try await store.beginWriterRequest(WriterRequest(
            taskID: taskID, noteID: nil, kind: .compose, request: request,
            style: writingStyles().style(for: request), brief: brief,
            generalKnowledge: brief.generalKnowledge, scopeLimit: limit,
            candidates: gathered.candidates, selection: Array(onTopic.prefix(limit)),
            excluded: [], sources: [], status: .awaiting
        ))
        try await store.postConversation(
            author: .curator,
            text: Self.scopeMessage(gathered.candidates, more: gathered.more),
            taskID: taskID
        )
        if local, onTopic.count > limit {
            try await store.postConversation(
                author: .writer,
                text: "Composing across \(onTopic.count) sources needs ChatGPT's larger context. Connect it in Settings and ask again, or compose on this Mac from \(limit) items: the first \(limit) are checked below, and you can change which.",
                taskID: taskID
            )
        }
        try await store.updateConversationTask(
            taskID, state: "awaiting_user", progress: "Waiting for you to confirm the scope"
        )
    }

    /// Candidates from search and the requested categories, capped, with likely strays marked.
    /// Items found only by category, or only by a weak meaning match, are possibly off-topic.
    func gather(
        _ brief: WriterBrief,
        selected: [UUID],
        excluding: Set<UUID>
    ) async throws -> (candidates: [ScopeCandidate], more: Int) {
        var keyword: [UUID] = []
        var meaning: [UUID: Float] = [:]
        var meaningOrder: [UUID] = []
        if !brief.query.isEmpty {
            for match in try await search.search(brief.query, limit: 100).matches {
                let id = match.passage.documentID
                if match.keywordRank != nil {
                    if !keyword.contains(id) {
                        keyword.append(id)
                    }
                } else {
                    if meaning[id] == nil {
                        meaningOrder.append(id)
                    }
                    meaning[id] = max(meaning[id] ?? 0, match.semanticScore ?? 0)
                }
            }
        }
        let members = try await store.categoryMembers(
            codes: brief.categoryCodes, limit: WriterLimits.maximumScope * 3
        )
        let strong = { (id: UUID) in
            keyword.contains(id) || (meaning[id] ?? 0) >= Self.meaningThreshold
        }
        let filed = members.map { id in
            let stray = !brief.query.isEmpty && !strong(id)
            return (
                id,
                stray ? "Filed in a matching category, but doesn't mention the subject"
                    : "Filed in a matching category",
                stray
            )
        }
        let entries: [(id: UUID, reason: String, offTopic: Bool)] =
            selected.map { ($0, "You selected it", false) }
                + keyword.map { ($0, "Text match", false) } + filed
                + meaningOrder.map { ($0, "Meaning match", !strong($0)) }
        var seen = excluding
        let order = entries.filter { seen.insert($0.id).inserted }
        let details = try await store.scopeDetails(order.map(\.id))
        // On-topic items first, so the cap drops likely strays before anything relevant.
        let found = order.filter { details[$0.id] != nil }
        let sorted = found.filter { !$0.offTopic } + found.filter(\.offTopic)
        let candidates = sorted.prefix(WriterLimits.maximumScope).compactMap { item in
            details[item.id].map {
                ScopeCandidate(
                    id: item.id, title: $0.title, filing: $0.filing, reason: item.reason,
                    offTopic: item.offTopic
                )
            }
        }
        return (candidates, max(0, sorted.count - candidates.count))
    }

    // MARK: Extract, write and save

    /// Picks up a confirmed scope: extracts, writes and saves the document.
    func continueCompose(
        taskID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard !executing else { throw ConversationError.busy }
        executing = true
        defer { executing = false }
        guard let request = try await store.writerRequest(taskID: taskID),
              request.kind == .compose, request.status == .writing
        else { throw WriterError.scopeChanged }
        let composition = try await produce(request, taskID: taskID, changed: changed)
        try Task.checkCancellation()
        let note = try await store.saveComposedDocument(
            composition.rendered, taskID: taskID, provider: inference.capabilities.identifier,
            sources: composition.versions
        )
        try await store.postConversation(
            author: .writer,
            text: Self.composedMessage(composition, style: request.style),
            references: [note.id],
            taskID: taskID
        )
        try await store.updateConversationTask(
            taskID, state: "succeeded", progress: "Completed", event: "completed"
        )
        await changed()
    }

    /// Extract (Researcher) and Write (Writer), reporting each stage on the task.
    func produce(
        _ request: WriterRequest,
        taskID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> WriterComposition {
        let store = store
        return try await WriterPipeline(store: store, inference: inference).produce(request) {
            progress, owner in
            try? await store.updateConversationTask(
                taskID, progress: progress, owner: owner,
                event: owner == nil ? "progress" : "delegated"
            )
            await changed()
        }
    }

    // MARK: Refresh

    /// Re-runs a composed document's request: gathers again, re-extracts only new or changed
    /// sources, rewrites, and proposes the new text for review instead of saving it.
    func refresh(
        taskID: UUID,
        noteID: UUID,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard let previous = try await store.latestWriterRequest(noteID: noteID),
              let note = try await store.document(id: noteID)
        else { throw WriterError.nothingToRefresh }
        try await store.updateConversationTask(
            taskID, progress: "Gathering sources", owner: .curator, event: "delegated"
        )
        await changed()
        let gathered = try await gather(previous.brief, selected: [], excluding: [noteID])
        let known = Set(previous.candidates.map(\.id) + previous.excluded)
        let live = try await Set(store.scopeDetails(previous.selection).keys)
        let kept = previous.selection.filter(live.contains)
        let added = gathered.candidates.filter { !known.contains($0.id) && !$0.offTopic }
        let limit = inference.capabilities.local ? WriterLimits.localScope : WriterLimits
            .maximumScope
        guard kept.count <= limit else { throw WriterError.needsChatGPT }
        let selection = Array((kept + added.map(\.id)).prefix(limit))
        let request = WriterRequest(
            taskID: taskID, noteID: noteID, kind: .refresh, request: previous.request,
            style: previous.style, brief: previous.brief,
            generalKnowledge: previous.generalKnowledge, scopeLimit: limit,
            candidates: previous.candidates + added, selection: selection,
            excluded: previous.excluded, sources: [], status: .writing
        )
        let delta = RefreshDelta(previous: previous.sources, selection: selection, store: store)
        guard try await delta.anything else {
            try await store.postConversation(
                author: .writer,
                text: "None of the sources behind “\(note.name)” have changed, and no new ones match, so there's nothing to refresh.",
                references: [noteID],
                taskID: taskID
            )
            return
        }
        try await store.beginWriterRequest(request)
        let composition = try await produce(request, taskID: taskID, changed: changed)
        let summary = RefreshDelta.summary(previous: previous.sources, now: composition.versions)
        guard composition.rendered.markdown != note.markdown else {
            try await store.setWriterRequestStatus(taskID, .unchanged)
            try await store.postConversation(
                author: .writer,
                text: "Refreshed “\(note.name)” (\(summary)). The text came out the same, so there's nothing to review.",
                references: [noteID],
                taskID: taskID
            )
            return
        }
        var drafts = [AgentChangeDraft(
            kind: .revision, noteID: noteID, before: note.markdown,
            after: composition.rendered.markdown, reason: "Refreshed: \(summary).",
            baseRevision: note.revision
        )]
        for id in composition.rendered.used where try await !store.linked(noteID, id) {
            drafts.append(AgentChangeDraft(
                kind: .link, noteID: noteID, targetID: id, before: "", after: "",
                reason: "A source the refreshed document now cites."
            ))
        }
        try await store.proposeWriterRefresh(drafts, taskID: taskID, sources: composition.versions)
        try await store.postConversation(
            author: .writer,
            text: "Refreshed “\(note.name)” (\(summary)). Review what changed below; nothing is saved until you apply it.",
            references: [noteID],
            taskID: taskID
        )
    }

    // MARK: Messages

    static func scopeMessage(_ candidates: [ScopeCandidate], more: Int) -> String {
        let marked = candidates.count(where: \.offTopic)
        var text = "Found \(Self.items(candidates.count)) for this document"
        if marked > 0 {
            text += marked == 1 ? ". 1 may be off-topic, so it's unchecked" :
                ". \(marked) may be off-topic, so they're unchecked"
        }
        if more > 0 {
            text += ". \(more.formatted()) more matched past the limit of \(WriterLimits.maximumScope)"
        }
        return text + ". Check the list below; nothing is read until you confirm it."
    }

    static func composedMessage(_ composition: WriterComposition, style: WritingStyle) -> String {
        let used = composition.rendered.used.count
        return "Wrote “\(composition.rendered.title)” in \(style.name) style from \(Self.items(used, noun: "source")). It's saved as a note you can edit, linked to every source it cites; facts no source covers are listed at the end."
    }

    static func items(_ count: Int, noun: String = "item") -> String {
        count == 1 ? "1 \(noun)" : "\(count.formatted()) \(noun)s"
    }
}

/// What a refresh would read differently from the document's last version.
struct RefreshDelta {
    let previous: [SourceVersion]
    let selection: [UUID]
    let store: DocumentStore

    /// Whether any source is new, gone or changed since the document was written.
    var anything: Bool {
        get async throws {
            let before = Dictionary(
                previous.map { ($0.id, $0.hash) },
                uniquingKeysWith: { a, _ in a }
            )
            guard Set(before.keys) == Set(selection) else { return true }
            for id in selection {
                guard let source = try await store.writerSource(id) else { return true }
                if source.version.hash != before[id] {
                    return true
                }
            }
            return false
        }
    }

    static func summary(previous: [SourceVersion], now: [SourceVersion]) -> String {
        let before = Dictionary(previous.map { ($0.id, $0.hash) }, uniquingKeysWith: { a, _ in a })
        let added = now.count { before[$0.id] == nil }
        let changed = now.count { version in
            before[version.id].map { $0 != version.hash } ?? false
        }
        let removed = previous.count { old in !now.contains { $0.id == old.id } }
        let parts = [
            added > 0 ? "\(added) new source\(added == 1 ? "" : "s")" : nil,
            changed > 0 ? "\(changed) changed" : nil,
            removed > 0 ? "\(removed) no longer included" : nil,
        ].compactMap(\.self)
        return parts.isEmpty ? "same sources" : parts.formatted(.list(type: .and))
    }
}
