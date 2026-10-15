import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

private let raindropCSV = """
id,title,note,excerpt,url,folder,tags,created,cover,highlights,favorite
1,Field notes on retention,,"Multi-line
excerpt, with a comma and ""quotes"".",https://notes.example/retention,Knowledge / Articles,"reading, memory",2025-03-04T10:00:00.000Z,,Highlight:Spacing beats cramming.,false
2,Synthetic toolkit,Try later,,https://tools.example/kit,Development / Libraries / Frontend,,2025-03-05T10:00:00.000Z,,,true
3,Unsorted paper,,An abstract.,https://papers.example/p1,Unsorted,,2025-03-06T10:00:00.000Z,,,false
4,Extension page,,,moz-extension://abc/page.html,Unsorted,,2025-03-07T10:00:00.000Z,,,false
5,Repeated toolkit,,,https://tools.example/kit,Development,,2025-03-08T10:00:00.000Z,,,false

"""

private let netscapeHTML = """
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
<DL><p>
  <DT><H3>Bookmarks bar</H3>
  <DL><p>
    <DT><H3>Research</H3>
    <DL><p>
      <DT><A HREF="https://papers.example/p2" ADD_DATE="1700000000" TAGS="ml,papers">Second paper</A>
      <DD>A short description.
    </DL><p>
    <DT><A HREF="javascript:void(0)">Bookmarklet</A>
    <DT><A HREF="https://home.example/">Home</A>
  </DL><p>
</DL><p>
"""

