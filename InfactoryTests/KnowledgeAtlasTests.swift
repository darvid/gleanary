import AppKit
import Foundation
@testable import Infactory
import SwiftUI
import Testing

private func category(_ code: String, _ name: String, id: Int) -> DecimalCategory {
    DecimalCategory(id: fixtureID(id), code: code, name: name)
}

private func fixtureID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)) ?? UUID()
}

private func item(_ id: Int, in categories: [DecimalCategory] = [], kind: String = "source")
    -> AtlasItem
{
    AtlasItem(
        id: fixtureID(10000 + id), title: "Fixture \(id)", kind: kind, host: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id) * 60),
        categoryIDs: categories.map(\.id)
    )
}

/// A small library with nesting, an empty category, multi-filing and unfiled items.
private struct AtlasFixture {
    let thinking = category("10", "Thinking", id: 1)
    let technology = category("50", "Technology", id: 2)
    let computing = category("50.01", "Computing", id: 3)
    let ai = category("50.02", "AI / ML", id: 4)
    let empty = category("60", "Nature", id: 5)
    /// "70" does not exist, so its child must hang from a synthesized group.
    let orphan = category("70.01", "Projects", id: 6)

    var categories: [DecimalCategory] {
        [thinking, technology, computing, ai, empty, orphan]
    }

    var snapshot: AtlasSnapshot {
        var items = (0 ..< 6).map { item($0, in: [thinking]) }
        items += (6 ..< 9).map { item($0, in: [computing]) }
        // Primary in AI / ML, secondary in Thinking: counted once.
        items += (9 ..< 13).map { item($0, in: [ai, thinking], kind: "summary") }
        items.append(item(13, in: [technology]))
        items.append(item(14, in: [orphan]))
        items += (15 ..< 17).map { item($0) }
        return AtlasSnapshot(categories: categories, items: items)
    }
}

private func child(_ node: AtlasNode, _ id: AtlasNodeID) -> AtlasNode? {
    node.children.first { $0.id == id }
}

private func sizable(_ counts: [Int]) -> AtlasNode {
    let categories = counts.indices.map { category(String(10 + $0), "Area \($0)", id: $0 + 1) }
    var next = 0
    var items: [AtlasItem] = []
    for (index, count) in counts.enumerated() {
        for _ in 0 ..< count {
            items.append(item(next, in: [categories[index]])); next += 1
        }
    }
    return AtlasHierarchy.project(AtlasSnapshot(categories: categories, items: items))
}

private func expectSiblingsTileWithoutOverlap(_ layout: AtlasLayout) {
    for position in layout.tiles.indices {
        let parent = layout.tiles[position]
        let children = layout.children(of: position)
        for child in children {
            let rect = layout.tiles[child].rect
            #expect(rect.width >= 0 && rect.height >= 0)
            #expect(parent.rect.insetBy(dx: -0.001, dy: -0.001).contains(rect))
            #expect(parent.contentRect.insetBy(dx: -0.001, dy: -0.001).contains(rect))
        }
        for (offset, left) in children.enumerated() {
            for right in children.dropFirst(offset + 1) {
                let overlap = layout.tiles[left].rect.intersection(layout.tiles[right].rect)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.001)
            }
        }
    }
}

