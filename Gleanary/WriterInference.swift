import Foundation
import FoundationModels

/// The Writer on this Mac: the gather plan, extraction one section of one item at a time, and
/// a single structured draft for small selections. Every call runs in its own session.
extension AppleConversationInference: WriterInferring, DocumentDrafting {
    func brief(request: String, categories: [DecimalCategory]) async throws -> WriterBrief {
        var properties: [DynamicGenerationSchema.Property] = [
            .init(
                name: "query",
                description: "1 to 6 topical search keywords.",
                schema: .init(type: String.self)
            ),
            .init(
                name: "fields",
                description: "Short names of the facts to extract.",
                schema: .init(
                    arrayOf: .init(type: String.self),
                    minimumElements: 1,
                    maximumElements: WriterLimits.maximumFields
                )
            ),
            .init(name: "generalKnowledge", schema: .init(type: Bool.self)),
        ]
        if !categories.isEmpty {
            properties.append(.init(name: "categoryCodes", schema: .init(
                arrayOf: .init(name: "CategoryCode", anyOf: categories.map(\.code)),
                minimumElements: 0, maximumElements: 6
            )))
        }
        struct Answer: Decodable {
            let query: String
            let fields: [String]
            let generalKnowledge: Bool
            let categoryCodes: [String]?
        }
        let answer: Answer = try await generate(
            instructions: WriterBrief.instructions,
            prompt: WriterBrief.prompt(request: request, categories: categories),
            root: .init(name: "WriterBrief", properties: properties),
            tokens: 300
        )
        return WriterBrief(
            query: answer.query, categoryCodes: answer.categoryCodes ?? [],
            fields: answer.fields, generalKnowledge: answer.generalKnowledge
        )
    }

    func extractFacts(_ chunk: ExtractionChunk) async throws -> [ExtractedFact] {
        let fact = DynamicGenerationSchema(name: "Fact", properties: [
            .init(name: "subject", schema: .init(type: String.self)),
            .init(name: "field", schema: .init(name: "Field", anyOf: chunk.fields)),
            .init(name: "value", schema: .init(type: String.self)),
            .init(
                name: "quote",
                description: "An exact quotation from the source text.",
                schema: .init(type: String.self)
            ),
        ])
        struct Facts: Decodable { let facts: [ExtractedFact] }
        let result: Facts = try await generate(
            instructions: ExtractionChunk.instructions,
            prompt: chunk.prompt,
            root: .init(name: "Facts", properties: [
                .init(name: "facts", schema: .init(
                    arrayOf: fact, minimumElements: 0, maximumElements: 12
                )),
            ]),
            tokens: 1200
        )
        return result.facts
    }

    func draftDocument(instructions: String, prompt: String, recordIDs: [String]) async throws
        -> WriterDraft
    {
        guard !recordIDs.isEmpty else { throw ConversationError.missingSource }
        let text = DynamicGenerationSchema(type: String.self)
        let strings = DynamicGenerationSchema(arrayOf: text, minimumElements: 0, maximumElements: 8)
        let records = DynamicGenerationSchema(
            arrayOf: .init(name: "RecordID", anyOf: recordIDs),
            minimumElements: 0, maximumElements: 6
        )
        let block = DynamicGenerationSchema(name: "Block", properties: [
            .init(name: "kind", schema: .init(
                name: "Kind", anyOf: WriterDraft.BlockKind.allCases.map(\.rawValue)
            )),
            .init(name: "text", schema: text), .init(name: "cells", schema: strings),
            .init(name: "records", schema: records),
            .init(name: "grade", description: "A scale grade, or empty.", schema: text),
            .init(name: "general", schema: .init(type: Bool.self)),
        ])
        let level = DynamicGenerationSchema(name: "Level", properties: [
            .init(name: "grade", schema: text), .init(name: "meaning", schema: text),
        ])
        let section = DynamicGenerationSchema(name: "Section", properties: [
            .init(name: "heading", schema: text), .init(name: "columns", schema: strings),
            .init(name: "blocks", schema: .init(
                arrayOf: block,
                minimumElements: 1,
                maximumElements: 12
            )),
        ])
        return try await generate(
            instructions: instructions,
            prompt: prompt,
            root: .init(name: "WriterDraft", properties: [
                .init(name: "title", schema: text),
                .init(name: "scale", schema: .init(name: "Scale", properties: [
                    .init(name: "name", schema: text),
                    .init(name: "levels", schema: .init(
                        arrayOf: level,
                        minimumElements: 0,
                        maximumElements: 6
                    )),
                ])),
                .init(name: "sections", schema: .init(
                    arrayOf: section,
                    minimumElements: 1,
                    maximumElements: 8
                )),
                .init(name: "conflicts", schema: .init(
                    arrayOf: .init(name: "Conflict", properties: [
                        .init(name: "text", schema: text), .init(name: "records", schema: records),
                    ]),
                    minimumElements: 0, maximumElements: 4
                )),
            ]),
            tokens: 2000
        )
    }

    func generate<Value: Decodable>(
        instructions: String,
        prompt: String,
        root: DynamicGenerationSchema,
        tokens: Int
    ) async throws -> Value {
        guard SystemLanguageModel.default.availability == .available
        else { throw LinkSummaryError.unavailable }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                schema: GenerationSchema(root: root, dependencies: []),
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: tokens)
            )
            try Task.checkCancellation()
            return try JSONDecoder().decode(
                Value.self,
                from: Data(response.content.jsonString.utf8)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LinkSummaryError {
            throw error
        } catch is DecodingError {
            throw LinkSummaryError.invalidOutput
        } catch {
            throw AppleLinkSummarizer.modelFailure(error)
        }
    }
}
