import Foundation
@testable import Infactory
import Testing

@Suite(.serialized)
struct AutoCategorizerTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    @Test func classificationTextDropsTheFolderLabelAndLink() throws {
        let bookmark = try ImportedBookmark(
            url: #require(URL(string: "https://www.example.org/post")),
            title: "Tuning retrieval",
            folder: ["Development", "AI"],
            tags: ["rag"],
            excerpt: "How to tune retrieval.",
            created: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let text = FilingText.classification(
            name: bookmark.title,
            sourceURL: bookmark.url,
            markdown: bookmark.markdown
        )
        #expect(text.hasPrefix("Tuning retrieval · example.org — "))
        #expect(text.contains("How to tune retrieval."))
        #expect(text.contains("Tags: rag"))
        #expect(!text.contains("Folder"))
        #expect(!text.contains("Development"))
        #expect(!text.contains("Bookmarked"))
        #expect(!text.contains("https://"))
    }
}

/// Papers go to 51, gardens to a new home, mysteries nowhere, and anything else gets an
/// invented code that validation must drop.
private actor FakeFiler: ConversationInferring {
    nonisolated let capabilities = InferenceCapabilities(
        identifier: "fixture.filer", local: false, structured: true, streaming: false
    )
    private(set) var calls: [[BookmarkClassification.Item]] = []
    var failure: (any Error)?

    func fail(with error: (any Error)?) {
        failure = error
    }

    func plan(
        request _: String,
        context _: ConversationPlanningContext
    ) throws -> ConversationPlan {
        throw LinkSummaryError.unavailable
    }

    nonisolated func research(question _: String, sources _: [ResearchSource])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func reply(question _: String, role _: AgentRole, history _: [ConversationTurn])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    func classifyBookmarks(
        _ items: [BookmarkClassification.Item],
        categories: [DecimalCategory],
        examples _: [UUID: [String]]
    ) throws -> [BookmarkClassification.Answer] {
        calls.append(items)
        if let failure {
            throw failure
        }
        let reply = items.map { item -> [String: Any] in
            let text = item.text.lowercased()
            if text.contains("paper") {
                return ["item": item.number, "code": "51", "newCategory": "", "confident": true]
            }
            if text.contains("garden") {
                return [
                    "item": item.number,
                    "code": "",
                    "newCategory": "Gardening",
                    "confident": false,
                ]
            }
            if text.contains("mystery") {
                return ["item": item.number, "code": "", "newCategory": "", "confident": false]
            }
            return ["item": item.number, "code": "99", "newCategory": "", "confident": true]
        }
        return try BookmarkClassification.decode(
            JSONSerialization.data(withJSONObject: ["answers": reply]),
            items: items,
            categories: categories
        )
    }
}

extension AutoCategorizerTests {
    private func library(_ titles: [String]) async throws -> DocumentStore {
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        try await store.saveCategory(code: "51", name: "Papers")
        let bookmarks = try titles.enumerated().map { index, title in
            try ImportedBookmark(
                url: #require(URL(string: "https://site\(index).example/")),
                title: title
            )
        }
        let original = try await ArtifactStore(root: root.appending(path: "artifacts"))
            .retain(Data("export".utf8), kind: .text, name: "x.csv")
        _ = try await store.importBookmarks(
            bookmarks,
            plan: BookmarkFolderPlan(bookmarks: bookmarks, existing: []),
            original: original
        )
        return store
    }

    @Test func categorizesInBatchesAndReusesAnswers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let titles = (1 ... 45).map { "Paper number \($0)" } + ["Garden beds", "Mystery", "Bogus"]
        let store = try await library(titles)
        let filer = FakeFiler()
        let result = try await BookmarkCategorizer(store: store, inference: filer).run()
        #expect(result.total == 48)
        #expect(result.checked == 48)
        #expect(result.suggested == 46)
        #expect(result.failed == 1)
        #expect(await filer.calls.map(\.count).sorted() == [8, 40])
        let pending = try await store.pendingFilingSuggestions()
        #expect(pending.count == 46)
        #expect(pending.filter(\.confident).count == 45)
        #expect(pending.contains { $0.newCategory == "Gardening" && $0.categoryID == nil })
        #expect(pending.allSatisfy { $0.engine == "fixture.filer" })

