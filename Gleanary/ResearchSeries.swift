import Foundation

/// The current working state is explicit; immutable snapshots preserve its history.
enum ResearchSeries {
    static let draftLimit = 3
    static let revisionLimit = 2

    struct Requirement: Codable, Sendable, Equatable {
        let id: String
        let quote: String
        let coverage: String
    }

    struct Intent: Codable, Sendable, Equatable {
        let brief: NoteSeries.Brief
        let requirements: [Requirement]
        let fields: [String]
        let preferredDomains: [String]
        let requestedCount: Int
        let countQuote: String
        let connected: Bool

        func validate(request: String) throws {
            guard NoteSeries.plain(brief.query, limit: 200), !fields.isEmpty,
                  fields.count <= NoteSeries.maximumFields,
                  fields.allSatisfy({ NoteSeries.plain($0, limit: 80) }),
                  Set(fields).count == fields.count,
                  brief.libraryQueries.count <= 6,
                  brief.libraryQueries.allSatisfy({ NoteSeries.plain($0, limit: 200) }),
                  requirements.count <= 24, Set(requirements.map(\.id)).count == requirements.count,
                  requirements
                  .allSatisfy({ !$0.quote.isEmpty && request.contains($0.quote) && NoteSeries.plain(
                      $0.id,
                      limit: 40
                  ) && NoteSeries.plain($0.coverage, limit: 700) }),
                  (0 ... NoteSeries.maximumNotes).contains(requestedCount),
                  requestedCount == 0 ? countQuote
                  .isEmpty : (!countQuote.isEmpty && request.contains(countQuote)),
                  preferredDomains.count <= 8,
                  preferredDomains.allSatisfy({ $0.range(
                      of: #"^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$"#,
                      options: .regularExpression
                  ) != nil })
            else { throw Failure.invalidIntent }
        }
    }

    struct Contract: Codable, Sendable, Equatable {
        let entry: NoteSeries.Entry
        /// Core evidence belongs to one note. Shared evidence is brief prerequisite context only.
        let records: [String]
        let sharedRecords: [String]
        let excludes: [String]
        let requirements: [String]
    }

    struct Relationship: Codable, Sendable, Equatable {
        let from: UUID
        let to: UUID
        let reason: String
        /// Only explicitly required relationships become publication obligations.
        let requirements: [String]

        var link: NoteSeries.Link {
            .init(
                from: from,
                to: to,
                paragraph: 0,
                anchor: "",
                reason: reason
            )
        }
    }

    struct Plan: Codable, Sendable, Equatable {
        let outline: NoteSeries.Outline
        let contracts: [Contract]
        let relationships: [Relationship]

        func assignedEvidence(_ evidence: NoteSeries.Dossier) -> NoteSeries.Dossier {
            var assigned = evidence
            assigned
                .topicRecords = Dictionary(uniqueKeysWithValues: contracts
                    .filter { $0.entry.existingNoteID == nil }
                    .map { ($0.entry.id, $0.records + $0.sharedRecords) })
            return assigned
        }

        func validate(intent: Intent, evidence: NoteSeries.Dossier) throws {
            try evidence.validate()
            try outline.validate(library: evidence.sources, brief: intent.brief)
            guard contracts.map(\.entry) == outline.entries,
                  intent.requestedCount == 0 || contracts.count == intent.requestedCount
            else { throw Failure.invalidPlan }
            let requirements = Set(intent.requirements.map(\.id))
            let covered = Set(contracts.flatMap(\.requirements) + relationships
                .flatMap(\.requirements))
            guard covered == requirements else { throw Failure.missingRequirements }
            try validateSourcePolicy(intent: intent, evidence: evidence)
            var owned = Set<String>()
            for contract in contracts {
                try validateContract(contract, requirements: requirements, evidence: evidence)
                if contract.entry.existingNoteID == nil {
                    guard owned.isDisjoint(with: contract.records)
                    else { throw Failure.duplicateOwnership }
                    owned.formUnion(contract.records)
                }
            }
            let ids = Set(outline.entries.map { $0.existingNoteID ?? $0.id } + evidence.sources
                .compactMap(\.noteID))
            let newIDs = Set(contracts.filter { $0.entry.existingNoteID == nil }.map(\.entry.id))
            guard relationships.count <= NoteSeries.maximumNotes * 4,
                  relationships
                  .allSatisfy({
                      newIDs.contains($0.from) && ids.contains($0.to) && $0.from != $0
                          .to && NoteSeries
                          .plain(
                              $0.reason,
                              limit: 400
                          ) && Set($0.requirements).isSubset(of: requirements) })
            else { throw Failure.invalidPlan }
            try assignedEvidence(evidence).validate()
        }

