import Foundation

/// What Extract and Write produced, before anything is saved.
struct WriterComposition: Sendable {
    let rendered: WriterDocument.Rendered
    /// Every source read, at the version read.
    let versions: [SourceVersion]
    /// Sources whose records came from a new extraction rather than the cache.
    let extracted: Int
    /// Model calls made, for automation budgets.
    let calls: Int
}

/// Extract (Researcher) then Write (Writer) for a confirmed selection. Chat and the weekly
/// digest both run it; neither saves anything until it returns.
struct WriterPipeline {
    let store: DocumentStore
    let inference: any ConversationInferring

    /// Whether this provider can write from this many sources: any number on the tool loop,
    /// a small selection on-device.
    static func canWrite(_ count: Int, with inference: any ConversationInferring) -> Bool {
        guard inference is any WriterInferring else { return false }
        return inference is any AgentResponding
            || (inference is any DocumentDrafting && count <= WriterLimits.localScope)
    }

    /// `progress` reports each step, with the agent that owns a stage when it starts.
    func produce(
        _ request: WriterRequest,
        progress: @escaping @Sendable (String, AgentRole?) async -> Void
    ) async throws -> WriterComposition {
        guard let writer = inference as? any WriterInferring,
              Self.canWrite(request.selection.count, with: inference)
        else { throw WriterError.needsChatGPT }
        let calls = CallCount()
        let total = request.selection.count
        await progress("Extracting 0 of \(total)", .researcher)
        var items: [(id: UUID, title: String, records: [FactRecord])] = []
        var versions: [SourceVersion] = []
        var webSources: [UUID: [WebResearchResult.Citation]] = [:]
        var extracted = 0
        for (index, id) in request.selection.enumerated() {
            try Task.checkCancellation()
            await progress("Extracting \(index + 1) of \(total)", nil)
            // An item deleted since the scope was confirmed is skipped, not fatal.
            guard let source = try await store.writerSource(id) else { continue }
            let version = source.version
            var records = try await store.cachedExtraction(
                version,
                fieldsKey: request.brief.fieldsKey
            )
            if records == nil {
                let fresh = try await extract(
                    source,
                    request: request,
                    writer: writer,
                    calls: calls
                )
                try await store.saveExtraction(
                    fresh, version: version, fieldsKey: request.brief.fieldsKey,
                    engine: inference.capabilities.identifier
                )
                records = fresh
                extracted += 1
            }
            if let web = try await store.webResearchEvidence(noteID: id) {
                _ = try web.markdown()
                webSources[id] = web.passages.flatMap(\.citations)
            }
            versions.append(version)
            items.append((id, source.title, records ?? []))
        }
        guard !items.isEmpty else { throw ConversationError.missingSource }
        await progress("Writing", .writer)
        let document = WriterDocument(
            evidence: WriterEvidence(items, fields: request.brief.fields, webSources: webSources),
            style: request.style, generalKnowledge: request.generalKnowledge,
            personal: request.personal
        )
        let draft = try await write(document, request: request, calls: calls, progress: progress)
        try Task.checkCancellation()
        return await WriterComposition(
            rendered: document.render(draft), versions: versions, extracted: extracted,
            calls: calls.value
        )
    }

    private func write(
        _ document: WriterDocument,
        request: WriterRequest,
        calls: CallCount,
        progress: @escaping @Sendable (String, AgentRole?) async -> Void
    ) async throws -> WriterDraft {
        if !inference.capabilities.local, let agent = inference as? any AgentResponding {
            return try await WriterAgent(
                model: CountingResponder(model: agent, calls: calls),
                toolbox: WriterToolbox(document: document), style: request.style,
                generalKnowledge: request.generalKnowledge, personal: request.personal
            ).run(request: request.request) { await progress($0, nil) }
        }
        guard let drafter = inference as? any DocumentDrafting
        else { throw WriterError.needsChatGPT }
        await calls.add()
        let draft = try await drafter.draftDocument(
            instructions: WriterAgent.instructions(
                style: request.style, generalKnowledge: request.generalKnowledge, tools: false,
                personal: request.personal
            ),
            prompt: WriterAgent.prompt(request: request.request, evidence: document.evidence),
            recordIDs: document.evidence.recordIDs
        )
        do { try document.validate(draft) } catch { throw ConversationError.invalidOutput }
        return draft
    }

    /// Each section of one source in its own call; the app keeps only facts whose quotes it
    /// finds in that section, and records every other requested field as not covered.
    private func extract(
        _ source: WriterSourceText,
        request: WriterRequest,
        writer: any WriterInferring,
        calls: CallCount
    ) async throws -> [FactRecord] {
        let fields = request.brief.fields
        let size = writer.local ? WriterLimits.localChunk : WriterLimits.remoteChunk
        let chunks = Array(AppleLinkSummarizer.chunks(source.text, limit: size)
            .prefix(WriterLimits.chunksPerItem))
        var records: [FactRecord] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await calls.add()
            let facts = try await writer.extractFacts(ExtractionChunk(
                title: source.title, text: chunk, fields: fields, request: request.request,
                part: index + 1, parts: chunks.count
            ))
            for record in FactRecord.verified(facts, in: chunk, fields: fields, sourceID: source.id)
                where !records.contains(where: {
                    $0.field == record.field && $0.subject == record.subject
                        && $0.value == record.value
                })
            {
                records.append(record)
            }
        }
        return FactRecord.completed(records, fields: fields, sourceID: source.id)
    }
}

/// Model calls made by one composition.
actor CallCount {
    private(set) var value = 0

    func add() {
        value += 1
    }
}

/// Counts each tool-loop turn as a model call.
private struct CountingResponder: AgentResponding {
    let model: any AgentResponding
    let calls: CallCount

    func agentTurn(instructions: String, input: [Data], tools: Data) async throws -> AgentTurn {
        await calls.add()
        return try await model.agentTurn(instructions: instructions, input: input, tools: tools)
    }
}
