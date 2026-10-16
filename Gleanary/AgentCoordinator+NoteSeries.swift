import Foundation

/// Fixed, bounded specialist stages with durable, immutable handoffs. Only publication writes
/// library notes. Drafts and retrieved text stay task-private and survive an explicit Retry.
extension AgentCoordinator {
    func startNoteSeries(
        taskID: UUID,
        request: String,
        selected: [UUID],
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard inference is any NoteSeriesInferring else { throw NoteSeries.Failure.needsChatGPT }
        let run = try await store.beginNoteSeries(
            taskID: taskID,
            request: request,
            provider: inference.capabilities.identifier,
            style: writingStyles().style(for: request),
            selected: selected
        )
        try await continueNoteSeries(run, changed: changed)
    }

    func continueNoteSeries(
        _ run: NoteSeries.Run,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        guard !run.published else { return }
        guard run.provider == inference.capabilities.identifier
        else { throw NoteSeries.Failure.providerChanged }
        guard let model = inference as? any NoteSeriesInferring,
              let researcher = inference as? any WebResearching
        else { throw NoteSeries.Failure.needsChatGPT }
        let brief = try await seriesBrief(run, model: model)
        try await seriesProgress(
            run,
            "Searching the PKMS for existing coverage",
            owner: .curator,
            changed: changed
        )
        let library = try await seriesLibrary(run, brief: brief)
        try await store.validateSeriesLibrary(library.value)
        let outline = try await seriesOutline(run, model: model, brief: brief, library: library)
        let newCount = outline.value.entries.filter { $0.existingNoteID == nil }.count
        try await seriesProgress(
            run,
            "Reusing \(outline.value.entries.count - newCount) existing notes, researching \(newCount) gaps",
            owner: .researcher,
            changed: changed
        )
        let dossier = try await seriesDossier(
            run,
            brief: brief,
            outline: outline,
            library: library,
            researcher: researcher,
            extractor: model,
            changed: changed
        )
        var drafts: [UUID: NoteSeries.Draft] = [:]
        var parents = [outline.id, dossier.id]
        for entry in outline.value.entries where entry.existingNoteID == nil {
            try await seriesProgress(
                run,
                "Writing \(drafts.count + 1) of \(newCount) notes: \(entry.title)",
                owner: .writer,
                changed: changed
            )
            let draft = try await seriesDraft(run, entry: entry, dossier: dossier, model: model)
            drafts[entry.id] = draft.value
            parents.append(draft.id)
        }
        try await seriesProgress(
            run,
            "Checking distinctness and connecting related notes",
            owner: .curator,
            changed: changed
        )
        if try await store
            .seriesArtifact(run, kind: .curation, as: NoteSeries.Curation.self) == nil
        {
            let curation: NoteSeries.Curation
            if drafts.isEmpty {
                curation = NoteSeries.Curation(distinct: true, links: [])
            } else {
                try await store.reserveSeriesCall(run)
                curation = try await model.curateSeries(
                    outline.value,
                    drafts: drafts,
                    library: library.value
                )
            }
            let candidate = try await store.checkpointSeries(
                run,
                kind: .curationCandidate,
                slot: UUID().uuidString,
                value: curation,
                parents: parents
            )
            try curation.validate(outline: outline.value, drafts: drafts, library: library.value)
            try await store.checkpointSeries(
                run,
                kind: .curation,
                value: curation,
                parents: [candidate.id]
            )
        }
        try await seriesProgress(
            run,
            "Publishing the linked note series",
            owner: .writer,
            changed: changed
        )
        _ = try await store.publishNoteSeries(run)
        await changed()
    }

    private func seriesBrief(
        _ run: NoteSeries.Run,
        model: any NoteSeriesInferring
    ) async throws -> NoteSeries.Artifact<NoteSeries.Brief> {
        if let cached = try await store.seriesArtifact(
            run,
            kind: .brief,
            as: NoteSeries.Brief.self
        ) {
            return cached
        }
        try await store.reserveSeriesCall(run)
        let brief = try await model.seriesBrief(request: run.request)
        guard NoteSeries.plain(brief.query, limit: 200), brief.libraryQueries.count <= 6,
              brief.libraryQueries.allSatisfy({ NoteSeries.plain($0, limit: 200) })
        else { throw NoteSeries.Failure.invalidOutline }
        return try await store.checkpointSeries(run, kind: .brief, value: brief, parents: [])
    }

