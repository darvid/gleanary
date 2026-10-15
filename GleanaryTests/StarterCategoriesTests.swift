import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

struct StarterCategoriesTests {
    private func packs(_ ids: String...) -> [StarterPack] {
        ids.compactMap { id in StarterPack.all.first { $0.id == id } }
    }

    private func category(_ code: String, _ name: String) -> DecimalCategory {
        DecimalCategory(id: UUID(), code: code, name: name)
    }

    @Test func everyPackProducesValidCategories() throws {
        let plan = StarterPlan(packs: StarterPack.all, existing: [category("10", "Inbox")])
        #expect(plan.unplaced.isEmpty)
        for category in plan.categories {
            try DecimalCategory.validate(code: category.code, name: category.name)
        }
        #expect(Set(plan.categories.map(\.code)).count == plan.categories.count)
    }

    @Test func essentialsExtendInboxAndAreasTakeBlocksInChosenOrder() {
        let plan = StarterPlan(
            packs: packs("writing", "essentials", "engineering"),
            existing: [category("10", "Inbox")]
        )
        #expect(plan.areas.map(\.packID) == ["essentials", "writing", "engineering"])
        #expect(plan.areas[0].categories.map(\.code) == ["11", "12", "13", "14", "15"])
        #expect(plan.areas[1].categories.first == .init(
            key: "area:writing",
            code: "20",
            name: "Writing"
        ))
        #expect(plan.areas[2].categories.map(\.code).prefix(2) == ["30", "31"])
    }

    @Test func sharedEntriesAppearOnceInTheFirstArea() {
        let plan = StarterPlan(packs: packs("product", "design", "business"), existing: [])
        let research = plan.categories.filter { $0.key == "user-research" }
        #expect(research.map(\.code) == ["22"])
        #expect(plan.categories.filter { $0.key == "competitors" }.count == 1)
        #expect(plan.areas[1].categories.map(\.code) == ["30", "31", "32", "33"])
    }

    @Test func existingCodesAndNamesAreNeverReused() {
        let plan = StarterPlan(packs: packs("essentials", "engineering", "writing"), existing: [
            category("10", "Inbox"),
            category("11", "Someday"),
            category("20", "Engineering"),
            category("31.04", "Agent architectures"),
            category("50", "books"),
        ])
        // 20–39 already hold categories, so new areas skip ahead and X0 stays reserved.
        #expect(plan.areas.map(\.packID) == ["essentials", "engineering", "writing"])
        let codes = plan.categories.map(\.code)
        #expect(!codes.contains { ["11", "20", "31"].contains(String($0.prefix(2))) })
        #expect(!plan.categories.contains { $0.key == "books" })
        let engineering = plan.areas[1].categories
        #expect(engineering.first?.code == "41")
        #expect(!engineering.contains { $0.key == "area:engineering" })
        #expect(plan.areas[2].categories.first?.code == "60")
    }

    @Test func packsBeyondTheLastFreeBlockAreReportedNotPlaced() {
        let existing = (2 ... 8).map { category("\($0)0", "Area \($0)") }
        let plan = StarterPlan(packs: packs("writing", "design"), existing: existing)
        #expect(plan.areas.map(\.packID) == ["writing"])
        #expect(plan.unplaced.map(\.id) == ["design"])
    }

    @Test func addingSkipsTakenCategoriesAndUndoKeepsFiledOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let created = try await store.addCategories([
            (code: "11", name: "Ideas"),
            (code: "12", name: "inbox"),
            (code: "10", name: "Elsewhere"),
            (code: "20", name: "Writing"),
        ])
        #expect(created.count == 2)
        #expect(try await store.categories().map(\.code) == ["10", "11", "20"])

        let note = try await store.save(MarkdownDocument(
            name: "Synthetic",
            markdown: "Synthetic idea."
        ))
        try await store.fileNote(note.id, categoryID: created[0])
        #expect(try await store.removeUnusedCategories(created) == 1)
        #expect(try await store.categories().map(\.code) == ["10", "11"])

        await #expect(throws: ConversationError.self) {
            try await store.addCategories([(code: "30", name: "Valid"), (code: "3", name: "Bad")])
        }
        #expect(try await store.categories().count == 2)
    }

    @Test func deletingKeepsItemsAndPromotesTheirNextHome() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let ids = try await store.addCategories([
            (code: "21", name: "Drafts"),
            (code: "22", name: "Published"),
        ])
        let both = try await store.save(MarkdownDocument(name: "Both", markdown: "Synthetic."))
        let only = try await store.save(MarkdownDocument(name: "Only", markdown: "Synthetic."))
        try await store.fileNote(both.id, categoryID: ids[0])
        try await store.fileNote(both.id, categoryID: ids[1], primary: false)
        try await store.fileNote(only.id, categoryID: ids[0])
        #expect(try await store.categoryItemCounts() == [ids[0]: 2, ids[1]: 1])

        try await store.deleteCategory(ids[0])
        #expect(try await store.categories(for: both.id).map(\.code) == ["22"])
        #expect(try await store.categories(for: only.id).isEmpty)
        #expect(try await store.document(id: only.id) != nil)
        // The promoted home is primary, so filing it elsewhere as primary still works.
        try await store.fileNote(both.id, categoryID: ids[1])
        #expect(try await store.categoryItemCounts() == [ids[1]: 1])
    }

    @Test func inboxCannotBeRenumberedOrDeletedAndCodesStayUnique() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let inbox = try #require(await store.categories().first(where: \.isInbox))
        await #expect(throws: ConversationError.inboxCategory) {
            try await store.deleteCategory(inbox.id)
        }
        try await store.saveCategory(id: inbox.id, code: "10", name: "Triage")
        try await store.saveCategory(code: "20", name: "Writing")
        await #expect(throws: ConversationError.categoryTaken) {
            try await store.saveCategory(code: "20", name: "Other")
        }
        await #expect(throws: ConversationError.categoryTaken) {
            try await store.saveCategory(code: "21", name: "writings")
        }
        #expect(try await store.categories().map(\.label) == ["10 Triage", "20 Writing"])
    }

    @Test func areasGroupByTensDigitAndSuggestTheNextFreeCode() {
        let areas = CategoryArea.group([
            category("31.04", "Agents"), category("30", "Computing"), category("10", "Inbox"),
            category("31", "Systems"), category("52", "Loose"),
        ])
        #expect(areas.map(\.digit) == [1, 3, 5])
        #expect(areas[1].title == "Computing")
        #expect(areas[1].categories.map(\.code) == ["30", "31", "31.04"])
        #expect(areas[1].nextFreeCode == "32")
        #expect(areas[0].title == "Inbox")
        #expect(areas[2].title == "Area 50–59")
    }

    @Test @MainActor func atlasCanHideEmptyCategoriesWithoutRecoloring() {
        let filed = category("31.04", "Agents"), parent = category("31", "Systems")
        let empty = [
            category("10", "Inbox"),
            category("40", "Writing"),
            category("40.01", "Drafts"),
        ]
        let item = AtlasItem(
            id: UUID(), title: "Synthetic", kind: "note", host: nil, updatedAt: .now,
            categoryIDs: [filed.id]
        )
        let atlas = KnowledgeAtlasModel()
        atlas.apply(AtlasSnapshot(categories: [filed, parent] + empty, items: [item]))
        #expect(atlas.emptyCategoryCount == 3)
        let hue = atlas.root.children.first { $0.code == "31" }?.hue
        atlas.hidesEmptyCategories = true
        #expect(atlas.root.children.map(\.code) == ["31"])
        #expect(atlas.root.children.first?.children.map(\.code) == ["31.04"])
        #expect(atlas.root.children.first?.hue == hue)
        #expect(atlas.emptyCategoryCount == 3)
        atlas.hidesEmptyCategories = false
        #expect(atlas.root.children.count == 3)
    }

    /// Renders the Filing settings page and the library sidebar for visual review. Set
    /// GLEANARY_LIBRARY_SCREENSHOTS to keep the images.
    @Test @MainActor func filingSettingsAndSidebarRender() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open(seed: [MarkdownDocument(
            name: "Synthetic",
            markdown: "Synthetic."
        )])
        let plan = try await StarterPlan(
            packs: packs("essentials", "engineering", "writing"),
            existing: store.categories()
        )
        _ = try await store.addCategories(plan.categories.map { (code: $0.code, name: $0.name) })
        _ = try await store.addCategories([(code: "21.01", name: "Swift")])
        let note = try #require(await store.documents().first)
        try await store.fileNote(
            note.id,
            categoryID: #require(await store.categories().first { $0.code == "21" }).id
        )
        let model = ConversationModel(store: store, coordinator: AgentCoordinator(store: store))
        await model.load()
        let library = LibraryModel(store: store)
        _ = NSApplication.shared
        for (name, view, size) in [
            (
                "filing-settings",
                AnyView(ConversationSettings(model: model, library: library, initialPage: .filing)),
                NSSize(width: 780, height: 600)
            ),
            (
                "filing-sidebar",
                AnyView(ContentView(library: library)),
                NSSize(width: 1000, height: 900)
            ),
            (
                "atlas-hide-empty",
                AnyView(HidingAtlas(store: store)),
                NSSize(width: 760, height: 420)
            ),
        ] {
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            defer { window.close() }
            for _ in 0 ..< 4 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let directory = ProcessInfo.processInfo.environment["GLEANARY_LIBRARY_SCREENSHOTS"]
                .map { URL(fileURLWithPath: $0) } ?? root
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try png.write(to: directory.appending(path: "\(name).png"))
        }
    }
}