struct KnowledgeAtlasProjectionTests {
    @Test func projectsCodesIntoNestedRegionsAndCountsEachItemOnce() throws {
        let fixture = AtlasFixture()
        let root = AtlasHierarchy.project(fixture.snapshot)
        #expect(root.itemCount == 17)
        #expect(root.children.map(\.id) == [
            .category(fixture.thinking.id), .category(fixture.technology.id),
            .category(fixture.empty.id), .group("70"), .uncategorized,
        ])

        let thinking = try #require(child(root, .category(fixture.thinking.id)))
        #expect(thinking.itemCount == 6)
        #expect(thinking.alsoFiledCount == 4)

        let technology = try #require(child(root, .category(fixture.technology.id)))
        #expect(technology.itemCount == 8)
        #expect(technology.children.map(\.id) == [
            .direct(fixture.technology.id), .category(fixture.computing.id),
            .category(fixture.ai.id),
        ])
        #expect(child(technology, .category(fixture.ai.id))?.itemCount == 4)
        #expect(child(technology, .direct(fixture.technology.id))?.title ==
            "\(fixture.technology.name), not in a subcategory")

        let empty = try #require(child(root, .category(fixture.empty.id)))
        #expect(empty.itemCount == 0 && empty.children.isEmpty)
        // The sidebar dims exactly the categories the map's Hide empty removes.
        let emptyIDs = AtlasHierarchy.emptyCategoryIDs(root)
        #expect(emptyIDs.contains(fixture.empty.id))
        #expect(!emptyIDs.contains(fixture.technology.id))
        let kept = AtlasHierarchy.withoutEmptyCategories(root)
        func contains(_ node: AtlasNode, _ id: AtlasNodeID) -> Bool {
            node.id == id || node.children.contains { contains($0, id) }
        }
        #expect(emptyIDs.allSatisfy { !contains(kept, .category($0)) })
        #expect(emptyIDs.allSatisfy { contains(root, .category($0)) })
        let group = try #require(child(root, .group("70")))
        #expect(group.children.map(\.id) == [.category(fixture.orphan.id)])
        #expect(child(root, .uncategorized)?.itemCount == 2)
        #expect(group.hue == AtlasHierarchy.hue(for: "70"))
        #expect(child(root, .uncategorized)?.hue == nil)
    }

    @Test func toleratesMissingMetadataAndUnknownMemberships() {
        let ghost = category("40", "Removed", id: 99)
        var unknown = item(1, in: [ghost])
        unknown = AtlasItem(
            id: unknown.id, title: "", kind: "mystery", host: nil, updatedAt: unknown.updatedAt,
            categoryIDs: unknown.categoryIDs
        )
        let root = AtlasHierarchy.project(AtlasSnapshot(categories: [], items: [unknown]))
        #expect(root.children.map(\.id) == [.uncategorized])
        #expect(root.children.first?.children.first?.title == "Untitled")
        #expect(unknown.kindLabel == "Note")
    }

    @Test func handlesEmptyLibrariesAndDeepNesting() throws {
        let empty = AtlasHierarchy.project(AtlasSnapshot(categories: [], items: []))
        #expect(empty.children.isEmpty && empty.itemCount == 0)

        let deep = [
            category("50", "Technology", id: 1), category("50.01", "Computing", id: 2),
            category("50.01.01", "Languages", id: 3), category("50.01.01.01", "Swift", id: 4),
        ]
        let root = AtlasHierarchy.project(AtlasSnapshot(
            categories: deep, items: [item(1, in: [deep[3]])]
        ))
        var node = try #require(root.children.first)
        var depth = 1
        while let next = node.children.first, next.kind != .item {
            node = next; depth += 1
        }
        #expect(depth == 4)
        #expect(node.id == .category(deep[3].id))
        #expect(root.itemCount == 1)
    }

    @Test func paletteSlotsDifferForConsecutiveAndDecadeCodes() {
        let consecutive = Set((10 ..< 19).map { AtlasHierarchy.hue(for: String($0)) })
        let decades = Set(stride(from: 10, through: 90, by: 10).map {
            AtlasHierarchy.hue(for: String($0))
        })
        #expect(consecutive.count == 9)
        #expect(decades.count == 9)
        #expect(AtlasHierarchy.hue(for: "50.02") == AtlasHierarchy.hue(for: "50"))
    }
}

