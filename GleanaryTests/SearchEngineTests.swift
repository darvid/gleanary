import Foundation
@testable import Gleanary
import GRDB
import Testing

private struct Fixture {
    let directory: URL
    let store: DocumentStore
    var databaseURL: URL {
        directory.appending(path: "library.sqlite")
    }

    var legacyURL: URL {
        directory.appending(path: "documents.json")
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DocumentStore(url: directory.appending(path: "library.sqlite"))
    }

    func clean() {
        try? FileManager.default.removeItem(at: directory)
    }

    func scalar(_ sql: String) throws -> String? {
        try DatabaseQueue(path: databaseURL.path).read { try String.fetchOne($0, sql: sql) }
    }

    func execute(_ sql: String, arguments: StatementArguments = []) throws {
        try DatabaseQueue(path: databaseURL.path).write { try $0.execute(
            sql: sql,
            arguments: arguments
        ) }
    }
}

private actor TestEmbedder: EmbeddingProviding {
    let descriptor: EmbeddingProfile
    private var calls: [String] = []
    private var failAfter: Int?
    private var unavailable = false
    private let failingText: String?

    init(
        revision: Int = 1,
        dimensions: Int = 3,
        failAfter: Int? = nil,
        failingText: String? = nil
    ) {
        descriptor = EmbeddingProfile(
            model: "synthetic",
            revision: revision,
            dimensions: dimensions
        )
        self.failAfter = failAfter
        self.failingText = failingText
    }

    func profile() throws -> EmbeddingProfile {
        if unavailable {
            throw GleanaryError.modelUnavailable
        }
        return descriptor
    }

    func vector(for text: String, profile: EmbeddingProfile) throws -> [Float] {
        if unavailable {
            throw GleanaryError.modelUnavailable
        }
        if text == failingText {
            throw GleanaryError.noVector
        }
        if let failAfter, calls.count >= failAfter {
            throw GleanaryError.noVector
        }
        calls.append(text)
        // Revision-specific vectors catch accidental mixing of embedding spaces.
        return (0 ..< profile.dimensions)
            .map { $0 == profile.revision % profile.dimensions ? 1 : 0 }
    }

    func count() -> Int {
        calls.count
    }

    func disable() {
        unavailable = true
    }
}

private actor PausedEmbedder: EmbeddingProviding {
    private var pause: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var didPause = false
    private var released = false

    func profile() -> EmbeddingProfile {
        EmbeddingProfile(model: "synthetic", revision: 1, dimensions: 3)
    }

    func vector(for _: String, profile _: EmbeddingProfile) async -> [Float] {
        if !released {
            await withCheckedContinuation { continuation in
                pause = continuation
                didPause = true
                waiting?.resume()
                waiting = nil
            }
        }
        return [1, 0, 0]
    }

    func waitUntilPaused() async {
        if !didPause {
            await withCheckedContinuation { waiting = $0 }
        }
    }

    func release() {
        released = true
        pause?.resume()
        pause = nil
    }
}

@Test func float32EncodingAndAccelerateScoring() throws {
    let vector = try VectorMath.normalized([3, 4], dimensions: 2)
    #expect(abs(vector[0] - 0.6) < 0.00001)
    let data = try VectorMath.encode(vector, dimensions: 2)
    #expect(data.count == 8)
    #expect(VectorMath.decode(data, dimensions: 2) == vector)
    #expect(VectorMath.dot([1, 0], [0, 1]) == 0)
    #expect(VectorMath.dot([1, 0], [-1, 0]) == -1)
    #expect(VectorMath.dot([], []) == nil)
    #expect(VectorMath.dot([1, 2], [1]) == nil)
    #expect(VectorMath.decode(Data([0, 0, 128, 63]), dimensions: 1) == [1])
    #expect(VectorMath.decode(Data(repeating: 0, count: 8), dimensions: 2) == nil)
    #expect(VectorMath.decode(Data([1]), dimensions: 2) == nil)
    for vector: [Float] in [[0, 0], [.nan, 1], [.infinity, 1], [1]] {
        #expect(throws: GleanaryError.self) { try VectorMath.encode(vector, dimensions: 2) }
    }
}

