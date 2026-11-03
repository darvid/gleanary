import Foundation
@testable import Gleanary
import Testing

struct LibraryGraphInspectorTests {
    private let note = GraphNode(id: "note", kind: .document, label: "Clear instructions")
    private let other = GraphNode(id: "other", kind: .document, label: "Evaluation practices")
    private let source = GraphNode(id: "source", kind: .document, label: "Official documentation")
    private let concept = GraphNode(id: "concept", kind: .concept, label: "Context")

    private func snapshot() -> LibraryGraphSnapshot {
        let edges = [
            GraphEdge(source: note.id, target: other.id, predicate: .relatedTo),
            GraphEdge(source: note.id, target: source.id, predicate: .derivedFrom),
            GraphEdge(source: concept.id, target: note.id, predicate: .supports),
        ]
        return LibraryGraphSnapshot(
            graph: GraphSnapshot(
                nodes: [source, other, note, concept],
                edges: edges,
                totalNodes: 4
            ),
            connections: edges.map { LibraryGraphConnection(edge: $0, reasons: [
                LibraryGraphReason(id: $0.id, label: "Linked notes", text: "Synthetic rationale."),
            ]) },
            sourceNodeIDs: [source.id]
        )
    }

    @Test func browsingSearchesAndSortsWithoutChangingTheGraph() {
        let data = snapshot()
        let inspector = LibraryGraphInspector(data: data)
        #expect(inspector.items(matching: "").map(\.id) == [
            note.id,
            concept.id,
            other.id,
            source.id,
        ])
        #expect(inspector.items(matching: "  EVALUATION  ").map(\.id) == [other.id])
        #expect(inspector.items(matching: "absent").isEmpty)
        #expect(inspector.data.graph == data.graph)
        #expect(inspector.connectionCount(for: note.id) == 3)
        #expect(inspector.connectionCount(for: "missing") == 0)
    }

    @Test func neighborsShowTheOtherEndpointGroupedByActualItemKind() throws {
        let inspector = LibraryGraphInspector(data: snapshot())
        let neighbors = inspector.neighbors(of: note.id)
        #expect(neighbors.count == 3)
        #expect(neighbors.allSatisfy { $0.node.id != note.id })
        #expect(neighbors.filter { $0.group == .notes }.map(\.node.id) == [other.id])
        let sourceRow = try #require(neighbors.first { $0.group == .sources })
        #expect(sourceRow.node.id == source.id)
        #expect(sourceRow.relationship == "Derived from")
        #expect(neighbors.filter { $0.group == .concepts }.map(\.node.id) == [concept.id])
        #expect(inspector.kind(of: note) == "Note")
        #expect(inspector.kind(of: source) == "Source")
        #expect(inspector.kind(of: concept) == "Concept")
    }

    @Test func directedRelationshipsReverseWithoutChangingTheirEvidence() throws {
        let inspector = LibraryGraphInspector(data: snapshot())
        let outgoing = try #require(inspector.neighbors(of: note.id).first {
            $0.node.id == source.id
        })
        let incoming = try #require(inspector.neighbors(of: source.id).first)
        #expect(incoming.relationship == "Source for")
        #expect(incoming.node.id == note.id)
        #expect(incoming.id == outgoing.id)
        #expect(incoming.connection.reasons.map(\.text) == outgoing.connection.reasons.map(\.text))
        #expect(LibraryGraphInspector.relationship(.uses, outgoing: true) == "Uses")
        #expect(LibraryGraphInspector.relationship(.uses, outgoing: false) == "Used by")
        #expect(LibraryGraphInspector.relationship(.partOf, outgoing: false) == "Contains")
        #expect(LibraryGraphInspector.relationship(.measuredBy, outgoing: false) == "Measures")
        for predicate in GraphPredicate.allCases {
            #expect(!LibraryGraphInspector.relationship(predicate, outgoing: false).isEmpty)
        }
    }

    @Test func documentMarksDifferByShapeWithoutColor() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let note = GraphDocumentMark(isSource: false)
        let source = GraphDocumentMark(isSource: true)
        #expect(note.label == "Note")
        #expect(source.label == "Source")
        #expect(note.path(in: rect).boundingRect == rect.insetBy(dx: 2, dy: 0))
        #expect(source.path(in: rect).boundingRect == rect.insetBy(dx: 2, dy: 0))
        #expect(note.path(in: rect).contains(CGPoint(x: 17, y: 2)))
        #expect(!source.path(in: rect).contains(CGPoint(x: 17, y: 2)))
        #expect(note.fold(in: rect).isEmpty)
        #expect(!source.fold(in: rect).isEmpty)
        #expect(!note.textLines(in: rect).isEmpty)
        #expect(source.textLines(in: rect).isEmpty)
        #expect(note.textLines(in: rect).boundingRect.width < note.path(in: rect).boundingRect
            .width)
        #expect(note.path(in: rect).boundingRect.contains(note.textLines(in: rect).boundingRect))
    }

    @Test func dotAndShapeMarksDropPageDetails() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let corner = CGPoint(x: 4, y: 4)
        for style in [GraphMarkStyle.dots, .shapes] {
            let note = GraphDocumentMark(isSource: false, style: style)
            let source = GraphDocumentMark(isSource: true, style: style)
            #expect(note.textLines(in: rect).isEmpty)
            #expect(source.fold(in: rect).isEmpty)
            // Notes are round in both styles; only Shapes squares off sources.
            #expect(!note.path(in: rect).contains(corner))
            #expect(source.path(in: rect).contains(corner) == (style == .shapes))
        }
    }

    @Test func emptyAndUnavailableEndpointsDoNotInventConnections() {
        let empty = LibraryGraphInspector(data: LibraryGraphSnapshot())
        #expect(empty.items(matching: "").isEmpty)
        #expect(empty.neighbors(of: note.id).isEmpty)
        var data = snapshot()
        data.graph.nodes.removeAll { $0.id == source.id }
        #expect(LibraryGraphInspector(data: data).neighbors(of: note.id).count == 2)
    }
}