struct KnowledgeAtlasLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 640)

    @Test func layoutIsDeterministicContainedAndNonOverlapping() {
        let root = AtlasHierarchy.project(AtlasFixture().snapshot)
        let first = AtlasLayout(root: root, bounds: bounds)
        let second = AtlasLayout(root: root, bounds: bounds)
        #expect(first.tiles.map(\.rect) == second.tiles.map(\.rect))
        #expect(first.tiles.map(\.id) == second.tiles.map(\.id))
        #expect(first.tiles.count == second.tiles.count)
        expectSiblingsTileWithoutOverlap(first)
        #expect(first.root?.rect == bounds)

        let sample = AtlasHierarchy.project(.sample())
        expectSiblingsTileWithoutOverlap(AtlasLayout(root: sample, bounds: bounds))
    }

    @Test func emptyHierarchyProducesOnlyTheRoot() {
        let layout = AtlasLayout(
            root: AtlasHierarchy.project(AtlasSnapshot(categories: [], items: [])),
            bounds: bounds
        )
        #expect(layout.tiles.count == 1)
        #expect(layout.children(of: 0).isEmpty)
        #expect(layout.smallestItemSize == nil)
    }

    @Test func squarifiedAreasFollowWeightsAndFillTheRectangle() {
        let weights = [5.0, 1, 3, 8, 2, 2, 1]
        let rects = AtlasLayout.squarify(weights, in: bounds)
        let area = bounds.width * bounds.height
        let total = weights.reduce(0, +)
        for (weight, rect) in zip(weights, rects) {
            #expect(abs(rect.width * rect.height - area * weight / total) < 1)
        }
        #expect(abs(rects.reduce(0) { $0 + $1.width * $1.height } - area) < 1)
        #expect(AtlasLayout.squarify([], in: bounds).isEmpty)
        #expect(AtlasLayout.squarify([0, 0], in: bounds).count == 2)
    }

    @Test func veryUnevenSizesKeepSmallRegionsDiscoverable() throws {
        let root = sizable([5000, 1, 0, 40])
        let layout = AtlasLayout(root: root, bounds: bounds)
        expectSiblingsTileWithoutOverlap(layout)
        let regions = layout.children(of: 0).map { layout.tiles[$0] }
        #expect(regions.count == 4)
        let area = bounds.width * bounds.height
        for region in regions.dropFirst() {
            // Minimum share, minus sibling gaps, keeps tiny and empty regions visible.
            #expect(region.rect.width * region.rect.height > area * 0.008)
        }
        let largest = try #require(regions.first)
        #expect(largest.rect.width * largest.rect.height > area * 0.85)
    }

    @Test func minorChangesKeepRegionsInPlace() {
        let before = AtlasLayout(root: sizable([40, 25, 60, 12, 30, 18]), bounds: bounds)
        let after = AtlasLayout(root: sizable([41, 25, 60, 12, 30, 18]), bounds: bounds)
        let old = before.children(of: 0).map { before.tiles[$0].rect }
        let new = after.children(of: 0).map { after.tiles[$0].rect }
        #expect(old.count == new.count)
        for (lhs, rhs) in zip(old, new) {
            #expect(abs(lhs.midX - rhs.midX) < bounds.width * 0.05)
            #expect(abs(lhs.midY - rhs.midY) < bounds.height * 0.05)
        }
    }

    @Test func itemsUseAReadableGridNewestFirst() throws {
        let leaf = category("10", "Thinking", id: 1)
        let root = AtlasHierarchy.project(AtlasSnapshot(
            categories: [leaf], items: (0 ..< 30).map { item($0, in: [leaf]) }
        ))
        let layout = AtlasLayout(root: root, bounds: bounds)
        let region = try #require(layout.children(of: 0).first)
        let items = layout.children(of: region).map { layout.tiles[$0] }
        #expect(items.count == 30)
        #expect(items.first?.node.item?.id == fixtureID(10029))
        let size = try #require(layout.smallestItemSize)
        for tile in items {
            #expect(abs(tile.rect.width - size.width) < 0.001)
        }
        #expect(items.first?.node.recency == 1)
        #expect(items.last?.node.recency == 0)
    }
}

