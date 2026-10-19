import Foundation

/// Every planning stage sees the same quotation authority as the Writer and verifier.
/// Full page text remains in retained sources, not an extra uncitable planning context.
struct ResearchEvidenceView: Encodable {
    struct Source: Encodable {
        let id: UUID
        let title: String
        let url: URL?
        let noteID: UUID?
        let readAt: String
        let limitations: [String]
    }

    struct Record: Encodable {
        let id: String
        let sourceID: UUID
        let field: String
        let quote: String
    }

    let sources: [Source]
    let records: [Record]

    init(_ evidence: NoteSeries.Dossier, records selected: Set<String>? = nil) {
        let facts = evidence.facts.filter { selected?.contains($0.id) ?? true }
        let sourceIDs = Set(facts.map(\.sourceID))
        sources = evidence.sources.filter { selected == nil || sourceIDs.contains($0.id) }
            .map { .init(
                id: $0.id,
                title: $0.title,
                url: $0.url,
                noteID: $0.noteID,
                readAt: $0.retrievedAt.formatted(.iso8601),
                limitations: $0.limitations
            ) }
        records = facts.map { .init(
            id: $0.id,
            sourceID: $0.sourceID,
            field: $0.field,
            quote: $0.quote
        ) }
    }
}
