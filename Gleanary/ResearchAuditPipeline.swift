import Foundation

/// Runs a confirmed audit: reads every confirmed item for the accepted criteria, then, for each
/// criterion nothing answered, searches the whole library three ways and reads what it finds.
/// A criterion is reported "not found" only when that whole protocol ran; anything that could
/// hide an answer makes it "unknown" instead.
struct ResearchAuditPipeline {
    let store: DocumentStore
    let search: SearchEngine
    let writer: any WriterInferring

    func run(
        _ audit: ResearchAudit,
        progress: @escaping @Sendable (String, AgentRole?) async -> Void
    ) async throws -> AuditReport {
        let accepted = audit.brief.dimensions.filter(\.accepted)
        guard !accepted.isEmpty else { throw WriterError.scopeChanged }
        let request = Self.extractionRequest(audit.request, dimensions: accepted)
        let calls = CallCount()
        var reading = try await read(audit, dimensions: accepted, request: request, calls: calls) {
            await progress($0, $1)
        }
        await progress("Searching your library", nil)
        let searchable = try await store.searchableItemCount()
        var keywordOnly = false
        var results: [DimensionResult] = []
        for dimension in audit.brief.dimensions {
            try Task.checkCancellation()
            let found = reading.evidence[dimension.label.lowercased()] ?? []
            guard dimension.accepted, found.isEmpty else {
                results.append(DimensionResult(
                    dimension: dimension, coverage: dimension.accepted ? .supported : .outOfScope,
                    evidence: found, searches: [], searchedItems: 0, limitations: []
                ))
                continue
            }
            let hidden = try await counterevidence(
                dimension, request: request, calls: calls, scope: Set(audit.selection)
            )
            keywordOnly = keywordOnly || hidden.keywordOnly
            results.append(Self.result(dimension, hidden: hidden, blocking: reading.blocking))
        }
        if keywordOnly {
            reading.notes
                .append("Meaning search wasn't ready, so the library search matched words only.")
        }
        return AuditReport(
            results: results, read: reading.revisions.count, selected: audit.selection.count,
            searchable: searchable, revisions: reading.revisions,
            limitations: Array(Set(reading.notes)).sorted(), checkedAt: Date()
        )
    }

    /// What reading the confirmed items found.
    private struct Reading {
        /// Stated answers, by lowercased criterion label.
        var evidence: [String: [AuditEvidence]] = [:]
        /// Anything here could hold an answer the audit didn't see, so no absence is claimed.
        var blocking: [String] = []
        var notes: [String] = []
        var revisions: [UUID: String] = [:]
    }