struct KnowledgeAtlasDetailTests {
    @Test func rampFadesSmoothlyBetweenItsBounds() {
        #expect(AtlasRenderer.ramp(5, 10, 20) == 0)
        #expect(AtlasRenderer.ramp(25, 10, 20) == 1)
        #expect(abs(AtlasRenderer.ramp(15, 10, 20) - 0.5) < 0.001)
        var previous = 0.0
        for value in stride(from: CGFloat(10), through: 20, by: 0.5) {
            let next = AtlasRenderer.ramp(value, 10, 20)
            #expect(next >= previous)
            previous = next
        }
    }

    @Test func itemsStartFadingInWhereTheyBecomeHittable() {
        let minimum = KnowledgeAtlasModel.minimumItemSize
        let hidden = CGRect(x: 0, y: 0, width: minimum - 0.5, height: 40)
        let half = CGRect(x: 0, y: 0, width: minimum * 1.5, height: 40)
        let shown = CGRect(x: 0, y: 0, width: minimum * 2, height: 40)
        #expect(AtlasRenderer.itemReveal(hidden) == 0)
        #expect(AtlasRenderer.itemReveal(half) > 0 && AtlasRenderer.itemReveal(half) < 1)
        #expect(AtlasRenderer.itemReveal(shown) == 1)
    }
}

struct KnowledgeAtlasCameraTests {
    let viewport = CGSize(width: 800, height: 500)

    @Test func fittingCentresAndZoomKeepsTheAnchorFixed() {
        let target = CGRect(x: 100, y: 100, width: 200, height: 100)
        let camera = AtlasCamera.fitting(target, in: viewport)
        let screen = camera.screen(target)
        #expect(abs(screen.midX - 400) < 0.001 && abs(screen.midY - 250) < 0.001)
        #expect(abs(screen.width - 800) < 0.001 || abs(screen.height - 500) < 0.001)

        let anchor = CGPoint(x: 120, y: 340)
        let before = camera.logical(anchor)
        let after = camera.zoomed(by: 3, around: anchor).logical(anchor)
        #expect(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001)
    }

    @Test func interpolationStartsAndEndsOnItsCameras() {
        let start = AtlasCamera()
        let end = AtlasCamera.fitting(
            CGRect(x: 600, y: 300, width: 40, height: 25), in: viewport
        )
        let first = AtlasCamera.interpolate(from: start, to: end, progress: 0, viewport: viewport)
        let last = AtlasCamera.interpolate(from: start, to: end, progress: 1, viewport: viewport)
        #expect(abs(first.scale - start.scale) < 0.001)
        #expect(abs(last.scale - end.scale) < 0.001)
        #expect(abs(last.offset.x - end.offset.x) < 0.01 && abs(last.offset.y - end.offset.y) <
            0.01)
        let middle = AtlasCamera.interpolate(
            from: start,
            to: end,
            progress: 0.5,
            viewport: viewport
        )
        #expect(middle.scale > start.scale && middle.scale < end.scale)
    }

    @Test func clampingLimitsScaleAndKeepsContentInView() {
        let bounds = CGRect(origin: .zero, size: viewport)
        let far = AtlasCamera(scale: 50, offset: CGPoint(x: 90000, y: -90000))
        let clamped = far.clamped(to: bounds, viewport: viewport, scales: 0.8 ... 10)
        #expect(clamped.scale == 10)
        let center = clamped.logical(CGPoint(x: 400, y: 250))
        #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(center))
    }
}

@Suite(.serialized) @MainActor struct KnowledgeAtlasNavigationTests {
    private func model() -> (KnowledgeAtlasModel, AtlasFixture) {
        let fixture = AtlasFixture()
        let atlas = KnowledgeAtlasModel(snapshot: fixture.snapshot)
        atlas.reduceMotion = true
        atlas.setViewport(CGSize(width: 1000, height: 640))
        return (atlas, fixture)
    }