@Suite(.serialized)
struct BookmarkImportTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    @Test func parsesRaindropCSV() throws {
        let file = try BookmarkParser.parse(Data(raindropCSV.utf8))
        #expect(file.format == .csv)
        #expect(file.skipped == 1)
        #expect(file.bookmarks.count == 4)
        let first = try #require(file.bookmarks.first)
        #expect(first.folder == ["Knowledge", "Articles"])
        #expect(first.tags == ["reading", "memory"])
        #expect(first.excerpt == "Multi-line\nexcerpt, with a comma and \"quotes\".")
        #expect(first.highlights == ["Spacing beats cramming."])
        #expect(first.created == ISO8601DateFormatter().date(from: "2025-03-04T10:00:00Z"))
        #expect(file.bookmarks[1].note == "Try later")
        #expect(file.bookmarks[2].folder.isEmpty)
        #expect(first.markdown.contains("> Spacing beats cramming."))
        #expect(first.markdown.contains("Folder: Knowledge / Articles"))
    }

    @Test func parsesNetscapeBookmarksWithoutTheBrowserRoot() throws {
        let file = try BookmarkParser.parse(Data(netscapeHTML.utf8))
        #expect(file.format == .netscapeHTML)
        #expect(file.skipped == 1)
        #expect(file.bookmarks.map(\.title) == ["Second paper", "Home"])
        #expect(file.bookmarks[0].folder == ["Research"])
        #expect(file.bookmarks[0].tags == ["ml", "papers"])
        #expect(file.bookmarks[0].excerpt == "A short description.")
        #expect(file.bookmarks[0].created == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(file.bookmarks[1].folder.isEmpty)
    }

    @Test func rejectsFilesThatAreNotBookmarks() {
        #expect(throws: BookmarkImportError.self) {
            try BookmarkParser.parse(Data("name,age\nAda,36\n".utf8))
        }
    }

    @Test func folderPlanUsesExistingNamesThenFreeBlocks() throws {
        let file = try BookmarkParser.parse(Data(raindropCSV.utf8))
        let inbox = DecimalCategory(id: UUID(), code: "10", name: "Inbox")
        let articles = DecimalCategory(id: UUID(), code: "11", name: "Articles")
        let plan = BookmarkFolderPlan(bookmarks: file.bookmarks, existing: [inbox, articles])
        #expect(plan.unsorted == 1)
        // Development has three bookmarks across its subtree, so it takes the first free block.
        #expect(plan.destination(for: ["Development"]) == .new(code: "20", name: "Development"))
        #expect(plan.destination(for: ["Development", "Libraries"]) ==
            .new(code: "21", name: "Libraries"))
        // Deeper folders join their nearest placed parent.
        #expect(plan.destination(for: ["Development", "Libraries", "Frontend"]) ==
            .new(code: "21", name: "Libraries"))
        #expect(plan.destination(for: ["Knowledge", "Articles"]) == .existing(articles.id))
        #expect(plan.destination(for: []) == .unfiled)
        #expect(plan.newCategories.map(\.code) == ["20", "21", "30"])
    }

    @Test func importsMetadataOnceAndFilesByPlan() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let file = try BookmarkParser.parse(Data(raindropCSV.utf8))
        let plan = try await BookmarkFolderPlan(
            bookmarks: file.bookmarks,
            existing: store.categories()
        )
        let artifacts = ArtifactStore(root: root.appending(path: "artifacts"))
        let original = try await artifacts.retain(
            Data(raindropCSV.utf8), kind: .text, name: "export.csv"
        )
        let report = try await store.importBookmarks(file.bookmarks, plan: plan, original: original)
        #expect(report.imported == 3)
        #expect(report.duplicates == 1)
        #expect(report.filed == 2)
        #expect(report.unfiledIDs.count == 1)
        #expect(report.categoriesCreated == plan.newCategories.count)
        let page = try await store.documentPage()
        #expect(page.total == 3)
        #expect(page.documents.allSatisfy { $0.coverage == "bookmark" && $0.kind == "source" })
        // Bookmark dates order the library, newest first.
        #expect(page.documents.map(\.name) == [
            "Unsorted paper", "Synthetic toolkit", "Field notes on retention",
        ])
        let snapshot = try await store.searchSnapshot(query: "cramming", candidateLimit: 10)
        #expect(!snapshot.keywordIDs.isEmpty)
        let again = try await store.importBookmarks(file.bookmarks, plan: plan, original: original)
        #expect(again.imported == 0)
        #expect(again.duplicates == 4)
    }

    @Test func fetchingABookmarkUpgradesTheSameNote() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let bookmark = try ImportedBookmark(
            url: #require(URL(string: "https://fixture.example/page")),
            title: "Saved for later",
            excerpt: "Only the export's excerpt."
        )
        let artifacts = ArtifactStore(root: root.appending(path: "artifacts"))
        let original = try await artifacts.retain(Data("export".utf8), kind: .text, name: "x.csv")
        let report = try await store.importBookmarks(
            [bookmark],
            plan: BookmarkFolderPlan(bookmarks: [bookmark], existing: []),
            original: original
        )
        let noteID = try #require(report.unfiledIDs.first)
        let engine = IngestionEngine(
            store: store,
            fetcher: ArticleFetcher(),
            summarizer: FixtureLinkSummarizer()
        )
        _ = try #require(await engine.enqueueBookmarkFetch(noteID: noteID))
        // Opening it again while the fetch is queued must not queue a second one.
        #expect(try await engine.enqueueBookmarkFetch(noteID: noteID) == nil)
        try await engine.run()
        #expect(try await store.captureJobs().count == 1)
        let documents = try await store.documents()
        #expect(documents.map(\.id) == [noteID])
        #expect(documents.first?.markdown.contains("synthetic summary") == true)
        #expect(try await store.unfetchedBookmarkURL(noteID: noteID) == nil)
        #expect(try await engine.enqueueBookmarkFetch(noteID: noteID) == nil)
        let captureID = try #require(await store.captureID(for: noteID))
        #expect(try await store.captureDetail(id: captureID).document.coverage == .article)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_BOOKMARK_EXPORT"] != nil))
    func importsARealExportQuickly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try #require(ProcessInfo.processInfo.environment["GLEANARY_BOOKMARK_EXPORT"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let clock = ContinuousClock()
        let parseStart = clock.now
        let file = try BookmarkParser.parse(data)
        let parsed = clock.now - parseStart
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let plan = try await BookmarkFolderPlan(
            bookmarks: file.bookmarks,
            existing: store.categories()
        )
        let original = try await ArtifactStore(root: root.appending(path: "artifacts"))
            .retain(data, kind: .text, name: "export.csv")
        let importStart = clock.now
        let report = try await store.importBookmarks(file.bookmarks, plan: plan, original: original)
        let imported = clock.now - importStart
        print("""
        BOOKMARKS parsed=\(file.bookmarks.count) skipped=\(file.skipped) in \(parsed); \
        imported=\(report.imported) duplicates=\(report.duplicates) rejected=\(report.rejected) \
        filed=\(report.filed) unfiled=\(report.unfiledIDs.count) \
        categories=\(report.categoriesCreated) in \(imported)
        """)
        for folder in plan.folders {
            print("PLAN \(folder.id) (\(folder.count)) -> \(folder.destination)")
        }
        #expect(report.imported > 0)
    }
}

