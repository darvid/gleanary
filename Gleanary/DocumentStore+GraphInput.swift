import Foundation
import GRDB

extension DocumentStore {
    static func prepareGraph(_ job: GraphJob, in db: Database) throws -> GraphPlan {
        guard let row = try Row
            .fetchOne(
                db,
                sql: "SELECT * FROM notes WHERE id = ? AND revision = ? AND deletedAt IS NULL",
                arguments: [job.noteID.uuidString,
                            job.revision.uuidString]
            ) else { throw GraphError.stale }
        let note = try document(row)
        let node = GraphNode(
            id: GraphNode.documentID(note.id),
            kind: .document,
            label: note.name,
            noteID: note.id
        )
        var segments = [GraphSegment(text: note.markdown)]
        if let capture = try Row.fetchOne(
            db,
            sql: "SELECT id, document FROM captures WHERE noteID = ? AND markdownHash = ? ORDER BY createdAt DESC LIMIT 1",
            arguments: [note.id.uuidString, ContentHash.of(note.markdown)]
        ) {
            let captureID = try uuid(capture["id"])
            let metadata = try JSONDecoder().decode(
                CapturedDocument.self,
                from: capture["document"]
            )
            let blocks = try Data
                .fetchAll(
                    db,
                    sql: "SELECT block FROM content_blocks WHERE captureID = ? ORDER BY ordinal",
                    arguments: [captureID.uuidString]
                )
                .map { try JSONDecoder().decode(
                    ContentBlock.self,
                    from: $0
                ) }
            segments = blocks.enumerated().compactMap { ordinal, block in
                // The creator's description and pinned comment are mostly promotion.
                guard ![.code, .table, .image].contains(block.kind),
                      !isReferenceSection(block.section),
                      !CreatorText.methods.contains(block.method) else { return nil }
                return GraphSegment(
                    text: block.text,
                    citation: SourceCitation(
                        captureID: captureID,
                        blockOrdinal: ordinal,
                        page: block.page,
                        section: block.section,
                        url: block
                            .sourceURL ?? metadata
                            .sourceURL,
                        startTime: block.startTime,
                        endTime: block.endTime
                    )
                )
            }
        }
        try insertAuthorClaims(for: note, node: node, job: job, in: db)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector.matches(
            in: note.markdown,
            range: NSRange(note.markdown.startIndex..., in: note.markdown)
        ) {
            guard let url = match.url, let identity = graphURLIdentity(url),
                  let range = Range(match.range, in: note.markdown) else { continue }
            try db.execute(
                sql: "INSERT OR IGNORE INTO graph_links(noteID, identity, quote, offset) VALUES (?, ?, ?, ?)",
                arguments: [
                    note.id.uuidString,
                    identity,
                    String(note.markdown[range]),
                    match.range.location,
                ]
            )
        }
        try refreshGraphLinks(in: db)
        // Start with the overview. Its selected entities then rank a small number of
        // supporting passages; the complete source remains available for exact evidence.
        let sourceChunks = GraphChunk.make(segments, limit: 7000)
        return GraphPlan(
            sourceChunks: sourceChunks,
            extractionIndices: sourceChunks.isEmpty ? [] : [0],
            selectionComplete: sourceChunks.count <= 1
        )
    }

    /// "By" relationships from what the capture recorded about its authors or channel. They
    /// hold however the note's text changed since, as for a saved link replaced by its summary.
    private static func insertAuthorClaims(
        for note: MarkdownDocument,
        node: GraphNode,
        job: GraphJob,
        in db: Database
    ) throws {
        guard let capture = try Row.fetchOne(
            db,
            sql: "SELECT id, document FROM captures WHERE noteID = ? ORDER BY createdAt DESC LIMIT 1",
            arguments: [note.id.uuidString]
        ) else { return }
        let captureID = try uuid(capture["id"])
        let metadata = try JSONDecoder().decode(CapturedDocument.self, from: capture["document"])
        for author in metadata.authors.compactMap(AuthorNames.name).prefix(50) {
            let target = GraphNode.entity(author, kind: .person, noteID: note.id)
            let claim = GraphClaim(
                source: node,
                target: target,
                predicate: .authoredBy,
                quote: author,
                citation: SourceCitation(
                    captureID: captureID,
                    blockOrdinal: 0,
                    page: nil,
                    section: "Capture metadata · authors",
                    url: metadata.sourceURL
                ),
                offset: 0,
                origin: "metadata"
            )
            try insertGraphClaim(claim, job: job, chunk: -1, in: db)
        }
    }