@Test func markdownExtractionAndBounds() {
    let chunks = MarkdownChunker.chunks(
        "# Heading\r\n\r\nRead **bold** [notes](https://example.com).\n\n```swift\nlet x = 1\n```",
        wordLimit: 5
    )
    #expect(chunks.first == "Heading")
    #expect(chunks.contains("Read bold notes."))
    #expect(MarkdownChunker.chunks("First paragraph.\n\n## Heading\n\nSecond paragraph.") == [
        "First paragraph.", "Heading", "Second paragraph.",
    ])
    #expect(chunks.allSatisfy { $0.split(separator: " ").count <= 5 })
    #expect(!chunks.joined().contains("https://"))
    #expect(!chunks.joined().contains("```"))
    #expect(MarkdownChunker.chunks(" \n\n ").isEmpty)
    #expect(MarkdownChunker.chunks("hello", wordLimit: 0).isEmpty)
    let long = (0 ..< 201).map { "word\($0)" }.joined(separator: " ")
    let bounded = MarkdownChunker.chunks(long)
    #expect(bounded.map { $0.split(separator: " ").count } == [80, 80, 41])
    #expect(bounded.joined(separator: " ") == long)
}

@Test func realAppleModelAndHybridRetrieval() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "local-library.md",
        markdown: """
        Search writing without an internet connection.

        A local library remains available while the network is offline.

        Semantic retrieval finds related ideas expressed with different words.

        Embeddings are computed on this device and stored locally.
        """
    )])
    let engine = SearchEngine(store: fixture.store)
    let report = try await engine.indexPending()
    #expect(report.generated > 3)
    let response = try await engine
        .search("I want to search my writing without an internet connection")
    #expect(response.matches.first?.passage.documentName == "local-library.md")
    #expect(response.matches.first?.passage.vector?.count == 512)
    #expect(response.matches.contains { $0.keywordRank != nil && $0.semanticRank != nil })
    let scoresAreFinite = response.matches.allSatisfy(\.score.isFinite)
    #expect(scoresAreFinite)
    #expect(zip(response.matches, response.matches.dropFirst()).allSatisfy { $0.score >= $1.score })
    #expect(try await engine.search("  ").matches.isEmpty)
    #expect(try await engine.search("notes", limit: 1).matches.count == 1)
}

@Test func reopeningReusesPersistedEmbeddingsAndPassageIDs() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let original = try await fixture.store.open(seed: [MarkdownDocument(
        name: "persistent.md",
        markdown: "Persist this passage across database reopenings."
    )])
    let first = SearchEngine(store: fixture.store, provider: TestEmbedder())
    _ = try await first.indexPending()
    let snapshot = try await fixture.store.searchSnapshot(query: "notes", candidateLimit: 100)
    let reopened = DocumentStore(url: fixture.databaseURL)
    #expect(try await reopened.open() == original)
    let provider = TestEmbedder()
    let report = try await SearchEngine(store: reopened, provider: provider).indexPending()
    #expect(report.generated == 0)
    #expect(report.completedNotes == 0)
    #expect(await provider.count() == 0)
    let restored = try await reopened.searchSnapshot(query: "notes", candidateLimit: 100)
    #expect(restored.passages.map(\.id) == snapshot.passages.map(\.id))
    #expect(restored.passages.map(\.vector) == snapshot.passages.map(\.vector))
    #expect(try fixture.scalar("PRAGMA journal_mode") == "wal")
}

@Test func editsReuseUnchangedChunksAndRenameUpdatesFTS() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var document = try #require(try await fixture.store.open(seed: [
        MarkdownDocument(name: "garden.md", markdown: "Apples are red.\n\nGardens need water."),
    ]).first)
    let provider = TestEmbedder()
    let engine = SearchEngine(store: fixture.store, provider: provider)
    #expect(try await engine.indexPending().generated == 2)
    let original = try await fixture.store.searchSnapshot(query: "Apples", candidateLimit: 10)
    document.markdown = "Apples are red.\n\nFlowers bloom in spring."
    document = try await fixture.store.save(document)
    let updated = try await engine.indexPending()
    #expect(updated.generated == 1)
    #expect(updated.reused == 1)
    let current = try await fixture.store.searchSnapshot(query: "Apples", candidateLimit: 10)
    #expect(current.passages.first(where: { $0.text == "Apples are red." })?.id == original.passages
        .first(where: { $0.text == "Apples are red." })?.id)
    #expect(try await fixture.store.searchSnapshot(query: "Gardens", candidateLimit: 10).keywordIDs
        .isEmpty)
    document.name = "ZEBRACODE.md"
    _ = try await fixture.store.save(document)
    #expect(try await engine.indexPending().generated == 0)
    #expect(try await fixture.store.searchSnapshot(query: "ZEBRACODE", candidateLimit: 10)
        .keywordIDs.count == 2)
    #expect(try fixture.scalar("SELECT count(*) FROM embeddings") == "2")
    #expect(try fixture.scalar("SELECT count(*) FROM note_revisions") == "3")
    #expect(try fixture.scalar("SELECT count(*) FROM local_changes") == "3")
}

