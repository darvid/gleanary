import Foundation

/// A bounded, task-scoped contract, not a mutable blackboard or a second library.
enum NoteSeries {
    static let maximumNotes = 12
    static let maximumLibrarySources = 16
    static let maximumWebSources = 8
    static let maximumFields = 24
    static let sourceCharacters = 24000
    static let factsPerSource = 8
    /// Covers 24 source extractions, two draft/review attempts for 12 new notes,
    /// planning, curation, hosted search, and a bounded retry allowance.
    static let maximumCalls = 96
    static let topicSourceLimit = 2
    static let topicRecordLimit = 16

    static func webSourceLimit(newNotes: Int) -> Int {
        min(maximumWebSources, max(4, newNotes))
    }

    enum SourceMode: String, Codable, Sendable { case libraryOnly, fillGaps, freshWeb }
    private enum BriefKeys: String, CodingKey { case query, mode, libraryQueries }
    struct Brief: Codable, Sendable, Equatable {
        let query: String
        let mode: SourceMode
        let libraryQueries: [String]

        init(query: String, mode: SourceMode, libraryQueries: [String] = []) {
            self.query = query
            self.mode = mode
            self.libraryQueries = libraryQueries
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: BriefKeys.self)
            query = try values.decode(String.self, forKey: .query)
            mode = try values.decode(SourceMode.self, forKey: .mode)
            libraryQueries = try values
                .decodeIfPresent([String].self, forKey: .libraryQueries) ?? []
        }
    }

    struct Source: Codable, Sendable, Equatable {
        let id: UUID
        let title: String
        let text: String
        let url: URL?
        let noteID: UUID?
        let revision: UUID?
        let contentHash: String
        let retrievedAt: Date
        let limitations: [String]
    }

    struct Entry: Codable, Sendable, Equatable {
        let id: UUID
        let title: String
        let purpose: String
        let fields: [String]
        /// Reuse this note instead of creating a competing one. Never modify its content.
        let existingNoteID: UUID?
    }

    private enum OutlineKeys: String,
        CodingKey { case title, entries, sizingReason, deferredCoverage }
    struct Outline: Codable, Sendable, Equatable {
        let title: String
        let entries: [Entry]
        let sizingReason: String
        let deferredCoverage: [String]

        init(
            title: String,
            entries: [Entry],
            sizingReason: String = "",
            deferredCoverage: [String] = []
        ) {
            self.title = title
            self.entries = entries
            self.sizingReason = sizingReason
            self.deferredCoverage = deferredCoverage
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: OutlineKeys.self)
            title = try values.decode(String.self, forKey: .title)
            entries = try values.decode([Entry].self, forKey: .entries)
            // Existing immutable checkpoints remain resumable without a new model call.
            sizingReason = try values.decodeIfPresent(String.self, forKey: .sizingReason) ?? ""
            deferredCoverage = try values
                .decodeIfPresent([String].self, forKey: .deferredCoverage) ?? []
        }

        func validate(library: [Source], brief: Brief) throws {
            guard Self.validTitle(title), (1 ... maximumNotes).contains(entries.count),
                  Set(entries.map(\.id)).count == entries.count,
                  Set(entries.map { $0.title.lowercased() }).count == entries.count,
                  Set(entries.flatMap(\.fields)).count <= maximumFields,
                  sizingReason.isEmpty || plain(sizingReason, limit: 1000),
                  deferredCoverage.count <= 24,
                  deferredCoverage.allSatisfy({ plain($0, limit: 700) }),
                  Set(deferredCoverage.map { $0.lowercased() }).count == deferredCoverage.count
            else { throw Failure.invalidOutline }
            let reused = entries.compactMap(\.existingNoteID)
            guard Set(reused).count == reused.count,
                  Set(reused).isSubset(of: Set(library.compactMap(\.noteID)))
            else { throw Failure.invalidOutline }
            for entry in entries {
                guard Self.validTitle(entry.title), plain(entry.purpose, limit: 700),
                      (1 ... 8).contains(entry.fields.count),
                      entry.fields.allSatisfy({ plain($0, limit: 80) })
                else { throw Failure.invalidOutline }
            }
            if brief.mode == .freshWeb, entries.allSatisfy({ $0.existingNoteID != nil }) {
                throw Failure.invalidOutline
            }
        }

        private static func validTitle(_ value: String) -> Bool {
            plain(value, limit: 120)
        }
    }

    struct Fact: Codable, Sendable, Equatable {
        let id: String
        let sourceID: UUID
        let field: String
        let value: String
        let quote: String
    }

    struct Dossier: Codable, Sendable, Equatable {
        let sources: [Source]
        let facts: [Fact]
        let unavailableURLs: [URL]
        var topicRecords: [UUID: [String]]? = nil
        var recoverySearchCount: Int? = nil
        var scopeRecords: [UUID: [String]]? = nil

        func facts(for entry: Entry) -> [Fact] {
            if let selected = scopeRecords?[entry.id] ?? topicRecords?[entry.id] {
                let ids = Set(selected)
                return facts.filter { ids.contains($0.id) }
            }
            return facts.filter { entry.fields.contains($0.field) }
        }

        func validateExtending(_ original: Dossier) throws {
            try validate()
            let newTopics = Set((topicRecords ?? [:]).keys)
                .subtracting((original.topicRecords ?? [:]).keys).count
            guard sources.count - original.sources.count <= newTopics * topicSourceLimit,
                  facts.count - original.facts.count <= newTopics * topicRecordLimit,
                  sources.dropFirst(original.sources.count).allSatisfy({ $0.noteID == nil }),
                  Array(sources.prefix(original.sources.count)) == original.sources,
                  Array(facts.prefix(original.facts.count)) == original.facts,
                  Array(unavailableURLs.prefix(original.unavailableURLs.count)) == original
                  .unavailableURLs,
                  (original.topicRecords ?? [:]).allSatisfy({ topicRecords?[$0.key] == $0.value }),
                  (original.scopeRecords ?? [:]).allSatisfy({ scopeRecords?[$0.key] == $0.value }),
                  (recoverySearchCount ?? 0) >= (original.recoverySearchCount ?? 0)
            else { throw Failure.invalidEvidence }
        }

        func validate() throws {
            let topics = topicRecords ?? [:]
            let scopes = scopeRecords ?? [:]
            guard Set(scopes.keys).isSubset(of: Set(topics.keys)),
                  scopes.values
                  .allSatisfy({
                      !$0.isEmpty && $0.count <= topicRecordLimit && Set($0).count == $0
                          .count && Set($0).isSubset(of: Set(facts.map(\.id))) }),
                  topics.count <= maximumNotes,
                  topics.values
                  .allSatisfy({
                      !$0.isEmpty && $0.count <= topicRecordLimit && Set($0).count == $0
                          .count && Set($0).isSubset(of: Set(facts.map(\.id))) }),
                  (recoverySearchCount ?? 0) >= 0,
                  sources.count <= maximumLibrarySources + maximumWebSources + topics
                  .count * topicSourceLimit,
                  Set(sources.map(\.id)).count == sources.count,
                  facts.count <= sources.count * factsPerSource + topics.count * topicRecordLimit,
                  Set(facts.map(\.id)).count == facts.count
            else { throw Failure.invalidEvidence }
            for source in sources {
                guard !source.title.isEmpty, source.title.count <= 1000,
                      !source.text.isEmpty, source.text.count <= sourceCharacters,
                      source.contentHash == ContentHash.of(source.text),
                      source.url.map(WebResearchResult.safeURL) ?? (source.noteID != nil)
                else { throw Failure.invalidEvidence }
            }
            for fact in facts {
                guard let source = sources.first(where: { $0.id == fact.sourceID }),
                      fact.quote.count >= 4, fact.quote.count <= 400,
                      FactRecord.normalized(source.text)
                      .contains(FactRecord.normalized(fact.quote)),
                      !fact.value.isEmpty, fact.value.count <= 300
                else { throw Failure.invalidEvidence }
            }
        }
    }

    struct TopicAssessment: Codable, Sendable {
        let sufficient: Bool
        let records: [String]
        let reason: String
        /// Only public topic keywords may reach hosted search, never PKMS text or reviewer prose.
        let query: String

        func validate(dossier: Dossier) throws {
            guard records.count <= topicRecordLimit, Set(records).count == records.count,
                  Set(records).isSubset(of: Set(dossier.facts.map(\.id))),
                  plain(reason, limit: 700),
                  query
                  .isEmpty ||
                  (plain(query, limit: 160) && query.split(whereSeparator: \.isWhitespace)
                      .count <= 12),
                  !sufficient || (!records.isEmpty && query.isEmpty)
            else { throw Failure.invalidEvidence }
        }
    }

    enum DraftIssue: Codable, Sendable, Equatable {
        case paragraphCount(Int), paragraphRange(minimum: Int, actual: Int), repeatedParagraph(Int),
             invalidProse(Int)
        case missingCitations(Int), excessiveCitations(Int), repeatedCitations(Int),
             unknownCitations(Int)
        case incompleteReview(expected: Int, actual: Int)
        case unverifiedParagraphs([Int])
        case invalidReview(Int)
        case rejectedParagraphs([ParagraphReview])

        var message: String {
            switch self {
            case let .paragraphCount(count): "The draft has \(count) paragraphs; expected 2–8."
            case let .paragraphRange(minimum, actual): "The draft has \(actual) paragraphs; expected \(minimum)–8."
            case let .repeatedParagraph(number): "Paragraph \(number) repeats an earlier paragraph."
            case let .invalidProse(number): "Paragraph \(number) must contain 1–1,400 characters of plain text without links, brackets or line breaks."
            case let .missingCitations(number): "Paragraph \(number) has no evidence citations."
            case let .excessiveCitations(number): "Paragraph \(number) cites more than eight evidence records."
            case let .repeatedCitations(number): "Paragraph \(number) repeats an evidence citation."
            case let .unknownCitations(number): "Paragraph \(number) cites a record outside this note's assigned evidence."
            case let .incompleteReview(expected, actual): "The verifier returned \(actual) paragraph results; expected \(expected). A complete source-support check is required."
            case let .unverifiedParagraphs(numbers): "\(numbers.count == 1 ? "Paragraph" : "Paragraphs") \(numbers.map(String.init).joined(separator: ", ")) did not pass verification for quotation support and topic relevance."
            case let .invalidReview(number): "The verifier returned missing, inconsistent or unanchored feedback for paragraph \(number)."
            case let .rejectedParagraphs(reviews): reviews.map {
                    "Paragraph \($0.paragraph) (\($0.verdict.label)): \($0.reason)"
                }.joined(separator: " ")
            }
        }
    }

    enum ParagraphVerdict: String, Codable, Sendable, CaseIterable {
        case supported, unsupported, offTopic, unsupportedAndOffTopic

        var label: String {
            switch self {
            case .supported: "supported"
            case .unsupported: "quotation support"
            case .offTopic: "topic relevance"
            case .unsupportedAndOffTopic: "quotation support and topic relevance"
            }
        }
    }

    struct ParagraphReview: Codable, Sendable, Equatable {
        let paragraph: Int
        let verdict: ParagraphVerdict
        let claim: String
        let reason: String

        func isValid(for text: String, number: Int) -> Bool {
            guard paragraph == number else { return false }
            if verdict == .supported {
                return claim.isEmpty && reason.isEmpty
            }
            return plain(reason, limit: 400) && plain(claim, limit: 1400) && text.contains(claim)
        }
    }

    struct Paragraph: Codable, Sendable, Equatable {
        let text: String
        let records: [String]

        func validationIssue(number: Int, allowedRecords: Set<String>) -> DraftIssue? {
            guard plain(text, limit: 1400) else { return .invalidProse(number) }
            guard !records.isEmpty else { return .missingCitations(number) }
            guard records.count <= 8 else { return .excessiveCitations(number) }
            guard Set(records).count == records.count else { return .repeatedCitations(number) }
            guard Set(records).isSubset(of: allowedRecords)
            else { return .unknownCitations(number) }
            return nil
        }
    }

    struct Draft: Codable, Sendable, Equatable {
        let paragraphs: [Paragraph]

        func validate(entry: Entry, dossier: Dossier, minimumParagraphs: Int = 2) throws {
            if let issue = validationIssue(
                entry: entry,
                dossier: dossier,
                minimumParagraphs: minimumParagraphs
            ) {
                throw Failure.draft(note: entry.title, issue: issue)
            }
        }

        func validationIssue(
            entry: Entry,
            dossier: Dossier,
            minimumParagraphs: Int = 2
        ) -> DraftIssue? {
            guard (minimumParagraphs ... 8).contains(paragraphs.count)
            else {
                return minimumParagraphs == 2 ? .paragraphCount(paragraphs.count) : .paragraphRange(
                    minimum: minimumParagraphs,
                    actual: paragraphs.count
                )
            }
            let allowed = Set(dossier.facts(for: entry).map(\.id))
            var seen = Set<String>()
            for (index, paragraph) in paragraphs.enumerated() {
                guard seen.insert(paragraph.text.lowercased()).inserted
                else { return .repeatedParagraph(index + 1) }
                if let issue = paragraph.validationIssue(
                    number: index + 1,
                    allowedRecords: allowed
                ) {
                    return issue
                }
            }
            return nil
        }

        func verificationIssue(reviews: [ParagraphReview]) -> DraftIssue? {
            guard reviews.count == paragraphs.count else {
                return .incompleteReview(expected: paragraphs.count, actual: reviews.count)
            }
            for (index, review) in reviews.enumerated() {
                guard review.isValid(for: paragraphs[index].text, number: index + 1) else {
                    return .invalidReview(index + 1)
                }
            }
            let rejected = reviews.filter { $0.verdict != .supported }
            return rejected.isEmpty ? nil : .rejectedParagraphs(rejected)
        }

        /// Older immutable checkpoints have only Boolean flags, not reviewer explanations.
        func verificationIssue(supported: [Bool]) -> DraftIssue? {
            guard supported.count == paragraphs.count else {
                return .incompleteReview(expected: paragraphs.count, actual: supported.count)
            }
            let unverified = supported.enumerated().compactMap { $0.element ? nil : $0.offset + 1 }
            return unverified.isEmpty ? nil : .unverifiedParagraphs(unverified)
        }
    }

    struct DraftFeedback: Codable, Sendable {
        let draft: Draft
        let structurallyValid: Bool
        let supported: [Bool]
        var distinctness: DistinctnessFeedback? = nil
        var issue: DraftIssue? = nil
        var reviews: [ParagraphReview]? = nil
    }

    struct ReviewNote: Codable, Sendable, Equatable {
        let id: UUID
        let title: String
        let text: String
    }

    struct DistinctnessFeedback: Codable, Sendable, Equatable {
        let reason: String
        let comparison: ReviewNote
    }

    struct Overlap: Codable, Sendable, Equatable {
        /// Only this new draft is revised; the comparison note is read-only.
        let from: UUID
        let to: UUID
        let reason: String
    }

    enum CurationIssueKind: String, Codable, Sendable {
        case overlap, missingOverlapDetails, invalidOverlap, tooManyLinks, missingDraft,
             selfLink, invalidTarget, invalidReason, duplicateTarget, invalidParagraph,
             invalidAnchor, anchorMismatch, multipleAnchors, droppedLink, unsupportedRevision
    }

    struct CurationIssue: Codable, Sendable, Equatable {
        let kind: CurationIssueKind
        let message: String
    }

    struct CurationFeedback: Codable, Sendable {
        let previous: Curation?
        let issues: [CurationIssue]
        var requiredLinks: [Link] = []
    }

    struct ReviewedSeries: Codable, Sendable {
        let drafts: [UUID: Draft]
        let curation: Curation
        let requirements: Curation
        var evidence: Dossier? = nil
        var scope: ScopeBundle? = nil
        var workflow: ResearchSeries.Accepted? = nil

        func validate(outline originalOutline: Outline, dossier original: Dossier) throws {
            let outline = scope?.outline ?? originalOutline
            let dossier = evidence ?? original
            try dossier.validateExtending(original)
            if let scope {
                try scope.validate(original: originalOutline, dossier: original)
                try dossier.validateExtending(scope.evidence)
            } else if !(dossier.scopeRecords ?? [:]).isEmpty {
                throw Failure.invalidArtifact
            }
            if let workflow {
                guard scope == nil, evidence == original,
                      requirements == workflow.plan.requiredCuration
                else { throw Failure.invalidArtifact }
                try workflow.validate(
                    outline: originalOutline,
                    evidence: original,
                    drafts: drafts,
                    curation: curation
                )
            }
            let expected = Set(outline.entries.filter { $0.existingNoteID == nil }.map(\.id))
            guard Set(drafts.keys) == expected,
                  Set((dossier.topicRecords ?? [:]).keys).isSubset(of: expected)
            else { throw Failure.invalidArtifact }
            for entry in outline.entries where entry.existingNoteID == nil {
                guard let draft = drafts[entry.id] else { throw Failure.invalidArtifact }
                try draft.validate(
                    entry: entry,
                    dossier: dossier,
                    minimumParagraphs: workflow == nil ? 2 : 1
                )
            }
            try curation.validate(outline: outline, drafts: drafts, library: dossier.sources)
            try curation.validatePreservedLinks(
                from: requirements,
                outline: outline,
                drafts: drafts,
                library: dossier.sources
            )
        }
    }

    private enum CurationKeys: String, CodingKey { case distinct, links, overlaps }

    struct Link: Codable, Sendable, Equatable {
        let from: UUID
        let to: UUID
        /// An exact phrase in this paragraph. Empty means a See also link instead.
        let paragraph: Int
        let anchor: String
        let reason: String
    }

    struct Curation: Codable, Sendable, Equatable {
        let distinct: Bool
        let links: [Link]
        let overlaps: [Overlap]

        init(distinct: Bool, links: [Link], overlaps: [Overlap] = []) {
            self.distinct = distinct
            self.links = links
            self.overlaps = overlaps
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CurationKeys.self)
            try values.encode(distinct, forKey: .distinct)
            try values.encode(links, forKey: .links)
            try values.encode(overlaps, forKey: .overlaps)
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CurationKeys.self)
            distinct = try values.decode(Bool.self, forKey: .distinct)
            links = try values.decode([Link].self, forKey: .links)
            // Older failed runs have only a Boolean verdict. Re-review them for an explanation.
            overlaps = try values.decodeIfPresent([Overlap].self, forKey: .overlaps) ?? []
        }

        func validate(outline: Outline, drafts: [UUID: Draft], library: [Source]) throws {
            if let issue = issues(outline: outline, drafts: drafts, library: library).first {
                throw Failure.curation(issue)
            }
        }

        func issues(outline: Outline, drafts: [UUID: Draft], library: [Source]) -> [CurationIssue] {
            let targets = Set(outline.entries.map { $0.existingNoteID ?? $0.id } + library
                .compactMap(\.noteID))
            return overlapIssues(outline: outline, drafts: drafts, targets: targets) + linkIssues(
                drafts: drafts,
                targets: targets
            )
        }

        private func overlapIssues(
            outline: Outline,
            drafts: [UUID: Draft],
            targets: Set<UUID>
        ) -> [CurationIssue] {
            var issues: [CurationIssue] = []
            if !distinct, overlaps.isEmpty {
                issues.append(.init(
                    kind: .missingOverlapDetails,
                    message: "The reviewer reported overlapping notes without identifying them."
                ))
            }
            var revised = Set<UUID>()
            for overlap in overlaps {
                guard !distinct, drafts[overlap.from] != nil, overlap.from != overlap.to,
                      targets.contains(overlap.to), plain(overlap.reason, limit: 400),
                      revised.insert(overlap.from).inserted
                else {
                    issues.append(.init(
                        kind: .invalidOverlap,
                        message: "The overlap review did not identify a valid new draft and comparison note."
                    ))
                    continue
                }
                let number = outline.entries.firstIndex { $0.id == overlap.from }
                    .map { $0 + 1 } ?? 0
                issues.append(.init(
                    kind: .overlap,
                    message: "Note \(number) overlaps another note: \(overlap.reason)"
                ))
            }
            for overlap in exactOverlaps(outline: outline, drafts: drafts)
                where !overlaps.contains(where: { $0.from == overlap.from })
            {
                let number = outline.entries.firstIndex { $0.id == overlap.from }
                    .map { $0 + 1 } ?? 0
                issues.append(.init(
                    kind: .overlap,
                    message: "Note \(number) repeats a paragraph from another draft."
                ))
            }
            return issues
        }

        private func linkIssues(drafts: [UUID: Draft], targets: Set<UUID>) -> [CurationIssue] {
            var issues: [CurationIssue] = []
            if links.count > maximumNotes * 4 {
                issues.append(.init(
                    kind: .tooManyLinks,
                    message: "The reviewer proposed more than \(maximumNotes * 4) links."
                ))
            }
            var pairs = Set<String>(), paragraphs = Set<String>()
            for (index, link) in links.enumerated() {
                let prefix = "Link \(index + 1): "
                guard let draft = drafts[link.from] else {
                    issues.append(.init(
                        kind: .missingDraft,
                        message: prefix + "the starting note is not a new draft."
                    ))
                    continue
                }
                if link.from == link.to {
                    issues.append(.init(
                        kind: .selfLink,
                        message: prefix + "a note cannot link to itself."
                    ))
                }
                if !targets.contains(link.to) {
                    issues.append(.init(
                        kind: .invalidTarget,
                        message: prefix + "the destination is not an allowed note."
                    ))
                }
                if !plain(link.reason, limit: 400) {
                    issues.append(.init(
                        kind: .invalidReason,
                        message: prefix + "the relationship explanation is missing or malformed."
                    ))
                }
                if !pairs.insert("\(link.from):\(link.to)").inserted {
                    issues.append(.init(
                        kind: .duplicateTarget,
                        message: prefix + "this relationship was proposed more than once."
                    ))
                }
                issues += anchorIssues(link, prefix: prefix, draft: draft, used: &paragraphs)
            }
            return issues
        }

        private func anchorIssues(
            _ link: Link,
            prefix: String,
            draft: Draft,
            used: inout Set<String>
        ) -> [CurationIssue] {
            var issues: [CurationIssue] = []
            guard !link.anchor.isEmpty else { return [] }
            guard draft.paragraphs.indices.contains(link.paragraph) else {
                issues.append(.init(
                    kind: .invalidParagraph,
                    message: prefix + "paragraph \(link.paragraph + 1) does not exist in the draft."
                ))
                return issues
            }
            if !plain(link.anchor, limit: 100) {
                issues.append(.init(
                    kind: .invalidAnchor,
                    message: prefix + "the anchor text is malformed or longer than 100 characters."
                ))
            }
            if draft.paragraphs[link.paragraph].text.components(separatedBy: link.anchor)
                .count != 2
            {
                issues.append(.init(
                    kind: .anchorMismatch,
                    message: prefix + "the anchor text does not occur exactly once in paragraph \(link.paragraph + 1)."
                ))
            }
            if !used.insert("\(link.from):\(link.paragraph)").inserted {
                issues.append(.init(
                    kind: .multipleAnchors,
                    message: prefix + "another inline link already uses this paragraph."
                ))
            }
            return issues
        }

        func overlapsToRepair(outline: Outline, drafts: [UUID: Draft]) -> [Overlap] {
            overlaps + exactOverlaps(outline: outline, drafts: drafts)
                .filter { detected in !overlaps.contains { $0.from == detected.from } }
        }

        /// Match the renderer's exact-duplication gate before freezing the reviewed checkpoint.
        private func exactOverlaps(outline: Outline, drafts: [UUID: Draft]) -> [Overlap] {
            var seen: [String: UUID] = [:]
            var affected = Set<UUID>()
            var result: [Overlap] = []
            for entry in outline.entries {
                for paragraph in drafts[entry.id]?.paragraphs ?? [] {
                    let text = paragraph.text.lowercased()
                    if let previous = seen[text], previous != entry.id,
                       affected.insert(entry.id).inserted
                    {
                        result.append(.init(
                            from: entry.id,
                            to: previous,
                            reason: "These drafts repeat an identical paragraph. Revise this draft's distinct contribution without duplicating the comparison."
                        ))
                    }
                    if seen[text] == nil {
                        seen[text] = entry.id
                    }
                }
            }
            return result
        }

        /// Repair must not make a candidate pass by silently removing valid relationships.
        func validatePreservedLinks(
            from previous: Curation,
            outline: Outline,
            drafts: [UUID: Draft],
            library: [Source]
        ) throws {
            let targets = Set(outline.entries.map { $0.existingNoteID ?? $0.id } + library
                .compactMap(\.noteID))
            for (index, link) in previous.links.enumerated()
                where drafts[link.from] != nil && targets.contains(link.to) && link.from != link.to
            {
                guard links.contains(where: { $0.from == link.from && $0.to == link.to }) else {
                    throw Failure.curation(.init(
                        kind: .droppedLink,
                        message: "Repair removed the relationship from link \(index + 1) instead of repairing it."
                    ))
                }
            }
        }
    }

    enum ArtifactKind: String, Codable, Sendable {
        case brief, library, outline, webSearch, webSource, facts, dossier, draftFeedback, draft,
             curationCandidate, curationRequirements, draftRevision, reviewedSeries,
             topicRepair, topicPlan, topicSearchStarted, topicSearch, topicSourceAttempt,
             topicAssessment,
             topicResearch, topicDossier, topicExhausted, scopeProposal, scopeReview, scopeBundle,
             scopeDraft, workflow, filing, curation
    }

    struct Artifact<Value: Codable & Sendable>: Sendable {
        let id: UUID
        let value: Value
    }

    struct Run: Sendable {
        let id: UUID
        let taskID: UUID
        let indexID: UUID
        let lease: UUID
        let request: String
        let provider: String
        let style: WritingStyle
        let selected: [UUID]
        let published: Bool
    }

    struct Publication: Sendable {
        let index: MarkdownDocument
        let created: [MarkdownDocument]
        let reused: [UUID]
    }

    enum Failure: LocalizedError {
        case needsChatGPT, invalidOutline, invalidEvidence, invalidDraft, invalidLinks,
             noWebSources, noFacts, staleLibrary, invalidArtifact, providerChanged, budget
        case curation(CurationIssue)
        case draft(note: String, issue: DraftIssue)
        case insufficientTopicEvidence(note: String, reason: String)
        var errorDescription: String? {
            switch self {
            case .needsChatGPT: "Researching a note series needs ChatGPT. Connect it in Settings. Library-only research is still available."
            case .invalidOutline: "The note-series outline failed its coverage or duplication checks. Retry; nothing was published. A series supports up to 12 distinct topics; existing notes count toward coverage."
            case .invalidEvidence: "The research evidence failed its source checks. Nothing was published."
            case .invalidDraft: "A draft failed its citation or source-support checks. Retry to resume; nothing was published."
            case let .draft(note, issue): "Draft “\(note)”: \(issue.message) Nothing was published. Retry reuses saved research and verified drafts."
            case let .insufficientTopicEvidence(note, reason): "Insufficient distinct evidence for “\(note)”: \(reason) Saved research and verified drafts remain intact; nothing was published. Narrow the topic or select additional sources for a new request. Another Retry will not restart this topic's search."
            case .invalidLinks: "The reviewer returned an unknown note reference. Your drafts are saved; nothing was published. Retry to rebuild the links."
            case let .curation(issue): "Final review: \(issue.message) Your drafts are saved; nothing was published. Retry resumes this review."
            case .noWebSources: "The cited web pages could not be read. Retry to resume, or ask for a library-only series. Nothing was published."
            case .noFacts: "There is not enough supported evidence to write these notes. Try a narrower topic or select more sources. Nothing was published."
            case .staleLibrary: "A saved note used by this series changed or was removed. Start a new request to research from its current version. Nothing was published."
            case .invalidArtifact: "A saved workflow checkpoint is invalid. Start a new research request; existing notes are unchanged."
            case .providerChanged: "This workflow was started with another ChatGPT model. Select that model to resume, or start a new request."
            case .budget: "This series reached its model-call limit. Start a narrower request. Nothing was published."
            }
        }
    }

    /// Models may return prose, not Markdown destinations. The app owns all links and citations.
    static func plain(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit &&
            !value.contains(where: { "[]<>\n\r".contains($0) }) && !value.contains("://")
    }
}