    @Test func focusingBackAndResetFollowTheHierarchy() throws {
        let (atlas, fixture) = model()
        #expect(atlas.focusID == .library)
        #expect(atlas.activate(.category(fixture.technology.id)) == .focused(
            .category(fixture.technology.id)
        ))
        atlas.activate(.category(fixture.ai.id))
        #expect(atlas.breadcrumb.map(\.id) == [
            .library, .category(fixture.technology.id), .category(fixture.ai.id),
        ])
        // The focused region, title included, fills the view.
        let region = try #require(atlas.focusTile).rect
        let screen = atlas.camera.screen(region)
        #expect(screen.width >= 1000 - 25 || screen.height >= 640 - 25)

        atlas.back()
        #expect(atlas.focusID == .category(fixture.technology.id))
        #expect(atlas.selectedID == .category(fixture.ai.id))
        atlas.reset()
        #expect(atlas.focusID == .library)
        #expect(abs(atlas.camera.scale - 1) < 0.001)
        #expect(!atlas.canGoBack)
    }

    @Test func zoomingRevealsDeeperContextAndHitTestsByLevelOfDetail() throws {
        let (atlas, fixture) = model()
        let technology = try #require(atlas.layout.tile(.category(fixture.technology.id)))
        let point = atlas.camera.screen(technology.contentRect)
        let center = CGPoint(x: point.midX, y: point.midY)
        let hit = try #require(atlas.hitTest(center))
        #expect(hit != .library)
        #expect(atlas.layout.path(to: atlas.layout.index[hit] ?? 0)
            .contains(atlas.layout.index[.category(fixture.technology.id)] ?? -1))

        atlas.focus(.category(fixture.technology.id), animated: false)
        atlas.zoom(by: 1.01, around: CGPoint(x: 500, y: 320))
        #expect(atlas.focusID != .library)
        atlas.zoom(by: 0.01, around: CGPoint(x: 500, y: 320))
        #expect(atlas.focusID == .library)
        #expect(atlas.camera.scale >= atlas.scaleRange.lowerBound)
    }

    @Test func activatingAnItemOpensItAndKeepsAtlasState() {
        let (atlas, fixture) = model()
        atlas.activate(.category(fixture.technology.id))
        atlas.activate(.category(fixture.ai.id))
        let camera = atlas.camera
        let itemID = fixtureID(10009)
        #expect(atlas.activate(.item(itemID)) == .open(itemID))
        #expect(atlas.selectedID == .item(itemID))
        // Opening detail leaves the model alone, so returning shows the same place.
        #expect(atlas.camera == camera)
        #expect(atlas.focusID == .category(fixture.ai.id))
        // Activating an empty region selects it instead of zooming into nothing.
        #expect(atlas.activate(.category(fixture.empty.id)) == nil)
        #expect(atlas.selectedID == .category(fixture.empty.id))
    }

    @Test func keyboardMovesBetweenSiblingsWithinTheContext() throws {
        let (atlas, fixture) = model()
        atlas.moveSelection(.right)
        #expect(atlas.selectedID == .category(fixture.thinking.id))
        var visited: Set<AtlasNodeID> = []
        for direction in [KnowledgeAtlasModel.Direction.right, .down, .left, .up, .right, .down] {
            atlas.moveSelection(direction)
            try visited.insert(#require(atlas.selectedID))
        }
        #expect(visited.count > 1)
        let regions = Set(atlas.layout.children(of: 0).map { atlas.layout.tiles[$0].id })
        #expect(visited.isSubset(of: regions))
    }

    @Test func refreshesKeepCameraAndDropVanishedState() {
        let (atlas, fixture) = model()
        atlas.activate(.category(fixture.technology.id))
        let camera = atlas.camera
        var snapshot = fixture.snapshot
        snapshot.items.append(item(50, in: [fixture.computing]))
        atlas.apply(snapshot)
        #expect(atlas.focusID == .category(fixture.technology.id))
        #expect(atlas.camera == camera)

        atlas.selectedID = .category(fixture.thinking.id)
        snapshot.categories
            .removeAll { $0.id == fixture.thinking.id || $0.id == fixture.technology.id }
        atlas.apply(snapshot)
        #expect(atlas.focusID == .library)
        #expect(atlas.selectedID == nil)

        atlas.kindFilter = .sources
        #expect(atlas.root.itemCount == snapshot.items.filter { $0.kind == "source" }.count)
    }

    @Test func searchMatchesAggregateUpTheHierarchy() throws {
        let (atlas, fixture) = model()
        atlas.setMatches([fixtureID(10009), fixtureID(10006)])
        let technology = try #require(atlas.layout.index[.category(fixture.technology.id)])
        let thinking = try #require(atlas.layout.index[.category(fixture.thinking.id)])
        #expect(atlas.matchCounts[0] == 2)
        #expect(atlas.matchCounts[technology] == 2)
        #expect(atlas.matchCounts[thinking] == 0)
        atlas.setMatches(nil)
        #expect(atlas.matchCounts.isEmpty)
    }
}