@Test func failedIndexResumesFromCommittedCache() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "One passage.\n\nAnother passage."
    )])
    let failing = SearchEngine(store: fixture.store, provider: TestEmbedder(failAfter: 1))
    await #expect(throws: GleanaryError.self) { try await failing.indexPending() }
    #expect(try await fixture.store.statistics().pendingNotes == 1)
    #expect(try fixture.scalar("SELECT count(*) FROM embeddings") == "1")
    let reopened = DocumentStore(url: fixture.databaseURL)
    _ = try await reopened.open()
    let report = try await SearchEngine(store: reopened, provider: TestEmbedder()).indexPending()
    #expect(report.generated == 1)
    #expect(report.reused == 1)
    #expect(try await reopened.statistics().pendingNotes == 0)
}

@Test func staleJobCannotPublishOverNewerRevisionOrDeletion() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var document = try #require(try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "Original content."
    )]).first)
    let profile = try await TestEmbedder().profile()
    try await fixture.store.prepareIndex(profile)
    let stale = try #require(try await fixture.store.nextJob(for: profile))
    document.markdown = "Newer content."
    document = try await fixture.store.save(document)
    for passage in stale.passages {
        try await fixture.store.cacheVector([1, 0, 0], hash: passage.contentHash, profile: profile)
    }
    #expect(try await fixture.store.complete(stale) == false)
    #expect(try await fixture.store.statistics().pendingNotes == 1)
    let current = try #require(try await fixture.store.nextJob(for: profile))
    try await fixture.store.remove(document)
    #expect(try await fixture.store.complete(current) == false)
    #expect(try await fixture.store.documents().isEmpty)
    #expect(try await fixture.store.searchSnapshot(query: "content", candidateLimit: 10).passages
        .isEmpty)
    #expect(try fixture.scalar("SELECT count(*) FROM notes WHERE deletedAt IS NOT NULL") == "1")
    #expect(try fixture
        .scalar("SELECT kind FROM local_changes ORDER BY sequence DESC LIMIT 1") == "delete")
}

@Test func modelUpgradeActivatesAtomicallyAndDoesNotMixSpaces() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [
        MarkdownDocument(name: "one.md", markdown: "One passage."),
        MarkdownDocument(name: "two.md", markdown: "Another passage."),
    ])
    _ = try await SearchEngine(store: fixture.store, provider: TestEmbedder()).indexPending()
    let next = EmbeddingProfile(model: "synthetic", revision: 2, dimensions: 4)
    try await fixture.store.prepareIndex(next)
    let job = try #require(try await fixture.store.nextJob(for: next))
    await #expect(throws: GleanaryError.self) { try await fixture.store.complete(job) }
    for passage in job.passages {
        try await fixture.store.cacheVector([0, 0, 1, 0], hash: passage.contentHash, profile: next)
    }
    #expect(try await fixture.store.complete(job))
    let during = try await fixture.store.searchSnapshot(query: "passage", candidateLimit: 10)
    #expect(during.profile?.revision == 1)
    #expect(during.passages.allSatisfy { $0.vector?.count == 3 })
    let report = try await SearchEngine(
        store: fixture.store,
        provider: TestEmbedder(revision: 2, dimensions: 4)
    ).indexPending()
    #expect(report.generated == 1)
    let after = try await fixture.store.searchSnapshot(query: "passage", candidateLimit: 10)
    #expect(after.profile == next)
    #expect(after.passages.allSatisfy { $0.vector == [0, 0, 1, 0] })
    #expect(try await fixture.store.complete(job) == false)
}

@Test func corruptVectorsAreNotScoredAndAreRepaired() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "Searchable bicycle."
    )])
    let engine = SearchEngine(store: fixture.store, provider: TestEmbedder())
    _ = try await engine.indexPending()
    for data in [Data([1]), Data(repeating: 0, count: 12)] {
        try fixture.execute("UPDATE embeddings SET vector = ?", arguments: [data])
        let response = try await engine.search("bicycle")
        #expect(response.matches.first?.keywordRank == 1)
        #expect(response.matches.first?.semanticScore == nil)
        #expect(try await engine.indexPending().generated == 1)
        #expect(try await fixture.store.statistics().pendingNotes == 0)
    }
}

