import Foundation

struct GraphNode: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case document, concept, person, organization, tool }
    let id: String
    let kind: Kind
    let label: String
    var noteID: UUID?

    static func documentID(_ id: UUID) -> String {
        "note:" + id.uuidString
    }

    static func entity(_ label: String, kind: Kind, noteID _: UUID) -> GraphNode {
        let normalized = normalize(label)
        // Exact normalized names merge within one type. Evidence remains source-specific,
        // while cross-type names stay separate (for example, an organization and a tool).
        return GraphNode(
            id: "entity:" + ContentHash
                .of([kind.rawValue, normalized].joined(separator: "\u{0}")),
            kind: kind,
            label: normalized
        )
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum GraphPredicate: String, Codable, Sendable, CaseIterable {
    case relatedTo = "related_to", derivedFrom = "derived_from"
    case mentions, linksTo = "links_to", authoredBy = "authored_by", uses, addresses, supports,
         limits
    case partOf = "part_of", comparesWith = "compares_with", evaluatedOn = "evaluated_on"
    case measuredBy = "measured_by", improvesOn = "improves_on"
    var label: String {
        rawValue.replacingOccurrences(of: "_", with: " ")
    }
}

struct GraphEdge: Identifiable, Codable, Sendable, Equatable {
    let source: String
    let target: String
    let predicate: GraphPredicate
    var id: String {
        ContentHash.of([source, predicate.rawValue, target].joined(separator: "\u{0}"))
    }
}

struct GraphEvidence: Identifiable, Sendable {
    let id: String
    let edge: GraphEdge
    let noteID: UUID
    let revision: UUID
    let noteName: String
    let sourceLabel: String
    let targetLabel: String
    let quote: String
    let citation: SourceCitation?
    let offset: Int
    let origin: String
    var inferred: Bool {
        origin == "model"
    }
}

struct GraphSnapshot: Sendable, Equatable {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var totalNodes = 0
    var matchingIDs: Set<String> = []
    var truncatedEdges = false
}

struct GraphPosition: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

struct GraphSegment: Codable, Sendable {
    let text: String
    var citation: SourceCitation?
    var offset = 0 // UTF-16 offset in the immutable block, or in this note revision.
}

struct GraphChunk: Codable, Sendable {
    let segments: [GraphSegment]
    var text: String {
        segments.map(\.text).joined(separator: "\n\n")
    }

    var extractionText: String {
        segments.map { segment in
            guard let section = segment.citation?.section, !section.isEmpty else {
                return segment.text
            }
            return "Section: \(section)\n\(segment.text)"
        }.joined(separator: "\n\n")
    }

    static func make(_ segments: [GraphSegment], limit: Int = 1800) -> [GraphChunk] {
        var chunks: [GraphChunk] = []
        var pending: [GraphSegment] = []
        var count = 0
        for segment in segments {
            var start = segment.text.startIndex
            while start < segment.text.endIndex {
                var end = segment.text.index(
                    start,
                    offsetBy: limit,
                    limitedBy: segment.text.endIndex
                ) ?? segment.text.endIndex
                // Split long blocks near a word boundary without losing any source characters.
                if end != segment.text.endIndex,
                   let space = segment.text[start ..< end].lastIndex(where: \.isWhitespace),
                   segment.text.distance(from: start, to: space) > limit / 2
                {
                    end = segment.text.index(after: space)
                }
                let text = String(segment.text[start ..< end])
                if count + text.count > limit, !pending.isEmpty {
                    chunks.append(GraphChunk(segments: pending)); pending = []; count = 0
                }
                pending.append(GraphSegment(
                    text: text,
                    citation: segment.citation,
                    offset: segment.offset + start
                        .utf16Offset(in: segment.text)
                ))
                count += text.count
                start = end
            }
        }
        if !pending.isEmpty {
            chunks.append(GraphChunk(segments: pending))
        }
        return chunks
    }
}

struct GraphClaim: Sendable {
    let source: GraphNode
    let target: GraphNode
    let predicate: GraphPredicate
    let quote: String
    let citation: SourceCitation?
    let offset: Int
    let origin: String
    var edge: GraphEdge {
        GraphEdge(source: source.id, target: target.id, predicate: predicate)
    }
}

struct GraphJob: Identifiable, Sendable {
    let noteID: UUID
    let revision: UUID
    let token: UUID
    let name: String
    let state: String
    let completed: Int
    let total: Int
    let error: String?
    var id: UUID {
        noteID
    }
}

struct GraphWork: Sendable {
    let job: GraphJob
    let chunk: GraphChunk
}

struct GraphPlan: Codable, Sendable {
    var sourceChunks: [GraphChunk]
    var extractionIndices: [Int]
    var selectionComplete: Bool

    var extractionChunks: [GraphChunk] {
        extractionIndices.map { sourceChunks[$0] }
    }
}

struct GraphCandidate: Sendable {
    let name: String
    let kind: ExtractedEntityKind
    let mentions: Int
    let sections: Int
    let firstChunk: Int
    let quote: String
}

struct GraphRelationCandidate: Sendable {
    let source: String
    let target: String
    let predicate: ExtractedPredicate
    let quote: String
}

struct GraphCurationWork: Sendable {
    let job: GraphJob
    let candidates: [GraphCandidate]
    let relations: [GraphRelationCandidate]
    let relationExcerpts: [String]
    let evidence: GraphChunk
    let sourceChunks: [GraphChunk]
    let mapEvidence: [GraphSegment]
}

enum MindMapRole: String, Codable, Sendable, CaseIterable {
    case subject, question, theme, mechanism, evidence, finding, tradeoff, limitation,
         application
}

struct MindMapNode: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let noteID: UUID
    let parentID: String?
    let title: String
    let summary: String
    let role: MindMapRole
    let ordinal: Int
    let depth: Int
    var collapsed: Bool
}

struct MindMapEvidence: Identifiable, Sendable, Equatable {
    let id: String
    let nodeID: String
    let noteID: UUID
    let noteName: String
    let quote: String
    let citation: SourceCitation?
    let offset: Int
}

struct MindMapSnapshot: Sendable, Equatable {
    var noteID: UUID?
    var title = ""
    var nodes: [MindMapNode] = []
}

struct MindMapSummary: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let generatedAt: Date
}

struct MindMapClaim: Sendable {
    let key: String
    let parentKey: String?
    let title: String
    let summary: String
    let role: MindMapRole
    let evidence: GraphSegment
}

enum GraphError: LocalizedError {
    case stale, unavailable
    var errorDescription: String? {
        switch self {
        case .stale: "This graph extraction was replaced, paused, or deleted."
        case .unavailable: "Entity extraction needs an available Apple Intelligence model. Documents and explicit links still work. Enable Apple Intelligence in System Settings, then retry."
        }
    }
}