    private func seriesLibrary(
        _ run: NoteSeries.Run,
        brief: NoteSeries.Artifact<NoteSeries.Brief>
    ) async throws -> NoteSeries.Artifact<[NoteSeries.Source]> {
        if let cached = try await store.seriesArtifact(
            run,
            kind: .library,
            as: [NoteSeries.Source].self
        ) {
            return cached
        }
        let queries = brief.value.libraryQueries.isEmpty ? [brief.value.query] : brief.value
            .libraryQueries
        var results: [[SearchMatch]] = []
        for query in queries {
            try await results.append(search.search(query, limit: 80).matches)
        }
        // Interleave query ranks so one broad phrase cannot crowd every focused concept out.
        let matches = (0 ..< 80)
            .flatMap { rank in results.compactMap { $0.indices.contains(rank) ? $0[rank] : nil } }
        var seen = Set<UUID>()
        let ids = (run.selected + matches.map(\.passage.documentID))
            .filter { seen.insert($0).inserted }.prefix(NoteSeries.maximumLibrarySources)
        var sources: [NoteSeries.Source] = []
        for id in ids {
            guard let note = try await store.document(id: id) else { continue }
            let text = String(note.markdown.prefix(NoteSeries.sourceCharacters))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sources.append(NoteSeries.Source(
                id: note.id,
                title: note.name,
                text: text,
                url: nil,
                noteID: note.id,
                revision: note.revision,
                contentHash: ContentHash.of(text),
                retrievedAt: Date(),
                limitations: note.markdown.count > text
                    .count ?
                    ["Only the first \(NoteSeries.sourceCharacters) characters were read."] :
                    []
            ))
        }
        return try await store.checkpointSeries(
            run,
            kind: .library,
            value: sources,
            parents: [brief.id]
        )
    }

    private func seriesOutline(
        _ run: NoteSeries.Run,
        model: any NoteSeriesInferring,
        brief: NoteSeries.Artifact<NoteSeries.Brief>,
        library: NoteSeries.Artifact<[NoteSeries.Source]>
    ) async throws -> NoteSeries.Artifact<NoteSeries.Outline> {
        if let cached = try await store.seriesArtifact(
            run,
            kind: .outline,
            as: NoteSeries.Outline.self
        ) {
            return cached
        }
        try await store.reserveSeriesCall(run)
        let outline = try await model.seriesOutline(
            request: run.request,
            brief: brief.value,
            library: library.value
        )
        try outline.validate(library: library.value, brief: brief.value)
        try await store.reserveSeriesCall(run)
        guard try await model.reviewSeriesOutline(
            outline,
            request: run.request,
            library: library.value
        )
        else { throw NoteSeries.Failure.invalidOutline }
        return try await store.checkpointSeries(
            run,
            kind: .outline,
            value: outline,
            parents: [brief.id, library.id]
        )
    }