@Test func keywordSearchHandlesPhrasesFilenamesAndUntrustedSyntaxWithoutModel() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [
        MarkdownDocument(name: "ZXQ729.md", markdown: "A red apple beside a café."),
        MarkdownDocument(name: "other.md", markdown: "An apple painted red."),
    ])
    let provider = TestEmbedder()
    await provider.disable()
    let engine = SearchEngine(store: fixture.store, provider: provider)
    let phrase = try await engine.search("\"red apple\"")
    #expect(phrase.matches.count == 1)
    #expect(phrase.matches.first?.passage.documentName == "ZXQ729.md")
    #expect(phrase.notice != nil)
    #expect(try await engine.search("ZXQ729").matches.first?.keywordRank == 1)
    #expect(try await engine.search("cafe").matches.count == 1)
    for query in ["\"unfinished", "AND NOT", "O'Reilly", "DROP TABLE notes; --", "🔥", "**", "\""] {
        _ = try await engine.search(query)
    }
    #expect(try await fixture.store.documents().count == 2)
}

@Test func unavailableQueryModelFallsBackToKeywordSearch() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "A unique bicycle."
    )])
    let provider = TestEmbedder()
    let engine = SearchEngine(store: fixture.store, provider: provider)
    _ = try await engine.indexPending()
    await provider.disable()
    let response = try await engine.search("bicycle")
    #expect(response.matches.count == 1)
    #expect(response.matches.first?.semanticRank == nil)
    #expect(response.notice?.contains("Keyword results only") == true)
}

@Test func conflictPreservesBothRevisionsWithoutOverwritingWinner() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var original = try #require(try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "Original."
    )]).first)
    var winner = original
    winner.markdown = "Winning edit."
    winner = try await fixture.store.save(winner)
    original.markdown = "Conflicting draft."
    await #expect(throws: GleanaryError.self) { try await fixture.store.save(original) }
    #expect(try await fixture.store.documents().first == winner)
    let revisions = try await fixture.store.history(for: original.id)
    #expect(Set(revisions.map(\.markdown)) == ["Original.", "Winning edit.", "Conflicting draft."])
    #expect(revisions.first(where: { $0.markdown == "Conflicting draft." })?.parentID == original
        .revision)
    #expect(try fixture
        .scalar("SELECT kind FROM local_changes ORDER BY sequence DESC LIMIT 1") == "conflict")
}

@Test func legacyJSONMigrationIsIdempotentAndPreservesOriginalFile() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let id = UUID()
    let bytes = Data(
        "[{\"id\":\"\(id.uuidString)\",\"name\":\"legacy.md\",\"markdown\":\"Original notes.\"}]"
            .utf8
    )
    try bytes.write(to: fixture.legacyURL)
    let imported = try await fixture.store.open()
    #expect(imported.count == 1)
    #expect(imported.first?.id == id)
    #expect(imported.first?.revision != nil)
    #expect(try Data(contentsOf: fixture.legacyURL) == bytes)
    try await fixture.store.remove(#require(imported.first))
    let reopened = DocumentStore(url: fixture.databaseURL)
    #expect(try await reopened.open().isEmpty)
    #expect(try Data(contentsOf: fixture.legacyURL) == bytes)
}

@Test func newLibraryStartsEmpty() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    #expect(try await fixture.store.open().isEmpty)
    #expect(try fixture.scalar("SELECT count(*) FROM notes") == "0")
}

@Test func untouchedBuiltInSamplesAreRetiredWithoutDeletingEdits() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let originalText = """
    # Growing an orchard

    Apple trees need sunlight and well-drained soil. Water young trees deeply once a week during dry weather. A layer of mulch helps the ground retain moisture.

    ## Pruning

    Prune fruit trees in late winter while they are dormant. Remove dead branches and open the canopy so sunlight reaches the fruit.
    """
    let untouched = MarkdownDocument(name: "orchard.md", markdown: originalText)
    let edited = MarkdownDocument(
        name: "orchard.md",
        markdown: originalText + "\n\nMy own addition."
    )
    _ = try await fixture.store.open(seed: [untouched, edited])
    #expect(untouched.retiredSampleSignature ==
        "01fe06465c9c9e0d4143751faa0efc90672edae8b6a1bbac1248e555fcd4d7e2")
    #expect(try await fixture.store.retireBuiltInSamples() == 1)
    let remaining = try await fixture.store.documents()
    #expect(remaining.count == 1)
    #expect(remaining.first?.id == edited.id)
    #expect(remaining.first?.name == edited.name)
    #expect(remaining.first?.markdown == edited.markdown)
    #expect(try fixture.scalar("SELECT count(*) FROM purged_notes") == "1")
    #expect(try await fixture.store.retireBuiltInSamples() == 0)
}