        // "Mystery" has a cached no-fit answer; only the unusable "Bogus" reply is asked again.
        let again = try await BookmarkCategorizer(store: store, inference: filer).run()
        #expect(again.total == 2)
        #expect(again.reused == 1)
        #expect(again.failed == 1)
        #expect(await filer.calls.count == 3)
        #expect(await filer.calls.last?.count == 1)
    }

    @Test func accountProblemsStopTheRun() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await library(["Paper one"])
        let filer = FakeFiler()
        await filer.fail(with: ChatGPTError.usageLimit)
        await #expect(throws: ChatGPTError.usageLimit) {
            try await BookmarkCategorizer(store: store, inference: filer).run()
        }
        await filer.fail(with: ChatGPTError.invalidOutput)
        let result = try await BookmarkCategorizer(store: store, inference: filer).run()
        #expect(result.failed == 1)
        #expect(try await store.pendingFilingSuggestions().isEmpty)
    }

    @Test func reviewAcceptsUndoesRejectsAndCreatesSuggestedHomes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await library(["Paper one", "Paper two", "Garden beds"])
        _ = try await BookmarkCategorizer(store: store, inference: FakeFiler()).run()
        let pending = try await store.pendingFilingSuggestions()
        let papers = pending.filter { $0.categoryID != nil }.map(\.noteID)
        let accepted = try await store.acceptFilingSuggestions(papers)
        #expect(accepted.accepted == 2)
        #expect(try await store.documentPage(scope: .unfiled).total == 1)
        #expect(try await store.undoFilingSuggestions(batch: accepted.batch) == 2)
        #expect(try await store.documentPage(scope: .unfiled).total == 3)
        #expect(try await store.pendingFilingSuggestions().count == 3)

        try await store.rejectFilingSuggestions([papers[0]])
        #expect(try await store.pendingFilingSuggestions().count == 2)
        // A rejected note is not suggested again.
        #expect(try await !store.filingCandidates().contains { $0.id == papers[0] })

        let garden = try #require(pending.first { $0.newCategory == "Gardening" })
        let created = try await store.createSuggestedCategory("Gardening", code: "52")
        let converted = try await store.pendingFilingSuggestions()
            .first { $0.noteID == garden.noteID }
        #expect(converted?.categoryID == created)
        #expect(converted?.newCategory == nil)
    }
}

extension AutoCategorizerTests {
    /// Scores the on-device model against folder-filed bookmarks it hasn't seen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["INFACTORY_BOOKMARK_EXPORT"] != nil
            && ProcessInfo.processInfo.environment["INFACTORY_NATIVE_CLASSIFICATION"] == "1"))
    func onDeviceModelFilesHeldOutBookmarks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try #require(ProcessInfo.processInfo.environment["INFACTORY_BOOKMARK_EXPORT"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let file = try BookmarkParser.parse(data)
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let plan = try await BookmarkFolderPlan(
            bookmarks: file.bookmarks,
            existing: store.categories()
        )
        let original = try await ArtifactStore(root: root.appending(path: "artifacts"))
            .retain(data, kind: .text, name: "export.csv")
        _ = try await store.importBookmarks(file.bookmarks, plan: plan, original: original)
        let categories = try await store.categories()
        let examples = try await store.filingExamples()
        let held = Array(examples.filter { $0.id.uuid.0 % 5 == 0 }.prefix(30))
        var titles: [UUID: [String]] = [:]
        for example in examples where example.id.uuid.0 % 5 != 0
            && (titles[example.categoryID]?.count ?? 0) < 3
        {
            titles[example.categoryID, default: []]
                .append(example.text.components(separatedBy: " — ")[0])
        }
        let inference = AppleConversationInference()
        let codes = Dictionary(categories.map { ($0.id, $0.code) }, uniquingKeysWith: { a, _ in a })
        var correct = 0, answered = 0, confidentCorrect = 0, confident = 0
        let clock = ContinuousClock(), start = clock.now
        let size = inference.classificationBatchSize
        for offset in stride(from: 0, to: held.count, by: size) {
            let batch = Array(held[offset ..< min(offset + size, held.count)])
            let items = batch.enumerated().map {
                BookmarkClassification.Item(number: $0.offset + 1, text: $0.element.text)
            }
            let answers = try await inference.classifyBookmarks(
                items, categories: categories, examples: titles
            )
            for answer in answers {
                let expected = codes[batch[answer.item - 1].categoryID]
                answered += 1
                if answer.code == expected {
                    correct += 1
                }
                if answer.confident {
                    confident += 1
                    if answer.code == expected {
                        confidentCorrect += 1
                    }
                }
                print(
                    "NATIVE \(answer.code.isEmpty ? "new:" + answer.newCategory : answer.code) expected=\(expected ?? "?") confident=\(answer.confident) :: \(batch[answer.item - 1].text.prefix(70))"
                )
            }
        }
        print(
            "NATIVE answered=\(answered)/\(held.count) correct=\(correct) confident=\(confident) confidentCorrect=\(confidentCorrect) in \(clock.now - start)"
        )
    }
}