    private func seriesDossier(
        _ run: NoteSeries.Run,
        brief: NoteSeries.Artifact<NoteSeries.Brief>,
        outline: NoteSeries.Artifact<NoteSeries.Outline>,
        library: NoteSeries.Artifact<[NoteSeries.Source]>,
        researcher: any WebResearching,
        extractor: any NoteSeriesInferring,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> NoteSeries.Artifact<NoteSeries.Dossier> {
        if let cached = try await store.seriesArtifact(
            run,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ) {
            return cached
        }
        let newEntries = outline.value.entries.filter { $0.existingNoteID == nil }
        var sources = library.value
        var unavailable: [URL] = []
        var parents = [outline.id, library.id]
        if brief.value.mode != .libraryOnly, !newEntries.isEmpty {
            let sourceLimit = NoteSeries.webSourceLimit(newNotes: newEntries.count)
            let web = try await seriesWebSearch(
                run,
                brief: brief,
                researcher: researcher,
                parent: outline.id,
                sourceLimit: sourceLimit,
                changed: changed
            )
            let pages = try await seriesWebSources(
                run,
                web: web,
                limit: sourceLimit,
                changed: changed
            )
            guard !pages.sources.isEmpty else { throw NoteSeries.Failure.noWebSources }
            sources += pages.sources.map(\.value)
            parents += pages.sources.map(\.id)
            unavailable = pages.unavailable
        }
        var records: [NoteSeries.Fact] = []
        if !newEntries.isEmpty {
            let fields = Array(Set(newEntries.flatMap(\.fields))).sorted()
            let sourceParents = parents
            for (index, source) in sources.enumerated() {
                try await seriesProgress(
                    run,
                    "Extracting evidence \(index + 1) of \(sources.count)",
                    owner: .researcher,
                    changed: changed
                )
                let facts = try await seriesFacts(
                    run,
                    source: source,
                    fields: fields,
                    extractor: extractor,
                    parents: sourceParents
                )
                parents.append(facts.id)
                records += facts.value.prefix(NoteSeries.factsPerSource).enumerated()
                    .map { offset, fact in
                        NoteSeries.Fact(
                            id: "E\(index + 1)R\(offset + 1)",
                            sourceID: source.id,
                            field: fact.field,
                            value: fact.value,
                            quote: fact.quote
                        )
                    }
            }
        }
        let dossier = NoteSeries.Dossier(
            sources: sources,
            facts: records,
            unavailableURLs: unavailable
        )
        try dossier.validate()
        return try await store.checkpointSeries(
            run,
            kind: .dossier,
            value: dossier,
            parents: parents
        )
    }

    private func seriesWebSearch(
        _ run: NoteSeries.Run,
        brief: NoteSeries.Artifact<NoteSeries.Brief>,
        researcher: any WebResearching,
        parent: UUID,
        sourceLimit: Int,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> NoteSeries.Artifact<WebResearchResult> {
        if let cached = try await store.seriesArtifact(
            run,
            kind: .webSearch,
            as: WebResearchResult.self
        ) {
            return cached
        }
        try await store.reserveSeriesCall(run)
        let store = store
        // Only the public query derived from the user's request reaches hosted search. PKMS
        // excerpts and outline text never enter an external search request.
        let web = try await researcher.researchWeb(
            question: "Research \(brief.value.query). Map the topic's distinct principal concepts and find diverse authoritative sources covering them, not just general overviews. Cite up to \(sourceLimit) distinct substantive source pages, as coverage requires; prefer complementary primary sources. A smaller topic needs fewer sources.",
            sources: []
        ) { text in
            try? await store.updateConversationTask(run.taskID, progress: text, owner: .researcher)
            await changed()
        }
        _ = try web.markdown()
        return try await store.checkpointSeries(
            run,
            kind: .webSearch,
            value: web,
            parents: [parent]
        )
    }

    private func seriesWebSources(
        _ run: NoteSeries.Run,
        web: NoteSeries.Artifact<WebResearchResult>,
        limit: Int,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> (sources: [NoteSeries.Artifact<NoteSeries.Source>], unavailable: [URL]) {
        var seen = Set<URL>()
        let urls = web.value.passages.flatMap(\.citations).map(\.url)
            .filter { seen.insert($0).inserted }.prefix(limit)
        var sources: [NoteSeries.Artifact<NoteSeries.Source>] = []
        var unavailable: [URL] = []
        var hashes = Set<String>()
        for url in urls {
            try await seriesProgress(
                run,
                "Reading web source \(sources.count + unavailable.count + 1) of \(urls.count)",
                owner: .researcher,
                changed: changed
            )
            let slot = ContentHash.of(url.absoluteString)
            do {
                let source: NoteSeries.Artifact<NoteSeries.Source>
                if let cached = try await store.seriesArtifact(
                    run,
                    kind: .webSource,
                    slot: slot,
                    as: NoteSeries.Source.self
                ) {
                    source = cached
                } else {
                    let downloaded = try await researchFetcher.fetch(url)
                    let value = try await Self.readSeriesSource(downloaded)
                    source = try await store.checkpointSeries(
                        run,
                        kind: .webSource,
                        slot: slot,
                        value: value,
                        parents: [web.id]
                    )
                }
                if hashes.insert(source.value.contentHash).inserted {
                    sources.append(source)
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as NoteSeries.Failure { throw error }
            catch { unavailable.append(url) }
        }
        return (sources, unavailable)
    }

    private static func readSeriesSource(_ downloaded: DownloadedContent) async throws -> NoteSeries
        .Source
    {
        guard WebResearchResult.safeURL(downloaded.url),
              downloaded.data.count <= 8_000_000 else { throw CaptureError.tooLarge }
        let document: CapturedDocument
        if downloaded.mime == "application/pdf" {
            document = try await PDFExtractor().extract(
                downloaded.data,
                name: "Research source",
                url: downloaded.url
            )
        } else if downloaded.mime == "text/plain" {
            let text = String(decoding: downloaded.data, as: UTF8.self)
            document = CapturedDocument(
                title: downloaded.url.host ?? "Research source",
                sourceURL: downloaded.url,
                coverage: .document,
                blocks: [ContentBlock(kind: .paragraph, markdown: text, text: text)]
            )
        } else {
            guard downloaded.mime == nil || downloaded.mime?.contains("html") == true
            else { throw CaptureError.unsupported }
            let html = String(data: downloaded.data, encoding: .utf8) ?? String(
                data: downloaded.data,
                encoding: .isoLatin1
            ) ?? ""
            document = try await HTMLExtractor.extract(
                HTMLExtractor.analyze(html, url: downloaded.url),
                url: downloaded.url
            )
        }
        let full = document.blocks.map(\.text).joined(separator: "\n\n")
        let text = String(full.prefix(NoteSeries.sourceCharacters))
        guard text.count >= 80 else { throw CaptureError.noContent }
        return NoteSeries.Source(
            id: UUID(),
            title: String(document.title.prefix(1000)),
            text: text,
            url: downloaded.url,
            noteID: nil,
            revision: nil,
            contentHash: ContentHash.of(text),
            retrievedAt: Date(),
            limitations: ["Captured coverage: \(document.coverage.rawValue)."] + document
                .warnings +
                (full.count > text
                    .count ?
                    ["Only the first \(NoteSeries.sourceCharacters) characters were read."] :
                    [])
        )
    }

    private func seriesFacts(
        _ run: NoteSeries.Run,
        source: NoteSeries.Source,
        fields: [String],
        extractor: any NoteSeriesInferring,
        parents: [UUID]
    ) async throws -> NoteSeries.Artifact<[FactRecord]> {
        if let cached = try await store.seriesArtifact(
            run,
            kind: .facts,
            slot: source.id.uuidString,
            as: [FactRecord].self
        ) {
            return cached
        }
        try await store.reserveSeriesCall(run)
        let facts = try await extractor.extractSeriesFacts(ExtractionChunk(
            title: source.title,
            text: source.text,
            fields: fields,
            request: run.request,
            part: 1,
            parts: 1
        ))
        let checked = FactRecord.verified(
            facts,
            in: source.text,
            fields: fields,
            sourceID: source.id
        )
        return try await store.checkpointSeries(
            run,
            kind: .facts,
            slot: source.id.uuidString,
            value: Array(checked.prefix(NoteSeries.factsPerSource)),
            parents: parents
        )
    }

    private func seriesDraft(
        _ run: NoteSeries.Run,
        entry: NoteSeries.Entry,
        dossier: NoteSeries.Artifact<NoteSeries.Dossier>,
        model: any NoteSeriesInferring
    ) async throws -> NoteSeries.Artifact<NoteSeries.Draft> {
        if let cached = try await store.seriesArtifact(
            run,
            kind: .draft,
            slot: entry.id.uuidString,
            as: NoteSeries.Draft.self
        ) {
            return cached
        }
        guard !dossier.value.facts(for: entry).isEmpty else { throw NoteSeries.Failure.noFacts }
        var feedback: NoteSeries.DraftFeedback?
        for _ in 0 ..< 2 {
            try await store.reserveSeriesCall(run)
            let draft = try await model.draftSeriesNote(
                entry,
                dossier: dossier.value,
                style: run.style,
                feedback: feedback
            )
            var structurallyValid = true
            do { try draft.validate(entry: entry, dossier: dossier.value) }
            catch { structurallyValid = false }
            var review: [Bool] = []
            if structurallyValid {
                try await store.reserveSeriesCall(run)
                review = try await model.verifySeriesDraft(
                    draft,
                    entry: entry,
                    dossier: dossier.value
                )
            }
            let result = NoteSeries.DraftFeedback(
                draft: draft,
                structurallyValid: structurallyValid,
                supported: review
            )
            feedback = result
            let attempt = try await store.checkpointSeries(
                run,
                kind: .draftFeedback,
                slot: entry.id.uuidString + "." + UUID().uuidString,
                value: result,
                parents: [dossier.id]
            )
            guard structurallyValid, review.count == draft.paragraphs.count,
                  review.allSatisfy(\.self) else { continue }
            return try await store.checkpointSeries(
                run,
                kind: .draft,
                slot: entry.id.uuidString,
                value: draft,
                parents: [attempt.id]
            )
        }
        throw NoteSeries.Failure.invalidDraft
    }

    private func seriesProgress(
        _ run: NoteSeries.Run,
        _ text: String,
        owner: AgentRole,
        changed: @escaping @Sendable () async -> Void
    ) async throws {
        try Task.checkCancellation()
        try await store.updateConversationTask(
            run.taskID,
            progress: text,
            owner: owner,
            event: "delegated"
        )
        await changed()
    }
}
