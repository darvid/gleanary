import Foundation

/// An unfiled note, reduced to what classification reads.
struct FilingCandidate: Sendable, Equatable {
    let id: UUID
    let revision: UUID
    let title: String
    let host: String?
    let text: String
}

/// A filed note; its title shows the model what belongs in its home.
struct FilingExample: Sendable, Equatable {
    let id: UUID
    let categoryID: UUID
    let text: String
}

enum FilingText {
    static let maximumCharacters = 600

    /// Title, site and the start of the note, minus the link line and the import's folder label.
    /// The folder is left out so filed and unfiled bookmarks are compared on content alone.
    static func classification(name: String, sourceURL: URL?, markdown: String) -> String {
        var body = markdown
        if body.hasPrefix("["), let end = body.firstIndex(of: "\n") {
            body = String(body[end...])
        }
        body = body.replacingOccurrences(
            of: #"Folder: [^·\n]*(· )?"#, with: "", options: .regularExpression
        )
        body = body.replacingOccurrences(
            of: #"Bookmarked [^·\n]*"#, with: "", options: .regularExpression
        )
        body = body.replacingOccurrences(
            of: #"[>#*\[\]()]+"#,
            with: " ",
            options: .regularExpression
        )
        body = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let host = sourceURL?.host()?.replacingOccurrences(of: "www.", with: "")
        let head = [name, host].compactMap(\.self).joined(separator: " · ")
        return String((head + " — " + body).prefix(maximumCharacters))
    }
}

struct CategorizationProgress: Sendable, Equatable {
    var total = 0
    var checked = 0
    var suggested = 0
    /// Answered from earlier runs without a model call.
    var reused = 0
    /// Items whose batch came back unusable; they stay unfiled and are retried next run.
    var failed = 0
}