extension StarterCategoriesTests {
    /// An empty library shows one empty state across the window, not an empty list column beside
    /// an empty detail pane.
    @Test @MainActor func emptyLibraryShowsOneEmptyState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let library = LibraryModel(store: store)
        UserDefaults.standard.set(LibraryPresentation.list.rawValue, forKey: "libraryPresentation")
        defer { UserDefaults.standard.removeObject(forKey: "libraryPresentation") }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ContentView(library: library)
            .preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        for _ in 0 ..< 4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(Self.descendant(NSTextField.self, in: host) {
            $0.placeholderString == "Search this view"
        } == nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["GLEANARY_LIBRARY_SCREENSHOTS"] {
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "list-empty.png"))
        }
    }

    @MainActor private static func descendant<View: NSView>(
        _ type: View.Type,
        in view: NSView,
        where predicate: (View) -> Bool
    ) -> View? {
        if let match = view as? View, predicate(match) {
            return match
        }
        for child in view.subviews {
            if let match = descendant(type, in: child, where: predicate) {
                return match
            }
        }
        return nil
    }
}

/// The atlas with empty categories hidden, for the render check.
private struct HidingAtlas: View {
    let store: DocumentStore
    @State private var atlas = KnowledgeAtlasModel()
    @AppStorage("atlasHidesEmptyCategories") private var hidesEmpty = false

    var body: some View {
        KnowledgeAtlasView(atlas: atlas, store: store, openItem: { _ in })
            .onAppear { hidesEmpty = true }
            .onDisappear { UserDefaults.standard.removeObject(forKey: "atlasHidesEmptyCategories") }
    }
}
