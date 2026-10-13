import Accelerate
import Foundation
import NaturalLanguage

protocol EmbeddingProviding: Sendable {
    func profile() async throws -> EmbeddingProfile
    func vector(for text: String, profile: EmbeddingProfile) async throws -> [Float]
}

actor AppleEmbeddingProvider: EmbeddingProviding {
    private var models: [Int: NLEmbedding] = [:]

    func profile() throws -> EmbeddingProfile {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw InfactoryError.modelUnavailable
        }
        models[model.revision] = model
        return EmbeddingProfile(revision: model.revision, dimensions: model.dimension)
    }

    func vector(for text: String, profile: EmbeddingProfile) throws -> [Float] {
        guard profile.model == "apple.naturallanguage.sentence", profile.language == "en",
              profile.encoding == "normalized-float32-le-v1"
        else { throw InfactoryError.incompatibleProfile }
        let model = models[profile.revision]
            ?? NLEmbedding.sentenceEmbedding(for: .english, revision: profile.revision)
        guard let model, model.dimension == profile.dimensions else {
            throw InfactoryError.incompatibleProfile
        }
        models[profile.revision] = model
        guard let vector = model.vector(for: text) else { throw InfactoryError.noVector }
        return try VectorMath.normalized(vector.map(Float.init), dimensions: profile.dimensions)
    }
}

enum VectorMath {
    static func normalized(_ vector: [Float], dimensions: Int) throws -> [Float] {
        guard dimensions > 0, vector.count == dimensions, vector.allSatisfy(\.isFinite) else {
            throw InfactoryError.invalidVector
        }
        // Double precision for the norm avoids overflow from finite Float32 inputs.
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw InfactoryError.invalidVector }
        return vector.map { Float(Double($0) / norm) }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        let result = vDSP.dot(a, b)
        return result.isFinite ? min(1, max(-1, result)) : nil
    }

    static func encode(_ vector: [Float], dimensions: Int) throws -> Data {
        let normalized = try normalized(vector, dimensions: dimensions)
        return normalized.reduce(into: Data(capacity: dimensions * 4)) { bytes, value in
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
    }

    static func decode(_ data: Data, dimensions: Int) -> [Float]? {
        guard dimensions > 0, data.count == dimensions * 4 else { return nil }
        let vector: [Float] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { offset in
                let bits = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        guard vector.allSatisfy(\.isFinite) else { return nil }
        let norm = vDSP.dot(vector, vector)
        guard abs(norm - 1) < 0.001 else { return nil }
        return vector
    }
}

struct SemanticCandidate: Sendable {
    let id: UUID
    let score: Float
}

protocol VectorRanking: Sendable {
    func rank(query: [Float], passages: [Passage], limit: Int) -> [SemanticCandidate]
}

/// Exact search is intentionally replaceable with a SQLite vector extension or ANN index.
struct ExactVectorSearch: VectorRanking {
    func rank(query: [Float], passages: [Passage], limit: Int) -> [SemanticCandidate] {
        passages.compactMap { passage in
            guard let vector = passage.vector, let score = VectorMath.dot(query, vector) else {
                return nil
            }
            return SemanticCandidate(id: passage.id, score: score)
        }.sorted {
            if $0.score == $1.score {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.score > $1.score
        }.prefix(max(0, limit)).map(\.self)
    }
}