@Test func malformedLegacyFileDoesNotSeedOrOverwriteAndCanBeRetried() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let bytes = Data("not JSON".utf8)
    try bytes.write(to: fixture.legacyURL)
    await #expect(throws: (any Error).self) { try await fixture.store.open() }
    #expect(try Data(contentsOf: fixture.legacyURL) == bytes)
    #expect(try fixture.scalar("SELECT count(*) FROM notes") == "0")
    try Data("[]".utf8).write(to: fixture.legacyURL)
    #expect(try await fixture.store.open().isEmpty)
}

@Test func importValidationDeduplicationAndAtomicFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [])
    let url = fixture.directory.appending(path: "sample.md")
    try Data("# Local note\n\nTest content.".utf8).write(to: url)
    let imported = try await fixture.store.readImports([url, url])
    try await fixture.store.importDocuments(imported)
    #expect(try await fixture.store.documents().count == 1)
    let invalid = MarkdownDocument(name: "", markdown: "bad")
    await #expect(throws: GleanaryError.self) {
        try await fixture.store.importDocuments([
            MarkdownDocument(name: "new.md", markdown: "Valid."),
            invalid,
        ])
    }
    #expect(try await fixture.store.documents().count == 1)
    for data in [Data([0xFF, 0xFE]), Data(repeating: 65, count: 1_000_001)] {
        try data.write(to: url)
        await #expect(throws: GleanaryError.self) { try await fixture.store.readImports([url]) }
    }
}

@Test func oneFailedNoteDoesNotBlockOtherNotes() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [
        MarkdownDocument(name: "bad.md", markdown: "Unembeddable text."),
        MarkdownDocument(name: "good.md", markdown: "A useful notebook."),
    ])
    let engine = SearchEngine(
        store: fixture.store,
        provider: TestEmbedder(failingText: "Unembeddable text.")
    )
    await #expect(throws: GleanaryError.self) { try await engine.indexPending() }
    #expect(try await fixture.store.statistics().pendingNotes == 1)
    let response = try await engine.search("notebook")
    #expect(response.matches.first?.passage.documentName == "good.md")
    #expect(response.matches.first?.semanticScore != nil)
}

@Test func cancelledIndexLeavesDurableJobForRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "A passage."
    )])
    let provider = PausedEmbedder()
    let engine = SearchEngine(store: fixture.store, provider: provider)
    let task = Task { try await engine.indexPending() }
    await provider.waitUntilPaused()
    task.cancel()
    await provider.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await fixture.store.statistics().pendingNotes == 1)
    #expect(try await SearchEngine(store: fixture.store, provider: TestEmbedder()).indexPending()
        .generated == 1)
}

@Test func failedMutationRollsBackNotesHistoryFTSAndJobsTogether() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let original = try #require(try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "Original text."
    )]).first)
    _ = try await SearchEngine(store: fixture.store, provider: TestEmbedder()).indexPending()
    try fixture.execute("""
    CREATE TRIGGER simulate_write_failure BEFORE INSERT ON local_changes BEGIN
    SELECT RAISE(ABORT, 'synthetic write failure'); END;
    """)
    var changed = original
    changed.markdown = "Different text."
    await #expect(throws: (any Error).self) { try await fixture.store.save(changed) }
    #expect(try await fixture.store.documents().first == original)
    #expect(try fixture.scalar("SELECT count(*) FROM note_revisions") == "1")
    #expect(try fixture.scalar("SELECT count(*) FROM local_changes") == "1")
    #expect(try await fixture.store.statistics().pendingNotes == 0)
    #expect(try await fixture.store.searchSnapshot(query: "Original", candidateLimit: 10).keywordIDs
        .count == 1)
    #expect(try await fixture.store.searchSnapshot(query: "Different", candidateLimit: 10)
        .keywordIDs.isEmpty)
}

