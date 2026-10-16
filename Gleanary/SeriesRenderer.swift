import Foundation

/// No model can invent a destination: links resolve only to this run's preallocated IDs,
/// read-only library snapshots, or the public pages the Researcher actually read.
enum SeriesRenderer {
    struct Edge { let from: UUID; let to: UUID; let reason: String }
    struct Output {
        let index: MarkdownDocument
        let notes: [MarkdownDocument]
        let edges: [Edge]
    }

    static func render(
        run: NoteSeries.Run,
        outline: NoteSeries.Outline,
        dossier: NoteSeries.Dossier,
        drafts: [UUID: NoteSeries.Draft],
        curation: NoteSeries.Curation
    ) throws -> Output {
        var titles = Dictionary(uniqueKeysWithValues: dossier.sources.compactMap { source in
            source.noteID.map { ($0, source.title) }
        })
        for entry in outline.entries
            where entry.existingNoteID == nil
        {
            titles[entry.id] = entry.title
        }
        titles[run.indexID] = outline.title
        let expected = Set(outline.entries.filter { $0.existingNoteID == nil }.map(\.id))
        guard Set(drafts.keys) == expected else { throw NoteSeries.Failure.invalidDraft }
        try curation.validate(outline: outline, drafts: drafts, library: dossier.sources)
        var notes: [MarkdownDocument] = []
        var edges: [Edge] = []
        var paragraphs = Set<String>()
        for entry in outline.entries {
            let target = entry.existingNoteID ?? entry.id
            edges.append(Edge(
                from: run.indexID,
                to: target,
                reason: "A member of this note series."
            ))
            guard let draft = drafts[entry.id] else { continue }
            try draft.validate(entry: entry, dossier: dossier)
            for paragraph in draft.paragraphs {
                guard paragraphs.insert(paragraph.text.lowercased()).inserted
                else { throw NoteSeries.Failure.invalidDraft }
            }
            let rendered = try renderNote(
                entry,
                draft: draft,
                run: run,
                dossier: dossier,
                links: curation.links.filter { $0.from == entry.id },
                titles: titles
            )
            notes.append(MarkdownDocument(id: entry.id, name: entry.title, markdown: rendered.text))
            edges += rendered.sources.compactMap { source in
                source.noteID.map { Edge(
                    from: entry.id,
                    to: $0,
                    reason: "Evidence cited by the new research note."
                ) }
            }
        }
        edges += curation.links.map { Edge(from: $0.from, to: $0.to, reason: $0.reason) }
        let reading: String = outline.entries.enumerated().map { offset, entry -> String in
            let id = entry.existingNoteID ?? entry.id
            let label = titles[id] ?? entry.title
            return "\(offset + 1). \(noteLink(id, title: label))\(entry.existingNoteID == nil ? "" : " — existing note")\n\n   \(entry.purpose)"
        }.joined(separator: "\n\n")
        var indexText = "## Reading path\n\n" + reading
        if !outline.sizingReason.isEmpty {
            indexText += "\n\n## Coverage\n\n" + outline.sizingReason
        }
        if !outline.deferredCoverage.isEmpty {
            indexText +=
                "\n\n## Remaining coverage\n\nThese topics remain outside this published reading path. They may need further research or a later run:\n\n" +
                outline.deferredCoverage.map { "- " + $0 }.joined(separator: "\n")
        }
        if !dossier.unavailableURLs.isEmpty {
            indexText +=
                "\n\n## Research limits\n\nThese pages could not be read and were not used as evidence:\n\n" +
                dossier.unavailableURLs
                .map {
                    "- [\(AgentCoordinator.markdownLabel($0.host ?? "Source"))](<\($0.absoluteString)>)"
                }.joined(separator: "\n")
        }
        indexText += "\n\nNew notes cite checked quotations from saved notes or retrieved web text. Existing notes were linked, not rewritten. Research checkpoints retain the source text read, retrieval dates, and extraction limits."
        return Output(
            index: MarkdownDocument(id: run.indexID, name: outline.title, markdown: indexText),
            notes: notes,
            edges: edges
        )
    }