        private func validateSourcePolicy(intent: Intent, evidence: NoteSeries.Dossier) throws {
            if intent.brief.mode == .libraryOnly {
                guard evidence.sources.allSatisfy({ $0.noteID != nil })
                else { throw Failure.invalidPlan }
            }
            if intent.brief.mode == .freshWeb {
                let webIDs = Set(evidence.sources.filter { $0.noteID == nil && $0.url != nil }
                    .map(\.id))
                let used = Set(contracts.flatMap { $0.records + $0.sharedRecords })
                guard evidence.facts
                    .contains(where: { used.contains($0.id) && webIDs.contains($0.sourceID) })
                else { throw Failure.invalidPlan }
            }
        }

        private func validateContract(
            _ contract: Contract,
            requirements: Set<String>,
            evidence: NoteSeries.Dossier
        ) throws {
            let records = contract.records + contract.sharedRecords
            guard Set(contract.requirements).isSubset(of: requirements),
                  contract.excludes.count <= 8, contract.excludes.allSatisfy({ NoteSeries.plain(
                      $0,
                      limit: 500
                  ) }),
                  records.count <= NoteSeries.topicRecordLimit, Set(records).count == records.count,
                  Set(records).isSubset(of: Set(evidence.facts.map(\.id)))
            else { throw Failure.invalidPlan }
            if contract.entry.existingNoteID == nil {
                guard !contract.records.isEmpty else { throw Failure.invalidPlan }
            } else if !records.isEmpty {
                throw Failure.invalidPlan
            }
        }

        var requiredCuration: NoteSeries.Curation {
            .init(
                distinct: true,
                links: relationships.filter { !$0.requirements.isEmpty }.map(\.link)
            )
        }
    }

    struct PlanReview: Codable, Sendable, Equatable {
        let valid: Bool
        let reason: String
    }

    struct EditorialIssue: Codable, Sendable, Equatable {
        let noteID: UUID
        let comparisonID: UUID?
        let claim: String
        let reason: String
    }

    struct EditorialReview: Codable, Sendable, Equatable {
        let issues: [EditorialIssue]
        let links: [NoteSeries.Link]

        func validate(
            plan: Plan,
            drafts: [UUID: NoteSeries.Draft],
            evidence: NoteSeries.Dossier,
            connected: Bool
        ) throws {
            let targets = Set(plan.outline.entries.map { $0.existingNoteID ?? $0.id } + evidence
                .sources.compactMap(\.noteID))
            guard issues.count <= NoteSeries.maximumNotes,
                  Set(issues.map(\.noteID)).count == issues.count
            else { throw Failure.invalidReview }
            for issue in issues {
                guard let draft = drafts[issue.noteID], NoteSeries.plain(issue.reason, limit: 400),
                      NoteSeries.plain(issue.claim, limit: 1400),
                      draft.paragraphs.contains(where: { $0.text.contains(issue.claim) }),
                      issue.comparisonID.map({ $0 != issue.noteID && targets.contains($0) }) ?? true
                else { throw Failure.invalidReview }
            }
            guard issues.isEmpty else { return }
            let curation = NoteSeries.Curation(distinct: true, links: links)
            try curation.validate(outline: plan.outline, drafts: drafts, library: evidence.sources)
            try curation.validatePreservedLinks(
                from: plan.requiredCuration,
                outline: plan.outline,
                drafts: drafts,
                library: evidence.sources
            )
            if connected, targets.count > 1 {
                let linked = Set(links.flatMap { [$0.from, $0.to] })
                guard Set(drafts.keys).isSubset(of: linked) else { throw Failure.disconnected }
            }
        }
    }

    enum Phase: String, Codable,
        Sendable
    { case intent, research, extraction, planning, reviewingPlan, drafting, editing,
           ready, blocked
    }

    enum FetchStatus: String, Codable, Sendable { case pending, fetching, read, unavailable }
    struct SourceJob: Codable, Sendable {
        let url: URL
        var status: FetchStatus = .pending
        var source: NoteSeries.Source?
    }

    struct NoteJob: Codable, Sendable {
        let id: UUID
        var attempts = 0
        var revisions = 0
        var draft: NoteSeries.Draft?
        var reviews: [NoteSeries.ParagraphReview] = []
        var feedback: String?
        var accepted = false
    }