@Test func chunkerUpgradeRebuildsDerivedTextWithoutChangingCanonicalHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let original = try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "Original text."
    )])
    _ = try await SearchEngine(store: fixture.store, provider: TestEmbedder()).indexPending()
    try fixture.execute("UPDATE metadata SET value = 'older-pipeline' WHERE key = 'chunker'")
    try fixture
        .execute("UPDATE passages SET text = 'Obsolete extraction', contentHash = 'old-hash'")
    let reopened = DocumentStore(url: fixture.databaseURL)
    #expect(try await reopened.open() == original)
    #expect(try await reopened.searchSnapshot(query: "Original", candidateLimit: 10).keywordIDs
        .count == 1)
    #expect(try await reopened.searchSnapshot(query: "Obsolete", candidateLimit: 10).keywordIDs
        .isEmpty)
    #expect(try await reopened.statistics().pendingNotes == 1)
    #expect(try fixture.scalar("SELECT count(*) FROM local_changes") == "1")
}

@Test func repeatedPassagesShareVectorsButKeepDistinctStableIdentities() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    var note = try #require(try await fixture.store.open(seed: [MarkdownDocument(
        name: "note.md",
        markdown: "Same passage.\n\nSame passage."
    )]).first)
    let engine = SearchEngine(store: fixture.store, provider: TestEmbedder())
    let report = try await engine.indexPending()
    #expect(report.generated == 1)
    #expect(report.reused == 1)
    let passages = try await fixture.store.searchSnapshot(query: "Same", candidateLimit: 10)
        .passages
    #expect(Set(passages.map(\.id)).count == 2)
    note.markdown = "Same passage."
    _ = try await fixture.store.save(note)
    #expect(try await engine.indexPending().generated == 0)
    let remaining = try await fixture.store.searchSnapshot(query: "Same", candidateLimit: 10)
        .passages
    #expect(remaining.first?.id == passages.first(where: { $0.ordinal == 1 })?.id)
    #expect(try fixture.scalar("SELECT count(*) FROM embeddings") == "1")
    _ = try await fixture.store.save(MarkdownDocument(name: "EmptyTitle", markdown: ""))
    #expect(try await fixture.store.searchSnapshot(query: "EmptyTitle", candidateLimit: 10)
        .keywordIDs.count == 1)
}

@Test func permanentDeletePrunesOnlyUnsharedVectors() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let documents = try await fixture.store.open(seed: [
        MarkdownDocument(
            name: "First",
            markdown: "Identical shared paragraph.\n\nUnique cobaltbeacon paragraph."
        ),
        MarkdownDocument(name: "Second", markdown: "Identical shared paragraph."),
    ])
    _ = try await SearchEngine(store: fixture.store, provider: TestEmbedder()).indexPending()
    let first = try #require(documents.first { $0.name == "First" })
    let second = try #require(documents.first { $0.name == "Second" })
    #expect(try fixture.scalar("SELECT count(*) FROM embeddings") == "2")
    let snapshot = try await fixture.store.searchSnapshot(query: "cobaltbeacon", candidateLimit: 10)
    let unique = try #require(snapshot.passages.first { $0.text.contains("cobaltbeacon") })
    let profile = try #require(snapshot.profile)
    _ = try await fixture.store.permanentlyRemove(first)
    try await fixture.store.cacheVector([1, 0, 0], hash: unique.contentHash, profile: profile)
    #expect(try fixture.scalar("SELECT count(*) FROM embeddings") == "1")
    #expect(try await fixture.store.searchSnapshot(query: "cobaltbeacon", candidateLimit: 10)
        .keywordIDs.isEmpty)
    _ = try await fixture.store.permanentlyRemove(second)
    #expect(try fixture.scalar("SELECT count(*) FROM embeddings") == "0")
    #expect(try fixture.scalar("SELECT count(*) FROM passages") == "0")
}

