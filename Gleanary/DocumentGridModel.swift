import Foundation
import Observation

@MainActor @Observable
final class DocumentGridModel {
    static let pageSize = 80
    static let maximumPages = 6
    var query = ""
    var scope: LibraryScope = .all
    var kindFilter = LibraryKindFilter.all
    private(set) var total = 0
    private(set) var generation = 0
    private(set) var cacheVersion = 0
    private(set) var loading = false
    var error: String?
    @ObservationIgnored private var pages: [Int: [DocumentSummary]] = [:]
    @ObservationIgnored private var recency: [Int] = []
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var visiblePages: Set<Int> = []
    @ObservationIgnored private let store: DocumentStore
    @ObservationIgnored private let favicons: FaviconLoader
    private var token = UUID()
    private var changeSequence: Int64 = 0
    private struct Request: Equatable {
        let query: String
        let scope: LibraryScope
        let kind: LibraryKindFilter
    }

    private var activeRequest = Request(query: "", scope: .all, kind: .all)
    private var pendingRequest: Request?

    private var requestedState: Request {
        Request(query: String(query.prefix(1000)), scope: scope, kind: kindFilter)
    }

    init(store: DocumentStore, favicons: FaviconLoader = FaviconLoader()) {
        self.store = store
        self.favicons = favicons
    }

    var cachedDocumentCount: Int {
        pages.values.reduce(0) { $0 + $1.count }
    }

    var hasLoaded: Bool {
        _ = cacheVersion
        return pages[0] != nil
    }

    func document(at index: Int) -> DocumentSummary? {
        // SwiftUI must observe arrivals in the otherwise observation-ignored page cache.
        _ = cacheVersion
        let page = index / Self.pageSize
        guard index >= 0, let rows = pages[page],
              rows.indices.contains(index % Self.pageSize) else { return nil }
        return rows[index % Self.pageSize]
    }

    func reload() async {
        token = UUID()
        let expected = token
        let request = requestedState
        pendingRequest = request
        defer {
            if token == expected {
                loading = false
                pendingRequest = nil
            }
        }
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        faviconTask?.cancel(); faviconTask = nil
        // Keep the current rows mounted until their replacement is ready.
        loading = true; error = nil
        do {
            let page = try await store.documentPage(
                query: request.query,
                scope: request.scope,
                kind: request.kind
            )
            guard token == expected, !Task.isCancelled else { return }
            pages = [:]; recency = []; visiblePages = []
            activeRequest = request
            total = page.total
            changeSequence = page.changeSequence
            cache(page.documents, page: 0)
            generation += 1
        } catch {
            guard token == expected, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        guard token == expected else { return }
        loading = false
    }

    /// Reopening a browser or mounting its search task should reuse matching, valid rows.
    /// Mutations still call reload() explicitly; an interrupted first load has no page to reuse.
    func reloadIfNeeded() async {
        if loading, pendingRequest == requestedState {
            return
        }
        guard loading || pages[0] == nil || activeRequest != requestedState || error != nil
        else { return }
        await reload()
    }

    /// The collection supplies only its viewport, not every logical item in the library.
    func show(indices: [Int]) {
        visiblePages = Set(indices.filter { $0 >= 0 && $0 < total }.map { $0 / Self.pageSize })
        for page in Array(tasks.keys) where !visiblePages.contains(page) {
            tasks[page]?.cancel()
            tasks[page] = nil
        }
        for page in visiblePages.sorted() {
            if pages[page] != nil {
                touch(page)
            }
            requestPage(page)
        }
        startFavicons()
    }

    func requestPage(_ page: Int) {
        guard !loading, page >= 0, page * Self.pageSize < total, pages[page] == nil,
              tasks[page] == nil, tasks.count < 2, error == nil else { return }
        let expected = token
        let request = activeRequest
        tasks[page] = Task { [weak self, store] in
            do {
                let result = try await store.documentPage(
                    query: request.query,
                    offset: page * Self.pageSize,
                    scope: request.scope, kind: request.kind
                )
                guard let self, token == expected, !Task.isCancelled else { return }
                tasks[page] = nil
                // Offset pages must not combine different orderings after a concurrent mutation.
                guard result.changeSequence == changeSequence, result.total == total else {
                    await reload(); return
                }
                total = result.total
                cache(result.documents, page: page)
                startFavicons()
            } catch {
                guard let self, token == expected, !Task.isCancelled else { return }
                tasks[page] = nil
                self.error = error.localizedDescription
            }
        }
    }

    func pause() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        faviconTask?.cancel(); faviconTask = nil
        visiblePages = []
    }

    func waitForPages() async {
        for task in tasks.values {
            await task.value
        }
    }

    private func cache(_ rows: [DocumentSummary], page: Int) {
        pages[page] = rows
        touch(page)
        while pages.count > Self.maximumPages {
            guard let victim = recency.first(where: { !visiblePages.contains($0) }) ?? recency
                .first else { break }
            pages[victim] = nil
            recency.removeAll { $0 == victim }
        }
        cacheVersion += 1
    }

    private func touch(_ page: Int) {
        recency.removeAll { $0 == page }
        recency.append(page)
    }

    private func startFavicons() {
        guard faviconTask == nil else { return }
        let expected = token
        faviconTask = Task { [weak self] in
            guard let self else { return }
            // One optional network request at a time, and only for the current viewport.
            while token == expected, !Task.isCancelled,
                  let entry = nextMissingFavicon()
            {
                let favicon = await favicons.load(source: entry.document.sourceURL)
                guard token == expected, !Task.isCancelled else { return }
                do {
                    try await store.saveFavicon(favicon, for: entry.document.id)
                    guard token == expected, !Task.isCancelled else { return }
                    if let rows = pages[entry.page],
                       let index = rows.firstIndex(where: { $0.id == entry.document.id })
                    {
                        var updated = rows
                        updated[index] = DocumentSummary(
                            id: entry.document.id,
                            name: entry.document.name,
                            sourceURL: entry.document.sourceURL,
                            faviconData: favicon?.data,
                            faviconChecked: true,
                            kind: entry.document.kind, filing: entry.document.filing,
                            updatedAt: entry.document.updatedAt, coverage: entry.document.coverage,
                            previewImage: entry.document.previewImage
                        )
                        cache(updated, page: entry.page)
                    }
                } catch {
                    self.error = "Could not save the site icon. \(error.localizedDescription)"
                    break
                }
            }
            if token == expected {
                faviconTask = nil
            }
        }
    }

    private func nextMissingFavicon() -> (page: Int, document: DocumentSummary)? {
        for page in visiblePages.sorted() {
            if let document = pages[page]?
                .first(where: { !$0.faviconChecked && $0.sourceURL != nil })
            {
                return (page, document)
            }
        }
        return nil
    }
}