    private func read(
        _ audit: ResearchAudit,
        dimensions: [AuditDimension],
        request: String,
        calls: CallCount,
        progress: @escaping @Sendable (String, AgentRole?) async -> Void
    ) async throws -> Reading {
        let fields = dimensions.map(\.label)
        let fieldsKey = ContentHash.of(dimensions.map { "\($0.label)\n\($0.criteria)" }
            .joined(separator: "\n\n"))
        var reading = Reading()
        let total = audit.selection.count
        await progress("Reading 0 of \(total)", .researcher)
        for (index, id) in audit.selection.enumerated() {
            try Task.checkCancellation()
            await progress("Reading \(index + 1) of \(total)", nil)
            guard let item = try await store.auditSource(id) else {
                reading.notes.append("An item was deleted after the scope was confirmed.")
                continue
            }
            let source = item.source
            if item.partial {
                reading.blocking.append(
                    "“\(source.title)” is only partly saved (\(item.coverage.label.lowercased()))."
                )
            }
            if source.text.count > WriterPipeline.readLimit(local: writer.local) {
                reading.notes.append(
                    "Only the start of “\(source.title)” was read in full; the rest was searched."
                )
            }
            var records = try await store.cachedExtraction(source.version, fieldsKey: fieldsKey)
            do {
                if records == nil {
                    records = try await extract(
                        source, fields: fields, key: fieldsKey, request: request, calls: calls
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reading.blocking
                    .append("“\(source.title)” couldn't be read: \(error.localizedDescription)")
                continue
            }
            reading.revisions[id] = item.revision
            for record in records ?? [] where record.status == .stated {
                reading.evidence[record.field.lowercased(), default: []].append(AuditEvidence(
                    itemID: id, title: source.title, value: record.value, quote: record.quote,
                    outsideScope: false
                ))
            }
        }
        return reading
    }

    private func extract(
        _ source: WriterSourceText,
        fields: [String],
        key: String,
        request: String,
        calls: CallCount
    ) async throws -> [FactRecord] {
        let records = try await WriterPipeline.extract(
            source, fields: fields, request: request, writer: writer, calls: calls
        )
        try await store.saveExtraction(
            records, version: source.version, fieldsKey: key, engine: "audit"
        )
        return records
    }

    /// A criterion nothing in the scope answered: supported if the library search found an
    /// answer, not found only if every search and item read worked.
    private static func result(
        _ dimension: AuditDimension,
        hidden: Counterevidence,
        blocking: [String]
    ) -> DimensionResult {
        let coverage: AuditCoverage = !hidden.evidence.isEmpty ? .supported
            : hidden.failures.isEmpty && blocking.isEmpty ? .notFound : .unknown
        var limitations = hidden.failures + (coverage == .unknown ? blocking : [])
        if hidden.evidence.contains(where: \.outsideScope) {
            limitations.append("Answered by an item outside the audit's scope.")
        }
        return DimensionResult(
            dimension: dimension, coverage: coverage, evidence: hidden.evidence,
            searches: hidden.searches, searchedItems: hidden.items, limitations: limitations
        )
    }

    private struct Counterevidence {
        var evidence: [AuditEvidence] = []
        var searches: [AuditSearch] = []
        var items = 0
        var failures: [String] = []
        var keywordOnly = false
    }

    /// Tries to disprove a gap: searches the literal criterion, its other names and a phrase an
    /// answer would contain, then reads the matching passages of each item found.
    private func counterevidence(
        _ dimension: AuditDimension,
        request: String,
        calls: CallCount,
        scope: Set<UUID>
    ) async throws -> Counterevidence {
        var result = Counterevidence()
        let queries: [(String, AuditSearch.Family)] = [
            (dimension.label, .literal),
            (dimension.alternateTerms.joined(separator: " "), .alternate),
            (dimension.answerQuery, .answer),
        ].filter { !$0.0.isEmpty }
        var order: [UUID] = []
        var passages: [UUID: [Passage]] = [:]
        for (query, family) in queries {
            try Task.checkCancellation()
            do {
                let response = try await search.search(query, limit: AuditLimits.passagesPerQuery)
                result.keywordOnly = result.keywordOnly || response.notice != nil
                result.searches.append(AuditSearch(
                    query: query, family: family, matches: response.matches.count, failed: false
                ))
                for match in response.matches {
                    let id = match.passage.documentID
                    if passages[id] == nil {
                        order.append(id)
                    }
                    if passages[id, default: []].allSatisfy({ $0.id != match.passage.id }) {
                        passages[id, default: []].append(match.passage)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.searches.append(AuditSearch(
                    query: query, family: family, matches: 0, failed: true
                ))
                result.failures.append("A library search failed: \(error.localizedDescription)")
            }
        }
        let titles = try await store.auditableItems(order)
        for id in order.filter({ titles[$0] != nil }).prefix(AuditLimits.counterItems) {
            try Task.checkCancellation()
            let text = (passages[id] ?? []).sorted { $0.ordinal < $1.ordinal }.map(\.text)
                .joined(separator: "\n\n")
            let title = titles[id] ?? ""
            result.items += 1
            do {
                await calls.add()
                let facts = try await writer.extractFacts(ExtractionChunk(
                    title: title, text: String(text.prefix(WriterLimits.remoteChunk)),
                    fields: [dimension.label], request: request, part: 1, parts: 1
                ))
                for record in FactRecord.verified(
                    facts, in: text, fields: [dimension.label], sourceID: id
                ) {
                    result.evidence.append(AuditEvidence(
                        itemID: id, title: title, value: record.value, quote: record.quote,
                        outsideScope: !scope.contains(id)
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failures.append("“\(title)” couldn't be read: \(error.localizedDescription)")
            }
        }
        return result
    }

    /// The request extraction sees: the question plus what each criterion requires, so a passage
    /// that only mentions the topic isn't reported as an answer.
    static func extractionRequest(_ request: String, dimensions: [AuditDimension]) -> String {
        "Research question: \(String(request.prefix(800)))\n"
            + "Report a field only when the text meets its criterion:\n"
            + dimensions.map { "- \($0.label): \($0.criteria)" }.joined(separator: "\n")
    }
}
