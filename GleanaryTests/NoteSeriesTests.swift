import Foundation
@testable import Gleanary
import GRDB
import Testing

private let topicSourceText = "Evaluation uses held-out cases. Evaluation measures task-specific success rates across independent test cases."

private let seriesSourceText = "Clear instructions state the desired task. Examples demonstrate the intended format. Evaluation compares outputs against explicit criteria. Test cases reveal inconsistent outputs."

private func conceptSentences(_ number: Int) -> [String] {
    [
        "Concept \(number) provides its own foundation.",
        "Concept \(number) has a distinct practical application.",
    ]
}

private actor SeriesFixtureFetcher: SourceFetching {
    var requests: [URL] = []
    var fail = false
    var cancelTarget = false
    func cancelTargetDownload() {
        cancelTarget = true
    }

    func setFailure(_ value: Bool) {
        fail = value
    }

    func fetch(_ url: URL) async throws -> DownloadedContent {
        requests.append(url)
        if cancelTarget, url.lastPathComponent == "targeted" {
            cancelTarget = false
            throw CancellationError()
        }
        if fail {
            throw CaptureError.downloadFailed
        }
        let text: String = if url.lastPathComponent == "targeted" {
            topicSourceText
        } else if let group = Int(url.lastPathComponent.replacingOccurrences(
            of: "group-",
            with: ""
        )) {
            (((group - 1) * 2 + 1) ... (group * 2)).flatMap(conceptSentences).joined(separator: " ")
        } else {
            seriesSourceText
        }
        return DownloadedContent(
            data: Data(text.utf8),
            url: url,
            mime: "text/plain",
            encoding: "utf-8"
        )
    }
}