protocol NoteSeriesInferring: SeriesEvidenceInferring {
    func proposeSeriesScope(
        _ entry: NoteSeries.Entry, request: String, dossier: NoteSeries.Dossier,
        feedback: NoteSeries.DraftFeedback, failure: String
    ) async throws -> NoteSeries.ScopeProposal
    func reviewSeriesScope(
        _ proposal: NoteSeries.ScopeProposal, entry: NoteSeries.Entry, request: String,
        dossier: NoteSeries.Dossier, feedback: NoteSeries.DraftFeedback
    ) async throws -> NoteSeries.ScopeReview
    func assessSeriesTopic(
        _ entry: NoteSeries.Entry,
        dossier: NoteSeries.Dossier,
        feedback: NoteSeries.DraftFeedback
    ) async throws -> NoteSeries.TopicAssessment
    func extractSeriesFacts(_ chunk: ExtractionChunk) async throws -> [ExtractedFact]
    func seriesBrief(request: String) async throws -> NoteSeries.Brief
    func seriesOutline(
        request: String,
        brief: NoteSeries.Brief,
        library: [NoteSeries.Source],
        style: WritingStyle
    ) async throws -> NoteSeries.Outline
    func reviewSeriesOutline(
        _ outline: NoteSeries.Outline,
        request: String,
        library: [NoteSeries.Source]
    ) async throws -> Bool
    func draftSeriesNote(
        _ entry: NoteSeries.Entry,
        request: String,
        dossier: NoteSeries.Dossier,
        style: WritingStyle,
        feedback: NoteSeries.DraftFeedback?
    ) async throws -> NoteSeries.Draft
    func verifySeriesDraft(
        _ draft: NoteSeries.Draft,
        entry: NoteSeries.Entry,
        dossier: NoteSeries.Dossier
    ) async throws -> [NoteSeries.ParagraphReview]
    func curateSeries(
        _ outline: NoteSeries.Outline,
        drafts: [UUID: NoteSeries.Draft],
        library: [NoteSeries.Source],
        feedback: NoteSeries.CurationFeedback?
    ) async throws -> NoteSeries.Curation
}
