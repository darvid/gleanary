import Foundation
@testable import Gleanary
import GRDB
import Testing

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
    func setFailure(_ value: Bool) {
        fail = value
    }

    func fetch(_ url: URL) async throws -> DownloadedContent {
        requests.append(url)
        if fail {
            throw CaptureError.downloadFailed
        }
        let text: String = if let group = Int(url.lastPathComponent.replacingOccurrences(
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

    func setOnCurate(_ action: @escaping @Sendable () async throws -> Void) {
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
        library: [NoteSeries.Source]
    ) throws -> NoteSeries.Outline {
        count("outline")
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
        searchSourceCount = sources.count
        await progress("Searching fixture web sources")
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

    func draftSeriesNote(
        _ entry: NoteSeries.Entry,
        dossier: NoteSeries.Dossier,
        style _: WritingStyle,
        feedback: NoteSeries.DraftFeedback?
    ) throws -> NoteSeries.Draft {
        count("draft")
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
        return .init(paragraphs: chosen.map { .init(text: $0.value, records: [$0.id]) })
    }

    func verifySeriesDraft(
        _ draft: NoteSeries.Draft,
        entry _: NoteSeries.Entry,
        dossier _: NoteSeries.Dossier
    ) -> [Bool] {
        count("verify")
        if rejectFirstReview, counts["verify"] == 1 {
            return Array(
                repeating: false,
                count: draft.paragraphs.count
            )
        }
        return Array(repeating: !unsupported, count: draft.paragraphs.count)
    }

    func curateSeries(
        _ outline: NoteSeries.Outline,
        drafts: [UUID: NoteSeries.Draft],
        library _: [NoteSeries.Source]
    ) async throws -> NoteSeries.Curation {
        count("curate")
        try await onCurate?()
        guard let source = outline.entries.first(where: { drafts[$0.id] != nil }),
              let target = outline.entries.first(where: { $0.id != source.id }),
              let text = drafts[source.id]?.paragraphs.first?.text
        else { return .init(
            distinct: true,
            links: []
        ) }
        let anchor = String(text.split(separator: " ").prefix(2).joined(separator: " "))
        return .init(
            distinct: true,
            links: [.init(
                from: source.id,
                to: badLinks ? UUID() : target.existingNoteID ?? target.id,
                paragraph: 0,
                anchor: anchor,
                reason: "A related concept in this reading path"
            )]
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
    }

    private func fixture(
        reuse: SeriesFixture.Reuse = .none,
        mode: NoteSeries.SourceMode = .fillGaps,
        savedCount: Int = 0,
        topicCount: Int = 2
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
        let coordinator = AgentCoordinator(store: store, fetcher: fetcher, inference: model)
        let task = try await store.beginConversation(
            "Research prompt engineering and write two connected notes",
            owner: .assistant
        )
        return Fixture(
            root: root,
            store: store,
            model: model,
            fetcher: fetcher,
            coordinator: coordinator,
            task: task,
            saved: saved
        )
    }

    private func execute(_ fixture: Fixture) async throws {
        try await fixture.coordinator.execute(
            taskID: fixture.task,
            request: "Research prompt engineering and write two connected notes",
            selected: []
        ) {}
    }

    private func run(_ fixture: Fixture) async throws -> NoteSeries
        .Run
    {
        try #require(await fixture.store.noteSeriesRun(taskID: fixture.task))
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
            library: []
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
            library: []
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