extension BookmarkImportTests {
    /// A background fetch that fails reports on its item, not in the window's notice, and
    /// waits for Try Again instead of failing again on every visit.
    @Test @MainActor func aFailedBookmarkFetchStaysOnItsItem() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        // `.invalid` never resolves, so the fetch fails without reaching any server.
        let bookmark = try ImportedBookmark(
            url: #require(URL(string: "https://fixture.invalid/page")),
            title: "Unreachable", excerpt: "Only the export's excerpt."
        )
        let original = try await ArtifactStore(root: root.appending(path: "artifacts"))
            .retain(Data("export".utf8), kind: .text, name: "x.csv")
        let report = try await store.importBookmarks(
            [bookmark], plan: BookmarkFolderPlan(bookmarks: [bookmark], existing: []),
            original: original
        )
        let noteID = try #require(report.unfiledIDs.first)
        let library = LibraryModel(store: store)
        await library.load()
        await library.fetchBookmarkIfNeeded(noteID)
        for _ in 0 ..< 100 where library.bookmarkFetchFailure(for: noteID) == nil {
            try await Task.sleep(for: .milliseconds(100))
            await library.refreshCaptures()
        }
        let failure = try #require(library.bookmarkFetchFailure(for: noteID))
        #expect(failure.error != nil)
        #expect(library.captureFailure == nil)
        #expect(library.error == nil)
        await library.fetchBookmarkIfNeeded(noteID)
        #expect(try await store.captureJobs().count == 1)
        // Clearing forgets the failure; the bookmark itself stays, ready to fetch again.
        await library.clearFailedCaptures([failure.id])
        #expect(try await store.captureJobs().isEmpty)
        #expect(library.bookmarkFetchFailure(for: noteID) == nil)
        #expect(try await store.unfetchedBookmarkURL(noteID: noteID) != nil)
        #expect(try await store.documents().map(\.id) == [noteID])
    }

    /// Renders the review sheet; set GLEANARY_LIBRARY_SCREENSHOTS to keep the images.
    @Test @MainActor func reviewSheetRendersFolderDestinations() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [])
        let library = LibraryModel(store: store)
        let url = root.appending(path: "export.csv")
        let export = ProcessInfo.processInfo.environment["GLEANARY_BOOKMARK_EXPORT"]
            .map { URL(fileURLWithPath: $0) }
        try (export.map { try Data(contentsOf: $0) } ?? Data(raindropCSV.utf8)).write(to: url)
        await library.load()
        let draft = try await library.prepareBookmarkImport(url)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: BookmarkImportView(library: library, draft: draft))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            for _ in 0 ..< 4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            if let directory = ProcessInfo.processInfo
                .environment["GLEANARY_LIBRARY_SCREENSHOTS"]
            {
                try png.write(to: URL(fileURLWithPath: directory)
                    .appending(path: "bookmark-import-\(name).png"))
            }
        }
    }
}

private struct ArticleFetcher: SourceFetching {
    func fetch(_ url: URL) throws -> DownloadedContent {
        let prose = String(
            repeating: "The fetched article explains spaced repetition in practical detail. ",
            count: 20
        )
        return DownloadedContent(
            data: Data("""
            <!doctype html><html><head><title>Fetched article</title></head>
            <body><article><h1>Fetched article</h1><p>\(prose)</p><p>\(prose)</p></article></body></html>
            """.utf8),
            url: url,
            mime: "text/html",
            encoding: "utf-8"
        )
    }
}