    private static func renderNote(
        _: NoteSeries.Entry,
        draft: NoteSeries.Draft,
        run: NoteSeries.Run,
        dossier: NoteSeries.Dossier,
        links: [NoteSeries.Link],
        titles: [UUID: String]
    ) throws -> (text: String, sources: [NoteSeries.Source]) {
        var sources: [NoteSeries.Source] = []
        var sections: [String] = []
        for (index, paragraph) in draft.paragraphs.enumerated() {
            var text = paragraph.text
            if let link = links.first(where: { !$0.anchor.isEmpty && $0.paragraph == index }),
               let range = text.range(of: link.anchor)
            {
                text.replaceSubrange(range, with: noteLink(link.to, title: link.anchor))
            }
            var cited = Set<UUID>()
            let markers = try paragraph.records.compactMap { recordID -> String? in
                guard let fact = dossier.facts.first(where: { $0.id == recordID }),
                      let source = dossier.sources.first(where: { $0.id == fact.sourceID })
                else { throw NoteSeries.Failure.invalidEvidence }
                guard cited.insert(source.id).inserted else { return nil }
                if !sources.contains(where: { $0.id == source.id }) {
                    sources.append(source)
                }
                let number = (sources.firstIndex(where: { $0.id == source.id }) ?? 0) + 1
                let label = run.style.citations == .inline ? source.title : String(number)
                return try "[\(AgentCoordinator.markdownLabel(label))](<\(destination(source))>)"
            }
            sections.append(text + " (" + markers.joined(separator: "; ") + ")")
        }
        let bibliography = try sources.enumerated().map { index, source in
            var item = try "\(index + 1). [\(AgentCoordinator.markdownLabel(source.title))](<\(destination(source))>)"
            if source.noteID == nil {
                item += " — web text read \(source.retrievedAt.formatted(.iso8601.year().month().day()))"
            }
            if !source.limitations.isEmpty {
                item += ". " + source.limitations.joined(separator: " ")
            }
            return item
        }.joined(separator: "\n")
        let related = links.filter(\.anchor.isEmpty).map { link in
            "- \(noteLink(link.to, title: titles[link.to] ?? "Related note")): \(link.reason)"
        }
        var text = sections.joined(separator: "\n\n")
        text += "\n\n## Continue reading\n\n" + noteLink(
            run.indexID,
            title: "Series index and reading path"
        )
        if !related.isEmpty {
            text += "\n\n" + related.joined(separator: "\n")
        }
        text += "\n\n## Sources\n\n" + bibliography
        return (text, sources)
    }

    /// Keep the original web bibliography available when the single-document Writer later
    /// consumes a series note. Quotes here come from retained pages, not the search summary.
    static func externalEvidence(
        records: Set<String>,
        dossier: NoteSeries.Dossier,
        searchCount: Int
    ) throws -> WebResearchResult? {
        let facts = dossier.facts.filter { records.contains($0.id) }
        let passages = dossier.sources.compactMap { source -> WebResearchResult.Passage? in
            guard source.noteID == nil, let url = source.url else { return nil }
            let used = facts.filter { $0.sourceID == source.id }
            guard !used.isEmpty else { return nil }
            let quote = used.map(\.quote).joined(separator: " ")
            let start = quote.unicodeScalars.count + 1
            return .init(
                text: quote + " [source]",
                citations: [.init(
                    startIndex: start,
                    endIndex: start + 8,
                    title: source.title,
                    url: url
                )]
            )
        }
        guard !passages.isEmpty else { return nil }
        let result = WebResearchResult(
            passages: passages,
            consultedURLs: passages.flatMap(\.citations).map(\.url),
            searchCount: searchCount
        )
        _ = try result.markdown()
        return result
    }

    private static func destination(_ source: NoteSeries.Source) throws -> String {
        if let id = source.noteID {
            return "gleanary://note/\(id.uuidString)"
        }
        guard let url = source.url,
              WebResearchResult.safeURL(url) else { throw NoteSeries.Failure.invalidEvidence }
        return url.absoluteString
    }

    private static func noteLink(_ id: UUID, title: String) -> String {
        "[\(AgentCoordinator.markdownLabel(title))](gleanary://note/\(id.uuidString))"
    }
}
