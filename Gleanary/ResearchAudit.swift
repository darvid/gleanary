import Foundation

/// A research audit (RESEARCH_GAPS.md): checks the items a person confirms against the criteria
/// they accept, then searches the whole library for anything that would answer a criterion
/// before reporting it as a possible gap. A gap is only ever "not found in this audit", never a
/// claim that the answer doesn't exist.
enum AuditLimits {
    static let maximumDimensions = 6
    /// Library search results kept per query when looking for a hidden answer.
    static let passagesPerQuery = 8
    /// Items outside the first reading whose matching passages are read for a hidden answer.
    static let counterItems = 6
    /// Findings shown before "Show more".
    static let shownFindings = 3
}

/// How well the audited evidence covers one criterion. These describe the audit, not the world.
enum AuditCoverage: String, Codable, Sendable {
    /// A source states something that meets the criterion.
    case supported
    /// The full protocol ran and found nothing that meets it.
    case notFound = "not_found"
    /// Something that could change the answer wasn't read or searched, so no gap is claimed.
    case unknown
    /// The person didn't accept the criterion, so it wasn't checked.
    case outOfScope = "out_of_scope"

    var label: String {
        switch self {
        case .supported: "Supported"
        case .notFound: "Not found"
        case .unknown: "Unknown"
        case .outOfScope: "Not checked"
        }
    }
}

/// One criterion the audit checks. Only criteria the person accepts are checked; the app starts
/// a criterion accepted only when its origin is a quote from their own request.
struct AuditDimension: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    /// What a source must state to answer it.
    let criteria: String
    /// An exact quote from the request it came from, or empty when the model suggested it.
    let origin: String
    let alternateTerms: [String]
    /// A phrasing of what an answer would say, for the hidden-answer search.
    let answerQuery: String
    var accepted: Bool

    var fromRequest: Bool {
        !origin.isEmpty
    }
}

struct AuditBrief: Codable, Sendable, Equatable {
    var query: String
    var categoryCodes: [String]
    var dimensions: [AuditDimension]

    /// The Writer's gather stage finds candidates the same way.
    var gatherBrief: WriterBrief {
        WriterBrief(
            query: query, categoryCodes: categoryCodes, fields: dimensions.map(\.label),
            generalKnowledge: false
        )
    }

    static let instructions = """
    You plan a research audit: checking what the user's saved library does and doesn't establish
    about their research question. Return only the plan.
    query: 1 to 6 topical search keywords for the subject, without filler.
    categoryCodes: supplied category codes whose names clearly match the subject, else empty.
    dimensions: 1 to 6 things the research needs to establish. For each:
    label: a short name (at most 6 words).
    criteria: one sentence saying what a source must state to answer it, specific enough that a
    passage that only mentions the topic doesn't count.
    origin: an exact, contiguous quote from the request that asks for it, or empty when the
    request doesn't ask for it and you are suggesting it.
    alternateTerms: up to 4 other words or phrases a source might use for it.
    answerQuery: a short phrase an answering passage would plausibly contain.
    Prefer what the user actually asked about. Never invent categories.
    """

    static func prompt(request: String, categories: [DecimalCategory]) -> String {
        WriterBrief.prompt(request: request, categories: categories)
    }

    static func jsonSchema(categories: [DecimalCategory]) -> [String: Any] {
        let code: [String: Any] = categories.isEmpty ? ["type": "string", "maxLength": 0]
            : ["type": "string", "enum": categories.map(\.code)]
        let text: [String: Any] = ["type": "string"]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["query", "categoryCodes", "dimensions"],
            "properties": [
                "query": text,
                "categoryCodes": ["type": "array", "maxItems": 6, "items": code],
                "dimensions": [
                    "type": "array", "minItems": 1, "maxItems": AuditLimits.maximumDimensions,
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "required": [
                            "label",
                            "criteria",
                            "origin",
                            "alternateTerms",
                            "answerQuery",
                        ],
                        "properties": [
                            "label": text, "criteria": text, "origin": text,
                            "alternateTerms": ["type": "array", "maxItems": 4, "items": text],
                            "answerQuery": text,
                        ],
                    ],
                ],
            ],
        ]
    }
}

/// What the model proposes, before the app checks it.
struct AuditProposal: Decodable, Sendable {
    struct Dimension: Decodable, Sendable {
        let label: String
        let criteria: String
        let origin: String
        let alternateTerms: [String]
        let answerQuery: String
    }

    let query: String
    let categoryCodes: [String]
    let dimensions: [Dimension]

