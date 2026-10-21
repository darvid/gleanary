import Foundation
import Observation
import SwiftUI

struct LinkedSourceContext {
    let store: DocumentStore
    let revision: String
    let canAdd: Bool
    let add: @MainActor (URL, UUID, UUID?) async throws -> Void
    var viewSource: (@MainActor (UUID) -> Void)?
    var summarize: (@MainActor (UUID) -> Void)?
    var createAnotherSummary: (@MainActor (UUID) -> Void)?
    var summarizingID: UUID?
    var cancelSummary: (@MainActor () -> Void)?
    var changed: @MainActor () async -> Void = {}
}

extension EnvironmentValues {
    @Entry var linkedSourceContext: LinkedSourceContext?
}

@MainActor @Observable final class LinkedSourcesModel {
    private(set) var sources: [LinkedSource] = []
    private(set) var adding = Set<String>()
    private(set) var failures: [String: String] = [:]
    private(set) var error: String?
    private var documentID: UUID?
    private var documentRevision: UUID?
    private var loadToken = UUID()

    func load(_ document: MarkdownDocument, from store: DocumentStore) async {
        let token = UUID()
        loadToken = token
        if documentID != document.id {
            sources = []; failures = [:]; adding = []; error = nil
        }
        documentID = document.id
        documentRevision = document.revision
        do {
            let sources = try await store.linkedSources(in: document)
            guard !Task.isCancelled, token == loadToken else { return }
            self.sources = sources
            error = nil
        } catch {
            guard !Task.isCancelled, token == loadToken else { return }
            self.error = "Linked sources could not be checked. Try again."
        }
    }

    func add(
        _ candidates: [LinkedSource],
        for document: MarkdownDocument,
        using context: LinkedSourceContext
    ) async {
        guard context.canAdd else { return }
        let pending = candidates.filter { $0.canAdd && !adding.contains($0.id) }
        adding.formUnion(pending.map(\.id))
        for source in pending {
            guard !Task.isCancelled else { break }
            do {
                try await context.add(source.link.url, document.id, source.retryID)
                if documentID == document.id {
                    failures[source.id] = nil
                }
            } catch {
                if documentID == document.id {
                    failures[source.id] = "Could not queue this source. Try again."
                }
            }
        }
        if documentID == document.id {
            adding.subtract(pending.map(\.id))
            if documentRevision == document.revision {
                await load(document, from: context.store)
            }
        }
    }
}
