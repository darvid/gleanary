import Foundation

extension NoteSeries {
    struct ScopeProposal: Codable, Sendable, Equatable {
        let possible: Bool
        let title: String
        let purpose: String
        let records: [String]
        let deferred: [String]
        let reason: String

        func validate(entry: Entry, dossier: Dossier) throws {
            guard plain(reason, limit: 700) else { throw Failure.invalidArtifact }
            guard possible else {
                guard title.isEmpty, purpose.isEmpty, records.isEmpty, deferred.isEmpty
                else { throw Failure.invalidArtifact }
                return
            }
            guard entry.existingNoteID == nil, plain(title, limit: 120), plain(purpose, limit: 700),
                  title != entry.title || purpose != entry.purpose,
                  !records.isEmpty, records.count <= topicRecordLimit,
                  Set(records).count == records.count,
                  Set(records).isSubset(of: Set(dossier.facts.map(\.id))),
                  !deferred.isEmpty, deferred.count <= 8,
                  deferred.allSatisfy({ plain($0, limit: 500) }),
                  Set(deferred.map { $0.lowercased() }).count == deferred.count
            else { throw Failure.invalidArtifact }
        }
    }

    struct ScopeReview: Codable, Sendable, Equatable {
        let preservesRequest: Bool
        let supported: Bool
        let reason: String

        func validate() throws {
            guard plain(reason, limit: 700) else { throw Failure.invalidArtifact }
        }
    }

    struct ScopeChange: Codable, Sendable, Equatable {
        let original: Entry
        let proposal: ScopeProposal
        let review: ScopeReview

        var entry: Entry {
            .init(
                id: original.id,
                title: proposal.title,
                purpose: proposal.purpose,
                fields: original.fields,
                existingNoteID: nil
            )
        }
    }

    struct ScopedDraft: Codable, Sendable {
        let entry: Entry
        let draft: Draft
    }

    struct ScopeBundle: Codable, Sendable, Equatable {
        let outline: Outline
        let evidence: Dossier
        let changes: [ScopeChange]

        static func narrowedOutline(_ original: Outline, changes: [ScopeChange]) throws -> Outline {
            guard !changes.isEmpty, changes.count <= maximumNotes,
                  Set(changes.map(\.original.id)).count == changes.count,
                  changes.allSatisfy({ change in original.entries.contains(change.original) })
            else { throw Failure.invalidArtifact }
            let entries = original.entries.map { entry in
                changes.first { $0.original.id == entry.id }?.entry ?? entry
            }
            let deferred = original.deferredCoverage + changes.flatMap { change in
                change.proposal.deferred.map { "\(change.entry.title): \($0)" }
            }
            guard Set(entries.map { $0.title.lowercased() }).count == entries.count,
                  deferred.count <= 24, deferred.allSatisfy({ plain($0, limit: 700) }),
                  Set(deferred.map { $0.lowercased() }).count == deferred.count
            else { throw Failure.invalidArtifact }
            return .init(
                title: original.title,
                entries: entries,
                sizingReason: "Supported coverage is organized into distinct notes. Automatically planned subtopics without sufficient evidence are explicitly deferred below.",
                deferredCoverage: deferred
            )
        }

        func validate(original: Outline, dossier: Dossier) throws {
            try evidence.validateExtending(dossier)
            let expected = try Self.narrowedOutline(original, changes: changes)
            guard outline == expected,
                  Set((evidence.scopeRecords ?? [:]).keys) == Set(changes.map(\.original.id))
            else { throw Failure.invalidArtifact }
            for change in changes {
                try change.proposal.validate(entry: change.original, dossier: evidence)
                try change.review.validate()
                guard change.proposal.possible, change.review.preservesRequest,
                      change.review.supported,
                      evidence.scopeRecords?[change.original.id] == change.proposal.records
                else { throw Failure.invalidArtifact }
            }
        }
    }
}