extension BookmarkImportTests {
    @Test func librarianAnswersAreValidatedBeforeTheyChangeThePlan() throws {
        let file = try BookmarkParser.parse(Data(raindropCSV.utf8))
        let inbox = DecimalCategory(id: UUID(), code: "10", name: "Inbox")
        let reading = DecimalCategory(id: UUID(), code: "11", name: "Reading")
        let categories = [inbox, reading]
        let plan = BookmarkFolderPlan(bookmarks: file.bookmarks, existing: categories)
        let folders = FolderMapping.folders(plan: plan, bookmarks: file.bookmarks)
        func number(_ path: String) throws -> Int {
            try #require(folders.first { $0.path.joined(separator: " / ") == path }).number
        }
        let answers = try [
            // Existing by code.
            FolderMapping.Answer(
                folder: number("Knowledge"),
                action: "existing",
                code: "11",
                name: "",
                reason: "Reading material"
            ),
            // "New" that duplicates an existing name becomes that category.
            FolderMapping.Answer(
                folder: number("Knowledge / Articles"),
                action: "new",
                code: "21",
                name: "reading",
                reason: "Articles are reading"
            ),
            // Two folders merged under one new code.
            FolderMapping.Answer(
                folder: number("Development"),
                action: "new",
                code: "30",
                name: "Engineering",
                reason: "Software work"
            ),
            FolderMapping.Answer(
                folder: number("Development / Libraries"),
                action: "new",
                code: "30",
                name: "Engineering",
                reason: "Same subject"
            ),
            // Conflicting name for an already-claimed new code: ignored.
            FolderMapping.Answer(
                folder: number("Development / Libraries / Frontend"),
                action: "new",
                code: "30",
                name: "Frontend",
                reason: "x"
            ),
            // A taken code with a different name: ignored.
            FolderMapping.Answer(
                folder: number("Knowledge"),
                action: "new",
                code: "10",
                name: "Notes",
                reason: "duplicate answer"
            ),
            // Unknown folder number: ignored.
            FolderMapping.Answer(folder: 999, action: "unfiled", code: "", name: "", reason: ""),
        ]
        let result = FolderMapping.apply(
            answers,
            to: plan,
            folders: folders,
            categories: categories
        )
        #expect(result.plan.destination(for: ["Knowledge"]) == .existing(reading.id))
        #expect(result.plan.destination(for: ["Knowledge", "Articles"]) == .existing(reading.id))
        #expect(result.plan.destination(for: ["Development"]) == .new(
            code: "30",
            name: "Engineering"
        ))
        #expect(result.plan.destination(for: ["Development", "Libraries"]) ==
            .new(code: "30", name: "Engineering"))
        // Untouched by the rejected answer.
        #expect(result.plan.destination(for: ["Development", "Libraries", "Frontend"]) ==
            plan.destination(for: ["Development", "Libraries", "Frontend"]))
        #expect(result.reasons["Knowledge"] == "Reading material")
        #expect(result.plan.newCategories.map(\.code).contains("30"))
        // Every code maps to exactly one name across the whole plan.
        var names: [String: Set<String>] = [:]
        for folder in result.plan.folders {
            if case let .new(code, name) = folder.destination {
                names[code, default: []].insert(name)
            }
        }
        #expect(names.values.allSatisfy { $0.count == 1 })
        // A folder the Librarian skipped that shares a claimed code follows the claimed name.
        let partial = try FolderMapping.apply([
            FolderMapping.Answer(
                folder: number("Development"),
                action: "new",
                code: plan.newCategories[0].code,
                name: "Engineering",
                reason: ""
            ),
        ], to: plan, folders: folders, categories: categories)
        let claimed = plan.newCategories[0].code
        #expect(partial.plan.folders.allSatisfy {
            if case let .new(code, name) = $0.destination,
               code == claimed
            {
                return name == "Engineering"
            }
            return true
        })
        // The Inbox is never a subject home, by code or by name.
        let inboxed = try FolderMapping.apply([
            FolderMapping.Answer(
                folder: number("Knowledge"),
                action: "existing",
                code: "10",
                name: "",
                reason: ""
            ),
            FolderMapping.Answer(
                folder: number("Development"),
                action: "new",
                code: "40",
                name: "Inbox",
                reason: ""
            ),
        ], to: plan, folders: folders, categories: categories)
        #expect(inboxed.changed == 0)
        #expect(!FolderMapping.prompt(folders: folders, categories: categories, withSamples: false)
            .contains("10 Inbox"))
    }

    @Test func streamedRepliesYieldOnlyCompleteFolderAnswers() {
        let partial = #"""
        {"folders":[{"folder":1,"action":"new","code":"20","name":"Brace } and \"quote\"","reason":"a {b}"},        {"folder":2,"action":"existing","code":"11","name":"","reason":"ok"},{"folder":3,"action":"ne
        """#
        let answers = FolderMapping.completedAnswers(inPartial: partial)
        #expect(answers.map(\.folder) == [1, 2])
        #expect(answers.first?.name == "Brace } and \"quote\"")
        #expect(FolderMapping.completedAnswers(inPartial: "{\"fold").isEmpty)
    }

    /// One real on-device Librarian pass over an export; prints the proposed homes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_BOOKMARK_EXPORT"] != nil
            && ProcessInfo.processInfo.environment["GLEANARY_NATIVE_CLASSIFICATION"] == "1"))
    func onDeviceLibrarianMapsARealExport() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GLEANARY_BOOKMARK_EXPORT"])
        let file = try BookmarkParser.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        let inbox = DecimalCategory(id: UUID(), code: "10", name: "Inbox")
        let plan = BookmarkFolderPlan(bookmarks: file.bookmarks, existing: [inbox])
        let folders = FolderMapping.folders(plan: plan, bookmarks: file.bookmarks)
        let clock = ContinuousClock(), start = clock.now
        let updates = UpdateCounter()
        let answers = try await AppleConversationInference()
            .librarianFolderPlan(folders, categories: [inbox]) { partial in
                Task { await updates.record(partial.count) }
            }
        await print(
            "LIBRARIAN progress updates=\(updates.counts.count) last=\(updates.counts.last ?? 0)"
        )
        let result = FolderMapping.apply(answers, to: plan, folders: folders, categories: [inbox])
        print(
            "LIBRARIAN answers=\(answers.count)/\(folders.count) changed=\(result.changed) in \(clock.now - start)"
        )
        for folder in result.plan.folders {
            print(
                "LIBRARIAN \(folder.id) -> \(folder.destination) :: \(result.reasons[folder.id] ?? "")"
            )
        }
        #expect(!answers.isEmpty)
    }
}

private actor UpdateCounter {
    private(set) var counts: [Int] = []
    func record(_ count: Int) {
        if count != counts.last {
            counts.append(count)
        }
    }
}