    static func selectGraphPassages(
        _ plan: GraphPlan,
        candidateNames: [String],
        title: String,
        limit: Int = 7
    ) -> GraphPlan {
        guard !plan.selectionComplete, plan.sourceChunks.count > 1 else { return plan }
        let names = candidateNames.map(searchableGraphText).filter { !$0.isEmpty }
        let titleTerms = Set(searchableGraphText(title).split(separator: " ").filter {
            $0.count >= 4 && !graphSelectionStopWords.contains(String($0))
        })
        var ranked: [(index: Int, score: Int)] = []
        for index in plan.sourceChunks.indices.dropFirst() {
            let chunk = plan.sourceChunks[index]
            let text = searchableGraphText(chunk.text)
            var score = max(0, 16 - index) + (index == 1 ? 30 : 0)
            score += names.filter(text.contains).count * 24
            score += titleTerms.filter(text.contains).count * 3
            let sections = chunk.segments.compactMap { $0.citation?.section?.lowercased() }
            if sections.contains(where: { section in
                graphOverviewSections.contains(where: section.contains)
            }) {
                score += 28
            }
            if sections.contains(where: { section in
                graphCoreSections.contains(where: section.contains)
            }) {
                score += 18
            }
            if text.range(
                of: #"\b(component|components|consist|include|uses|evaluated|measured)\b"#,
                options: .regularExpression
            ) != nil {
                score += 6
            }
            ranked.append((index, score))
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        let selected = [0] + ranked.prefix(max(0, min(limit, plan.sourceChunks.count) - 1))
            .map(\.index)
        return GraphPlan(
            sourceChunks: plan.sourceChunks,
            extractionIndices: selected.sorted(),
            selectionComplete: true
        )
    }

    static func mindMapEvidence(in chunks: [GraphChunk], limit: Int = 16) -> [GraphSegment] {
        var ranked: [(segment: GraphSegment, score: Int, order: Int)] = []
        var seen = Set<String>()
        var order = 0
        for (chunkIndex, chunk) in chunks.enumerated() {
            for segment in chunk.segments {
                defer { order += 1 }
                let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 40 else { continue }
                let text = String(trimmed.prefix(700))
                guard let range = segment.text.range(of: text),
                      seen.insert(ContentHash.of(text)).inserted else { continue }
                let searchable = searchableGraphText(text)
                let section = segment.citation?.section?.lowercased() ?? ""
                var score = chunkIndex == 0 ? 90 : max(0, 20 - chunkIndex)
                if graphOverviewSections.contains(where: section.contains) {
                    score += 35
                }
                if section.range(
                    of: #"result|finding|evaluation|experiment|limitation"#,
                    options: .regularExpression
                ) != nil {
                    score += 70
                }
                if searchable.range(
                    of: #"\b(result|results|finding|findings|benchmark|evaluated|evaluation|limitation|limitations|strongest|outperform)\b"#,
                    options: .regularExpression
                ) != nil {
                    score += 45
                }
                ranked.append((
                    GraphSegment(
                        text: text,
                        citation: segment.citation,
                        offset: segment.offset + range.lowerBound.utf16Offset(in: segment.text)
                    ),
                    score,
                    order
                ))
            }
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score > rhs.score
        }
        return ranked.prefix(limit).map(\.segment)
    }

    private static func searchableGraphText(_ text: String) -> String {
        GraphNode.normalize(text.replacingOccurrences(
            of: #"[^\p{L}\p{N}]+"#,
            with: " ",
            options: .regularExpression
        ))
    }

    private static let graphSelectionStopWords: Set<String> = [
        "about", "after", "before", "from", "into", "paper", "study", "that", "their",
        "these", "this", "using", "with",
    ]

    private static let graphOverviewSections = [
        "abstract", "introduction", "overview", "conclusion", "conclusions", "discussion",
    ]

    private static let graphCoreSections = [
        "approach", "architecture", "design", "implementation", "method", "methodology",
        "system",
    ]

    private static func isReferenceSection(_ section: String?) -> Bool {
        guard let section else { return false }
        let normalized = section.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "references" || normalized == "bibliography" ||
            normalized.hasPrefix("references ") || normalized.hasPrefix("bibliography ")
    }

    static func graphURLIdentity(_ url: URL) -> String? {
        if let media = try? MediaTarget.parse(url) {
            return media.identity
        }
        return (try? CaptureRequest.canonicalURL(url)).map { "url:" + $0 }
    }

    /// Resolve retained links again when another document arrives; never fetch linked URLs.
    static func refreshGraphLinks(in db: Database) throws {
        var targets: [String: [GraphNode]] = [:]
        for row in try Row.fetchAll(db, sql: """
        SELECT notes.id, notes.name, sources.identity, captures.document FROM captures
        JOIN notes ON notes.id = captures.noteID JOIN sources ON sources.id = captures.sourceID
        WHERE notes.deletedAt IS NULL
        """) {
            let id = try uuid(row["id"])
            let node = GraphNode(
                id: GraphNode.documentID(id),
                kind: .document,
                label: row["name"],
                noteID: id
            )
            let identity: String = row["identity"]
            targets[identity, default: []].append(node)
            let metadata = try JSONDecoder().decode(CapturedDocument.self, from: row["document"])
            if let url = metadata.sourceURL, let identity = graphURLIdentity(url) {
                targets[identity, default: []].append(node)
            }
        }
        for row in try Row.fetchAll(db, sql: """
        SELECT graph_jobs.*, notes.name, graph_links.identity, graph_links.quote, graph_links.offset
        FROM graph_links JOIN graph_jobs ON graph_jobs.noteID = graph_links.noteID
        JOIN notes ON notes.id = graph_links.noteID WHERE notes.deletedAt IS NULL
        """) {
            let job = try graphJob(row)
            let source = GraphNode(
                id: GraphNode.documentID(job.noteID),
                kind: .document,
                label: job.name,
                noteID: job.noteID
            )
            for target in targets[row["identity"] as String] ?? [] where target.id != source.id {
                try insertGraphClaim(GraphClaim(
                    source: source,
                    target: target,
                    predicate: .linksTo,
                    quote: row["quote"],
                    citation: nil,
                    offset: row["offset"],
                    origin: "link"
                ), job: job, chunk: -1, in: db)
            }
        }
    }
}
