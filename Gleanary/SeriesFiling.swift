import Foundation

/// Filing is a separate, optional handoff after the complete series has been published.
enum SeriesFiling {
    struct Status: Identifiable, Sendable {
        var id: UUID {
            taskID
        }

        let taskID: UUID
        let noteIDs: [UUID]
        let unfiled: Int
        let homes: [String]
        let batches: [UUID]
    }

    static func suggestions(
        candidates: [FilingCandidate],
        answers: [Int: CachedClassification],
        taxonomy: BookmarkCategorizer.Taxonomy,
        local: Bool
    ) -> [FilingSuggestionDraft] {
        let categories = Dictionary(
            taxonomy.categories.map { ($0.code, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        return candidates.indices.compactMap { index in
            guard let answer = answers[index] else { return nil }
            let category = categories[answer.code]
            let name = answer.newCategory.flatMap { NoteSeries.plain($0, limit: 60) ? $0 : nil }
            guard category != nil || name != nil else { return nil }
            return FilingSuggestionDraft(
                noteID: candidates[index].id,
                categoryID: category,
                newCategory: category == nil ? name : nil,
                confidence: answer.confident && !local ? 0.9 : 0.5,
                engine: taxonomy.engine
            )
        }
    }
}

extension AgentCoordinator {
    func filePublishedSeries(
        _ run: NoteSeries.Run,
        changed: @escaping @Sendable () async -> Void
    ) async {
        do {
            guard let candidates = try await store.beginSeriesFiling(run),
                  !candidates.isEmpty else { return }
            let filingModel = filingInference ?? inference
            let classifier = BookmarkCategorizer(store: store, inference: filingModel)
            let taxonomy = try await classifier.taxonomy(allowEmpty: true)
            let answers = try await classifier.answers(candidates, taxonomy: taxonomy)
            try Task.checkCancellation()
            let suggestions = SeriesFiling.suggestions(
                candidates: candidates,
                answers: answers.answers,
                taxonomy: taxonomy,
                local: filingModel.capabilities.local
            )
            try await store.finishSeriesFiling(
                run,
                candidates: candidates,
                suggestions: suggestions,
                categories: taxonomy.categories
            )
        } catch {
            // Publication already succeeded. The review action remains available even if filing
            // is interrupted, unavailable, or its remaining model budget has been exhausted.
        }
        await changed()
    }
}
