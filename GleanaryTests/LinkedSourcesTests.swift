import Foundation
@testable import Gleanary
import GRDB
import Testing

private struct LinkedSourcesFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store: DocumentStore

    init() {
        store = DocumentStore(url: root.appending(path: "library.sqlite"))
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }

    func count(_ table: String) throws -> Int {
        try DatabaseQueue(path: store.url.path).read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
        }
    }

    func publish(_ job: CaptureJob) async throws -> UUID {
        try await store.publishCapture(job, document: CapturedDocument(
            title: "Synthetic source", sourceURL: job.request.url, coverage: .document,
            blocks: [ContentBlock(
                kind: .paragraph,
                markdown: "Synthetic evidence.",
                text: "Synthetic evidence."
            )]
        ), artifacts: [])
    }
}

private actor LinkedSourceFetcher: SourceFetching {
    var calls = 0
    func fetch(_ url: URL) throws -> DownloadedContent {
        calls += 1
        guard url.path.hasPrefix("/source-") else { throw CaptureError.http(404) }
        return DownloadedContent(
            data: Data("Synthetic source text for a local capture fixture.".utf8),
            url: url, mime: "text/plain", encoding: "utf-8"
        )
    }
}

struct LinkedSourcesTests {
    @Test @MainActor func progressReloadsWithinAnExtractingJobAndClearsOnFailure() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [MarkdownDocument(
            name: "Phase fixture", markdown: "[Source](https://example.org/phases)"
        )])
        let note = try #require(notes.first)
        let request = try CaptureRequest
            .webLink(#require(URL(string: "https://example.org/phases")))
        _ = try await fixture.store.enqueueCapture(request)
        let model = LinkedSourcesModel()
        await model.load(note, from: fixture.store)
        #expect(model.sources.first?.captureProgress == "Queued")
        let job = try #require(await fixture.store.claimCapture())
        await model.load(note, from: fixture.store)
        #expect(model.sources.first?.captureProgress == "Fetching source…")
        for phase in [
            "Extracting text",
            "Capturing a page screenshot",
            "Writing a brief summary with Fixture",
            "Finishing capture",
        ] {
            try await fixture.store.checkpoint(job, acquired: [], progress: phase)
            await model.load(note, from: fixture.store)
            #expect(model.sources.first?.captureProgress == phase)
            #expect(model.sources.first?.canAdd == false)
        }
        try await fixture.store.failCapture(job, error: "Synthetic failure")
        await model.load(note, from: fixture.store)
        #expect(model.sources.first?.captureProgress == nil)
        #expect(model.sources.first?.retryID == job.id)
    }

    @Test @MainActor func savedSourceSummariesUseProvenanceNotTitlesAndExcludeDeletedNotes(
    ) async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let notes = try await fixture.store.open(seed: [MarkdownDocument(
            name: "Links", markdown: "[Source](https://example.org/source)"
        )])
        let note = try #require(notes.first)
        _ = try await fixture.store
            .enqueueCapture(CaptureRequest
                .webLink(#require(URL(string: "https://example.org/source"))))
        let job = try #require(await fixture.store.claimCapture())
        let sourceID = try await fixture.publish(job)
        let captureID = try #require(await fixture.store.captureID(for: sourceID))
        #expect(try await fixture.store.librarySummaries(for: sourceID).isEmpty)
        let source = try await fixture.store.researchSource(noteID: sourceID)
        let task = try await fixture.store.beginConversation(
            "Summarize fixture",
            owner: .researcher
        )
        let summary = try await fixture.store.saveResearch(
            "A synthetic summary.", name: "Overview", sources: [source], taskID: task,
            provider: "fixture"
        )
        let noteTask = try await fixture.store.beginConversation(
            "Annotate fixture",
            owner: .researcher
        )
        _ = try await fixture.store.saveResearch(
            "Not a summary.", name: "Summary in title only", sources: [source], taskID: noteTask,
            provider: "fixture", kind: "note"
        )
        #expect(try await fixture.store.librarySummaries(forCapture: captureID)
            .map(\.id) == [summary.id])
        #expect(try await fixture.store.linkedSources(in: note).first?.summaries
            .map(\.id) == [summary.id])
        let preview = DocumentPreviewModel()
        preview.selectedID = sourceID
        await preview.load(from: fixture.store)
        #expect(preview.summaries.map(\.id) == [summary.id])
        #expect(!preview.related.contains(where: { $0.id == summary.id }))
        try await fixture.store.archive(summary.id, reason: "Synthetic fixture")
        #expect(try await fixture.store.librarySummaries(for: sourceID).map(\.id) == [summary.id])
        try await fixture.store.remove(summary)
        #expect(try await fixture.store.librarySummaries(for: sourceID).isEmpty)
        #expect(try await fixture.store.linkedSources(in: note).first?.summaries.isEmpty == true)
        preview.selectedID = note.id
        await preview.load(from: fixture.store)
        #expect(preview.summaries.isEmpty)
    }

    @Test func markdownLinksResolveReferencesSkipCodeAndImagesAndDeduplicateIdentities() throws {
        let links = try LinkedSourceLink.extract(from: """
        [First **source**](https://EXAMPLE.com:443/paper?q=1#overview)
        [Duplicate](https://example.com/paper?q=1#results)
        [Different query](https://example.com/paper?q=2)
        [Reference][official]
        <https://example.org/angle> and https://example.org/bare.
        [Internal](gleanary://note/00000000-0000-0000-0000-000000000001)
        [Mail](mailto:fixture@example.org)
        [Unsafe](https://user:password@example.org/private)
        ![Image](https://example.org/image.png)
        `https://example.org/inline-code`

        ```text
        https://example.org/fenced-code
        [Not a source](https://example.org/code-link)
        ```

        [official]: https://example.org/reference
        """)
        #expect(links.map(\.id) == [
            "url:https://example.com/paper?q=1", "url:https://example.com/paper?q=2",
            "url:https://example.org/reference", "url:https://example.org/angle",
            "url:https://example.org/bare",
        ])
        #expect(links.first?.title == "First source")
        #expect(try LinkedSourceLink.extract(from: "A note without web links.").isEmpty)
    }

    @Test func bibliographyTitlesReplaceCitationMarkersAndBareURLsWithoutReorderingSources() throws {
        let links = try LinkedSourceLink.extract(from: """
        Checked evidence ([1](https://example.org/first#claim); [2](https://example.org/second)).
        Additional evidence: https://example.org/third.

        ## Sources

        1. [Second source](https://example.org/second)
        2. [Prompt **design** strategies](https://example.org/first#bibliography)
        3. [Third source](https://example.org/third)

        Another citation ([1](https://example.org/first)).
        """)
        #expect(links.map(\.id) == [
            "url:https://example.org/first",
            "url:https://example.org/second",
            "url:https://example.org/third",
        ])
        #expect(links.map(\.title) == ["Prompt design strategies", "Second source", "Third source"])
        let markers = try LinkedSourceLink.extract(from: """
        [42](https://example.org/number-only) and [S3](https://example.org/source-marker).
        """)
        #expect(markers.map(\.title) == [
            "https://example.org/number-only",
            "https://example.org/source-marker",
        ])
        let paragraphs = try LinkedSourceLink.extract(from: """
        [1](https://example.org/first)

        [Descriptive source](https://example.org/first)
        """)
        #expect(paragraphs.first?.title == "Descriptive source")
    }

    @Test func captureAndSuggestionsUseTheSameSpecializedIdentities() throws {
        let links = try LinkedSourceLink.extract(from: """
        [Paper](https://arxiv.org/pdf/2601.12345.pdf)
        [Same paper](https://arxiv.org/abs/2601.12345)
        [Video](https://youtu.be/dQw4w9WgXcQ)
        [Same video](https://www.youtube.com/watch?v=dQw4w9WgXcQ)
        """)
        #expect(links.count == 2)
        for link in links {
            #expect(try CaptureRequest.webLink(link.url).identity == link.id)
        }
        #expect(links[0].id == "arxiv:2601.12345")
    }

    @Test func detectingSourcesIsReadOnlyAndDoesNotQueueCapture() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let note = MarkdownDocument(
            name: "Writer fixture",
            markdown: "[Source](https://example.org/source-1)"
        )
        _ = try await fixture.store.open(seed: [note])
        let before = try await fixture.store.document(id: note.id)
        for _ in 0 ..< 2 {
            let sources = try await fixture.store.linkedSources(in: note)
            #expect(sources.count == 1)
            #expect(sources[0].canAdd)
        }
        #expect(try fixture.count("ingestion_jobs") == 0)
        #expect(try fixture.count("note_links") == 0)
        #expect(try fixture.count("note_sources") == 0)
        #expect(try await fixture.store.document(id: note.id)?.revision == before?.revision)
    }

    @Test func duplicateRequestsShareAnActiveJobAndKeepLateReferencesAcrossRestart() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let url = try #require(URL(string: "https://example.org/source-1"))
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "First", markdown: "[Source](\(url))"),
            MarkdownDocument(name: "Second", markdown: "[Source](\(url))"),
        ])
        let firstID = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            url,
            referencing: notes[0].id
        ))
        let claimed = try #require(await fixture.store.claimCapture())
        let secondID = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            url,
            referencing: notes[1].id
        ))
        #expect(firstID == secondID)
        #expect(try fixture.count("ingestion_jobs") == 1)
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open()
        let job = try #require(await reopened.captureJobs().first)
        #expect(Set(job.request.referencingNoteIDs ?? []) == Set(notes.map(\.id)))
        // The worker's claimed request predates the second note's Add action.
        let target = try await fixture.publish(claimed)
        #expect(try fixture.count("note_links") == 2)
        #expect(try fixture.count("note_sources") == 1)
        for note in notes {
            let sources = try await reopened.linkedSources(in: note)
            #expect(sources[0].noteID == target)
            #expect(!sources[0].canAdd)
            #expect(try await reopened.linkedItems(for: note.id).first?.document.id == target)
        }
    }

    @Test func concurrentAddsAreAtomicAndExistingCapturesAreReusedIncludingArchivedOnes(
    ) async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let url = try #require(URL(string: "https://example.org/source-1"))
        let note = MarkdownDocument(name: "References", markdown: "[Source](\(url))")
        _ = try await fixture.store.open(seed: [note])
        let request = try CaptureRequest.webLink(url, referencing: note.id)
        let other = DocumentStore(url: fixture.store.url)
        _ = try await other.open()
        async let left = fixture.store.enqueueCapture(request)
        async let right = other.enqueueCapture(request)
        #expect(try await left == right)
        let job = try #require(await fixture.store.claimCapture())
        let target = try await fixture.publish(job)
        let original = try #require(await fixture.store.document(id: target))
        try await fixture.store.archive(target, reason: "Synthetic archive")
        let sources = try await fixture.store.linkedSources(in: note)
        #expect(sources[0].noteID == target)
        #expect(sources[0].archived)
        #expect(!sources[0].canAdd)
        _ = try await fixture.store.enqueueCapture(request)
        #expect(try fixture.count("captures") == 1)
        #expect(try fixture.count("note_links") == 1)
        #expect(try await fixture.store.document(id: target)?.revision == original.revision)
        #expect(try await fixture.store.document(id: note.id)?.markdown == note.markdown)
        let graph = try await fixture.store.libraryGraph()
        #expect(graph.graph.nodes.allSatisfy { $0.noteID != target })
    }

    @Test func cancelledAndFailedJobsOfferRetryAndDoNotBlockOtherSources() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let note = MarkdownDocument(
            name: "References",
            markdown: "[One](https://example.org/source-1) [Two](https://example.org/source-2)"
        )
        _ = try await fixture.store.open(seed: [note])
        let links = try LinkedSourceLink.extract(from: note.markdown)
        let first = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            links[0].url,
            referencing: note.id
        ))
        try await fixture.store.cancelCapture(first)
        var sources = try await fixture.store.linkedSources(in: note)
        #expect(sources[0].retryID == first)
        try await fixture.store.retryCapture(first)
        let failed = try #require(await fixture.store.claimCapture())
        try await fixture.store.failCapture(failed, error: "Synthetic capture failure")
        sources = try await fixture.store.linkedSources(in: note)
        #expect(sources[0].canAdd)
        #expect(sources[0].job?.error == "Synthetic capture failure")
        #expect(sources[1].canAdd)
        _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            links[1].url,
            referencing: note.id
        ))
        let successful = try #require(await fixture.store.claimCapture())
        _ = try await fixture.publish(successful)
        try await fixture.store.retryCapture(first)
        let retried = try #require(await fixture.store.claimCapture())
        _ = try await fixture.publish(retried)
        #expect(try await fixture.store.linkedSources(in: note).allSatisfy { $0.noteID != nil })
        #expect(try fixture.count("note_links") == 2)
    }

    @Test func retryJoinsAnotherActiveCaptureInsteadOfQueuingDuplicateWork() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let url = try #require(URL(string: "https://example.org/source-1"))
        let notes = try await fixture.store.open(seed: [
            MarkdownDocument(name: "First", markdown: "[Source](\(url))"),
            MarkdownDocument(name: "Second", markdown: "[Source](\(url))"),
        ])
        let failedID = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            url,
            referencing: notes[0].id
        ))
        let failed = try #require(await fixture.store.claimCapture())
        try await fixture.store.failCapture(failed, error: "Synthetic failure")
        _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            url,
            referencing: notes[1].id
        ))
        try await fixture.store.retryCapture(failedID)
        let jobs = try await fixture.store.captureJobs()
        #expect(jobs.filter { !$0.state.terminal }.count == 1)
        let current = try #require(await fixture.store.claimCapture())
        _ = try await fixture.publish(current)
        #expect(try fixture.count("note_links") == 2)
    }

    @Test @MainActor func unavailableCaptureContextDoesNotQueueAnything() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let note = MarkdownDocument(
            name: "References",
            markdown: "[Source](https://example.org/source-1)"
        )
        _ = try await fixture.store.open(seed: [note])
        let model = LinkedSourcesModel()
        await model.load(note, from: fixture.store)
        let context = LinkedSourceContext(
            store: fixture.store,
            revision: "fixture",
            canAdd: false
        ) { _, _, _ in
            Issue.record("Disabled capture context must not enqueue work")
        }
        await model.add(model.sources, for: note, using: context)
        #expect(model.adding.isEmpty)
        #expect(try fixture.count("ingestion_jobs") == 0)
        await model.load(
            MarkdownDocument(name: "No links", markdown: "No external links."),
            from: fixture.store
        )
        #expect(model.sources.isEmpty)
        #expect(model.failures.isEmpty)
    }

    @Test func removedLinksAndDeletedNotesDoNotReceiveStaleReferences() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let url = try #require(URL(string: "https://example.org/source-1"))
        var note = MarkdownDocument(name: "References", markdown: "[Source](\(url))")
        let deleted = MarkdownDocument(name: "Removed note", markdown: note.markdown)
        _ = try await fixture.store.open(seed: [note, deleted])
        note = try #require(await fixture.store.document(id: note.id))
        let currentDeleted = try #require(await fixture.store.document(id: deleted.id))
        _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            url,
            referencing: note.id
        ))
        _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(
            url,
            referencing: deleted.id
        ))
        let job = try #require(await fixture.store.claimCapture())
        note.markdown = "The external link was removed."
        _ = try await fixture.store.save(note)
        try await fixture.store.remove(currentDeleted)
        _ = try await fixture.publish(job)
        #expect(try fixture.count("note_links") == 0)
    }

    @Test @MainActor func addAllKeepsSuccessfulRequestsWhenOneQueueOperationFails() async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let note = MarkdownDocument(name: "References", markdown: (1 ... 5).map {
            "[Source \($0)](https://example.org/source-\($0))"
        }.joined(separator: "\n"))
        _ = try await fixture.store.open(seed: [note])
        let original = try #require(await fixture.store.document(id: note.id))
        let model = LinkedSourcesModel()
        await model.load(note, from: fixture.store)
        var calls: [URL] = []
        let context = LinkedSourceContext(
            store: fixture.store,
            revision: "fixture",
            canAdd: true
        ) { url, id, retry in
            calls.append(url)
            #expect(id == note.id)
            #expect(retry == nil)
            if url.path == "/source-3" {
                throw CaptureError.downloadFailed
            }
            _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(url, referencing: id))
        }
        await model.add(model.sources, for: note, using: context)
        #expect(calls.count == 5)
        #expect(model.adding.isEmpty)
        #expect(model.failures.count == 1)
        #expect(model.sources.filter(\.canAdd).count == 1)
        #expect(try fixture.count("ingestion_jobs") == 4)
        // Repeated Add all skips the four already-queued jobs.
        await model.add(model.sources, for: note, using: context)
        #expect(calls.count == 6)
        #expect(try fixture.count("ingestion_jobs") == 4)
        #expect(try await fixture.store.document(id: note.id)?.revision == original.revision)
    }

    @Test func fiveLinksTravelThroughTheExistingCaptureEngineWithoutARealNetworkOrModel(
    ) async throws {
        let fixture = LinkedSourcesFixture(); defer { fixture.clean() }
        let note = MarkdownDocument(name: "References", markdown: (1 ... 5).map {
            "[Source \($0)](https://example.org/source-\($0))"
        }.joined(separator: "\n"))
        _ = try await fixture.store.open(seed: [note])
        let fetcher = LinkedSourceFetcher()
        let engine = IngestionEngine(
            store: fixture.store,
            fetcher: fetcher,
            settings: { CaptureSettings(summarize: false, previews: false)
            }
        )
        for link in try LinkedSourceLink.extract(from: note.markdown) {
            _ = try await engine.enqueue(link.url.absoluteString, referencing: note.id)
        }
        #expect(await fetcher.calls == 0)
        try await engine.run()
        let sources = try await fixture.store.linkedSources(in: note)
        #expect(sources.count == 5)
        #expect(sources.allSatisfy { $0.noteID != nil })
        #expect(try fixture.count("captures") == 5)
        #expect(try fixture.count("note_links") == 5)
        #expect(try await fixture.store.document(id: note.id)?.markdown == note.markdown)
    }
}