private actor SeriesFixture: ConversationInferring, NoteSeriesInferring, WriterInferring,
    WebResearching
{
    enum Reuse: Sendable { case none, first, all }
    enum CurationFault: Sendable { case anchor, overlap, legacyOverlap, dropLinks, unknownHandle }
    var curationFaults: [CurationFault] = []
    var curationFeedback: [NoteSeries.CurationFeedback] = []
    var revisedEntries: [UUID] = []
    var unsupportedRevisions = false
    enum DraftFault: String, Sendable,
        CaseIterable { case foreignCitation, formattedProse, incompleteReview, unverified }
    var draftFault: DraftFault?
    var seenDraftFeedback: [NoteSeries.DraftFeedback?] = []
    enum ScopeMode: Sendable { case decline, allow, mandatory, unsupported, invalidRecords,
                                    hiddenDeferral
    }

    var scopeMode: ScopeMode = .decline
    var cancelScopeProposal = false
    var cancelScopeReview = false
    var cancelScopeDraft = false
    func setScopeMode(
        _ value: ScopeMode,
        cancelProposal: Bool = false,
        cancelReview: Bool = false,
        cancelDraft: Bool = false
    ) {
        scopeMode = value
        cancelScopeProposal = cancelProposal
        cancelScopeReview = cancelReview
        cancelScopeDraft = cancelDraft
    }

    enum TopicEvidence: Sendable { case saved, missing, insufficient, otherField, invalid }
    var topicEvidence: TopicEvidence = .saved
    var cancelAfterTopicResearch = false
    var cancelTopicRevision = false
    var cancelSearch = false
    var inventedTopicQuotes = false
    func inventTopicQuotes() {
        inventedTopicQuotes = true
    }

    var searchedQuestions: [String] = []
    func setTopicEvidence(
        _ value: TopicEvidence,
        cancelAfterResearch: Bool = false,
        cancelRevision: Bool = false,
        cancelSearch: Bool = false
    ) {
        topicEvidence = value
        cancelAfterTopicResearch = cancelAfterResearch
        cancelTopicRevision = cancelRevision
        self.cancelSearch = cancelSearch
    }

    var malformedReview = false
    func setMalformedReview(_ value: Bool) {
        malformedReview = value
    }

    func setDraftFault(_ fault: DraftFault?) {
        draftFault = fault
    }

    func setCurationFaults(_ faults: [CurationFault], unsupportedRevisions: Bool = false) {
        curationFaults = faults
        self.unsupportedRevisions = unsupportedRevisions
    }

    let capabilities = InferenceCapabilities(
        identifier: "series-fixture",
        local: false,
        structured: true,
        streaming: true
    )
    nonisolated let local = false
    let reuse: Reuse
    let topicCount: Int
    let mode: NoteSeries.SourceMode
    var counts: [String: Int] = [:]
    var failSecondDraftOnce = false
    var unsupported = false
    var rejectFirstReview = false
    var badLinks = false
    var invalidOutline = false
    var onCurate: (@Sendable () async throws -> Void)?
    var seenLibrary: [NoteSeries.Source] = []
    var seenOutlineStyle: WritingStyle?
    var seenDraftStyles: [WritingStyle] = []
    var seenDraftRequests: [String] = []
    var libraryQueries: [String] = []
    func setQueries(_ queries: [String]) {
        libraryQueries = queries
    }

    var searchedQuestion = ""
    var searchSourceCount = -1

    init(reuse: Reuse = .none, mode: NoteSeries.SourceMode = .fillGaps, topicCount: Int = 2) {
        self.reuse = reuse
        self.topicCount = topicCount
        self.mode = mode
    }

    func configure(
        failSecond: Bool = false,
        unsupported: Bool = false,
        rejectFirstReview: Bool = false,
        badLinks: Bool = false,
        invalidOutline: Bool = false
    ) {
        failSecondDraftOnce = failSecond
        self.unsupported = unsupported
        self.rejectFirstReview = rejectFirstReview
        self.badLinks = badLinks
        self.invalidOutline = invalidOutline
    }

    func setOnCurate(_ action: (@Sendable () async throws -> Void)?) {
        onCurate = action
    }

    private func count(_ name: String) {
        counts[name, default: 0] += 1
    }

    func plan(
        request _: String,
        context _: ConversationPlanningContext
    ) async throws -> ConversationPlan {
        count("plan")
        return ConversationPlan(steps: [.init(
            action: .researchSeries,
            argument: "Research prompt engineering and write two notes"
        )])
    }

    func researchTitle(for _: String) throws -> String {
        throw ConversationError.invalidOutput
    }

    nonisolated func reply(
        question _: String,
        role _: AgentRole,
        history _: [ConversationTurn]
    )
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish(throwing: ConversationError.invalidReply) }
    }

    nonisolated func research(
        question _: String,
        sources _: [ResearchSource]
    )
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish(throwing: ConversationError.invalidOutput) }
    }

    func brief(
        request _: String,
        categories _: [DecimalCategory]
    ) throws -> WriterBrief {
        throw ConversationError
            .invalidOutput
    }

    func seriesBrief(request _: String) -> NoteSeries.Brief {
        count("brief")
        return .init(query: "prompt", mode: mode, libraryQueries: libraryQueries)
    }

    func seriesOutline(
        request _: String,
        brief _: NoteSeries.Brief,
        library: [NoteSeries.Source],
        style: WritingStyle
    ) throws -> NoteSeries.Outline {
        count("outline")
        seenOutlineStyle = style
        seenLibrary = library
        if topicCount != 2 {
            return .init(
                title: "Concept reading path",
                entries: (1 ... topicCount).map { number in
                    .init(
                        id: UUID(),
                        title: "Concept \(number)",
                        purpose: "Explain concept \(number)",
                        fields: ["topic-\(number)"],
                        existingNoteID: reuse == .all && library.indices
                            .contains(number - 1) ? library[number - 1].noteID : nil
                    )
                },
                sizingReason: "Each selected concept has a distinct purpose; overlapping details stay together.",
                deferredCoverage: topicCount == 12 ?
                    [
                        "Advanced applications — deferred because this run reached its 12-topic limit.",
                    ] :
                    []
            )
        }
        let candidates = library.sorted { $0.title < $1.title }
        let entries = [
            ("Prompt structure", "Explain clear instructions and examples", "structure"),
            ("Prompt evaluation", "Explain evaluation and test cases", "evaluation"),
        ]
        return NoteSeries.Outline(
            title: "Prompt engineering reading path",
            entries: entries.prefix(reuse == .all && candidates.count == 1 ? 1 : 2).enumerated()
                .map { index, item in
                    let existing = reuse == .all || (reuse == .first && index == 0)
                    return .init(
                        id: UUID(),
                        title: item.0,
                        purpose: item.1,
                        fields: [item.2],
                        existingNoteID: existing && candidates.indices
                            .contains(index) ? candidates[index]
                            .noteID : nil
                    )
                }
        )
    }

    func reviewSeriesOutline(
        _: NoteSeries.Outline,
        request _: String,
        library _: [NoteSeries.Source]
    ) -> Bool {
        count("outlineReview")
        return !invalidOutline
    }

    func researchWeb(
        question: String,
        sources: [ResearchSource],
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> WebResearchResult {
        count("web")
        searchedQuestion = question
        searchedQuestions.append(question)
        searchSourceCount = sources.count
        await progress("Searching fixture web sources")
        if question.contains("targeted evaluation") {
            if cancelSearch {
                cancelSearch = false; throw CancellationError()
            }
            let url = try #require(URL(string: "https://research.example.org/targeted"))
            return .init(
                passages: [.init(
                    text: "Public research [cite].",
                    citations: [.init(
                        startIndex: 16,
                        endIndex: 22,
                        title: "Targeted evidence",
                        url: url
                    )]
                )],
                consultedURLs: [url],
                searchCount: 1
            )
        }
        if topicCount != 2 {
            let groups = (topicCount + 1) / 2
            let urls = try (1 ... groups)
                .map { try #require(URL(string: "https://research.example.org/group-\($0)")) }
            return .init(passages: urls.map { url in
                .init(
                    text: "Public research [cite].",
                    citations: [.init(
                        startIndex: 16,
                        endIndex: 22,
                        title: "Concept evidence",
                        url: url
                    )]
                )
            }, consultedURLs: urls, searchCount: 1)
        }
        let url = try #require(URL(string: "https://research.example.org/prompts"))
        return .init(
            passages: [.init(
                text: "Public research [cite].",
                citations: [.init(startIndex: 16, endIndex: 22, title: "Prompt evidence", url: url)]
            )],
            consultedURLs: [url],
            searchCount: 1
        )
    }

    func extractSeriesFacts(_ chunk: ExtractionChunk) -> [ExtractedFact] {
        extractFacts(chunk)
    }

    func extractFacts(_ chunk: ExtractionChunk) -> [ExtractedFact] {
        count("extract")
        return chunk.fields.flatMap { field in
            if field.hasPrefix("topic-"), let number = Int(field.dropFirst(6)) {
                return conceptSentences(number).filter { chunk.text.contains($0) }.map {
                    ExtractedFact(subject: "concept", field: field, value: $0, quote: $0)
                }
            }
            if chunk.text.contains("held-out cases") {
                if inventedTopicQuotes {
                    return [ExtractedFact(
                        subject: "evaluation",
                        field: field,
                        value: "An unsupported guarantee.",
                        quote: "This invented quotation is absent from the fetched page."
                    )]
                }
                return [
                    "Evaluation uses held-out cases.",
                    "Evaluation measures task-specific success rates across independent test cases.",
                ].map {
                    ExtractedFact(subject: "evaluation", field: field, value: $0, quote: $0)
                }
            }
            let sentences = field == "structure" ? [
                "Clear instructions state the desired task.",
                "Examples demonstrate the intended format.",
            ] : [
                "Evaluation compares outputs against explicit criteria.",
                "Test cases reveal inconsistent outputs.",
            ]
            return sentences.filter { chunk.text.contains($0) }.map { ExtractedFact(
                subject: "prompt",
                field: field,
                value: $0,
                quote: $0
            ) }
        }
    }

    func proposeSeriesScope(
        _ entry: NoteSeries.Entry,
        request _: String,
        dossier: NoteSeries.Dossier,
        feedback _: NoteSeries.DraftFeedback,
        failure _: String
    ) throws -> NoteSeries.ScopeProposal {
        count("scopeProposal")
        if cancelScopeProposal {
            cancelScopeProposal = false; throw CancellationError()
        }
        if scopeMode == .decline {
            return .init(
                possible: false,
                title: "",
                purpose: "",
                records: [],
                deferred: [],
                reason: "The requested topic cannot safely be narrowed in this fixture."
            )
        }
        let facts = dossier.facts
            .filter { $0.quote.contains("held-out") || $0.quote.contains("independent test") }
        let selected = facts.isEmpty ? dossier.facts(for: entry) : facts
        return .init(
            possible: true,
            title: facts.isEmpty ? "Evaluation and Test Cases" : "Held-Out Evaluation",
            purpose: facts
                .isEmpty ? "Explain evaluation criteria and test cases" :
                "Explain held-out cases and task-specific success measures",
            records: scopeMode == .invalidRecords ? ["UNKNOWN_SCOPE_FIXTURE"] : selected.prefix(2)
                .map(\.id),
            deferred: scopeMode == .hiddenDeferral ? [] :
                [
                    "Audio prompting and explicit uncertainty guidance remain outside this evidence-backed note.",
                ],
            reason: "The broad request permits a disclosed evidence-backed subset without dropping an explicit requirement."
        )
    }

    func reviewSeriesScope(
        _: NoteSeries.ScopeProposal,
        entry _: NoteSeries.Entry,
        request _: String,
        dossier _: NoteSeries.Dossier,
        feedback _: NoteSeries.DraftFeedback
    ) throws -> NoteSeries.ScopeReview {
        count("scopeReview")
        if cancelScopeReview {
            cancelScopeReview = false; throw CancellationError()
        }
        return .init(
            preservesRequest: scopeMode != .mandatory,
            supported: scopeMode != .unsupported,
            reason: scopeMode == .mandatory ?
                "The user explicitly required audio prompting; disclosure does not permit dropping it." :
                "The narrower purpose is supported and the missing automatically planned coverage is disclosed."
        )
    }

    func assessSeriesTopic(
        _ entry: NoteSeries.Entry,
        dossier: NoteSeries.Dossier,
        feedback _: NoteSeries.DraftFeedback
    ) throws -> NoteSeries
        .TopicAssessment
    {
        count("topicAssess")
        if cancelAfterTopicResearch, (dossier.recoverySearchCount ?? 0) > 0 {
            cancelAfterTopicResearch = false
            throw CancellationError()
        }
        if topicEvidence == .invalid {
            return .init(
                sufficient: true,
                records: ["UNKNOWN_FIXTURE"],
                reason: "A fixture invalid record.",
                query: ""
            )
        }
        if topicEvidence == .otherField {
            let records = dossier.facts.filter { !entry.fields.contains($0.field) }.prefix(2)
                .map(\.id)
            return .init(
                sufficient: true,
                records: records,
                reason: "Existing quotations cover this topic despite a different field label.",
                query: ""
            )
        }
        let targeted = dossier.facts
            .filter { $0.quote.contains("held-out") || $0.quote.contains("independent test") }
        if topicEvidence == .insufficient || (topicEvidence == .missing && targeted.isEmpty) {
            return .init(
                sufficient: false,
                records: [],
                reason: "The evidence lacks topic-specific evaluation methods.",
                query: "targeted evaluation"
            )
        }
        let records = topicEvidence == .missing ? targeted : dossier.facts(for: entry)
        return .init(
            sufficient: true,
            records: records.prefix(16).map(\.id),
            reason: "These quotations support a distinct topic-specific contribution.",
            query: ""
        )
    }

    func draftSeriesNote(
        _ entry: NoteSeries.Entry,
        request: String,
        dossier: NoteSeries.Dossier,
        style: WritingStyle,
        feedback: NoteSeries.DraftFeedback?
    ) throws -> NoteSeries.Draft {
        count("draft")
        seenDraftRequests.append(request)
        seenDraftStyles.append(style)
        seenDraftFeedback.append(feedback)
        if feedback?.distinctness != nil {
            if cancelScopeDraft,
               dossier
               .scopeRecords?[entry.id] !=
               nil
            {
                cancelScopeDraft = false; throw CancellationError()
            }
            if cancelTopicRevision {
                cancelTopicRevision = false; throw CancellationError()
            }
            revisedEntries.append(entry.id)
        }
        if feedback != nil {
            count("repair")
        }
        if failSecondDraftOnce, counts["draft"] == 2 {
            failSecondDraftOnce = false
            throw ChatGPTError.server
        }
        let facts = dossier.facts(for: entry)
        var seen = Set<String>()
        let chosen = facts.filter { seen.insert($0.value).inserted }.prefix(2)
        var paragraphs: [NoteSeries.Paragraph] = chosen
            .map { .init(text: $0.value, records: [$0.id]) }
        if entry.fields.contains("evaluation"), paragraphs.count == 2 {
            let paragraph = paragraphs[1]
            switch draftFault {
            case .foreignCitation: paragraphs[1] = .init(
                    text: paragraph.text,
                    records: ["foreign-fixture-record"]
                )
            case .formattedProse: paragraphs[1] = .init(
                    text: paragraph.text + "\nA second line.",
                    records: paragraph.records
                )
            default: break
            }
        }
        return .init(paragraphs: paragraphs)
    }

    func verifySeriesDraft(
        _ draft: NoteSeries.Draft,
        entry: NoteSeries.Entry,
        dossier _: NoteSeries.Dossier
    ) -> [NoteSeries.ParagraphReview] {
        count("verify")
        if malformedReview {
            return draft.paragraphs.enumerated().map { index, paragraph in
                .init(
                    paragraph: index + 1,
                    verdict: .supported,
                    claim: paragraph.text,
                    reason: "A supported verdict cannot also reject a claim."
                )
            }
        }
        if entry.fields.contains("evaluation") {
            if draftFault == .incompleteReview {
                return reviews(draft, flags: [true])
            }
            if draftFault == .unverified {
                return reviews(draft, flags: [true, false])
            }
        }
        if rejectFirstReview, counts["verify"] == 1 {
            return reviews(draft, flags: Array(repeating: false, count: draft.paragraphs.count))
        }
        return reviews(draft, flags: Array(
            repeating: !unsupported && !(unsupportedRevisions && revisedEntries.contains(entry.id)),
            count: draft.paragraphs.count
        ))
    }

    private func reviews(_ draft: NoteSeries.Draft, flags: [Bool]) -> [NoteSeries.ParagraphReview] {
        flags.enumerated().map { index, supported in
            .init(
                paragraph: index + 1,
                verdict: supported ? .supported : .unsupported,
                claim: supported ? "" : draft.paragraphs[index].text,
                reason: supported ? "" :
                    "The cited quotation describes one test case, not a guarantee for all outputs."
            )
        }
    }

    func curateSeries(
        _ outline: NoteSeries.Outline,
        drafts: [UUID: NoteSeries.Draft],
        library _: [NoteSeries.Source],
        feedback: NoteSeries.CurationFeedback?
    ) async throws -> NoteSeries.Curation {
        count("curate")
        if let feedback {
            curationFeedback.append(feedback)
        }
        let fault = curationFaults.isEmpty ? nil : curationFaults.removeFirst()
        try await onCurate?()
        if fault == .unknownHandle {
            throw NoteSeries.Failure.invalidLinks
        }
        guard let source = outline.entries.first(where: { drafts[$0.id] != nil }),
              let target = outline.entries.first(where: { $0.id != source.id }),
              let text = drafts[source.id]?.paragraphs.first?.text
        else { return .init(
            distinct: true,
            links: []
        ) }
        let anchor = String(text.split(separator: " ").prefix(2).joined(separator: " "))
        let links: [NoteSeries.Link] = fault == .dropLinks ? [] : [.init(
            from: source.id,
            to: badLinks ? UUID() : target.existingNoteID ?? target.id,
            paragraph: 0,
            anchor: fault == .anchor ? "Absent phrase" : anchor,
            reason: "A related concept in this reading path"
        )]
        let overlap = fault == .overlap
        return .init(
            distinct: !overlap && fault != .legacyOverlap,
            links: links,
            overlaps: overlap ? [.init(
                from: target.id,
                to: source.id,
                reason: "The second draft repeats the first draft's explanation."
            )] : []
        )
    }
}

@Suite(.serialized) struct NoteSeriesTests {
    private struct Fixture {
        let root: URL
        let store: DocumentStore
        let model: SeriesFixture
        let fetcher: SeriesFixtureFetcher
        let coordinator: AgentCoordinator
        let task: UUID
        let saved: [MarkdownDocument]
        let request: String
    }

    private func fixture(
        reuse: SeriesFixture.Reuse = .none,
        mode: NoteSeries.SourceMode = .fillGaps,
        savedCount: Int = 0,
        topicCount: Int = 2,
        request: String = "Research prompt engineering and write two connected notes",
        styles: WritingStyleChoice = WritingStyleChoice()
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        var saved: [MarkdownDocument] = []
        for index in 0 ..< savedCount {
            try await saved.append(store.save(MarkdownDocument(
                name: "Prompt existing \(index)",
                markdown: seriesSourceText + " PRIVATE_FIXTURE"
            )))
        }
        let model = SeriesFixture(reuse: reuse, mode: mode, topicCount: topicCount)
        let fetcher = SeriesFixtureFetcher()
        let coordinator = AgentCoordinator(
            store: store,
            fetcher: fetcher,
            inference: model,
            writingStyles: { styles }
        )
        let task = try await store.beginConversation(request, owner: .assistant)
        return Fixture(
            root: root,
            store: store,
            model: model,
            fetcher: fetcher,
            coordinator: coordinator,
            task: task,
            saved: saved,
            request: request
        )
    }

    private func execute(_ fixture: Fixture) async throws {
        try await fixture.coordinator.execute(
            taskID: fixture.task,
            request: fixture.request,
            selected: []
        ) {}
    }

    private func run(_ fixture: Fixture) async throws -> NoteSeries
        .Run
    {
        try #require(await fixture.store.noteSeriesRun(taskID: fixture.task))
    }

    private func savedDrafts(_ fixture: Fixture) async throws
        -> [UUID: NoteSeries.Artifact<NoteSeries.Draft>]
    {
        let run = try await run(fixture)
        let outline = try #require(await fixture.store.seriesArtifact(
            run,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        var result: [UUID: NoteSeries.Artifact<NoteSeries.Draft>] = [:]
        for entry in outline.value.entries where entry.existingNoteID == nil {
            result[entry.id] = try #require(await fixture.store.seriesArtifact(
                run,
                kind: .draft,
                slot: entry.id.uuidString,
                as: NoteSeries.Draft.self
            ))
        }
        return result
    }

    private func resume(_ fixture: Fixture) async throws {
        try await fixture.store.updateConversationTask(
            fixture.task,
            state: "failed",
            progress: "Fixture review failure"
        )
        try await fixture.store.retryNoteSeries(taskID: fixture.task)
        try await execute(fixture)
    }

    private func expectReviewFailure(
        _ fixture: Fixture,
        kind: NoteSeries.CurationIssueKind
    ) async throws {
        do {
            try await execute(fixture)
            Issue.record("Expected a specific final-review failure")
        } catch let NoteSeries.Failure.curation(issue) {
            #expect(issue.kind == kind)
            #expect(NoteSeries.Failure.curation(issue).localizedDescription
                .contains("drafts are saved"))
        }
        #expect(try await fixture.store.documents().isEmpty)
    }

    private func reviewLink(
        _ from: UUID,
        _ to: UUID,
        paragraph: Int = 0,
        anchor: String = "Alpha",
        reason: String = "Related concepts"
    ) -> NoteSeries.Link {
        .init(from: from, to: to, paragraph: paragraph, anchor: anchor, reason: reason)
    }

    @Test func curationDiagnosticsIdentifyEachStructuralFailure() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let outline = NoteSeries.Outline(
            title: "Fixture concepts",
            entries: [a, b, c].enumerated().map { index, id in
                .init(
                    id: id,
                    title: "Concept \(index)",
                    purpose: "A distinct concept",
                    fields: ["concept"],
                    existingNoteID: nil
                )
            }
        )
        let drafts: [UUID: NoteSeries.Draft] = [
            a: .init(paragraphs: [
                .init(text: "Alpha supports Beta.", records: []),
                .init(text: "Another Alpha claim.", records: []),
            ]),
            b: .init(paragraphs: [
                .init(text: "Beta has a distinct purpose.", records: []),
                .init(text: "Another Beta claim.", records: []),
            ]),
            c: .init(paragraphs: [
                .init(text: "Gamma has a distinct purpose.", records: []),
                .init(text: "Another Gamma claim.", records: []),
            ]),
        ]
        let valid = reviewLink(a, b)
        let samples: [([NoteSeries.Link], NoteSeries.CurationIssueKind)] = [
            ([reviewLink(UUID(), b)], .missingDraft),
            ([reviewLink(a, a)], .selfLink),
            ([reviewLink(a, UUID())], .invalidTarget),
            ([reviewLink(a, b, reason: "")], .invalidReason),
            ([valid, valid], .duplicateTarget),
            ([reviewLink(a, b, paragraph: 9)], .invalidParagraph),
            ([reviewLink(a, b, anchor: "[Alpha]")], .invalidAnchor),
            ([reviewLink(a, b, anchor: "Missing")], .anchorMismatch),
            ([valid, reviewLink(a, c, anchor: "Beta")], .multipleAnchors),
            (Array(repeating: valid, count: 49), .tooManyLinks),
        ]
        for (links, kind) in samples {
            let review = NoteSeries.Curation(distinct: true, links: links)
            let issues = review.issues(outline: outline, drafts: drafts, library: [])
            #expect(issues.contains { $0.kind == kind })
            #expect(issues.allSatisfy { !$0.message.isEmpty })
            #expect(throws: NoteSeries.Failure.self) { try review.validate(
                outline: outline,
                drafts: drafts,
                library: []
            ) }
        }
        try NoteSeries.Curation(distinct: true, links: [valid]).validate(
            outline: outline,
            drafts: drafts,
            library: []
        )
        try NoteSeries.Curation(distinct: true, links: [reviewLink(a, b, anchor: "")]).validate(
            outline: outline,
            drafts: drafts,
            library: []
        )
        let malformed = NoteSeries.Curation(
            distinct: false,
            links: [],
            overlaps: [.init(from: UUID(), to: a, reason: "Repeated coverage")]
        )
        #expect(malformed.issues(outline: outline, drafts: drafts, library: []).first?
            .kind == .invalidOverlap)
        var duplicates = drafts
        let repeated = try #require(drafts[a]?.paragraphs.first)
        let unique = try #require(drafts[b]?.paragraphs.last)
        duplicates[b] = .init(paragraphs: [repeated, unique])
        let approvedByModel = NoteSeries.Curation(distinct: true, links: [])
        #expect(approvedByModel.issues(outline: outline, drafts: duplicates, library: []).first?
            .kind == .overlap)
        #expect(approvedByModel.overlapsToRepair(outline: outline, drafts: duplicates).first?
            .from == b)
    }

    @Test func legacyReviewAndDraftFeedbackCheckpointsStillDecode() throws {
        let review = try JSONDecoder().decode(
            NoteSeries.Curation.self,
            from: Data(#"{"distinct":false,"links":[]}"#.utf8)
        )
        #expect(!review.distinct)
        #expect(review.overlaps.isEmpty)
        let feedback = try JSONDecoder().decode(
            NoteSeries.DraftFeedback.self,
            from: Data(#"{"draft":{"paragraphs":[]},"structurallyValid":true,"supported":[]}"#.utf8)
        )
        #expect(feedback.distinctness == nil)
    }

    @Test(arguments: [SeriesFixture.CurationFault.anchor, .unknownHandle])
    fileprivate func malformedLinksAreRepairedOnceWithoutRepeatingResearch(_ fault: SeriesFixture
        .CurationFault) async throws
    {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([fault])
        try await execute(f)
        let run = try await run(f)
        #expect(run.published)
        #expect(await f.model.counts["curate"] == 2)
        #expect(await f.model.counts["draft"] == 2)
        #expect(await f.model.counts["web"] == 1)
        #expect(await f.model.revisedEntries.isEmpty)
        let feedback = try #require(await f.model.curationFeedback.last)
        #expect(feedback.issues.first?
            .kind == (fault == .anchor ? .anchorMismatch : .invalidTarget))
        #expect(try await f.store.seriesArtifact(
            run,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ) != nil)
    }

    @Test func overlapRepairRevisesOnlyTheFlaggedDraftAndKeepsOriginalCheckpoints() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.overlap])
        try await execute(f)
        let run = try await run(f)
        let outline = try #require(await f.store.seriesArtifact(
            run,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let originals = try await savedDrafts(f)
        let affected = outline.value.entries[1].id, unaffected = outline.value.entries[0].id
        #expect(await f.model.revisedEntries == [affected])
        #expect(await f.model.counts["draft"] == 3)
        #expect(await f.model.counts["verify"] == 3)
        #expect(await f.model.counts["web"] == 1)
        #expect(await f.model.counts["curate"] == 2)
        let revision = try #require(await f.store.latestSeriesArtifact(
            run,
            kind: .draftRevision,
            slotPrefix: affected.uuidString + ".",
            as: NoteSeries.Draft.self
        ))
        #expect(revision.id != originals[affected]?.id)
        #expect(try await f.store.latestSeriesArtifact(
            run,
            kind: .draftRevision,
            slotPrefix: unaffected.uuidString + ".",
            as: NoteSeries.Draft.self
        ) == nil)
        let reviewed = try #require(await f.store.seriesArtifact(
            run,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ))
        #expect(reviewed.value.drafts[affected] == revision.value)
        #expect(reviewed.value.drafts[unaffected] == originals[unaffected]?.value)
        #expect(try await f.store.seriesArtifactIncludesParents(
            run,
            artifactID: reviewed.id,
            parents: [revision.id]
        ))
        #expect(run.published)
    }

    @Test func persistentInvalidLinksStayRecoverableAndDoNotRedraftOnRetry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.configure(badLinks: true)
        try await expectReviewFailure(f, kind: .invalidTarget)
        let originals = try await savedDrafts(f)
        #expect(await f.model.counts["curate"] == 2)
        await f.model.configure()
        try await resume(f)
        #expect(try await run(f).published)
        #expect(await f.model.counts["curate"] == 3)
        #expect(await f.model.counts["draft"] == 2)
        #expect(await f.model.counts["web"] == 1)
        #expect(try await savedDrafts(f).mapValues(\.id) == originals.mapValues(\.id))
    }

    @Test func repairCannotSilentlyDropRelationshipsEvenAcrossExplicitRetry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.anchor, .dropLinks])
        try await expectReviewFailure(f, kind: .droppedLink)
        let failed = try await run(f)
        let requirements = try #require(await f.store.seriesArtifact(
            failed,
            kind: .curationRequirements,
            as: NoteSeries.Curation.self
        ))
        #expect(requirements.value.links.count == 1)
        try await resume(f)
        let resumed = try await run(f)
        #expect(resumed.published)
        #expect(await f.model.counts["draft"] == 2)
        #expect(await f.model.counts["web"] == 1)
        let feedback = try #require(await f.model.curationFeedback.last)
        #expect(feedback.issues.contains { $0.kind == .droppedLink })
        #expect(feedback.requiredLinks == requirements.value.links)
    }

    @Test func legacyOverlapVerdictsAreDiagnosedBeforeTargetedRepair() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.legacyOverlap, .legacyOverlap])
        try await expectReviewFailure(f, kind: .missingOverlapDetails)
        #expect(await f.model.revisedEntries.isEmpty)
        let originals = try await savedDrafts(f)
        await f.model.setCurationFaults([.overlap])
        try await resume(f)
        #expect(try await run(f).published)
        #expect(await f.model.counts["curate"] == 4)
        #expect(await f.model.revisedEntries.count == 1)
        #expect(await f.model.counts["web"] == 1)
        #expect(try await savedDrafts(f).mapValues(\.id) == originals.mapValues(\.id))
    }

    @Test func overlappingDraftRevisionsMustStillPassEvidenceChecks() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.overlap], unsupportedRevisions: true)
        try await expectReviewFailure(f, kind: .unsupportedRevision)
        let run = try await run(f)
        #expect(await f.model.revisedEntries.count == 2)
        #expect(await f.model.counts["curate"] == 1)
        #expect(try await savedDrafts(f).count == 2)
        #expect(try await f.store.latestSeriesArtifact(
            run,
            kind: .draftRevision,
            as: NoteSeries.Draft.self
        ) == nil)
        #expect(try await f.store.seriesArtifact(
            run,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ) == nil)
    }

    @Test func cancellationAfterADraftRepairResumesItsRevisionWithoutRepeatingIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.overlap])
        await f.model.setOnCurate {
            if await f.model.counts["curate"] == 2 {
                throw CancellationError()
            }
        }
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let failed = try await run(f)
        let revision = try #require(await f.store.latestSeriesArtifact(
            failed,
            kind: .draftRevision,
            as: NoteSeries.Draft.self
        ))
        let originals = try await savedDrafts(f)
        #expect(try await f.store.documents().isEmpty)
        await f.model.setOnCurate(nil)
        try await resume(f)
        #expect(try await run(f).published)
        #expect(await f.model.counts["draft"] == 3)
        #expect(await f.model.counts["web"] == 1)
        #expect(await f.model.revisedEntries.count == 1)
        #expect(try await f.store.latestSeriesArtifact(
            failed,
            kind: .draftRevision,
            as: NoteSeries.Draft.self
        )?.id == revision.id)
        #expect(try await savedDrafts(f).mapValues(\.id) == originals.mapValues(\.id))
    }

    @Test func repairRespectsTheOriginalModelCallBudget() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.anchor])
        await f.model.setOnCurate {
            let current = try #require(await f.store.noteSeriesRun(taskID: f.task))
            for _ in 0 ..< NoteSeries.maximumCalls {
                do { try await f.store.reserveSeriesCall(current) }
                catch NoteSeries.Failure.budget { break }
            }
        }
        await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
        #expect(await f.model.counts["curate"] == 1)
        #expect(try await f.store.documents().isEmpty)
        #expect(try await savedDrafts(f).count == 2)
    }

    @MainActor private func waitForSeriesWorker(_ model: ConversationModel) async throws {
        for _ in 0 ..< 400 {
            if !model.running {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Fixture series worker did not finish")
        await model.cancel()
    }

    @Test @MainActor func chatRetryShowsTheSpecificFailureAndResumesSavedWork() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.anchor, .anchor])
        let conversation = ConversationModel(store: f.store, coordinator: f.coordinator)
        await conversation.load()
        conversation.composer = f.request
        await conversation.send()
        try await waitForSeriesWorker(conversation)
        let task = try #require(conversation.tasks
            .first { $0.state == "failed" && $0.progress.contains("anchor text") })
        #expect(task.progress.contains("Link 1:"))
        #expect(task.progress.contains("drafts are saved"))
        #expect(try await f.store.documents().isEmpty)
        let calls = await f.model.counts
        conversation.composer = "Keep this unsent draft"
        await conversation.send(retry: task)
        try await waitForSeriesWorker(conversation)
        #expect(conversation.tasks.first { $0.id == task.id }?.state == "succeeded")
        #expect(conversation.composer == "Keep this unsent draft")
        #expect(try await f.store.noteSeriesRun(taskID: task.id)?.published == true)
        #expect(await f.model.counts["web"] == calls["web"])
        #expect(await f.model.counts["draft"] == calls["draft"])
    }

    @Test(arguments: WritingStyle.presets + [WritingStyle.starterCustom])
    func explicitFormatAndStyleReachBothOutliningAndDrafting(style: WritingStyle) async throws {
        let request = "Research prompt engineering and write two connected notes as a formal report in \(style.name) style"
        let styles = WritingStyleChoice(custom: style.isPreset ? .starterCustom : style)
        let f = try await fixture(request: request, styles: styles)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let run = try await run(f)
        #expect(run.published)
        #expect(run.style == style)
        #expect(await f.model.seenOutlineStyle == style)
        #expect(await f.model.seenDraftStyles == [style, style])
        #expect(await f.model.seenDraftRequests == [request, request])
    }

    @Test func oneRequestResearchesWritesAndPublishesLinkedNotesAtomically() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let run = try await run(f)
        #expect(run.published)
        let notes = try await f.store.documents()
        #expect(notes.count == 3)
        for note in notes {
            let evidence = try #require(await f.store.webResearchEvidence(noteID: note.id))
            #expect(evidence.passages.flatMap(\.citations)
                .allSatisfy { $0.url.absoluteString == "https://research.example.org/prompts" })
        }
        let index = try #require(notes.first { $0.id == run.indexID })
        let members = notes.filter { $0.id != index.id }
        for note in members {
            #expect(index.markdown.contains(note.id.uuidString))
            #expect(note.markdown.contains(index.id.uuidString))
            #expect(note.markdown.contains("https://research.example.org/prompts"))
        }
        #expect(members.contains { note in members.contains { other in
            note.id != other.id && note.markdown.contains(other.id.uuidString)
        } })
        #expect(await f.model.counts["plan"] == 1)
        #expect(await f.model.counts["web"] == 1)
        #expect(await f.model.searchSourceCount == 0)
        #expect(try await f.store.conversationTasks().first?.state == "succeeded")
        #expect(try await f.store.conversationMessages().filter { $0.author == "writer" }
            .count == 1)
        let count = await f.model.counts
        try await execute(f)
        #expect(await f.model.counts == count)
        #expect(try await f.store.documents().count == 3)
    }

    @Test(arguments: [1, 7, 12])
    func coverageSizedSeriesPublishesWithoutAnArtificialThreeTopicQuota(_ count: Int) async throws {
        let f = try await fixture(topicCount: count)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let run = try await run(f)
        let notes = try await f.store.documents()
        #expect(notes.count == count + 1)
        #expect(await f.model.counts["draft"] == count)
        #expect(await f.fetcher.requests.count == (count + 1) / 2)
        let index = try #require(notes.first { $0.id == run.indexID })
        #expect(index.markdown.contains("## Coverage"))
        if count == 12 {
            #expect(index.markdown.contains("## Remaining coverage"))
            #expect(index.markdown.contains("Advanced applications"))
            #expect(await f.model.searchedQuestion.contains("up to 8"))
        }
        let calls = await f.model.counts
        try await execute(f)
        #expect(await f.model.counts == calls)
        #expect(try await f.store.documents().count == count + 1)
    }

    @Test func twelveExistingNotesCanCoverTheWholeSeriesWithoutCreatingNewNotes() async throws {
        let f = try await fixture(reuse: .all, savedCount: 12, topicCount: 12)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        #expect(await f.model.seenLibrary.count == 12)
        #expect(await f.model.counts["web"] == nil)
        #expect(await f.model.counts["draft"] == nil)
        #expect(try await f.store.documents().count == 13)
        for saved in f.saved {
            #expect(try await f.store.document(id: saved.id) == saved)
        }
    }

    @Test func oversizedSeriesFailsBeforeResearchAndItsBudgetCoversTwelveDraftRepairs(
    ) async throws {
        let f = try await fixture(topicCount: 13)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
        #expect(try await f.store.documents().isEmpty)
        #expect(await f.model.counts["web"] == nil)
        let worstCase = 3 + NoteSeries.maximumLibrarySources + NoteSeries.maximumWebSources +
            NoteSeries.maximumNotes * 4 + 2
        #expect(NoteSeries.maximumCalls >= worstCase)
        #expect(NoteSeries.webSourceLimit(newNotes: 1) == 4)
        #expect(NoteSeries.webSourceLimit(newNotes: 7) == 7)
        #expect(NoteSeries.webSourceLimit(newNotes: 12) == 8)
    }

    @Test func oldOutlinesRemainDecodableAndNewCoverageMetadataIsValidated() throws {
        let entry = NoteSeries.Entry(
            id: UUID(),
            title: "Focused concept",
            purpose: "Explain the concept",
            fields: ["meaning"],
            existingNoteID: nil
        )
        let encoder = JSONEncoder()
        var legacy = try #require(JSONSerialization
            .jsonObject(with: encoder.encode(NoteSeries.Outline(
                title: "Reading path",
                entries: [entry]
            ))) as? [String: Any])
        legacy.removeValue(forKey: "sizingReason")
        legacy.removeValue(forKey: "deferredCoverage")
        let decoded = try JSONDecoder().decode(
            NoteSeries.Outline.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.sizingReason.isEmpty)
        #expect(decoded.deferredCoverage.isEmpty)
        let brief = NoteSeries.Brief(query: "concept", mode: .fillGaps)
        try decoded.validate(library: [], brief: brief)
        for gaps in [
            ["Unsafe [link](javascript:bad)"],
            Array(repeating: "Same gap", count: 2),
            Array(repeating: "Gap", count: 25),
        ] {
            let invalid = NoteSeries.Outline(
                title: "Reading path",
                entries: [entry],
                sizingReason: "Focused scope.",
                deferredCoverage: gaps
            )
            #expect(throws: NoteSeries.Failure.self) { try invalid.validate(
                library: [],
                brief: brief
            ) }
        }
    }

    @Test func existingCoverageIsReusedWithoutWebSearchOrDuplicateNotes() async throws {
        let f = try await fixture(reuse: .all, savedCount: 2)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let run = try await run(f)
        #expect(try await f.store.documents().count == 3)
        let index = try #require(await f.store.document(id: run.indexID))
        for saved in f.saved {
            #expect(index.markdown.contains(saved.id.uuidString))
            #expect(try await f.store.document(id: saved.id) == saved)
        }
        #expect(await f.model.counts["web"] == nil)
        #expect(await f.model.counts["draft"] == nil)
        #expect(await f.fetcher.requests.isEmpty)
        #expect(await f.model.seenLibrary.count == 2)
        #expect(try await f.store.conversationMessages().last?.references.count == 3)
    }

    @Test func aSingleSufficientExistingNoteDoesNotForceRedundantNewNotes() async throws {
        let f = try await fixture(reuse: .all, savedCount: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        #expect(try await f.store.documents().count == 2)
        #expect(await f.model.counts["web"] == nil)
        #expect(await f.model.counts["draft"] == nil)
        let saved = try #require(f.saved.first)
        #expect(try await f.store.document(id: saved.id) == saved)
    }

    @Test func partialCoverageFillsOnlyGapsAndLinksExistingNotesWithoutSharingThemWithSearch(
    ) async throws {
        let f = try await fixture(reuse: .first, savedCount: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        #expect(try await f.store.documents().count == 3)
        let saved = try #require(f.saved.first)
        #expect(try await f.store.document(id: saved.id) == saved)
        let created = try #require(await f.store.documents()
            .first { $0.name == "Prompt evaluation" })
        #expect(created.markdown.contains(saved.id.uuidString))
        #expect(!created.markdown.contains("PRIVATE_FIXTURE"))
        #expect(await f.model.searchSourceCount == 0)
        #expect(await f.model.searchedQuestion.contains("PRIVATE_FIXTURE") == false)
        #expect(await f.model.counts["draft"] == 1)
    }

    @Test func curatorSearchesReferencedConceptsEvenWithoutSemanticIndexing() async throws {
        let f = try await fixture(reuse: .first)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let note = try await f.store.save(MarkdownDocument(
            name: "Writing clear instructions",
            markdown: seriesSourceText
        ))
        await f.model.setQueries(["clear instructions", "prompt evaluation"])
        try await execute(f)
        #expect(await f.model.seenLibrary.contains { $0.noteID == note.id })
        #expect(try await f.store.documents().count == 3)
        #expect(try await f.store.document(id: note.id) == note)
    }

    @Test func libraryOnlySeriesNeverUsesWebTools() async throws {
        let f = try await fixture(mode: .libraryOnly, savedCount: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        #expect(await f.model.counts["web"] == nil)
        #expect(await f.fetcher.requests.isEmpty)
        #expect(try await f.store.documents().count == 4)
    }

    @Test func failedSecondNoteResumesFromCheckpointAfterRestartWithoutDuplicatingResearch(
    ) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.configure(failSecond: true)
        await #expect(throws: ChatGPTError.self) { try await execute(f) }
        #expect(try await f.store.documents().isEmpty)
        let initial = try await run(f)
        let db = try await f.store.readyDatabase()
        #expect(try await db.read { try Int.fetchOne(
            $0,
            sql: "SELECT count(*) FROM note_series_artifacts WHERE kind = 'draft'"
        ) } == 1)
        let reopened = DocumentStore(url: f.store.url)
        _ = try await reopened.open()
        try await reopened.recoverConversation()
        try await reopened.retryNoteSeries(taskID: f.task)
        let resumed = try #require(await reopened.noteSeriesRun(taskID: f.task))
        #expect(resumed.id == initial.id)
        #expect(resumed.lease != initial.lease)
        let coordinator = AgentCoordinator(store: reopened, fetcher: f.fetcher, inference: f.model)
        try await coordinator.execute(taskID: f.task, request: "Original request", selected: []) {}
        #expect(try await reopened.documents().count == 3)
        #expect(await f.model.counts["plan"] == 1)
        #expect(await f.model.counts["outline"] == 1)
        #expect(await f.model.counts["web"] == 1)
        #expect(await f.model.counts["extract"] == 1)
        #expect(await f.model.counts["draft"] == 3)
        #expect(await f.fetcher.requests.count == 1)
    }

    @Test func draftDiagnosticsIdentifyStructuralAndVerifierFailures() throws {
        let sourceID = UUID()
        let text = "Alpha supports a clear purpose. Beta addresses a different purpose."
        let source = NoteSeries.Source(
            id: sourceID,
            title: "Fixture evidence",
            text: text,
            url: URL(string: "https://evidence.example.org/guide"),
            noteID: nil,
            revision: nil,
            contentHash: ContentHash.of(text),
            retrievedAt: Date(timeIntervalSince1970: 0),
            limitations: []
        )
        let entry = NoteSeries.Entry(
            id: UUID(),
            title: "Fixture concept",
            purpose: "Explain Alpha",
            fields: ["topic"],
            existingNoteID: nil
        )
        let dossier = NoteSeries.Dossier(sources: [source], facts: [
            .init(
                id: "allowed",
                sourceID: sourceID,
                field: "topic",
                value: "Alpha supports a clear purpose.",
                quote: "Alpha supports a clear purpose."
            ),
            .init(
                id: "other-topic",
                sourceID: sourceID,
                field: "other",
                value: "Beta addresses a different purpose.",
                quote: "Beta addresses a different purpose."
            ),
        ], unavailableURLs: [])
        try dossier.validate()
        let first = NoteSeries.Paragraph(
            text: "Alpha supports a clear purpose.",
            records: ["allowed"]
        )
        let second = NoteSeries.Paragraph(text: "Alpha has a clear purpose.", records: ["allowed"])
        let samples: [([NoteSeries.Paragraph], NoteSeries.DraftIssue)] = [
            ([first], .paragraphCount(1)),
            (Array(repeating: first, count: 9), .paragraphCount(9)),
            (
                [first, .init(text: first.text.uppercased(), records: first.records)],
                .repeatedParagraph(2)
            ),
            ([first, .init(text: "", records: first.records)], .invalidProse(2)),
            (
                [first, .init(text: String(repeating: "x", count: 1401), records: first.records)],
                .invalidProse(2)
            ),
            ([first, .init(text: "A line\nbreak", records: first.records)], .invalidProse(2)),
            ([first, .init(text: "A [link]", records: first.records)], .invalidProse(2)),
            ([first, .init(text: second.text, records: [])], .missingCitations(2)),
            (
                [first, .init(text: second.text, records: Array(repeating: "allowed", count: 9))],
                .excessiveCitations(2)
            ),
            (
                [first, .init(text: second.text, records: ["allowed", "allowed"])],
                .repeatedCitations(2)
            ),
            ([first, .init(text: second.text, records: ["unknown"])], .unknownCitations(2)),
            ([first, .init(text: second.text, records: ["other-topic"])], .unknownCitations(2)),
        ]
        for (paragraphs, issue) in samples {
            let draft = NoteSeries.Draft(paragraphs: paragraphs)
            #expect(draft.validationIssue(entry: entry, dossier: dossier) == issue)
            do {
                try draft.validate(entry: entry, dossier: dossier)
                Issue.record("Expected draft validation to fail")
            } catch let NoteSeries.Failure.draft(note, actual) {
                #expect(note == entry.title)
                #expect(actual == issue)
                #expect(!actual.message.isEmpty)
            }
            #expect(try JSONDecoder().decode(
                NoteSeries.DraftIssue.self,
                from: JSONEncoder().encode(issue)
            ) == issue)
        }
        let valid = NoteSeries.Draft(paragraphs: [first, second])
        try valid.validate(entry: entry, dossier: dossier)
        #expect(valid.verificationIssue(supported: [true, true]) == nil)
        #expect(valid.verificationIssue(supported: [true, false]) == .unverifiedParagraphs([2]))
        #expect(valid.verificationIssue(supported: [false, true]) == .unverifiedParagraphs([1]))
        #expect(valid.verificationIssue(supported: [false, false]) == .unverifiedParagraphs([1, 2]))
        for flags in [[], [false], [true, true, true]] {
            #expect(valid.verificationIssue(supported: flags) == .incompleteReview(
                expected: 2,
                actual: flags.count
            ))
        }
    }

    private func expectInsufficientTopic(_ f: Fixture, resuming: Bool = false) async throws {
        do {
            if resuming {
                try await resume(f)
            } else {
                try await execute(f)
            }
            Issue.record("Expected insufficient topic evidence")
        } catch let NoteSeries.Failure.insufficientTopicEvidence(note, reason) {
            #expect(note == "Prompt evaluation")
            #expect(!reason.isEmpty)
        }
    }

    @Test func targetedRecoveryReusesSavedEvidenceWithoutSearching() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.overlap])
        try await execute(f)
        #expect(await f.model.counts["topicAssess"] == 1)
        #expect(await f.model.counts["web"] == 1)
        #expect(await f.fetcher.requests.count == 1)
        let completed = try await run(f)
        let original = try #require(await f.store.seriesArtifact(
            completed,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ))
        let selected = try #require(await f.store.latestSeriesArtifact(
            completed,
            kind: .topicDossier,
            as: NoteSeries.Dossier.self
        ))
        #expect(selected.value.sources == original.value.sources)
        #expect(selected.value.facts == original.value.facts)
        #expect(selected.value.topicRecords?.count == 1)
        #expect(try await f.store.seriesArtifact(
            completed,
            kind: .topicSearchStarted,
            slot: #require(selected.value.topicRecords?.keys.first).uuidString,
            as: String.self
        ) == nil)
        #expect(try await f.store.documents().count == 3)
    }

    @Test func targetedResearchPublishesVerifiedNewEvidenceWithoutRewritingOtherNotes(
    ) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setTopicEvidence(.missing)
        await f.model.setCurationFaults([.overlap])
        try await execute(f)
        let completed = try await run(f)
        let outline = try #require(await f.store.seriesArtifact(
            completed,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let affected = try #require(outline.value.entries.last)
        let unchanged = try #require(outline.value.entries.first)
        let originals = try await savedDrafts(f)
        let reviewed = try #require(await f.store.seriesArtifact(
            completed,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries
                .self
        ))
        let evidence = try #require(reviewed.value.evidence)
        let base = try #require(await f.store.seriesArtifact(
            completed,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ))
        try evidence.validateExtending(base.value)
        #expect(reviewed.value.drafts[unchanged.id] == originals[unchanged.id]?.value)
        #expect(evidence.facts(for: unchanged) == base.value.facts(for: unchanged))
        #expect(evidence.topicRecords?[affected.id]?.allSatisfy { $0.hasPrefix("T") } == true)
        #expect(await f.model.counts["topicAssess"] == 2)
        #expect(await f.model.counts["web"] == 2)
        #expect(await f.model.counts["draft"] == 3)
        #expect(await f.fetcher.requests.count == 2)
        let queries = await f.model.searchedQuestions
        #expect(queries.last?.contains("targeted evaluation") == true)
        #expect(queries.last?.contains(affected.title) == false)
        #expect(queries.last?.contains("repeats the first draft") == false)
        #expect(await f.model.searchSourceCount == 0)
        let published = try #require(await f.store.document(id: affected.id))
        #expect(published.markdown.contains("https://research.example.org/targeted"))
        #expect(published.markdown.contains("held-out cases"))
        let external = try #require(await f.store.webResearchEvidence(noteID: affected.id))
        #expect(external.searchCount == 2)
        #expect(external.passages.flatMap(\.citations)
            .allSatisfy { $0.url.lastPathComponent == "targeted" })
        #expect(try await f.store.documents().count == 3)
    }

    @Test func insufficientTargetedEvidenceStopsWithoutRepeatingSearchOnRetry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        try await expectInsufficientTopic(f)
        #expect(try await f.store.documents().isEmpty)
        let calls = await f.model.counts
        let reads = await f.fetcher.requests
        #expect(calls["web"] == 2)
        #expect(calls["draft"] == 2)
        let failed = try await run(f)
        #expect(try await f.store.latestSeriesArtifact(
            failed,
            kind: .topicDossier,
            as: NoteSeries.Dossier.self
        ) == nil)
        try await expectInsufficientTopic(f, resuming: true)
        #expect(await f.model.counts == calls)
        #expect(await f.fetcher.requests == reads)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test(arguments: [true, false])
    func failedResearchedRevisionsAreTerminalWithoutRepeatedInference(
        unsupported: Bool
    ) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setTopicEvidence(.missing)
        await f.model.setCurationFaults(
            unsupported ? [.overlap] : [.overlap, .overlap],
            unsupportedRevisions: unsupported
        )
        try await expectInsufficientTopic(f)
        let calls = await f.model.counts
        #expect(calls["web"] == 2)
        #expect(try await f.store.documents().isEmpty)
        await f.model.setCurationFaults([])
        try await expectInsufficientTopic(f, resuming: true)
        var expected = calls
        expected["scopeProposal", default: 0] += 1
        #expect(await f.model.counts == expected)
        try await expectInsufficientTopic(f, resuming: true)
        #expect(await f.model.counts == expected)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func topicEvidenceSelectionsAreScopedAndOriginalEvidenceCannotBeChanged() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let completed = try await run(f)
        let base = try #require(await f.store.seriesArtifact(
            completed,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ))
        let outline = try #require(await f.store.seriesArtifact(
            completed,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let target = try #require(outline.value.entries.last)
        let first = try #require(outline.value.entries.first)
        let originalDrafts = try await savedDrafts(f)
        let draft = try #require(originalDrafts[target.id]?.value)
        await f.model.setTopicEvidence(.otherField)
        let feedback = NoteSeries.DraftFeedback(
            draft: draft,
            structurallyValid: true,
            supported: [true, true]
        )
        let plan = try await f.model.assessSeriesTopic(
            target,
            dossier: base.value,
            feedback: feedback
        )
        try plan.validate(dossier: base.value)
        var scoped = base.value
        scoped.topicRecords = [target.id: plan.records]
        try scoped.validateExtending(base.value)
        #expect(scoped.facts(for: target).allSatisfy { !target.fields.contains($0.field) })
        #expect(scoped.facts(for: first) == base.value.facts(for: first))
        var invalid = scoped
        invalid.topicRecords = [target.id: ["UNKNOWN_FIXTURE"]]
        #expect(throws: NoteSeries.Failure.self) { try invalid.validate() }
        let altered = NoteSeries.Dossier(
            sources: base.value.sources,
            facts: Array(base.value.facts.dropLast()),
            unavailableURLs: [],
            topicRecords: scoped.topicRecords
        )
        #expect(throws: NoteSeries.Failure.self) { try altered.validateExtending(base.value) }
        for plan in try [
            NoteSeries.TopicAssessment(
                sufficient: true,
                records: [],
                reason: "Missing coverage.",
                query: ""
            ),
            .init(
                sufficient: true,
                records: ["UNKNOWN_FIXTURE"],
                reason: "Unknown record.",
                query: ""
            ),
            .init(
                sufficient: true,
                records: Array(repeating: #require(base.value.facts.first?.id), count: 17),
                reason: "Too many records.",
                query: ""
            ),
            .init(
                sufficient: true,
                records: [#require(base.value.facts.first?.id)],
                reason: "Unexpected search query.",
                query: "public query"
            ),
        ] {
            #expect(throws: NoteSeries.Failure.self) { try plan.validate(dossier: base.value) }
        }
        let legacy = try JSONDecoder().decode(
            NoteSeries.Dossier.self,
            from: Data(#"{"sources":[],"facts":[],"unavailableURLs":[]}"#
                .utf8)
        )
        #expect(legacy.topicRecords == nil)
        #expect(legacy.recoverySearchCount == nil)
    }

    @Test func libraryOnlyRecoveryNeverSearchesTheWeb() async throws {
        let f = try await fixture(mode: .libraryOnly, savedCount: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setTopicEvidence(.missing)
        await f.model.setCurationFaults([.overlap])
        try await expectInsufficientTopic(f)
        #expect(await f.model.counts["web"] == nil)
        #expect(await f.fetcher.requests.isEmpty)
        #expect(try await f.store.documents().count == f.saved.count)
        for note in f.saved {
            #expect(try await f.store.document(id: note.id) == note)
        }
    }

    @Test(arguments: ["assessment", "revision", "search", "fetch"])
    func interruptedTopicRecoveryDoesNotRestartExternalWork(stage: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setTopicEvidence(
            .missing,
            cancelAfterResearch: stage == "assessment",
            cancelRevision: stage == "revision",
            cancelSearch: stage == "search"
        )
        if stage == "fetch" {
            await f.fetcher.cancelTargetDownload()
        }
        await f.model.setCurationFaults([.overlap])
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let before = await f.fetcher.requests
        let searches = await f.model.counts["web"]
        if ["search", "fetch"].contains(stage) {
            try await expectInsufficientTopic(f, resuming: true)
            #expect(try await f.store.documents().isEmpty)
        } else {
            try await resume(f)
            #expect(try await f.store.documents().count == 3)
        }
        #expect(await f.model.counts["web"] == searches)
        #expect(await f.fetcher.requests == before)
    }

    @Test(arguments: [true, false])
    func restoredTopicRevisionCountsAsTheResumeRepairPass(unsupported: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setTopicEvidence(.missing, cancelRevision: true)
        await f.model.setCurationFaults(
            unsupported ? [.overlap] : [.overlap, .overlap],
            unsupportedRevisions: unsupported
        )
        await #expect(throws: CancellationError.self) { try await execute(f) }
        try await expectInsufficientTopic(f, resuming: true)
        let calls = await f.model.counts
        #expect(calls["draft"] == (unsupported ? 5 : 4))
        #expect(calls["web"] == 2)
        try await expectInsufficientTopic(f, resuming: true)
        var expected = calls
        expected["scopeProposal", default: 0] += 1
        #expect(await f.model.counts == expected)
        try await expectInsufficientTopic(f, resuming: true)
        #expect(await f.model.counts == expected)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func targetedRecoveryRejectsInventedQuotesAndInvalidRecordSelections() async throws {
        for invalidSelection in [true, false] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            await f.model.setTopicEvidence(invalidSelection ? .invalid : .missing)
            if !invalidSelection {
                await f.model.inventTopicQuotes()
            }
            await f.model.setCurationFaults([.overlap])
            if invalidSelection {
                await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
                #expect(await f.model.counts["web"] == 1)
            } else {
                try await expectInsufficientTopic(f)
                #expect(await f.model.counts["web"] == 2)
                try await expectInsufficientTopic(f, resuming: true)
                #expect(await f.model.counts["web"] == 2)
            }
            #expect(try await f.store.documents().isEmpty)
            #expect(await f.model.counts["draft"] == 2)
        }
    }

    @Test func targetedResearchRemainsInsideTheOriginalModelCallBudget() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setTopicEvidence(.missing)
        await f.model.setCurationFaults([.overlap])
        let store = f.store
        await f.model.setOnCurate {
            let database = try await store.database()
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE note_series_runs SET calls = ?",
                    arguments: [NoteSeries.maximumCalls - 1]
                )
            }
        }
        await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
        let database = try await f.store.database()
        #expect(try await database.read { try Int.fetchOne(
            $0,
            sql: "SELECT calls FROM note_series_runs"
        ) } == NoteSeries.maximumCalls)
        #expect(await f.model.counts["topicAssess"] == 1)
        #expect(await f.model.counts["web"] == 1)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func evidenceDrivenNarrowingPublishesAllNotesWithExplicitDeferrals() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(.allow)
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        try await execute(f)
        let completed = try await run(f)
        let original = try #require(await f.store.seriesArtifact(
            completed,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let base = try #require(await f.store.seriesArtifact(
            completed,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ))
        let reviewed = try #require(await f.store.seriesArtifact(
            completed,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ))
        let scope = try #require(reviewed.value.scope)
        try scope.validate(original: original.value, dossier: base.value)
        #expect(scope.outline.entries.map(\.id) == original.value.entries.map(\.id))
        #expect(scope.outline.entries.first == original.value.entries.first)
        #expect(scope.outline.entries.last?.title == "Held-Out Evaluation")
        let affected = try #require(original.value.entries.last)
        let unchanged = try #require(original.value.entries.first)
        let originalDrafts = try await savedDrafts(f)
        #expect(reviewed.value.drafts[unchanged.id] == originalDrafts[unchanged.id]?.value)
        #expect(scope.outline.deferredCoverage.last?.contains("Audio prompting") == true)
        let index = try #require(await f.store.document(id: completed.indexID))
        #expect(index.markdown.contains("Remaining coverage"))
        #expect(index.markdown.contains("Held-Out Evaluation"))
        #expect(index.markdown.contains("Audio prompting"))
        let note = try #require(await f.store.document(id: affected.id))
        #expect(note.name == "Held-Out Evaluation")
        #expect(note.markdown.contains("held-out cases"))
        #expect(note.markdown.contains("https://research.example.org/targeted"))
        #expect(try await f.store.documents().count == 3)
        #expect(await f.model.counts["scopeProposal"] == 1)
        #expect(await f.model.counts["scopeReview"] == 1)
        #expect(await f.model.counts["web"] == 2)
        #expect(await f.model.counts["draft"] == 3)
    }

    @Test(arguments: [true, false])
    func narrowingCannotDropMandatoryCoverageOrPassUnsupportedScope(mandatory: Bool) async throws {
        let f =
            try await fixture(request: mandatory ?
                "Research prompts including audio prompting and explicit uncertainty guidance; write connected notes" :
                "Research prompt engineering and write connected notes")
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(mandatory ? .mandatory : .unsupported)
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        try await expectInsufficientTopic(f)
        #expect(try await f.store.documents().isEmpty)
        #expect(await f.model.counts["scopeProposal"] == 1)
        #expect(await f.model.counts["scopeReview"] == 1)
        #expect(await f.model.counts["draft"] == 2)
        let calls = await f.model.counts
        try await expectInsufficientTopic(f, resuming: true)
        #expect(await f.model.counts == calls)
        let failed = try await run(f)
        #expect(try await f.store.latestSeriesArtifact(
            failed,
            kind: .scopeBundle,
            as: NoteSeries.ScopeBundle.self
        ) == nil)
    }

    @Test(arguments: ["proposal", "review", "draft"])
    func scopeNarrowingResumesOldExhaustionWithoutRepeatingResearch(stage: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(
            .allow,
            cancelProposal: stage == "proposal",
            cancelReview: stage == "review",
            cancelDraft: stage == "draft"
        )
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let failed = try await run(f)
        let originalDrafts = try await savedDrafts(f)
        let sourceCalls = await f.model.counts["web"]
        let pages = await f.fetcher.requests
        #expect(try await f.store.documents().isEmpty)
        try await resume(f)
        #expect(try await f.store.documents().count == 3)
        #expect(await f.model.counts["web"] == sourceCalls)
        #expect(await f.fetcher.requests == pages)
        #expect(try await savedDrafts(f).mapValues(\.id) == originalDrafts.mapValues(\.id))
        let scope = try #require(try await f.store.latestSeriesArtifact(
            run(f),
            kind: .scopeBundle,
            as: NoteSeries.ScopeBundle.self
        ))
        let affected = try #require(scope.value.changes.first)
        // The old terminal marker stays immutable; only the independently approved scope supersedes
        // it.
        #expect(try await f.store.seriesArtifact(
            failed,
            kind: .topicExhausted,
            slot: affected.original.id.uuidString,
            as: String.self
        ) != nil)
    }

    @Test func narrowedDraftAndRequiredLinksSurviveAnotherFinalReviewFailure() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(.allow)
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap, .dropLinks])
        try await expectReviewFailure(f, kind: .droppedLink)
        let failed = try await run(f)
        let cached = try #require(await f.store.latestSeriesArtifact(
            failed,
            kind: .scopeDraft,
            as: NoteSeries.ScopedDraft.self
        ))
        let calls = await f.model.counts
        try await resume(f)
        #expect(try await f.store.documents().count == 3)
        #expect(await f.model.counts["draft"] == calls["draft"])
        #expect(await f.model.counts["scopeProposal"] == calls["scopeProposal"])
        #expect(await f.model.counts["scopeReview"] == calls["scopeReview"])
        #expect(await f.model.counts["web"] == calls["web"])
        #expect(try await f.store.latestSeriesArtifact(
            run(f),
            kind: .scopeDraft,
            as: NoteSeries.ScopedDraft.self
        )?.id == cached.id)
    }

    @Test(arguments: [true, false])
    func malformedScopeProposalsCannotRenameOrPublishNotes(invalidRecords: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(invalidRecords ? .invalidRecords : .hiddenDeferral)
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
        #expect(await f.model.counts["scopeReview"] == nil)
        #expect(await f.model.counts["draft"] == 2)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func narrowedScopeKeepsLibraryOnlyPolicyAndSavedSourcesIntact() async throws {
        let f = try await fixture(mode: .libraryOnly, savedCount: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(.allow)
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        try await execute(f)
        #expect(await f.model.counts["web"] == nil)
        #expect(await f.fetcher.requests.isEmpty)
        #expect(try await f.store.documents().count == f.saved.count + 3)
        for note in f.saved {
            #expect(try await f.store.document(id: note.id) == note)
        }
    }

    @Test func independentScopeReviewCannotExceedTheSharedCallBudget() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(.allow, cancelProposal: true)
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let database = try await f.store.database()
        try await database.write { db in
            try db.execute(
                sql: "UPDATE note_series_runs SET calls = ?",
                arguments: [NoteSeries.maximumCalls - 1]
            )
        }
        await #expect(throws: NoteSeries.Failure.self) { try await resume(f) }
        #expect(try await database.read { try Int.fetchOne(
            $0,
            sql: "SELECT calls FROM note_series_runs"
        ) } == NoteSeries.maximumCalls)
        #expect(await f.model.counts["scopeReview"] == nil)
        #expect(await f.model.counts["web"] == 2)
        #expect(try await f.store.documents().isEmpty)
        #expect(try await f.store.latestSeriesArtifact(
            run(f),
            kind: .scopeBundle,
            as: NoteSeries.ScopeBundle.self
        ) == nil)
    }

    @Test func scopeSnapshotValidationCannotChangeOtherNotesOrHideDeferrals() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setScopeMode(.allow)
        await f.model.setTopicEvidence(.insufficient)
        await f.model.setCurationFaults([.overlap])
        try await execute(f)
        let completed = try await run(f)
        let original = try #require(await f.store.seriesArtifact(
            completed,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let base = try #require(await f.store.seriesArtifact(
            completed,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ))
        let reviewed = try #require(await f.store.seriesArtifact(
            completed,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ))
        let scope = try #require(reviewed.value.scope)
        let hidden = NoteSeries.Outline(
            title: scope.outline.title,
            entries: scope.outline.entries,
            sizingReason: scope.outline.sizingReason,
            deferredCoverage: []
        )
        #expect(throws: NoteSeries.Failure.self) {
            try NoteSeries.ScopeBundle(
                outline: hidden,
                evidence: scope.evidence,
                changes: scope.changes
            )
            .validate(original: original.value, dossier: base.value)
        }
        let first = try #require(scope.outline.entries.first)
        let changed = NoteSeries.Entry(
            id: first.id,
            title: "Unrelated change",
            purpose: first.purpose,
            fields: first.fields,
            existingNoteID: first.existingNoteID
        )
        let altered = NoteSeries.Outline(
            title: scope.outline.title,
            entries: [changed] + scope.outline.entries.dropFirst(),
            sizingReason: scope.outline.sizingReason,
            deferredCoverage: scope.outline.deferredCoverage
        )
        #expect(throws: NoteSeries.Failure.self) {
            try NoteSeries.ScopeBundle(
                outline: altered,
                evidence: scope.evidence,
                changes: scope.changes
            )
            .validate(original: original.value, dossier: base.value)
        }
        let forged = NoteSeries.ReviewedSeries(
            drafts: reviewed.value.drafts,
            curation: reviewed.value.curation,
            requirements: reviewed.value.requirements,
            evidence: scope.evidence
        )
        #expect(throws: NoteSeries.Failure.self) { try forged.validate(
            outline: original.value,
            dossier: base.value
        ) }
    }

    @Test func paragraphReviewsRejectMalformedOrUnanchoredCritique() throws {
        let draft = NoteSeries.Draft(paragraphs: [
            .init(text: "An example is a test case.", records: ["F1"]),
            .init(text: "All outputs are guaranteed.", records: ["F1"]),
        ])
        let accepted = NoteSeries.ParagraphReview(
            paragraph: 1,
            verdict: .supported,
            claim: "",
            reason: ""
        )
        for verdict in [
            NoteSeries.ParagraphVerdict.unsupported,
            .offTopic,
            .unsupportedAndOffTopic,
        ] {
            let rejection = NoteSeries.ParagraphReview(
                paragraph: 2,
                verdict: verdict,
                claim: "All outputs are guaranteed.",
                reason: "The quotation covers one example, not all outputs."
            )
            #expect(draft
                .verificationIssue(reviews: [accepted, rejection]) ==
                .rejectedParagraphs([rejection]))
            #expect(try JSONDecoder().decode(
                NoteSeries.ParagraphReview.self,
                from: JSONEncoder().encode(rejection)
            ) == rejection)
        }
        let invalid: [NoteSeries.ParagraphReview] = [
            .init(paragraph: 1, verdict: .supported, claim: "", reason: ""),
            .init(paragraph: 2, verdict: .supported, claim: "All outputs", reason: ""),
            .init(
                paragraph: 2,
                verdict: .supported,
                claim: "",
                reason: "This verdict contradicts its explanation."
            ),
            .init(paragraph: 2, verdict: .unsupported, claim: "", reason: "Missing claim."),
            .init(paragraph: 2, verdict: .unsupported, claim: " ", reason: "Blank claim."),
            .init(
                paragraph: 2,
                verdict: .unsupported,
                claim: "Invented rejected text",
                reason: "A claim must match the paragraph."
            ),
            .init(paragraph: 2, verdict: .offTopic, claim: "All outputs", reason: ""),
            .init(
                paragraph: 2,
                verdict: .unsupported,
                claim: "All outputs",
                reason: String(repeating: "x", count: 401)
            ),
            .init(
                paragraph: 2,
                verdict: .unsupported,
                claim: "All outputs",
                reason: "An injected [link]"
            ),
        ]
        for review in invalid {
            #expect(draft.verificationIssue(reviews: [accepted, review]) == .invalidReview(2))
        }
        #expect(draft.verificationIssue(reviews: [accepted]) == .incompleteReview(
            expected: 2,
            actual: 1
        ))
        #expect(draft
            .verificationIssue(reviews: [accepted, accepted, accepted]) == .incompleteReview(
                expected: 2,
                actual: 3
            ))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NoteSeries.ParagraphReview.self, from: Data(
                #"{"paragraph":1,"verdict":"unknown","claim":"","reason":""}"#.utf8
            ))
        }
    }

    @Test func malformedReviewsNeverApproveOrPublishADraft() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setMalformedReview(true)
        do {
            try await execute(f)
            Issue.record("Expected malformed-review failure")
        } catch let NoteSeries.Failure.draft(_, issue) {
            #expect(issue == .invalidReview(1))
        }
        #expect(await f.model.counts["draft"] == 2)
        #expect(await f.model.counts["verify"] == 2)
        #expect(try await f.store.documents().isEmpty)
        let failed = try await run(f)
        let outline = try #require(await f.store.seriesArtifact(
            failed,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let entry = try #require(outline.value.entries.first)
        #expect(try await f.store.seriesArtifact(
            failed,
            kind: .draft,
            slot: entry.id.uuidString,
            as: NoteSeries.Draft.self
        ) == nil)
        let feedback = try #require(await f.store.latestSeriesArtifact(
            failed,
            kind: .draftFeedback,
            slotPrefix: entry.id
                .uuidString + ".",
            as: NoteSeries.DraftFeedback
                .self
        ))
        #expect(feedback.value.supported == [false, false])
        #expect(feedback.value.issue == .invalidReview(1))
    }

    @Test func overlapRepairReceivesExactCritiqueWithinAttemptsAndAcrossRetry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setCurationFaults([.overlap], unsupportedRevisions: true)
        try await expectReviewFailure(f, kind: .unsupportedRevision)
        let originals = try await savedDrafts(f)
        let failed = try await run(f)
        let affected = try #require(await f.model.revisedEntries.first)
        let attempt = try #require(await f.store.latestSeriesArtifact(
            failed,
            kind: .draftFeedback,
            slotPrefix: affected
                .uuidString + ".",
            as: NoteSeries.DraftFeedback
                .self
        ))
        let critique = try #require(attempt.value.reviews)
        #expect(critique.count == 2)
        for review in critique {
            #expect(review.verdict == .unsupported)
            #expect(!review.reason.isEmpty)
            #expect(attempt.value.draft.paragraphs[review.paragraph - 1].text
                .contains(review.claim))
        }
        let secondAttempt = try #require(await f.model.seenDraftFeedback.last ?? nil)
        #expect(secondAttempt.reviews == critique)
        #expect(secondAttempt.distinctness != nil)
        let count = await f.model.seenDraftFeedback.count
        await f.model.setCurationFaults([])
        try await resume(f)
        let received = await f.model.seenDraftFeedback
        let resumed = try #require(received[count])
        #expect(resumed.reviews == critique)
        #expect(resumed.draft == attempt.value.draft)
        #expect(try await savedDrafts(f).mapValues(\.id) == originals.mapValues(\.id))
        #expect(await f.model.counts["draft"] == 5)
        #expect(await f.model.counts["web"] == 1)
        #expect(try await f.store.documents().count == 3)
    }

    @Test func legacyDraftFeedbackRemainsDecodable() throws {
        let legacy = Data(#"{"draft":{"paragraphs":[]},"structurallyValid":false,"supported":[]}"#
            .utf8)
        let decoded = try JSONDecoder().decode(NoteSeries.DraftFeedback.self, from: legacy)
        #expect(decoded.issue == nil)
        #expect(decoded.distinctness == nil)
        #expect(decoded.reviews == nil)
        #expect(!decoded.structurallyValid)
    }

    @Test(arguments: SeriesFixture.DraftFault.allCases)
    private func initialDraftFailuresNameTheNoteAndResumeWithSavedFeedback(fault: SeriesFixture
        .DraftFault) async throws
    {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setDraftFault(fault)
        let expected: NoteSeries.DraftIssue? = switch fault {
        case .foreignCitation: .unknownCitations(2)
        case .formattedProse: .invalidProse(2)
        case .incompleteReview: .incompleteReview(expected: 2, actual: 1)
        case .unverified: nil
        }
        var failureIssue: NoteSeries.DraftIssue?
        do {
            try await execute(f)
            Issue.record("Expected an initial-draft failure")
        } catch let NoteSeries.Failure.draft(note, issue) {
            #expect(note == "Prompt evaluation")
            failureIssue = issue
            if let expected {
                #expect(issue == expected)
            } else {
                guard case let .rejectedParagraphs(reviews) = issue else {
                    Issue.record("Expected paragraph-level rejection feedback")
                    return
                }
                #expect(reviews.map(\.paragraph) == [2])
                #expect(reviews.first?.verdict == .unsupported)
                #expect(reviews.first?.reason.contains("not a guarantee") == true)
            }
            #expect(NoteSeries.Failure.draft(note: note, issue: issue).localizedDescription
                .contains("Nothing was published"))
        }
        let failed = try await run(f)
        let outline = try #require(await f.store.seriesArtifact(
            failed,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let first = try #require(outline.value.entries.first)
        let second = try #require(outline.value.entries.last)
        let original = try #require(await f.store.seriesArtifact(
            failed,
            kind: .draft,
            slot: first.id.uuidString,
            as: NoteSeries.Draft.self
        ))
        #expect(try await f.store.seriesArtifact(
            failed,
            kind: .draft,
            slot: second.id.uuidString,
            as: NoteSeries.Draft.self
        ) == nil)
        let feedback = try #require(await f.store.latestSeriesArtifact(
            failed,
            kind: .draftFeedback,
            slotPrefix: second.id
                .uuidString + ".",
            as: NoteSeries.DraftFeedback
                .self
        ))
        #expect(feedback.value.issue == failureIssue)
        #expect(try await f.store.documents().isEmpty)
        #expect(await f.model.counts["draft"] == 3)
        #expect(await f.model.counts["curate"] == nil)
        let calls = await f.model.counts
        await f.model.setDraftFault(nil)
        try await f.store.updateConversationTask(
            f.task,
            state: "failed",
            progress: "Fixture failure"
        )
        try await f.store.retryNoteSeries(taskID: f.task)
        let restarted = AgentCoordinator(store: f.store, fetcher: f.fetcher, inference: f.model)
        try await restarted.execute(taskID: f.task, request: f.request, selected: []) {}
        let received = try #require(await f.model.seenDraftFeedback.last ?? nil)
        #expect(received.issue == failureIssue)
        #expect(received.reviews == feedback.value.reviews)
        #expect(received.draft == feedback.value.draft)
        #expect(try await savedDrafts(f)[first.id]?.id == original.id)
        #expect(await f.model.counts["draft"] == 4)
        #expect(await f.model.counts["web"] == calls["web"])
        #expect(await f.model.counts["extract"] == calls["extract"])
        #expect(await f.model.counts["outline"] == calls["outline"])
        #expect(try await f.store.documents().count == 3)
    }

    @Test func retryDoesNotUseDraftFeedbackFromAnotherEvidenceCheckpoint() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setDraftFault(.unverified)
        await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
        let failed = try await run(f)
        let outline = try #require(await f.store.seriesArtifact(
            failed,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        let entry = try #require(outline.value.entries.last)
        let dossier = try #require(await f.store.seriesArtifact(
            failed,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ))
        let feedback = try #require(await f.store.latestSeriesArtifact(
            failed,
            kind: .draftFeedback,
            slotPrefix: entry.id
                .uuidString + ".",
            as: NoteSeries.DraftFeedback
                .self
        ))
        let other = try await f.store.checkpointSeries(
            failed,
            kind: .dossier,
            slot: "other-fixture-evidence",
            value: dossier.value,
            parents: []
        )
        try await f.store.checkpointSeries(
            failed,
            kind: .draftFeedback,
            slot: entry.id.uuidString + ".stale-fixture",
            value: feedback.value,
            parents: [other.id]
        )
        await f.model.setDraftFault(nil)
        try await resume(f)
        let received = await f.model.seenDraftFeedback
        #expect(received.last.flatMap(\.self) == nil)
        #expect(await f.model.counts["web"] == 1)
        #expect(try await f.store.documents().count == 3)
    }

    @Test @MainActor func freshChatDraftFailurePersistsItsDiagnosisAndRetryPreservesTheComposer(
    ) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.store.clearConversation()
        await f.model.setDraftFault(.unverified)
        let conversation = ConversationModel(store: f.store, coordinator: f.coordinator)
        await conversation.load()
        conversation.composer = f.request
        await conversation.send()
        try await waitForSeriesWorker(conversation)
        let failed = try #require(conversation.tasks.first { $0.state == "failed" })
        #expect(failed.progress.contains("Prompt evaluation"))
        #expect(failed.progress.contains("Paragraph 2"))
        #expect(failed.progress.contains("quotation support"))
        #expect(failed.progress.contains("not a guarantee for all outputs"))
        #expect(failed.progress.contains("Nothing was published"))
        #expect(try await f.store.documents().isEmpty)
        await f.model.setDraftFault(nil)
        let restarted = ConversationModel(
            store: f.store,
            coordinator: AgentCoordinator(
                store: f.store,
                fetcher: f.fetcher,
                inference: f.model
            )
        )
        await restarted.load()
        #expect(restarted.tasks.first { $0.id == failed.id }?.progress == failed.progress)
        restarted.composer = "Keep this unsent draft"
        await restarted.send(retry: failed)
        try await waitForSeriesWorker(restarted)
        #expect(restarted.tasks.first { $0.id == failed.id }?.state == "succeeded")
        #expect(restarted.composer == "Keep this unsent draft")
        #expect(await f.model.counts["web"] == 1)
        #expect(await f.model.counts["draft"] == 4)
    }

    @Test func writerReceivesVerificationFeedbackOnItsBoundedRepairAttempt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.configure(rejectFirstReview: true)
        try await execute(f)
        #expect(await f.model.counts["repair"] == 1)
        #expect(await f.model.counts["draft"] == 3)
        #expect(try await f.store.documents().count == 3)
    }

    @Test func explicitSelectionsJoinTheCuratorScopeButImplicitFollowupsDoNot() async throws {
        for explicit in [true, false] {
            let f = try await fixture(reuse: explicit ? .first : .none)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let note = try await f.store.save(MarkdownDocument(
                name: "Selected checklist",
                markdown: seriesSourceText
            ))
            try await f.coordinator.execute(
                taskID: f.task,
                request: "Research prompts and write connected notes",
                selected: [note.id],
                userSelected: explicit
            ) {}
            #expect(await f.model.seenLibrary.contains { $0.noteID == note.id } == explicit)
            #expect(try await f.store.document(id: note.id) == note)
        }
    }

    @Test func invalidClaimsLinksAndOutlineNeverPublishNotes() async throws {
        for failure in ["claims", "links", "outline"] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            await f.model.configure(
                unsupported: failure == "claims",
                badLinks: failure == "links",
                invalidOutline: failure == "outline"
            )
            await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
            #expect(try await f.store.documents().isEmpty)
            #expect(try await f.store.conversationMessages().filter { $0.author == "writer" }
                .isEmpty)
        }
    }

    @Test func changedLibrarySourcesFencePublicationAndPreserveTheUserEdit() async throws {
        let f = try await fixture(reuse: .first, savedCount: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let note = try #require(f.saved.first)
        let store = f.store
        await f.model.setOnCurate {
            _ = try await store.save(MarkdownDocument(
                id: note.id,
                name: note.name,
                markdown: "User changed this note.",
                revision: note.revision
            ))
        }
        await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
        #expect(try await f.store.documents().count == 1)
        #expect(try await f.store.document(id: note.id)?.markdown == "User changed this note.")
    }

    @Test func publicationFailureRollsBackEveryNoteLinkAndMessageThenRetriesIdempotently(
    ) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let db = try await f.store.readyDatabase()
        try await db
            .write {
                try $0
                    .execute(
                        sql: "CREATE TRIGGER series_fixture_failure BEFORE INSERT ON notes WHEN NEW.name = 'Prompt evaluation' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
                    )
            }
        await #expect(throws: DatabaseError.self) { try await execute(f) }
        #expect(try await f.store.documents().isEmpty)
        #expect(try await db.read { try Int.fetchOne(
            $0,
            sql: "SELECT count(*) FROM authored_artifacts"
        ) } == 0)
        #expect(try await db
            .read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note_links") } == 0)
        let counts = await f.model.counts
        try await db.write { try $0.execute(sql: "DROP TRIGGER series_fixture_failure") }
        try await execute(f)
        #expect(await f.model.counts == counts)
        #expect(try await f.store.documents().count == 3)
        #expect(try await f.store.conversationMessages().filter { $0.author == "writer" }
            .count == 1)
        let run = try await run(f)
        _ = try await f.store.publishNoteSeries(run)
        #expect(try await f.store.documents().count == 3)
    }

    @Test func cancelledAndSupersededLeasesCannotCheckpointOrPublish() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.configure(failSecond: true)
        await #expect(throws: ChatGPTError.self) { try await execute(f) }
        let old = try await run(f)
        try await f.store.updateConversationTask(f.task, state: "cancelled", progress: "Cancelled")
        await #expect(throws: CancellationError.self) { try await f.store.checkpointSeries(
            old,
            kind: .curation,
            value: NoteSeries.Curation(distinct: true, links: []),
            parents: []
        ) }
        try await f.store.retryNoteSeries(taskID: f.task)
        await #expect(throws: CancellationError.self) { try await f.store.checkpointSeries(
            old,
            kind: .curation,
            value: NoteSeries.Curation(distinct: true, links: []),
            parents: []
        ) }
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func budgetAndArtifactOwnershipAreEnforcedOutsideTheModel() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await f.store.beginNoteSeries(
            taskID: f.task,
            request: "Fixture",
            provider: "series-fixture",
            style: .plain,
            selected: []
        )
        for _ in 0 ..< NoteSeries.maximumCalls {
            try await f.store.reserveSeriesCall(run)
        }
        await #expect(throws: NoteSeries.Failure.self) { try await f.store.reserveSeriesCall(run) }
        await #expect(throws: NoteSeries.Failure.self) { try await f.store.checkpointSeries(
            run,
            kind: .brief,
            value: NoteSeries.Brief(query: "prompt", mode: .fillGaps),
            parents: [UUID()]
        ) }
        let artifact = try await f.store.checkpointSeries(
            run,
            kind: .brief,
            value: NoteSeries.Brief(query: "prompt", mode: .fillGaps),
            parents: []
        )
        let db = try await f.store.readyDatabase()
        try await db.write { try $0.execute(
            sql: "UPDATE note_series_artifacts SET payload = ? WHERE id = ?",
            arguments: [Data("{}".utf8), artifact.id.uuidString]
        ) }
        await #expect(throws: NoteSeries.Failure.self) { try await f.store.seriesArtifact(
            run,
            kind: .brief,
            as: NoteSeries.Brief.self
        ) }
    }

    @Test func inaccessibleWebPagesDoNotBecomeEvidenceAndCanBeRetried() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.fetcher.setFailure(true)
        await #expect(throws: NoteSeries.Failure.self) { try await execute(f) }
        #expect(try await f.store.documents().isEmpty)
        await f.fetcher.setFailure(false)
        try await execute(f)
        #expect(await f.model.counts["web"] == 1)
        #expect(try await f.store.documents().count == 3)
    }

    @Test func plannerRoutesCompoundSeriesAsOneOperationAndRejectsMixedMutations() throws {
        let context = ConversationPlanningContext(
            purpose: "request",
            history: [],
            records: [],
            categories: []
        )
        let plan = try ConversationPlan.decode(
            Data(
                #"{"steps":[{"action":"researchSeries","argument":"Research prompt engineering and write notes","categoryCode":"","targets":[]}]}"#
                    .utf8
            ),
            context: context
        )
        try plan.validate(context: context, hasURL: false)
        #expect(plan.steps.first?.action.owner == .writer)
        #expect(throws: ConversationError.self) { try ConversationPlan(steps: plan.steps + [.init(
            action: .saveNote,
            argument: "Other"
        )]).validate(context: context, hasURL: false) }
    }

    @Test func upgradingExistingAuthoredArtifactsPreservesOrdinaryNotesAndAllowsSeriesMembers(
    ) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try await f.store.saveResearch(
            "An existing ordinary research note.",
            name: "Original research",
            sources: [],
            taskID: f.task,
            provider: "fixture"
        )
        let db = try await f.store.readyDatabase()
        try await db.write { db in
            try db.execute(sql: """
            DROP TABLE note_series_members;
            DROP TABLE note_series_artifacts;
            DROP TABLE note_series_runs;
            CREATE TABLE authored_artifacts_old (
                noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                taskID TEXT UNIQUE NOT NULL REFERENCES conversation_tasks(id), kind TEXT NOT NULL,
                provider TEXT NOT NULL, createdAt REAL NOT NULL
            );
            INSERT INTO authored_artifacts_old SELECT * FROM authored_artifacts;
            DROP TABLE authored_artifacts;
            ALTER TABLE authored_artifacts_old RENAME TO authored_artifacts;
            DELETE FROM grdb_migrations WHERE identifier = 'note-series-v1';
            """)
        }
        let reopened = DocumentStore(url: f.store.url)
        _ = try await reopened.open()
        #expect(try await reopened.document(id: original.id) == original)
        let other = try await reopened.save(MarkdownDocument(
            name: "Ordinary fixture",
            markdown: "Synthetic content"
        ))
        let migrated = try await reopened.readyDatabase()
        await #expect(throws: DatabaseError.self) {
            try await migrated.write { try $0.execute(
                sql: "INSERT INTO authored_artifacts VALUES (?,?,'research','fixture',0)",
                arguments: [other.id.uuidString, f.task.uuidString]
            ) }
        }
        let task = try await reopened.beginConversation(
            "Research prompts and write notes",
            owner: .assistant
        )
        let coordinator = AgentCoordinator(store: reopened, fetcher: f.fetcher, inference: f.model)
        try await coordinator.execute(
            taskID: task,
            request: "Research prompts and write notes",
            selected: []
        ) {}
        #expect(try await migrated.read { try Int.fetchOne(
            $0,
            sql: "SELECT count(*) FROM authored_artifacts"
        ) } == 4)
        #expect(try await reopened.document(id: original.id) == original)
    }

    @MainActor @Test func conversationCancellationAndRetryResumeTheSameDurableTask() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let conversation = ConversationModel(store: f.store, coordinator: f.coordinator)
        await conversation.load()
        await f.model.setOnCurate { try await Task.sleep(for: .seconds(10)) }
        conversation.composer = "Research prompts and write two connected notes"
        await conversation.send()
        for _ in 0 ..< 300 where await f.model.counts["curate"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await f.model.counts["curate"] == 1)
        await conversation.cancel()
        #expect(!conversation.running)
        let task = try #require(conversation.tasks.first)
        #expect(task.state == "cancelled")
        #expect(try await f.store.documents().isEmpty)
        let counts = await f.model.counts
        await f.model.setOnCurate {}
        conversation.composer = "Keep this unsent draft"
        await conversation.send(retry: task)
        for _ in 0 ..< 300
            where conversation.running
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(conversation.tasks.first?.id == task.id)
        #expect(conversation.tasks.first?.state == "succeeded")
        #expect(conversation.composer == "Keep this unsent draft")
        #expect(await f.model.counts["web"] == counts["web"])
        #expect(await f.model.counts["draft"] == counts["draft"])
        #expect(try await f.store.documents().count == 3)
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_LIVE_NOTE_SERIES_SIZING"] == "1"))
    func liveSIWCChoosesCoverageDrivenBreadthWithoutANoteCount() async throws {
        let session = ChatGPTSession()
        let choice = try #require(await session.catalog().first)
        let provider = ChatGPTConversationInference(session: session, model: choice.slug)
        let brief = NoteSeries.Brief(query: "distributed systems", mode: .fillGaps)
        let broadRequest = "Research distributed systems and build a connected foundational-to-advanced note collection. Cover architectures and communication, time and ordering, replication, consistency, consensus, transactions, sharding, failure handling, coordination, security, performance, stream processing, testing and operations. Choose scope from meaningful concepts, not an arbitrary note quota; identify important coverage left outside this run."
        let broad = try await provider.seriesOutline(
            request: broadRequest,
            brief: brief,
            library: [],
            style: .plain
        )
        try broad.validate(library: [], brief: brief)
        #expect(broad.entries.count > 3)
        #expect(broad.entries.count <= 12)
        if broad.entries.count == 12 {
            #expect(!broad.deferredCoverage.isEmpty)
        }
        #expect(try await provider.reviewSeriesOutline(broad, request: broadRequest, library: []))
        let focusedRequest = "Research the meaning of idempotency and write connected notes if useful. Keep the scope to its definition and a simple illustration; implementations, retry strategies, distributed protocols and operational concerns are outside this request. Do not split a focused concept merely to produce multiple notes."
        let focusedBrief = NoteSeries.Brief(query: "idempotency definition", mode: .fillGaps)
        let focused = try await provider.seriesOutline(
            request: focusedRequest,
            brief: focusedBrief,
            library: [],
            style: .plain
        )
        try focused.validate(library: [], brief: focusedBrief)
        #expect(focused.entries.count < broad.entries.count)
        #expect(focused.entries.count <= 2)
        #expect(try await provider.reviewSeriesOutline(
            focused,
            request: focusedRequest,
            library: []
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(["broad": broad, "focused": focused])
            .write(to: FileManager.default.temporaryDirectory
                .appending(path: "gleanary-sizing-live-outlines.json"))
        print(
            "Live coverage sizing: broad subject selected \(broad.entries.count) topics; focused subject selected \(focused.entries.count)."
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_NOTE_SERIES"] == "1"))
    func liveSIWCResearchSeriesReusesPKMSAndPublishesVerifiedLinkedNotes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gleanary-series-live-library-v2")
        var succeeded = false
        defer {
            if succeeded {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let saved = try await store.documents()
        let existing: MarkdownDocument = if let note = saved
            .first(where: { $0.name == "Writing clear instructions" })
        {
            note
        } else {
            try await store.save(MarkdownDocument(
                name: "Writing clear instructions",
                markdown: "Clear instructions tell a language model what task to perform. State the desired output format and relevant constraints. Separate instructions from input data so their roles are clear. Give the model relevant context rather than expecting it to infer missing information. Explicit instructions make the intended task easier to understand; they do not guarantee correct outputs."
            ))
        }
        let session = ChatGPTSession()
        let choice = try #require(await session.catalog().first)
        let provider = ChatGPTConversationInference(session: session, model: choice.slug)
        let coordinator = AgentCoordinator(store: store, inference: provider)
        let request = "Research prompt engineering and write a series of two connected notes: reuse my existing note on writing clear instructions if sufficient, and cover evaluating prompts as the other topic. Use the web to research evaluation methods."
        let task: UUID
        if let previous = try await store.conversationTasks().first {
            task = previous.id
            if previous.state != "succeeded" {
                try await store.recoverConversation()
                try await store.retryNoteSeries(taskID: task)
            }
        } else {
            task = try await store.beginConversation(request, owner: .assistant)
        }
        do { try await coordinator.execute(taskID: task, request: request, selected: []) {} }
        catch {
            let db = try await store.readyDatabase()
            let artifacts = try await db.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT kind, slot, payload FROM note_series_artifacts ORDER BY createdAt"
                ).map { row in
                    [
                        "kind": row["kind"] as String,
                        "slot": row["slot"] as String,
                        "payload": String(decoding: row["payload"] as Data, as: UTF8.self),
                    ]
                }
            }
            try JSONEncoder().encode(artifacts)
                .write(to: FileManager.default.temporaryDirectory
                    .appending(path: "gleanary-series-live-failure.json"))
            throw error
        }
        let run = try #require(await store.noteSeriesRun(taskID: task))
        #expect(run.published)
        let outline = try #require(await store.seriesArtifact(
            run,
            kind: .outline,
            as: NoteSeries.Outline.self
        ))
        #expect(outline.value.entries.contains { $0.existingNoteID == existing.id })
        let notes = try await store.documents()
        #expect(notes.count >= 3)
        #expect(try await store.document(id: existing.id) == existing)
        let created = notes.filter { $0.id != existing.id && $0.id != run.indexID }
        #expect(created.contains { $0.markdown.contains(existing.id.uuidString) })
        #expect(created
            .allSatisfy {
                $0.markdown.contains("https://") && $0.markdown.contains(run.indexID.uuidString)
            })
        let dossier = try #require(await store.seriesArtifact(
            run,
            kind: .dossier,
            as: NoteSeries.Dossier.self
        ))
        #expect(dossier.value.sources.contains { $0.noteID == nil && $0.url != nil })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(notes)
            .write(to: FileManager.default.temporaryDirectory
                .appending(path: "gleanary-series-live-notes.json"))
        try encoder.encode(dossier.value)
            .write(to: FileManager.default.temporaryDirectory
                .appending(path: "gleanary-series-live-evidence.json"))
        succeeded = true
        print(
            "Live note series published \(created.count) new notes plus an index, reusing an existing synthetic note."
        )
    }
}
