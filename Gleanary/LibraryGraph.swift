import Foundation

struct GraphCamera: Equatable {
    var scale = 1.0
    var pan = CGSize.zero
}

struct LibraryGraphRequest: Equatable, Sendable {
    var scope = LibraryScope.all
    var kind = LibraryKindFilter.all
    var query = ""
    var focus: UUID?
    var depth = 1
    var includesConcepts = false
    var limit = 200
}

struct LibraryGraphReason: Identifiable, Sendable {
    let id: String
    let label: String
    let text: String
    var noteID: UUID?
    var citation: SourceCitation?
}

struct LibraryGraphConnection: Identifiable, Sendable {
    let edge: GraphEdge
    let reasons: [LibraryGraphReason]
    var id: String {
        edge.id
    }
}

struct LibraryGraphSnapshot: Sendable {
    var graph = GraphSnapshot()
    var connections: [LibraryGraphConnection] = []
    var titles: [String: String] = [:]
    var truncatedReasons = false
    var sourceNodeIDs: Set<String> = []
}