import AppKit
import SwiftUI

extension AutoCategorizerTests {
    /// Renders the review sheet; set INFACTORY_LIBRARY_SCREENSHOTS to keep the images.
    @Test @MainActor func reviewSheetRendersGroupedSuggestions() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let store = try await library(
            (1 ... 12).map { "Paper number \($0)" } + ["Garden beds", "Garden tools", "Mystery"]
        )
        _ = try await BookmarkCategorizer(store: store, inference: FakeFiler()).run()
        let model = LibraryModel(store: store)
        await model.load()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host =
                NSHostingView(rootView: FilingSuggestionsView(library: model) { FakeFiler() })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            for _ in 0 ..< 6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            if let directory = ProcessInfo.processInfo
                .environment["INFACTORY_LIBRARY_SCREENSHOTS"]
            {
                try png.write(to: URL(fileURLWithPath: directory)
                    .appending(path: "filing-suggestions-\(name).png"))
            }
        }
    }
}

/// Answers slowly so a run can be stopped mid-way.
private actor SlowFiler: ConversationInferring {
    nonisolated let capabilities = InferenceCapabilities(
        identifier: "fixture.slow", local: false, structured: true, streaming: false
    )
    private(set) var calls = 0

    func plan(
        request _: String,
        context _: ConversationPlanningContext
    ) throws -> ConversationPlan {
        throw LinkSummaryError.unavailable
    }

    nonisolated func research(question _: String, sources _: [ResearchSource])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func reply(question _: String, role _: AgentRole, history _: [ConversationTurn])
        -> AsyncThrowingStream<ResearchEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    func classifyBookmarks(
        _ items: [BookmarkClassification.Item],
        categories _: [DecimalCategory],
        examples _: [UUID: [String]]
    ) async throws -> [BookmarkClassification.Answer] {
        calls += 1
        try await Task.sleep(for: .milliseconds(200))
        return items.map {
            BookmarkClassification.Answer(
                item: $0.number,
                code: "51",
                newCategory: "",
                confident: true
            )
        }
    }
}

extension AutoCategorizerTests {
    @Test @MainActor func stoppingShowsStoppingThenEndsTheRun() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await library((1 ... 400).map { "Paper \($0)" })
        let model = LibraryModel(store: store)
        await model.load()
        let filer = SlowFiler()
        model.startCategorizing(using: filer)
        #expect(model.categorizationState == .running)
        while (model.categorization?.checked ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.stopCategorizing()
        #expect(model.categorizationState == .stopping)
        let callsAtStop = await filer.calls
        while model.categorizationState != .idle {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.categorizationStopped)
        // At most the batches already in flight; none start after Stop.
        #expect(await filer.calls <= callsAtStop + filer.classificationConcurrency)
        let checked = model.categorization?.checked ?? 0
        #expect(checked > 0 && checked < 400)
        // Picking up again only asks about what's left.
        #expect(try await store.filingCandidates().count < 400)
    }
}
