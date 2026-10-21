@testable import Gleanary
import Testing

struct GraphAccessibilityTests {
    @Test func everyLargeGraphItemRemainsReachableThroughBoundedPages() {
        let nodes = GraphScaleFixture.snapshot(count: 10000).nodes
        var page = GraphAccessibilityPage(nodes: nodes, selectedID: nil)
        var visited = Set<String>()
        for _ in 0 ..< 130 {
            #expect(page.nodes.count <= GraphAccessibilityPage.size)
            visited.formUnion(page.nodes.map(\.id))
            guard let nextID = page.nextID else { break }
            let next = GraphAccessibilityPage(nodes: nodes, selectedID: nextID)
            #expect(next.previousID == page.nodes.last?.id)
            page = next
        }
        #expect(visited == Set(nodes.map(\.id)))
        #expect(page.nextID == nil)
        #expect(page.value == "Items 9921 through 10000 of 10000")
    }

    @Test func selectionFindsItsPageWithoutChangingNodeIdentity() {
        let nodes = GraphScaleFixture.snapshot(count: 1000).nodes
        let page = GraphAccessibilityPage(nodes: nodes, selectedID: nodes[805].id)
        #expect(page.nodes == nodes[800 ..< 880])
        #expect(page.previousID == nodes[799].id)
        #expect(page.nextID == nodes[880].id)
        #expect(page.value == "Items 801 through 880 of 1000")
        let first = GraphAccessibilityPage(nodes: nodes, selectedID: "missing")
        #expect(first.nodes == nodes[0 ..< 80])
        #expect(first.previousID == nil)
    }

    @Test func smallAndEmptyGraphsNeedNoPaging() {
        let nodes = GraphScaleFixture.snapshot(count: 12).nodes
        let page = GraphAccessibilityPage(nodes: nodes, selectedID: nodes.last?.id)
        #expect(Array(page.nodes) == nodes)
        #expect(page.previousID == nil && page.nextID == nil)
        let empty = GraphAccessibilityPage(nodes: [], selectedID: nil)
        #expect(empty.nodes.isEmpty)
        #expect(empty.previousID == nil && empty.nextID == nil)
        #expect(empty.value == "No items")
    }
}
