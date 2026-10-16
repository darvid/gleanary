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

        func facts(for entry: Entry) -> [Fact] {
            facts.filter { entry.fields.contains($0.field) }
        }

        func validate() throws {
            guard sources.count <= maximumLibrarySources + maximumWebSources,
                  Set(sources.map(\.id)).count == sources.count,
                  facts.count <= sources.count * factsPerSource,
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

    struct Paragraph: Codable, Sendable, Equatable {
        let text: String
        let records: [String]
    }

    struct Draft: Codable, Sendable, Equatable {
        let paragraphs: [Paragraph]

        func validate(entry: Entry, dossier: Dossier) throws {
            let allowed = Set(dossier.facts(for: entry).map(\.id))
            guard (2 ... 8).contains(paragraphs.count),
                  Set(paragraphs.map { $0.text.lowercased() }).count == paragraphs.count
            else { throw Failure.invalidDraft }
            for paragraph in paragraphs {
                guard plain(paragraph.text, limit: 1400), !paragraph.records.isEmpty,
                      paragraph.records.count <= 8,
                      Set(paragraph.records).count == paragraph.records.count,
                      Set(paragraph.records).isSubset(of: allowed)
                else { throw Failure.invalidDraft }
            }
        }
    }

    struct DraftFeedback: Codable, Sendable {
        let draft: Draft
        let structurallyValid: Bool
        let supported: [Bool]
    }

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

        func validate(outline: Outline, drafts: [UUID: Draft], library: [Source]) throws {
            guard distinct, links.count <= maximumNotes * 4 else { throw Failure.invalidLinks }
            let targets = Set(outline.entries.map { $0.existingNoteID ?? $0.id } + library
                .compactMap(\.noteID))
            var used = Set<String>()
            for link in links {
                guard let draft = drafts[link.from], link.from != link.to,
                      targets.contains(link.to), plain(link.reason, limit: 400),
                      used.insert("\(link.from):\(link.to)").inserted
                else { throw Failure.invalidLinks }
                if !link.anchor.isEmpty {
                    guard draft.paragraphs.indices.contains(link.paragraph),
                          plain(link.anchor, limit: 100),
                          draft.paragraphs[link.paragraph].text.components(separatedBy: link.anchor)
                          .count == 2,
                          used.insert("\(link.from):\(link.paragraph)").inserted
                    else { throw Failure.invalidLinks }
                }
            }
        }
    }

    enum ArtifactKind: String, Codable, Sendable {
        case brief, library, outline, webSearch, webSource, facts, dossier, draftFeedback, draft,
             curationCandidate,
             curation
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
        var errorDescription: String? {
            switch self {
            case .needsChatGPT: "Researching a note series needs ChatGPT. Connect it in Settings. Library-only research is still available."
            case .invalidOutline: "The note-series outline failed its coverage or duplication checks. Retry; nothing was published. A series supports up to 12 distinct topics; existing notes count toward coverage."
            case .invalidEvidence: "The research evidence failed its source checks. Nothing was published."
            case .invalidDraft: "A draft failed its citation or source-support checks. Retry to resume; nothing was published."
            case .invalidLinks: "The notes or proposed links failed the Curator's checks. Retry to resume; nothing was published."
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

protocol NoteSeriesInferring: Sendable {
    func extractSeriesFacts(_ chunk: ExtractionChunk) async throws -> [ExtractedFact]
    func seriesBrief(request: String) async throws -> NoteSeries.Brief
    func seriesOutline(
        request: String,
        brief: NoteSeries.Brief,
        library: [NoteSeries.Source]
    ) async throws -> NoteSeries.Outline
    func reviewSeriesOutline(
        _ outline: NoteSeries.Outline,
        request: String,
        library: [NoteSeries.Source]
    ) async throws -> Bool
    func draftSeriesNote(
        _ entry: NoteSeries.Entry,
        dossier: NoteSeries.Dossier,
        style: WritingStyle,
        feedback: NoteSeries.DraftFeedback?
    ) async throws -> NoteSeries.Draft
    func verifySeriesDraft(
        _ draft: NoteSeries.Draft,
        entry: NoteSeries.Entry,
        dossier: NoteSeries.Dossier
    ) async throws -> [Bool]
    func curateSeries(
        _ outline: NoteSeries.Outline,
        drafts: [UUID: NoteSeries.Draft],
        library: [NoteSeries.Source]
    ) async throws -> NoteSeries.Curation
}