struct NavigationHistoryTests {
    @Test func backForwardAndBranching() {
        var history = NavigationHistory<String>()
        #expect(history.back() == nil)
        history.visit("all")
        history.visit("all")
        history.visit("category")
        history.visit("item")
        #expect(history.entries == ["all", "category", "item"])
        #expect(history.back() == "category")
        #expect(history.back() == "all")
        #expect(history.back() == nil)
        #expect(history.forward() == "category")
        // Visiting somewhere new after going back drops the old forward path.
        history.visit("chat")
        #expect(history.entries == ["all", "category", "chat"])
        #expect(!history.canGoForward)
        history.replace("chat, scrolled")
        #expect(history.back() == "category")
        #expect(history.forward() == "chat, scrolled")
    }

    @Test func historyIsBounded() {
        var history = NavigationHistory<Int>()
        history.limit = 3
        (1 ... 5).forEach { history.visit($0) }
        #expect(history.entries == [3, 4, 5])
        #expect(history.current == 5)
        #expect(history.back() == 4)
    }

    @MainActor @Test func onlyDeliberateAtlasMovesCountAsNavigation() {
        let fixture = AtlasFixture()
        let atlas = KnowledgeAtlasModel(snapshot: fixture.snapshot)
        atlas.reduceMotion = true
        atlas.setViewport(CGSize(width: 1000, height: 640))
        let before = atlas.navigations
        atlas.zoom(by: 3, around: CGPoint(x: 500, y: 320), animated: false)
        #expect(atlas.navigations == before)
        atlas.activate(.category(fixture.technology.id))
        #expect(atlas.navigations == before + 1)
    }
}

@Suite(.serialized) struct KnowledgeAtlasStoreTests {
    @Test @MainActor func snapshotReadsLibraryItemsAndOrderedMemberships() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        let notes = (0 ..< 3).map {
            MarkdownDocument(
                name: "Atlas fixture \($0)",
                markdown: "Saved atlasword evidence \($0)."
            )
        }
        _ = try await store.open(seed: notes)
        try await store.saveCategory(code: "50", name: "Technology")
        try await store.saveCategory(code: "50.02", name: "AI / ML")
        let categories = try await store.categories()
        let technology = try #require(categories.first { $0.code == "50" })
        let ai = try #require(categories.first { $0.code == "50.02" })
        try await store.fileNote(notes[0].id, categoryID: technology.id)
        try await store.fileNote(notes[0].id, categoryID: ai.id, primary: false)
        try await store.fileNote(notes[1].id, categoryID: ai.id)

        let snapshot = try await store.atlasSnapshot()
        #expect(snapshot.items.count == 3)
        #expect(Set(snapshot.categories.map(\.code)).isSuperset(of: ["50", "50.02"]))
        let first = try #require(snapshot.items.first { $0.id == notes[0].id })
        #expect(first.categoryIDs == [technology.id, ai.id])
        #expect(first.kind == "note")
        #expect(snapshot.items.first { $0.id == notes[2].id }?.categoryIDs.isEmpty == true)

