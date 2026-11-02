import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

private enum ResearchFixtureError: Error { case unexpected }

private let practiceSentences = [
    "Clear instructions define the desired task and output.",
    "Examples demonstrate the expected response format.",
    "Evaluation compares outputs against task-specific criteria.",
]

private actor ResearchFixtureFetcher: SourceFetching {
    var requests = 0
    var cancel = false
    func cancelNext() {
        cancel = true
    }

    func fetch(_ url: URL) throws -> DownloadedContent {
        requests += 1
        if cancel {
            cancel = false; throw CancellationError()
        }
        return .init(
            data: Data(practiceSentences.joined(separator: " ").utf8),
            url: url,
            mime: "text/plain",
            encoding: "utf-8"
        )
    }
}

private actor ResearchFixture: ConversationInferring, EvidenceSeriesInferring, WebResearching {
    let capabilities = InferenceCapabilities(
        identifier: "fixture.evidence",
        local: false,
        structured: true,
        streaming: true
    )
    var mode: NoteSeries.SourceMode = .freshWeb
    var counts: [String: Int] = [:]
    var writes: [UUID: Int] = [:]
    var cancellation: String?
    var editorialTargets: [Int] = []
    var repeatIssue = false
    var rejectPlan = false
    var reuse = false
    var requiredEdge = false
    var omitSuggestedEdge = false
    var filingCode = ""
    var filingNewCategory = ""
    var filingConfident = false
    var filingAlternate: String?
    var filingFails = false
    var filingCallback: (@Sendable () async throws -> Void)?

    func configureFiling(
        code: String = "",
        newCategory: String = "",
        confident: Bool = false,
        alternate: String? = nil,
        fails: Bool = false,
        callback: (@Sendable () async throws -> Void)? = nil
    ) {
        filingCode = code; filingNewCategory = newCategory; filingConfident = confident
        filingAlternate = alternate; filingFails = fails; filingCallback = callback
    }

    func classifyBookmarks(
        _ items: [BookmarkClassification.Item],
        categories _: [DecimalCategory],
        examples _: [UUID: [String]]
    ) async throws
        -> [BookmarkClassification.Answer]
    {
        try call("filing")
        try await filingCallback?()
        if filingFails {
            throw ResearchFixtureError.unexpected
        }
        return items.map { .init(
            item: $0.number,
            code: $0
                .number == 2 ? (filingAlternate ?? filingCode) : filingCode,
            newCategory: filingNewCategory,
            confident: filingConfident
        ) }
    }

    func configure(
        mode: NoteSeries.SourceMode = .freshWeb,
        cancel: String? = nil,
        edits: [Int] = [],
        repeatIssue: Bool = false,
        rejectPlan: Bool = false,
        reuse: Bool = false,
        requiredEdge: Bool = false,
        omitSuggestedEdge: Bool = false
    ) {
        self.mode = mode; cancellation = cancel; editorialTargets = edits; self
            .repeatIssue = repeatIssue
        self.rejectPlan = rejectPlan; self.reuse = reuse; self.requiredEdge = requiredEdge; self
            .omitSuggestedEdge = omitSuggestedEdge
    }

    private func call(_ name: String) throws {
        counts[name, default: 0] += 1
        if cancellation == name {
            cancellation = nil; throw CancellationError()
        }
    }

    func plan(
        request: String,
        context _: ConversationPlanningContext
    )
        -> ConversationPlan
    {
        .init(steps: [.init(action: .researchSeries, argument: request)])
    }

    func researchTitle(for _: String) throws -> String {
        throw ResearchFixtureError.unexpected
    }

    nonisolated func research(
        question _: String,
        sources _: [ResearchSource]
    )
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish(throwing: ResearchFixtureError.unexpected) }
    }

    nonisolated func reply(
        question _: String,
        role _: AgentRole,
        history _: [ConversationTurn]
    )
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish(throwing: ResearchFixtureError.unexpected) }
    }

    func mapFolders(
        _: [FolderMapping.Folder],
        categories _: [DecimalCategory],
        withSamples _: Bool,
        progress _: @escaping @Sendable ([FolderMapping.Answer]) -> Void
    ) throws -> [FolderMapping.Answer] {
        throw ResearchFixtureError.unexpected
    }

    func classifyBookmarks(
        _: [BookmarkClassification.Item],
        categories _: [DecimalCategory],
        examples _: [UUID: [String]]
    ) throws -> [BookmarkClassification.Answer] {
        throw ResearchFixtureError.unexpected
    }

    func researchSeriesIntent(request: String) throws -> ResearchSeries.Intent {
        try call("intent")
        return .init(
            brief: .init(query: "prompt practices", mode: mode, libraryQueries: ["prompt"]),
            requirements: [.init(id: "R1", quote: request, coverage: "Explain prompt practices")],
            fields: ["practice"],
            preferredDomains: [],
            requestedCount: 0,
            countQuote: "",
            connected: true
        )
    }

    func researchWeb(
        question _: String,
        sources _: [ResearchSource],
        progress _: @escaping @Sendable (String) async -> Void
    ) throws -> WebResearchResult {
        try call("search")
        let url = try #require(URL(string: "https://docs.example.org/practices"))
        return .init(
            passages: [.init(
                text: "Public research [cite].",
                citations: [.init(
                    startIndex: 16,
                    endIndex: 22,
                    title: "Practice evidence",
                    url: url
                )]
            )],
            consultedURLs: [url],
            searchCount: 1
        )
    }

    func extractSeriesFacts(_: ExtractionChunk) throws -> [ExtractedFact] {
        try call("extract")
        return practiceSentences.map { .init(
            subject: "prompt",
            field: "practice",
            value: $0,
            quote: $0
        ) }
    }

    func evidenceSeriesPlan(
        request _: String,
        intent _: ResearchSeries.Intent,
        evidence: NoteSeries.Dossier,
        previous _: ResearchSeries.Plan?,
        feedback _: String?
    ) throws -> ResearchSeries.Plan {
        try call("plan")
        if reuse, let source = evidence.sources.first(where: { $0.noteID != nil }) {
            let entry = NoteSeries.Entry(
                id: UUID(),
                title: source.title,
                purpose: "Explain prompt practices",
                fields: ["practice"],
                existingNoteID: source.noteID
            )
            return .init(
                outline: .init(title: "Prompt reading path", entries: [entry]),
                contracts: [.init(
                    entry: entry,
                    records: [],
                    sharedRecords: [],
                    excludes: [],
                    requirements: ["R1"]
                )],
                relationships: []
            )
        }
        let titles = ["Clear instructions", "Demonstrations", "Evaluation"]
        let web = Set(evidence.sources.filter { $0.noteID == nil }.map(\.id))
        let facts = mode == .freshWeb ? evidence.facts
            .filter { web.contains($0.sourceID) } : evidence.facts
        let contracts = facts.prefix(3).enumerated().map { index, fact in
            ResearchSeries.Contract(
                entry: .init(
                    id: UUID(),
                    title: titles[index],
                    purpose: "Explain \(titles[index])",
                    fields: ["practice"],
                    existingNoteID: nil
                ),
                records: [fact.id],
                sharedRecords: [],
                excludes: titles.filter { $0 != titles[index] },
                requirements: index == 0 ? ["R1"] : []
            )
        }
        guard contracts.count == 3 else { throw ResearchSeries.Failure.invalidPlan }
        return .init(
            outline: .init(title: "Prompt reading path", entries: contracts.map(\.entry)),
            contracts: contracts,
            relationships: [.init(
                from: contracts[1].entry.id,
                to: contracts[2].entry.id,
                reason: "Evaluation checks demonstrations",
                requirements: requiredEdge ? ["R1"] : []
            )]
        )
    }

    func reviewEvidenceSeriesPlan(
        request _: String,
        intent _: ResearchSeries.Intent,
        plan _: ResearchSeries.Plan,
        evidence _: NoteSeries.Dossier
    ) throws -> ResearchSeries.PlanReview {
        try call("planReview")
        return .init(
            valid: !rejectPlan,
            reason: rejectPlan ? "Explicitly requested coverage is unavailable." : "The distinct contracts are supported by the retained quotations."
        )
    }

    func writeEvidenceSeriesNote(
        request _: String,
        contract: ResearchSeries.Contract,
        plan _: ResearchSeries.Plan,
        evidence: NoteSeries.Dossier,
        style _: WritingStyle,
        feedback _: String?
    ) throws -> NoteSeries.Draft {
        try call("write")
        writes[contract.entry.id, default: 0] += 1
        let fact = try #require(evidence.facts.first { contract.records.contains($0.id) })
        return .init(paragraphs: [.init(text: fact.quote, records: [fact.id])])
    }

    func verifySeriesDraft(
        _ draft: NoteSeries.Draft,
        entry _: NoteSeries.Entry,
        dossier _: NoteSeries.Dossier
    ) throws -> [NoteSeries.ParagraphReview] {
        try call("verify")
        return draft.paragraphs.indices.map { .init(
            paragraph: $0 + 1,
            verdict: .supported,
            claim: "",
            reason: ""
        ) }
    }

    func editEvidenceSeries(
        request _: String,
        intent _: ResearchSeries.Intent,
        plan: ResearchSeries.Plan,
        drafts: [UUID: NoteSeries.Draft],
        evidence _: NoteSeries.Dossier,
        feedback _: String?
    ) throws -> ResearchSeries.EditorialReview {
        try call("edit")
        guard plan.contracts.count > 1 else { return .init(issues: [], links: []) }
        let entries = plan.contracts.map(\.entry)
        let issueIndex: Int? = if repeatIssue {
            0
        } else if !editorialTargets.isEmpty {
            editorialTargets.removeFirst()
        } else {
            nil
        }
        let issues: [ResearchSeries.EditorialIssue] = try issueIndex.map { index in
            let paragraph = try #require(drafts[entries[index].id]?.paragraphs.first)
            return [.init(
                noteID: entries[index].id,
                comparisonID: nil,
                claim: paragraph.text,
                reason: "Focus the note on its assigned evidence-backed contribution."
            )]
        } ?? []
        let links = [
            NoteSeries.Link(
                from: entries[0].id,
                to: entries[1].id,
                paragraph: 0,
                anchor: "",
                reason: "Demonstrations clarify instructions"
            ),
            .init(
                from: omitSuggestedEdge ? entries[2].id : entries[1].id,
                to: omitSuggestedEdge ? entries[0].id : entries[2].id,
                paragraph: 0,
                anchor: "",
                reason: "Evaluation checks prompt behavior"
            ),
        ]
        return .init(issues: issues, links: links)
    }
}