@Test @MainActor func duplicateCaptureSurfacesExistingNoteNotice() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [])
    let library = LibraryModel(
        store: fixture.store,
        provider: TestEmbedder(),
        graphProvider: UnavailableGraphProvider()
    )
    let request = CaptureRequest(identity: "fixture:duplicate-notice", label: "Duplicate fixture")
    let content = CapturedDocument(
        title: "Existing note",
        coverage: .note,
        blocks: [ContentBlock(
            kind: .paragraph,
            markdown: "A retained local note.",
            text: "A retained local note.",
            method: "fixture"
        )]
    )
    _ = try await fixture.store.enqueueCapture(request)
    let firstJob = try #require(await fixture.store.claimCapture())
    let noteID = try await fixture.store.publishCapture(firstJob, document: content, artifacts: [])
    await library.refreshCaptures()
    #expect(library.captureNotice == CaptureNotice(
        id: firstJob.id,
        noteID: noteID,
        title: "Saved to Gleanary",
        noteName: "Existing note"
    ))

    let duplicateID = try await fixture.store.enqueueCapture(request)
    #expect(try await fixture.store.claimCapture() == nil)
    let duplicateJob = try #require(try await fixture.store.captureJobs()
        .first { $0.id == duplicateID })
    #expect(duplicateJob.state == .ready)
    #expect(duplicateJob.noteID == noteID)
    #expect(duplicateJob.progress == "Already captured; existing note kept")
    await library.refreshCaptures()
    #expect(library.captureNotice == CaptureNotice(
        id: duplicateID,
        noteID: noteID,
        title: "Already in Gleanary",
        noteName: "Existing note"
    ))
    #expect(library.documentCount == 1)
}

@Test @MainActor func deletingNoteClearsResultsAndSurvivesRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let note = MarkdownDocument(
        name: "Delete fixture.md",
        markdown: "Synthetic cobaltbeacon content."
    )
    _ = try await fixture.store.open(seed: [note])
    let library = LibraryModel(
        store: fixture.store,
        provider: TestEmbedder(),
        graphProvider: UnavailableGraphProvider()
    )
    await library.load()
    await library.indexingTask?.value
    library.query = "cobaltbeacon"
    await library.search()
    #expect(!library.matches.isEmpty)
    library.summary = "Synthetic summary to clear."
    #expect(await library.remove(note.id))
    await library.indexingTask?.value
    #expect(library.documentCount == 0)
    #expect(library.matches.isEmpty)
    #expect(library.selectedMatch == nil)
    #expect(library.summary.isEmpty)
    #expect(!library.busy)
    #expect(await library.remove(note.id) == false)
    #expect(try await fixture.store.searchSnapshot(query: "cobaltbeacon", candidateLimit: 10)
        .passages.isEmpty)
    #expect(try await fixture.store.history(for: note.id).isEmpty)
    await #expect(throws: GleanaryError.self) { try await fixture.store.save(note) }
    let reopened = DocumentStore(url: fixture.databaseURL)
    #expect(try await reopened.open(seed: [note]).isEmpty)
    await library.graph.extractionTask?.value
    await library.graph.layoutTask?.value
}

@Test @MainActor func libraryRemainsUsableWhileEmbeddingAndIndexesEdits() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    _ = try await fixture.store.open(seed: [
        MarkdownDocument(name: "water.md", markdown: "Carry water on a long walk."),
        MarkdownDocument(name: "search.md", markdown: "Search a local notebook."),
        MarkdownDocument(name: "garden.md", markdown: "Apple trees need sunlight."),
    ])
    let provider = PausedEmbedder()
    let library = LibraryModel(
        store: fixture.store,
        provider: provider,
        graphProvider: UnavailableGraphProvider()
    )
    await library.load()
    await provider.waitUntilPaused()
    #expect(library.ready)
    #expect(!library.busy)
    #expect(library.indexing)
    library.query = "water"
    await library.search()
    #expect(!library.matches.isEmpty)
    #expect(library.matches.allSatisfy { $0.keywordRank != nil })
    #expect(await library.save(MarkdownDocument(
        name: "new.md",
        markdown: "Synthetic notebook content."
    )))
    #expect(library.documentCount == 4)
    await provider.release()
    await library.indexingTask?.value
    #expect(!library.indexing)
    #expect(library.pendingNotes == 0)
    #expect(library.error == nil)
    let restored = LibraryModel(
        store: DocumentStore(url: fixture.databaseURL),
        provider: TestEmbedder(), graphProvider: UnavailableGraphProvider()
    )
    await restored.load()
    await restored.indexingTask?.value
    #expect(restored.documentCount == library.documentCount)
    #expect(restored.documentGrid.document(at: 0) == library.documentGrid.document(at: 0))
    await library.graph.extractionTask?.value
    await library.graph.layoutTask?.value
    await restored.graph.extractionTask?.value
    await restored.graph.layoutTask?.value
}