    /// Drops unknown categories and duplicate criteria, and clears any origin that isn't
    /// really in the request, so a model's suggestion can't pass as the person's own.
    func validated(request: String, categories: [DecimalCategory]) throws -> AuditBrief {
        let codes = Set(categories.map(\.code))
        let picked = Array(Set(categoryCodes.filter { codes.contains($0) })).sorted()
        let query = Self.plain(query, limit: 200)
        let haystack = FactRecord.normalized(request)
        var seen = Set<String>()
        var dimensions: [AuditDimension] = []
        for proposed in self.dimensions {
            let label = Self.plain(proposed.label, limit: 60)
            let criteria = Self.plain(proposed.criteria, limit: 300)
            guard !label.isEmpty, !criteria.isEmpty, seen.insert(label.lowercased()).inserted
            else { continue }
            let origin = Self.plain(proposed.origin, limit: 300)
            let quoted = origin.count >= 3 && haystack.contains(FactRecord.normalized(origin))
            dimensions.append(AuditDimension(
                id: "d\(dimensions.count + 1)", label: label, criteria: criteria,
                origin: quoted ? origin : "",
                alternateTerms: proposed.alternateTerms.prefix(4)
                    .map { Self.plain($0, limit: 60) }
                    .filter { !$0.isEmpty },
                answerQuery: Self.plain(proposed.answerQuery, limit: 200),
                accepted: quoted
            ))
            if dimensions.count == AuditLimits.maximumDimensions {
                break
            }
        }
        guard !dimensions.isEmpty, !query.isEmpty || !picked.isEmpty
        else { throw ConversationError.invalidPlan }
        return AuditBrief(query: query, categoryCodes: picked, dimensions: dimensions)
    }

    private static func plain(_ text: String, limit: Int) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }
}

/// Models that can plan an audit. Audits read many items and search the whole library, so they
/// run with ChatGPT only.
protocol ResearchAuditing: Sendable {
    func auditBrief(request: String, categories: [DecimalCategory]) async throws
        -> AuditProposal
}

/// A passage that meets a criterion, with the quote the app found in the item's text.
struct AuditEvidence: Codable, Sendable, Equatable {
    let itemID: UUID
    let title: String
    let value: String
    let quote: String
    /// Found by the library search rather than in the items the person confirmed.
    let outsideScope: Bool
}

/// One query of the hidden-answer search.
struct AuditSearch: Codable, Sendable, Equatable {
    enum Family: String, Codable, Sendable { case literal, alternate, answer }
    let query: String
    let family: Family
    let matches: Int
    let failed: Bool
}

struct DimensionResult: Codable, Sendable, Equatable, Identifiable {
    let dimension: AuditDimension
    let coverage: AuditCoverage
    let evidence: [AuditEvidence]
    let searches: [AuditSearch]
    /// Items outside the first reading whose matching passages were read.
    let searchedItems: Int
    let limitations: [String]
    var dismissed = false

    var id: String {
        dimension.id
    }

    var isGap: Bool {
        coverage == .notFound && !dismissed
    }
}

struct AuditReport: Codable, Sendable, Equatable {
    var results: [DimensionResult]
    /// Items read in full, out of those confirmed.
    let read: Int
    let selected: Int
    /// Live items in the library's search index when the audit ran.
    let searchable: Int
    /// Each item read, at the revision read, so a later change marks the audit stale.
    let revisions: [UUID: String]
    let limitations: [String]
    let checkedAt: Date

    var gaps: [DimensionResult] {
        results.filter(\.isGap)
    }
}

struct ResearchAudit: Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable { case awaiting, auditing, completed, cancelled }

    let taskID: UUID
    let request: String
    var brief: AuditBrief
    let candidates: [ScopeCandidate]
    var selection: [UUID]
    let scopeLimit: Int
    var status: Status
    var report: AuditReport?
    /// Set on load: an item the audit read was changed or deleted since.
    var stale = false

    var id: UUID {
        taskID
    }
}

extension AuditReport {
    /// The finding's wording, bounded to what this audit read and searched.
    static func observation(_: DimensionResult, report: AuditReport) -> String {
        "No passage meeting this criterion was found in the \(items(report.read)) read, or in a search of \(items(report.searchable)) in your library."
    }

    static func reason(_ dimension: AuditDimension) -> String {
        dimension.fromRequest ? "You asked about it: “\(dimension.origin)”."
            : "You accepted it as a criterion for this audit."
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }

    /// The chat reply when an audit finishes.
    var summary: String {
        let checked = results.filter { $0.coverage != .outOfScope }
        func count(_ coverage: AuditCoverage) -> Int {
            checked.count(where: { $0.coverage == coverage })
        }
        var text =
            "Checked \(checked.count == 1 ? "1 criterion" : "\(checked.count) criteria") against \(Self.items(read)), then searched your library for anything that answers what wasn't found."
        let gaps = count(.notFound)
        text += gaps == 0 ? " No gaps under these criteria and this search."
            : gaps == 1 ? " 1 possible gap is below."
            : " \(gaps) possible gaps are below."
        if count(.unknown) > 0 {
            text +=
                " \(count(.unknown)) couldn't be assessed, because something that might answer it wasn't fully read."
        }
        return text + " This covers only your saved items, not research in general."
    }
}