private let promptEngineeringRequest = "can you research prompt engineering best practices in 2026 starting with official documentation from frontier labs, and document them for me with relations to related concepts clustered around that knowledge?"

@Suite(.serialized) struct ResearchSeriesTests {
    private struct Fixture {
        let root: URL
        let store: DocumentStore
        let provider: ResearchFixture
        let fetcher: ResearchFixtureFetcher
        let coordinator: AgentCoordinator
        let task: UUID
    }

    private let request = "Research prompt practices and connect the concepts"
    private func fixture(saved: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "research-fixture-\(UUID().uuidString)")
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        if saved {
            _ = try await store.save(MarkdownDocument(
                name: "Saved prompt practices",
                markdown: practiceSentences.joined(separator: " ")
            ))
        }
        let provider = ResearchFixture()
        let fetcher = ResearchFixtureFetcher()
        let coordinator = AgentCoordinator(store: store, fetcher: fetcher, inference: provider)
        let task = try await store.beginConversation(request, owner: .assistant)
        return .init(
            root: root,
            store: store,
            provider: provider,
            fetcher: fetcher,
            coordinator: coordinator,
            task: task
        )
    }

    private func execute(_ fixture: Fixture) async throws {
        try await fixture.coordinator
            .execute(taskID: fixture.task, request: request, selected: []) {}
    }

    private func resume(_ fixture: Fixture) async throws {
        try await fixture.store.updateConversationTask(
            fixture.task,
            state: "failed",
            progress: "Fixture interrupted"
        )
        try await fixture.store.retryNoteSeries(taskID: fixture.task)
        try await execute(fixture)
    }

    private func state(_ fixture: Fixture) async throws -> ResearchSeries.State {
        let run = try #require(await fixture.store.noteSeriesRun(taskID: fixture.task))
        return try #require(await fixture.store.latestSeriesArtifact(
            run,
            kind: .workflow,
            as: ResearchSeries.State.self
        )).value
    }

    private func filingCategory(
        _ f: Fixture,
        code: String,
        name: String
    ) async throws -> DecimalCategory {
        let category = DecimalCategory(id: UUID(), code: code, name: name)
        try await f.store.saveCategory(id: category.id, code: code, name: name)
        return category
    }

    @Test func publishedCollectionFilesClearMatchesSeparatelyWithScopedUndo() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let ai = try await filingCategory(f, code: "31", name: "Artificial intelligence")
        let security = try await filingCategory(f, code: "32", name: "Security")
        await f.provider.configureFiling(code: "31", confident: true, alternate: "32")
        try await execute(f)
        let notes = try await f.store.documents()
        let status = try #require(await f.store.publishedSeriesFiling()[f.task])
        #expect(status.noteIDs.count == 4)
        #expect(status.unfiled == 0)
        #expect(Set(status.homes) == Set([ai.label, security.label]))
        #expect(status.batches.count == 1)
        #expect(await f.provider.counts["filing"] == 1)
        let counts = await f.provider.counts
        try await execute(f)
        #expect(await f.provider.counts == counts)
        for batch in status.batches {
            #expect(try await f.store.undoFilingSuggestions(
                batch: batch,
                noteIDs: Set(status.noteIDs),
                includeSources: false
            ) == 4)
        }
        #expect(try await f.store.publishedSeriesFiling()[f.task]?.unfiled == 4)
        #expect(try await f.store.documents() == notes)
        #expect(try await f.store.conversationTasks().first?.state == "succeeded")
    }

    @Test func uncertainAndMissingHomesRemainOneCollectionForReview() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await filingCategory(f, code: "31", name: "Artificial intelligence")
        await f.provider.configureFiling(code: "31", confident: false)
        try await execute(f)
        let status = try #require(await f.store.publishedSeriesFiling()[f.task])
        #expect(status.unfiled == 4 && status.batches.isEmpty)
        #expect(try await f.store.pendingFilingSuggestions().count == 4)
        #expect(try await f.store.pendingFilingSuggestions().allSatisfy { !$0.confident })
    }

    @Test func emptyTaxonomyProposesOneSharedNewHomeWithoutCreatingIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configureFiling(newCategory: "Prompt engineering", confident: true)
        try await execute(f)
        let suggestions = try await f.store.pendingFilingSuggestions()
        #expect(suggestions.count == 4)
        #expect(suggestions
            .allSatisfy { $0.categoryID == nil && $0.newCategory == "Prompt engineering" })
        #expect(try await f.store.categories().allSatisfy { $0.name != "Prompt engineering" })
        let scope = Set(suggestions.map(\.noteID))
        let unrelated = try await f.store.save(MarkdownDocument(
            name: "Synthetic unrelated note",
            markdown: "A different subject."
        ))
        try await f.store.saveFilingSuggestions([.init(
            noteID: unrelated.id,
            categoryID: nil,
            newCategory: "Prompt engineering",
            confidence: 0.5,
            engine: "fixture"
        )])
        _ = try await f.store.createSuggestedCategory(
            "Prompt engineering",
            code: "31",
            noteIDs: scope
        )
        let pending = try await f.store.pendingFilingSuggestions()
        #expect(pending.filter { scope.contains($0.noteID) }.allSatisfy { $0.categoryID != nil })
        #expect(pending.first { $0.noteID == unrelated.id }?.categoryID == nil)
        #expect(try await f.store.acceptFilingSuggestions(Array(scope), includeSources: false)
            .accepted == 4)
    }

    @Test func filingFailureOrCancellationKeepsPublishedSuccessAndNeverRepeatsResearch(
    ) async throws {
        for cancel in [false, true] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try await filingCategory(f, code: "31", name: "Artificial intelligence")
            if cancel {
                await f.provider.configure(cancel: "filing")
            }
            await f.provider.configureFiling(fails: !cancel)
            try await execute(f)
            #expect(try await f.store.documents().count == 4)
            #expect(try await f.store.conversationTasks().first?.state == "succeeded")
            #expect(try await f.store.publishedSeriesFiling()[f.task]?.unfiled == 4)
            let counts = await f.provider.counts
            try await execute(f)
            #expect(await f.provider.counts == counts)
        }
    }

    @Test func reusedNotesKeepTheirHomeAndOnlyTheNewIndexIsFiled() async throws {
        let f = try await fixture(saved: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try #require(await f.store.documents().first)
        let old = try await filingCategory(f, code: "21", name: "Existing knowledge")
        let new = try await filingCategory(f, code: "31", name: "Artificial intelligence")
        try await f.store.fileNote(saved.id, categoryID: old.id, includeSources: false)
        await f.provider.configure(mode: .libraryOnly, reuse: true)
        await f.provider.configureFiling(code: "31", confident: true)
        try await execute(f)
        let status = try #require(await f.store.publishedSeriesFiling()[f.task])
        #expect(status.noteIDs.count == 1 && !status.noteIDs.contains(saved.id))
        #expect(status.homes == [new.label])
        #expect(try await f.store.categories(for: saved.id).map(\.id) == [old.id])
        #expect(try await f.store.document(id: saved.id) == saved)
    }

    @Test func editingOrFilingDuringClassificationPreventsAutomaticRelocation() async throws {
        for edit in [false, true] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let chosen = try await filingCategory(f, code: "31", name: "Artificial intelligence")
            let manual = try await filingCategory(f, code: "32", name: "Manual home")
            await f.provider.configureFiling(code: "31", confident: true, callback: {
                let run = try #require(await f.store.noteSeriesRun(taskID: f.task))
                if edit {
                    var note = try #require(await f.store.document(id: run.indexID))
                    note.markdown += " Synthetic concurrent edit."
                    _ = try await f.store.save(note)
                } else {
                    try await f.store.fileNote(
                        run.indexID,
                        categoryID: manual.id,
                        includeSources: false
                    )
                }
            })
            try await execute(f)
            let run = try #require(await f.store.noteSeriesRun(taskID: f.task))
            #expect(try await f.store.categories(for: run.indexID)
                .map(\.id) == (edit ? [] : [manual.id]))
            let status = try #require(await f.store.publishedSeriesFiling()[f.task])
            #expect(status.homes.contains(chosen.label))
        }
    }

    @Test func clearingChatDuringFilingCannotRecreateMessagesOrFileTheNotes() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await filingCategory(f, code: "31", name: "Artificial intelligence")
        await f.provider.configureFiling(
            code: "31",
            confident: true,
            callback: { try await f.store.clearConversation() }
        )
        try await execute(f)
        #expect(try await f.store.conversationMessages().isEmpty)
        #expect(try await f.store.publishedSeriesFiling().isEmpty)
        #expect(try await f.store.pendingFilingSuggestions().isEmpty)
        for note in try await f.store
            .documents()
        {
            #expect(try await f.store.categories(for: note.id).isEmpty)
        }
    }

    @Test func filingUsesTheConfiguredClassifierInsteadOfTheWritingModel() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await filingCategory(f, code: "31", name: "Artificial intelligence")
        let classifier = ResearchFixture()
        await classifier.configureFiling(code: "31", confident: true)
        try await f.coordinator.setInference(f.provider, filing: classifier)
        try await execute(f)
        #expect(await f.provider.counts["filing"] == nil)
        #expect(await classifier.counts["filing"] == 1)
        #expect(try await f.store.publishedSeriesFiling()[f.task]?.unfiled == 0)
    }

    @Test func filingAndUndoNeverMoveTheCitedOriginals() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let destination = try await filingCategory(f, code: "31", name: "Artificial intelligence")
        let originalHome = try await filingCategory(f, code: "32", name: "Original sources")
        let sourceID = UUID()
        await f.provider.configureFiling(code: "31", confident: true, callback: {
            let run = try #require(await f.store.noteSeriesRun(taskID: f.task))
            let db = try await f.store.database()
            try await db.write { db in
                try db.execute(
                    sql: "INSERT INTO sources(id,identity,createdAt) VALUES (?,?,0)",
                    arguments: [sourceID.uuidString, "synthetic-public-source"]
                )
                try db.execute(
                    sql: "INSERT INTO source_categories VALUES (?,?,1)",
                    arguments: [sourceID.uuidString, originalHome.id.uuidString]
                )
                try db.execute(
                    sql: "INSERT INTO note_sources(noteID, sourceID) VALUES (?,?)",
                    arguments: [run.indexID.uuidString, sourceID.uuidString]
                )
            }
        })
        try await execute(f)
        let status = try #require(await f.store.publishedSeriesFiling()[f.task])
        #expect(status.homes == [destination.label])
        for batch in status.batches {
            _ = try await f.store.undoFilingSuggestions(
                batch: batch,
                noteIDs: Set(status.noteIDs),
                includeSources: false
            )
        }
        let db = try await f.store.database()
        let homes = try await db.read { db in try String.fetchAll(
            db,
            sql: "SELECT categoryID FROM source_categories WHERE sourceID = ?",
            arguments: [sourceID.uuidString]
        ) }
        #expect(homes == [originalHome.id.uuidString])
    }

    @Test func exhaustedResearchBudgetSkipsFilingWithoutResettingOrRepeatingIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let run = try #require(await f.store.noteSeriesRun(taskID: f.task))
        let db = try await f.store.database()
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM note_series_artifacts WHERE runID = ? AND kind = 'filing'",
                arguments: [run.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE note_series_runs SET calls = ? WHERE id = ?",
                arguments: [NoteSeries.maximumCalls, run.id.uuidString]
            )
        }
        let before = await f.provider.counts
        await f.coordinator.filePublishedSeries(run) {}
        #expect(await f.provider.counts == before)
        #expect(try await f.store.documents().count == 4)
        #expect(try await f.store.publishedSeriesFiling()[f.task]?.unfiled == 4)
    }

    @Test func explicitFollowUpClassifiesOnlyThisCollection() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let status = try #require(await f.store.publishedSeriesFiling()[f.task])
        let other = try await f.store.save(MarkdownDocument(
            name: "Synthetic unrelated subject",
            markdown: "Unrelated material."
        ))
        _ = try await filingCategory(f, code: "31", name: "Artificial intelligence")
        await f.provider.configureFiling(code: "31")
        let categorizer = BookmarkCategorizer(store: f.store, inference: f.provider)
        let result = try await categorizer.run(noteIDs: Set(status.noteIDs))
        #expect(result.total == 4)
        #expect(try await f.store.pendingFilingSuggestions().count == 4)
        #expect(try await f.store.pendingFilingSuggestions().allSatisfy { $0.noteID != other.id })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_SERIES_FILING"] == "1"))
    func livePublicCollectionFilingPreservesNotesAndSupportsUndo() async throws {
        let input = try #require(ProcessInfo.processInfo
            .environment["GLEANARY_LIVE_SERIES_FILING_INPUT"])
        let source = URL(fileURLWithPath: input).standardizedFileURL
        #expect(source.path
            .hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(source.deletingLastPathComponent().lastPathComponent
            .hasPrefix("gleanary-evidence-series-"))
        guard source.path
            .hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path),
            source.deletingLastPathComponent().lastPathComponent
            .hasPrefix("gleanary-evidence-series-") else { return }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gleanary-live-filing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(path: "library.sqlite")
        var readOnly = Configuration()
        readOnly.readonly = true
        let inputDatabase = try DatabaseQueue(path: source.path, configuration: readOnly)
        try inputDatabase.backup(to: DatabaseQueue(path: destination.path))
        let store = DocumentStore(url: destination)
        _ = try await store.open()
        for category in [
            ("31", "AI and prompt engineering"),
            ("32", "Software testing and evaluation"),
            ("33", "Security and prompt injection"),
        ] {
            try await store.saveCategory(id: UUID(), code: category.0, name: category.1)
        }
        let task = try #require(await store.publishedSeriesFiling().keys.first)
        let run = try #require(await store.noteSeriesRun(taskID: task))
        let before = try await store.documents()
        let session = ChatGPTSession()
        let catalog = try await session.catalog()
        let model = try #require(catalog.first).slug
        let provider = HostedInference(session: session, model: model)
        let coordinator = AgentCoordinator(store: store, inference: provider)
        await coordinator.filePublishedSeries(run) {}
        let status = try #require(await store.publishedSeriesFiling()[task])
        #expect(status.noteIDs.count == before.count)
        #expect(status.unfiled < status.noteIDs.count)
        #expect(!status.batches.isEmpty)
        #expect(try await store.documents() == before)
        print(
            "Public filing acceptance: \(root.path); model \(model); \(before.count - status.unfiled) auto-filed, \(status.unfiled) for review; homes \(status.homes)"
        )
        for note in before {
            try await print(
                "Filing: \(note.name) -> \(store.categories(for: note.id).map(\.label))"
            )
        }
        for batch in status.batches {
            _ = try await store.undoFilingSuggestions(
                batch: batch,
                noteIDs: Set(status.noteIDs),
                includeSources: false
            )
        }
        #expect(try await store.publishedSeriesFiling()[task]?.unfiled == before.count)
        #expect(try await store.documents() == before)
    }

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["GLEANARY_SERIES_FILING_SCREENSHOTS"] == "1"))
    @MainActor func collectionFilingFollowUpFitsNarrowAndWidePanes() async throws {
        _ = NSApplication.shared
        let ids = (0 ..< 8).map { _ in UUID() }
        let complete = SeriesFiling.Status(
            taskID: UUID(),
            noteIDs: ids,
            unfiled: 0,
            homes: ["31 Artificial intelligence", "32 Security"],
            batches: [UUID()]
        )
        let partial = SeriesFiling.Status(
            taskID: UUID(),
            noteIDs: ids,
            unfiled: 2,
            homes: ["31 Artificial intelligence"],
            batches: [UUID()]
        )
        let pending = SeriesFiling.Status(
            taskID: UUID(),
            noteIDs: ids,
            unfiled: 8,
            homes: [],
            batches: []
        )
        for width in [320.0, 680.0] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
                    SeriesFilingActions(status: complete, review: {}, undo: {})
                    Divider()
                    SeriesFilingActions(status: partial, review: {}, undo: {})
                    Divider()
                    SeriesFilingActions(status: pending, review: {}, undo: {})
                    Divider()
                    SeriesFilingActions(status: pending, working: true, review: {}, undo: {})
                }.padding(20).frame(width: width, height: 360, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(dark ? .dark : .light))
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                let window = NSWindow(
                    contentRect: NSRect(x: -10000, y: 0, width: width, height: 360),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                host.appearance = appearance
                window.contentView = host
                window.orderFront(nil)
                defer { window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                #expect(abs(host.bounds.width - width) < 1)
                #expect(abs(host.bounds.height - 360) < 1)
                #expect(host.fittingSize.height <= 360)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png
                    .write(
                        to: URL(
                            fileURLWithPath: "/tmp/gleanary-series-filing-\(Int(width))-\(dark ? "dark" : "light").png"
                        )
                    )
            }
        }
    }

    @Test func evidenceFirstWorkflowPublishesSingleParagraphNotesAndConceptualLinks() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let completed = try await state(f)
        #expect(completed.phase == .ready)
        #expect(completed.notes.allSatisfy { $0.accepted && $0.attempts == 1 })
        #expect(try await f.store.documents().count == 4)
        #expect(await f.provider.counts["search"] == 1)
        #expect(await f.fetcher.requests == 1)
        let run = try #require(await f.store.noteSeriesRun(taskID: f.task))
        let accepted = try #require(await f.store.seriesArtifact(
            run,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ))
        #expect(accepted.value.scope == nil)
        #expect(accepted.value.workflow != nil)
        #expect(accepted.value.drafts.values.allSatisfy { $0.paragraphs.count == 1 })
        let ids = try await f.store.documents().map(\.id)
        try await execute(f)
        #expect(try await f.store.documents().map(\.id) == ids)
    }

    @Test func newlyDiscoveredOverlapsOnDifferentNotesRepairAutomatically() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(edits: [0, 1])
        try await execute(f)
        let completed = try await state(f)
        #expect(completed.editorialAttempts == 3)
        #expect(completed.notes.map(\.revisions) == [1, 1, 0])
        #expect(completed.notes.map(\.attempts) == [2, 2, 1])
        #expect(await f.provider.counts["write"] == 5)
        #expect(await f.provider.counts["search"] == 1)
        #expect(try await f.store.documents().count == 4)
    }

    @Test func aRepeatedFindingStopsWithoutResettingOnRetry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(repeatIssue: true)
        await #expect(throws: ResearchSeries.Failure.self) { try await execute(f) }
        #expect(try await state(f).phase == .blocked)
        #expect(try await f.store.documents().isEmpty)
        let counts = await f.provider.counts
        await #expect(throws: ResearchSeries.Failure.self) { try await resume(f) }
        #expect(await f.provider.counts == counts)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func interruptedVerificationResumesTheSameDraftWithoutAnotherSearchOrWrite() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(cancel: "verify")
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let previous = try await state(f)
        let draft = try #require(previous.notes.first?.draft)
        #expect(previous.notes.first?.accepted == false)
        try await resume(f)
        let completed = try await state(f)
        #expect(completed.notes.first?.draft == draft)
        #expect(completed.notes.first?.attempts == 1)
        #expect(await f.provider.counts["write"] == 3)
        #expect(await f.provider.counts["search"] == 1)
        #expect(await f.fetcher.requests == 1)
    }

    @Test func interruptedPlanReviewKeepsTheCandidateAndItsAllocatedIDs() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(cancel: "planReview")
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let previous = try await state(f)
        #expect(previous.phase == .reviewingPlan)
        let ids = try #require(previous.plan).outline.entries.map(\.id)
        try await resume(f)
        #expect(try await state(f).plan?.outline.entries.map(\.id) == ids)
        #expect(await f.provider.counts["plan"] == 1)
        #expect(await f.provider.counts["planReview"] == 2)
        #expect(await f.provider.counts["search"] == 1)
    }

    @Test func savedLibraryRevisionChangesInvalidatePublicationWithoutRewritingOtherNotes(
    ) async throws {
        let f = try await fixture(saved: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(cancel: "verify")
        await #expect(throws: CancellationError.self) { try await execute(f) }
        var existing = try #require(await f.store.documents().first)
        existing.markdown += " A synthetic concurrent edit."
        let changed = try await f.store.save(existing)
        let counts = await f.provider.counts
        await #expect(throws: NoteSeries.Failure.self) { try await resume(f) }
        #expect(await f.provider.counts == counts)
        #expect(try await f.store.documents().count == 1)
        #expect(try await f.store.document(id: changed.id) == changed)
    }

    @Test func publicationRequiresMatchingParagraphReviewsNotJustAnEditorApproval() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await execute(f)
        let run = try #require(await f.store.noteSeriesRun(taskID: f.task))
        let reviewed = try #require(await f.store.seriesArtifact(
            run,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ))
        let accepted = try #require(reviewed.value.workflow)
        let evidence = try #require(reviewed.value.evidence)
        var jobs = accepted.notes
        jobs[0].reviews = []
        let forged = ResearchSeries.Accepted(
            request: accepted.request,
            intent: accepted.intent,
            plan: accepted.plan,
            planReview: accepted.planReview,
            notes: jobs,
            editorial: accepted.editorial
        )
        #expect(throws: ResearchSeries.Failure.self) {
            try forged.validate(
                outline: accepted.plan.outline,
                evidence: evidence,
                drafts: reviewed.value.drafts,
                curation: reviewed.value.curation
            )
        }
        let first = try #require(accepted.plan.contracts.first)
        let missing = ResearchSeries.Contract(
            entry: first.entry,
            records: first.records,
            sharedRecords: first.sharedRecords,
            excludes: first.excludes,
            requirements: []
        )
        let incomplete = ResearchSeries.Plan(
            outline: accepted.plan.outline,
            contracts: [missing] + accepted.plan.contracts.dropFirst(),
            relationships: accepted.plan.relationships
        )
        #expect(throws: ResearchSeries.Failure.self) { try incomplete.validate(
            intent: accepted.intent,
            evidence: evidence
        ) }
        let second = accepted.plan.contracts[1]
        let repeated = ResearchSeries.Contract(
            entry: second.entry,
            records: first.records,
            sharedRecords: [],
            excludes: second.excludes,
            requirements: second.requirements
        )
        let duplicate = ResearchSeries.Plan(
            outline: accepted.plan.outline,
            contracts: [first, repeated, accepted.plan.contracts[2]],
            relationships: accepted.plan.relationships
        )
        #expect(throws: ResearchSeries.Failure.self) { try duplicate.validate(
            intent: accepted.intent,
            evidence: evidence
        ) }
    }

    @Test func interruptedSearchIsNotSilentlyIssuedAgain() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(cancel: "search")
        await #expect(throws: CancellationError.self) { try await execute(f) }
        await #expect(throws: ResearchSeries.Failure.self) { try await resume(f) }
        #expect(await f.provider.counts["search"] == 1)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test(arguments: [NoteSeries.SourceMode.libraryOnly, .fillGaps])
    func sufficientSavedMaterialIsReusedWithoutNetworkOrRewritingIt(mode: NoteSeries
        .SourceMode) async throws
    {
        let f = try await fixture(saved: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try #require(await f.store.documents().first)
        await f.provider.configure(mode: mode, reuse: true)
        try await execute(f)
        #expect(await f.provider.counts["search"] == nil)
        #expect(await f.fetcher.requests == 0)
        #expect(try await f.store.document(id: before.id) == before)
        #expect(try await f.store.documents().count == 2)
    }

    @Test func interruptedDownloadIsNotRepeatedWhenItsOutcomeIsUnknown() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.fetcher.cancelNext()
        await #expect(throws: CancellationError.self) { try await execute(f) }
        #expect(try await state(f).sources.first?.status == .fetching)
        await #expect(throws: ResearchSeries.Failure.self) { try await resume(f) }
        #expect(await f.fetcher.requests == 1)
        #expect(await f.provider.counts["search"] == 1)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func explicitWorkingStateDoesNotDependOnWallClockOrdering() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(cancel: "verify")
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let run = try #require(await f.store.noteSeriesRun(taskID: f.task))
        let previous = try #require(await f.store.researchSeriesState(run))
        var next = previous.value
        next.revision += 1
        next.problem = "Synthetic clock reversal"
        let saved = try await f.store.checkpointSeries(
            run,
            kind: .workflow,
            slot: String(format: "%06d", next.revision),
            value: next,
            parents: [previous.id]
        )
        let database = try await f.store.database()
        try await database.write { db in try db.execute(
            sql: "UPDATE note_series_artifacts SET createdAt = 1 WHERE id = ?",
            arguments: [saved.id.uuidString]
        ) }
        #expect(try await f.store.researchSeriesState(run)?.id == saved.id)
        try await resume(f)
        #expect(try await f.store.documents().count == 4)
    }

    @Test func optionalModelSuggestedRelationshipsMayChangeButRequiredEdgesCannotDisappear(
    ) async throws {
        for required in [true, false] {
            let f = try await fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            await f.provider.configure(requiredEdge: required, omitSuggestedEdge: true)
            if required {
                await #expect(throws: ResearchSeries.Failure.self) { try await execute(f) }
                #expect(try await f.store.documents().isEmpty)
            } else {
                try await execute(f)
                #expect(try await f.store.documents().count == 4)
            }
        }
    }

    @Test func infeasibleCoverageStopsBeforeWritingInsteadOfDeferringARequirement() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(rejectPlan: true)
        await #expect(throws: ResearchSeries.Failure.self) { try await execute(f) }
        #expect(await f.provider.counts["plan"] == 3)
        #expect(await f.provider.counts["write"] == nil)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test func budgetAndCancellationLeaseStillProtectTheNewWorkflow() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.provider.configure(cancel: "verify")
        await #expect(throws: CancellationError.self) { try await execute(f) }
        let database = try await f.store.database()
        try await database.write { db in try db.execute(
            sql: "UPDATE note_series_runs SET calls = ?",
            arguments: [NoteSeries.maximumCalls]
        ) }
        let counts = await f.provider.counts
        await #expect(throws: NoteSeries.Failure.self) { try await resume(f) }
        #expect(await f.provider.counts == counts)
        #expect(try await f.store.documents().isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_LIVE_RESEARCH_SERIES"] == "1"))
    func livePublicPromptPublishesGroundedConnectedKnowledgeWithoutManualRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gleanary-evidence-series-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let saved: MarkdownDocument? = if ProcessInfo.processInfo
            .environment["GLEANARY_LIVE_RESEARCH_SAVED_NOTE"] == "1"
        {
            try await store.save(MarkdownDocument(
                name: "Prompt evaluation and regression testing",
                markdown: """
                Evaluate prompts with task-specific tests reflecting real-world inputs. Evaluate early and often, use scoped tests at each stage, and run regression evaluations on every prompt change and model-version upgrade. Expand the test set when monitoring uncovers new failure cases.

                Build representative datasets from privacy-safe production examples, hand-written edge cases, adversarial inputs, and long or multi-turn tasks. Repeated trials help account for nondeterministic outputs; report mean results and variation. Use pass-at-k only when any one correct attempt counts as success.

                For model judges, prefer pairwise comparisons, classification, or scoring against explicit criteria. Watch for response-order and verbosity biases. Re-evaluate model-specific prompting recommendations on your own tasks before transferring them to another model. Use evaluation results to decide whether additional workflow or multi-agent complexity is justified.

                Sources: https://developers.openai.com/api/docs/guides/evaluation-best-practices and https://docs.x.ai/developers/model-capabilities/text/best-practices
                """
            ))
        } else {
            nil
        }
        let session = ChatGPTSession()
        let choice = try #require(await session.catalog().first)
        let provider = HostedInference(session: session, model: choice.slug)
        let coordinator = AgentCoordinator(store: store, inference: provider)
        let task = try await store.beginConversation(promptEngineeringRequest, owner: .assistant)
        print("Public research acceptance: model \(choice.slug); isolated results \(root.path)")
        do {
            try await coordinator.execute(
                taskID: task,
                request: promptEngineeringRequest,
                selected: []
            ) {
                if let progress = try? await store.conversationTasks().first?
                    .progress
                {
                    print("Acceptance: \(progress)")
                }
            }
        } catch {
            if let run = try await store.noteSeriesRun(taskID: task),
               let state = try await store.latestSeriesArtifact(
                   run,
                   kind: .workflow,
                   as: ResearchSeries.State.self
               )
            {
                try JSONEncoder().encode(state.value).write(to: root.appending(path: "state.json"))
                print(
                    "Acceptance stopped in \(state.value.phase.rawValue): \(error.localizedDescription)"
                )
            }
            throw error
        }
        let run = try #require(await store.noteSeriesRun(taskID: task))
        #expect(run.published)
        let reviewed = try #require(await store.seriesArtifact(
            run,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ))
        let accepted = try #require(reviewed.value.workflow)
        let evidence = try #require(reviewed.value.evidence)
        try reviewed.value.validate(outline: accepted.plan.outline, dossier: evidence)
        #expect(accepted.plan.outline.entries.count >= 3)
        #expect(accepted.editorial.issues.isEmpty)
        #expect(!accepted.editorial.links.isEmpty)
        #expect(evidence.sources
            .contains {
                $0.url?.host?.contains("openai.com") == true || $0.url?.host?
                    .contains("anthropic.com") == true || $0.url?.host?.contains("google") == true
            })
        let notes = try await store.documents()
        #expect(notes.count == accepted.notes.count + 1 + (saved == nil ? 0 : 1))
        if let saved {
            #expect(try await store.document(id: saved.id) == saved)
            #expect(accepted.plan.contracts.contains { $0.entry.existingNoteID == saved.id })
        }
        #expect(notes.filter { $0.id != run.indexID && $0.id != saved?.id }
            .allSatisfy {
                $0.markdown.contains("https://") && $0.markdown.contains(run.indexID.uuidString)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(notes).write(to: root.appending(path: "notes.json"))
        try encoder.encode(reviewed.value).write(to: root.appending(path: "accepted.json"))
        let database = try await store.database()
        let calls = try await database.read { try Int.fetchOne(
            $0,
            sql: "SELECT calls FROM note_series_runs"
        ) }
        print(
            "Acceptance published \(accepted.notes.count) notes plus index, \(accepted.editorial.links.count) conceptual links, \(calls ?? 0) model calls; no Retry."
        )
    }
}
