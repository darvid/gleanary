import Foundation

actor SearchEngine {
    private let store: DocumentStore
    private let provider: any EmbeddingProviding
    private let vectors: any VectorRanking
    private var indexing = false

    init(
        store: DocumentStore,
        provider: any EmbeddingProviding = AppleEmbeddingProvider(),
        vectors: any VectorRanking = ExactVectorSearch()
    ) {
        self.store = store
        self.provider = provider
        self.vectors = vectors
    }

    /// Jobs are durable; quitting mid-note leaves both the job and completed cache rows in SQLite.
    func indexPending(
        progress: @Sendable (LibraryStatistics) async -> Void = { _ in }
    ) async throws -> IndexingReport {
        guard !indexing else { return IndexingReport() }
        indexing = true
        defer { indexing = false }
        let profile = try await provider.profile()
        try await store.prepareIndex(profile)
        try await store.repairInvalidVectors()
        var report = IndexingReport()
        var firstFailure: (any Error)?
        while let job = try await store.nextJob(for: profile) {
            do {
                for passage in job.passages {
                    try Task.checkCancellation()
                    if try await store
                        .cachedVector(hash: passage.contentHash, profile: profile) != nil
                    {
                        report.reused += 1
                    } else {
                        let vector = try await provider.vector(for: passage.text, profile: profile)
                        try Task.checkCancellation()
                        try await store.cacheVector(
                            vector,
                            hash: passage.contentHash,
                            profile: profile
                        )
                        report.generated += 1
                    }
                }
                try Task.checkCancellation()
                if try await store.complete(job) {
                    report.completedNotes += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A problematic note must not prevent other notes from being indexed.
                try await store.recordFailure(job, message: error.localizedDescription)
                if firstFailure == nil {
                    firstFailure = error
                }
            }
            try await progress(store.statistics())
        }
        if let firstFailure {
            throw firstFailure
        }
        return report
    }

    func search(_ query: String, limit: Int = 20) async throws -> SearchResponse {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else {
            return SearchResponse(matches: [], notice: nil)
        }
        let limit = min(limit, 100)
        let candidateLimit = max(limit * 5, 100)
        let snapshot = try await store.searchSnapshot(query: query, candidateLimit: candidateLimit)
        var semantic: [SemanticCandidate] = []
        var notice: String?
        if let profile = snapshot.profile, snapshot.passages.contains(where: { $0.vector != nil }) {
            do {
                // Query vectors must come from the active profile, never a partially built
                // replacement.
                let vector = try await provider.vector(for: query, profile: profile)
                let normalized = try VectorMath.normalized(vector, dimensions: profile.dimensions)
                semantic = vectors.rank(
                    query: normalized,
                    passages: snapshot.passages,
                    limit: candidateLimit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notice = "Keyword results only. \(error.localizedDescription)"
            }
        } else {
            notice = "Keyword results only. Semantic indexing is pending."
        }
        return SearchResponse(
            matches: Self.fuse(snapshot: snapshot, semantic: semantic, limit: limit),
            notice: notice
        )
    }

    /// Reciprocal rank fusion avoids comparing BM25 and cosine scores on incompatible scales.
    private static func fuse(
        snapshot: SearchSnapshot,
        semantic: [SemanticCandidate],
        limit: Int
    ) -> [SearchMatch] {
        let keywordRanks = Dictionary(uniqueKeysWithValues: snapshot.keywordIDs.enumerated().map { (
            $0.element,
            $0.offset + 1
        ) })
        let semanticRanks = Dictionary(uniqueKeysWithValues: semantic.enumerated().map { (
            $0.element.id,
            $0.offset + 1
        ) })
        let similarities = Dictionary(uniqueKeysWithValues: semantic.map { ($0.id, $0.score) })
        return snapshot.passages.compactMap { passage in
            let keywordRank = keywordRanks[passage.id]
            let semanticRank = semanticRanks[passage.id]
            guard keywordRank != nil || semanticRank != nil else { return nil }
            let score = (keywordRank.map { 1.0 / Double(60 + $0) } ?? 0)
                + (semanticRank.map { 1.0 / Double(60 + $0) } ?? 0)
            return SearchMatch(
                passage: passage,
                score: score,
                semanticScore: similarities[passage.id],
                keywordRank: keywordRank,
                semanticRank: semanticRank
            )
        }.sorted {
            if $0.score == $1.score {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.score > $1.score
        }.prefix(limit).map(\.self)
    }
}
