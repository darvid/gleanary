import CryptoKit
import Foundation

struct MarkdownDocument: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = .init()
    var name: String
    var markdown: String
    /// Nil denotes a new note. Optional also decodes the original documents.json format.
    var revision: UUID?
}

struct Passage: Identifiable, Sendable {
    let id: UUID
    let documentID: UUID
    let documentName: String
    let ordinal: Int
    let text: String
    let contentHash: String
    var vector: [Float]?
    var citation: SourceCitation?
}

struct SearchMatch: Identifiable, Sendable {
    var id: UUID {
        passage.id
    }

    let passage: Passage
    let score: Double
    let semanticScore: Float?
    let keywordRank: Int?
    let semanticRank: Int?

    var explanation: String {
        if keywordRank != nil, semanticRank != nil {
            return "Text + meaning"
        }
        return keywordRank != nil ? "Text match" : "Meaning match"
    }
}

struct SearchResponse: Sendable {
    let matches: [SearchMatch]
    let notice: String?
}

struct LibraryStatistics: Sendable {
    let passages: Int
    let embeddedPassages: Int
    let pendingNotes: Int
}

struct EmbeddingProfile: Codable, Sendable, Equatable {
    let model: String
    let revision: Int
    let language: String
    let dimensions: Int
    let pipeline: String
    let encoding: String

    init(
        model: String = "apple.naturallanguage.sentence",
        revision: Int,
        language: String = "en",
        dimensions: Int,
        pipeline: String = MarkdownChunker.version,
        encoding: String = "normalized-float32-le-v1"
    ) {
        self.model = model
        self.revision = revision
        self.language = language
        self.dimensions = dimensions
        self.pipeline = pipeline
        self.encoding = encoding
    }

    var id: String {
        ContentHash.of("\(model)|\(revision)|\(language)|\(dimensions)|\(pipeline)|\(encoding)")
    }
}

struct IndexJob: Sendable {
    let documentID: UUID
    let revision: UUID
    let profile: EmbeddingProfile
    let passages: [Passage]
}

struct IndexingReport: Sendable {
    var generated = 0
    var reused = 0
    var completedNotes = 0
}

struct SearchSnapshot: Sendable {
    let profile: EmbeddingProfile?
    let passages: [Passage]
    let keywordIDs: [UUID]
}

struct NoteRevision: Identifiable, Sendable {
    let id: UUID
    let parentID: UUID?
    let name: String
    let markdown: String
    let createdAt: Date
    let isDeleted: Bool
}

enum ContentHash {
    static func of(_ text: String) -> String {
        bytes(Data(text.utf8))
    }

    static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum NoteLink {
    static func id(from url: URL) -> UUID? {
        guard url.scheme == "gleanary",
              url.host == "note"
        else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

enum GleanaryError: LocalizedError {
    case modelUnavailable, noVector, invalidFile(String), invalidDatabase, invalidVector
    case editConflict, noteDeleted, invalidNote, incompatibleProfile, operationInProgress

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Wait for the current library operation to finish."
        case .modelUnavailable:
            "Apple’s English sentence model is unavailable. Keyword search still works. Retry indexing when the model is ready."
        case .noVector:
            "The model could not embed this text. Your note is saved; keyword search still works."
        case let .invalidFile(name):
            "Could not import \(name). Choose a UTF-8 Markdown file under 1 MB."
        case .invalidDatabase:
            "The library contains an invalid record. No automatic reset was performed. Restore a backup or report this error."
        case .invalidVector:
            "An embedding has an invalid dimension or value. Retry indexing to rebuild it."
        case .editConflict:
            "This note changed since you opened it. Your draft was preserved in revision history. Reopen the note and merge your changes."
        case .noteDeleted:
            "This note has been deleted. Your draft was preserved in revision history."
        case .invalidNote:
            "Give the note a name and keep its Markdown under 5 MB."
        case .incompatibleProfile:
            "The saved embedding model is not available on this device. Using keyword search while the new index is built."
        }
    }
}