    struct State: Codable, Sendable {
        var revision = 0
        var phase: Phase = .intent
        var intent: Intent?
        var library: [NoteSeries.Source] = []
        var searchStarted = false
        var sources: [SourceJob] = []
        var evidence: NoteSeries.Dossier?
        var planAttempts = 0
        var plan: Plan?
        var planReview: PlanReview?
        var notes: [NoteJob] = []
        var editorialAttempts = 0
        var editorial: EditorialReview?
        var problem: String?

        var drafts: [UUID: NoteSeries.Draft] {
            Dictionary(uniqueKeysWithValues: notes.compactMap { job in
                job.draft.map { (job.id, $0) }
            })
        }
    }

    struct Accepted: Codable, Sendable {
        let request: String
        let intent: Intent
        let plan: Plan
        let planReview: PlanReview
        let notes: [NoteJob]
        let editorial: EditorialReview

        func validate(
            outline: NoteSeries.Outline,
            evidence: NoteSeries.Dossier,
            drafts: [UUID: NoteSeries.Draft],
            curation: NoteSeries.Curation
        ) throws {
            try intent.validate(request: request)
            try plan.validate(intent: intent, evidence: evidence)
            guard plan.outline == outline, planReview.valid, NoteSeries.plain(
                planReview.reason,
                limit: 1000
            ),
                Set(notes.map(\.id)) == Set(drafts.keys), notes.count == drafts.count,
                plan.assignedEvidence(evidence) == evidence,
                curation == NoteSeries.Curation(distinct: true, links: editorial.links),
                editorial.issues.isEmpty
            else { throw Failure.invalidReview }
            for note in notes {
                guard note.accepted, let draft = note.draft, draft == drafts[note.id],
                      draft.verificationIssue(reviews: note.reviews) == nil
                else { throw Failure.invalidReview }
            }
            try editorial.validate(
                plan: plan,
                drafts: drafts,
                evidence: evidence,
                connected: intent.connected
            )
        }
    }

    enum Failure: Error, LocalizedError {
        case invalidIntent, invalidPlan, missingRequirements, duplicateOwnership, invalidReview,
             disconnected, interruptedSearch
        case stopped(String)
        var errorDescription: String? {
            switch self {
            case .invalidIntent: "Research requirements were malformed. Nothing was published."
            case .invalidPlan: "The evidence-backed note plan was incomplete or invalid. Nothing was published."
            case .missingRequirements: "The note plan omitted explicitly requested coverage. Nothing was published."
            case .duplicateOwnership: "The plan assigned the same core evidence to multiple notes. Nothing was published."
            case .invalidReview: "The review did not match the current notes. Nothing was published."
            case .disconnected: "The requested conceptual relationships are incomplete. Nothing was published."
            case .interruptedSearch: "Research was interrupted before its results were saved. Saved work remains intact; this search will not be repeated automatically. Start a new request to research again."
            case let .stopped(reason): "Research series stopped: \(reason) Saved work remains intact; nothing was published."
            }
        }
    }
}

protocol SeriesEvidenceInferring: Sendable {
    func extractSeriesFacts(_ chunk: ExtractionChunk) async throws -> [ExtractedFact]
    func verifySeriesDraft(
        _ draft: NoteSeries.Draft,
        entry: NoteSeries.Entry,
        dossier: NoteSeries.Dossier
    ) async throws -> [NoteSeries.ParagraphReview]
}

protocol EvidenceSeriesInferring: SeriesEvidenceInferring {
    func researchSeriesIntent(request: String) async throws -> ResearchSeries.Intent
    func evidenceSeriesPlan(
        request: String,
        intent: ResearchSeries.Intent,
        evidence: NoteSeries.Dossier,
        previous: ResearchSeries.Plan?,
        feedback: String?
    ) async throws -> ResearchSeries.Plan
    func reviewEvidenceSeriesPlan(
        request: String,
        intent: ResearchSeries.Intent,
        plan: ResearchSeries.Plan,
        evidence: NoteSeries.Dossier
    ) async throws -> ResearchSeries.PlanReview
    func writeEvidenceSeriesNote(
        request: String,
        contract: ResearchSeries.Contract,
        plan: ResearchSeries.Plan,
        evidence: NoteSeries.Dossier,
        style: WritingStyle,
        feedback: String?
    ) async throws -> NoteSeries.Draft
    func editEvidenceSeries(
        request: String,
        intent: ResearchSeries.Intent,
        plan: ResearchSeries.Plan,
        drafts: [UUID: NoteSeries.Draft],
        evidence: NoteSeries.Dossier,
        feedback: String?
    ) async throws -> ResearchSeries.EditorialReview
}