        let projected = AtlasHierarchy.project(snapshot)
        #expect(projected.itemCount == 3)
        let technologyNode = try #require(child(projected, .category(technology.id)))
        #expect(technologyNode.itemCount == 2)
        #expect(child(technologyNode, .category(ai.id))?.alsoFiledCount == 1)

        let matches = try await store.libraryMatches(query: "atlasword")
        #expect(matches == Set(notes.map(\.id)))
        #expect(try await store.libraryMatches(query: "nothingmatcheshere").isEmpty)

        let atlas = KnowledgeAtlasModel()
        await atlas.load(from: store)
        #expect(atlas.root.itemCount == 3)
        #expect(atlas.error == nil)
    }

    /// Writes light and dark renders when INFACTORY_ATLAS_SCREENSHOTS names a directory.
    @Test @MainActor func rendersAtlasScreenshotsOnRequest() async throws {
        guard let directory = ProcessInfo.processInfo.environment["INFACTORY_ATLAS_SCREENSHOTS"]
        else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshot = AtlasSnapshot.sample()
        let technology = try #require(snapshot.categories.first { $0.code == "50" })
        let ai = try #require(snapshot.categories.first { $0.code == "50.02" })
        for dark in [false, true] {
            for stage in ["overview", "category", "contents", "zoomed", "dense"] {
                var source = snapshot
                if stage == "dense" {
                    // About 9,000 items, so most item tiles start below the drawable size.
                    source.items = (0 ..< 12).flatMap { copy in
                        snapshot.items.map { item in
                            AtlasItem(
                                id: UUID(), title: item.title, kind: item.kind, host: item.host,
                                updatedAt: item.updatedAt.addingTimeInterval(Double(copy)),
                                categoryIDs: item.categoryIDs
                            )
                        }
                    }
                }
                let atlas = KnowledgeAtlasModel(snapshot: source)
                atlas.reduceMotion = true
                if stage == "zoomed" || stage == "contents" {
                    // Every other source gets a synthetic page still.
                    let still = try #require(Self.syntheticStill())
                    atlas.useThumbnails(Dictionary(uniqueKeysWithValues: source.items
                            .filter { $0.kind == "source" }.enumerated()
                            .filter { $0.offset.isMultiple(of: 2) }.map { ($0.element.id, still) }))
                }
                let host = NSHostingView(rootView: KnowledgeAtlasView(
                    atlas: atlas, store: nil, openItem: { _ in }
                ).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.appearance = appearance
                host.appearance = appearance
                window.contentView = host
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(300))
                switch stage {
                case "category":
                    atlas.focus(.category(technology.id), animated: false)
                    atlas.selectedID = .category(ai.id)
                case "contents":
                    atlas.focus(.category(technology.id), animated: false)
                    atlas.focus(.category(ai.id), animated: false)
                case "zoomed":
                    atlas.focus(.category(ai.id), animated: false)
                    atlas.zoom(by: 3, around: CGPoint(x: 120, y: 90))
                default:
                    atlas.selectedID = .category(technology.id)
                    atlas.hoveredID = .category(ai.id)
                }
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appending(
                    path: "atlas-\(stage)-\(dark ? "dark" : "light").png"
                ))
            }
        }
    }

    /// A page-like still: a dark masthead band over a lighter body with a block of "text".
    private static func syntheticStill() -> AtlasThumbnail? {
        guard let context = CGContext(
            data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 250, width: 640, height: 70))
        context.setFillColor(CGColor(gray: 0.45, alpha: 1))
        for line in 0 ..< 6 {
            context.fill(CGRect(
                x: 40,
                y: 200 - line * 30,
                width: 360 + (line % 3) * 60,
                height: 12
            ))
        }
        context.setFillColor(CGColor(gray: 0.6, alpha: 1))
        context.fill(CGRect(x: 470, y: 60, width: 130, height: 150))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return AtlasThumbnail(data: output as Data)
    }
}