/// Suggests homes for every unfiled note. Work is durable per batch: suggestions and model
/// answers are saved as they arrive, so stopping and starting again repeats nothing.
actor BookmarkCategorizer {
    let store: DocumentStore
    let inference: any ConversationInferring

    init(store: DocumentStore, inference: any ConversationInferring) {
        self.store = store
        self.inference = inference
    }

    /// What items are classified against: the homes, a few titles from each, and a key that
    /// changes with the engine or the categories, so a cached answer is reused only while it
    /// still means the same.
    struct Taxonomy: Sendable {
        let categories: [DecimalCategory]
        let examples: [UUID: [String]]
        let engine: String
        let key: String
    }

    func taxonomy() async throws -> Taxonomy {
        let categories = try await store.categories()
        guard !BookmarkClassification.choices(categories).isEmpty else {
            throw CategorizationError.noCategories
        }
        let engine = inference.capabilities.identifier
        return try await Taxonomy(
            categories: categories,
            examples: Self.exampleTitles(store.filingExamples()),
            engine: engine,
            key: ContentHash.of(engine + "\n" + categories.map(\.label).joined(separator: "\n"))
        )
    }

    func run(
        progress: @escaping @Sendable (CategorizationProgress) async -> Void = { _ in }
    ) async throws -> CategorizationProgress {
        let candidates = try await store.filingCandidates()
        let taxonomy = try await taxonomy()
        var state = CategorizationProgress(total: candidates.count)
        await progress(state)
        let size = inference.classificationBatchSize
        let batches = stride(from: 0, to: candidates.count, by: size).map {
            Array(candidates[$0 ..< min($0 + size, candidates.count)])
        }
        var next = 0
        try await withThrowingTaskGroup(of: CategorizationProgress.self) { group in
            func start() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask { try await self.classify(batch, taxonomy: taxonomy) }
            }
            for _ in 0 ..< max(1, inference.classificationConcurrency) {
                start()
            }
            while let done = try await group.next() {
                state.checked += done.checked
                state.suggested += done.suggested
                state.reused += done.reused
                state.failed += done.failed
                await progress(state)
                try Task.checkCancellation()
                start()
            }
        }
        return state
    }

    /// One batch's answers, keyed by position: from earlier runs where possible, else from
    /// one model call whose answers are cached as they arrive.
    struct BatchAnswers: Sendable {
        var answers: [Int: CachedClassification] = [:]
        var reused = 0
        /// Items whose answer came back unusable.
        var failed = 0
        /// Whether a model call was made.
        var called = false
    }

    func answers(_ batch: [FilingCandidate], taxonomy: Taxonomy) async throws -> BatchAnswers {
        var result = BatchAnswers()
        let keys = batch.map { ContentHash.of(taxonomy.key + "\n" + $0.text) }
        let cached = try await store.cachedClassifications(keys)
        let misses = batch.indices.filter { cached[keys[$0]] == nil }
        for index in batch.indices {
            if let answer = cached[keys[index]] {
                result.answers[index] = answer
                result.reused += 1
            }
        }
        guard !misses.isEmpty else { return result }
        // A batch scheduled just before Stop must not send a request.
        try Task.checkCancellation()
        let items = misses.enumerated().map { offset, index in
            BookmarkClassification.Item(number: offset + 1, text: batch[index].text)
        }
        result.called = true
        do {
            var fresh: [String: CachedClassification] = [:]
            for answer in try await inference.classifyBookmarks(
                items, categories: taxonomy.categories, examples: taxonomy.examples
            ) {
                let index = misses[answer.item - 1]
                let value = CachedClassification(
                    code: answer.code,
                    newCategory: answer.newCategory.isEmpty ? nil : answer.newCategory,
                    confident: answer.confident
                )
                result.answers[index] = value
                fresh[keys[index]] = value
            }
            try await store.cacheClassifications(fresh)
            result.failed += misses.count - fresh.count
        } catch let error where Self.stopsRun(error) {
            throw error
        } catch {
            // One unusable reply skips its batch; the rest of the run continues.
            result.failed += misses.count
        }
        return result
    }

    private func classify(
        _ batch: [FilingCandidate],
        taxonomy: Taxonomy
    ) async throws -> CategorizationProgress {
        let found = try await answers(batch, taxonomy: taxonomy)
        var result = CategorizationProgress(
            checked: batch.count, reused: found.reused, failed: found.failed
        )
        let byCode = Dictionary(
            taxonomy.categories.map { ($0.code, $0.id) }, uniquingKeysWith: { first, _ in first }
        )
        let drafts = found.answers.compactMap { index, answer -> FilingSuggestionDraft? in
            let categoryID = byCode[answer.code]
            guard categoryID != nil || answer.newCategory != nil else { return nil }
            return FilingSuggestionDraft(
                noteID: batch[index].id,
                categoryID: categoryID,
                newCategory: categoryID == nil ? answer.newCategory : nil,
                // The on-device model's own confidence didn't track accuracy on held-out
                // bookmarks, so its suggestions are always reviewed rather than bulk-accepted.
                confidence: answer.confident && !inference.capabilities.local ? 0.9 : 0.5,
                engine: taxonomy.engine
            )
        }
        try await store.saveFilingSuggestions(drafts)
        result.suggested = drafts.count
        return result
    }

    /// Sign-in, plan, usage and availability problems affect every batch, so they end the run.
    static func stopsRun(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let error = error as? ChatGPTError {
            return [.signInRequired, .planNotAuthorized, .usageLimit, .modelDenied, .network,
                    .keychain, .busy].contains(error)
        }
        if let error = error as? LinkSummaryError {
            return [.unavailable, .modelRestricted, .modelBusy].contains(error)
        }
        return false
    }

    /// A few recent titles per category show the model what each home holds.
    private static func exampleTitles(_ examples: [FilingExample]) -> [UUID: [String]] {
        var titles: [UUID: [String]] = [:]
        for example in examples where (titles[example.categoryID]?.count ?? 0) < 3 {
            let title = example.text.components(separatedBy: " — ").first ?? example.text
            titles[example.categoryID, default: []].append(title)
        }
        return titles
    }
}

enum CategorizationError: LocalizedError {
    case noCategories

    var errorDescription: String? {
        "Add some categories first—auto-categorization chooses among your existing homes."
    }
}
