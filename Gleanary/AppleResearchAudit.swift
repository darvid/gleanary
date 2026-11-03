import Foundation
import FoundationModels

/// Research audits on this Mac: the plan and the support check by guided generation, each in
/// its own session. Extraction is the Writer's on-device extraction, and audits read at most
/// `WriterLimits.localScope` items, as composing does.
extension AppleConversationInference: ResearchAuditing {
    func auditBrief(request: String, categories: [DecimalCategory]) async throws
        -> AuditProposal
    {
        let text = DynamicGenerationSchema(type: String.self)
        let dimension = DynamicGenerationSchema(name: "Dimension", properties: [
            .init(name: "label", description: "A short name for the question.", schema: text),
            .init(
                name: "criteria",
                description: "What a source must state to answer it.",
                schema: text
            ),
            .init(
                name: "origin",
                description: "An exact quote from the request, or empty when suggested.",
                schema: text
            ),
            .init(name: "alternateTerms", schema: .init(
                arrayOf: text, minimumElements: 0, maximumElements: 4
            )),
            .init(name: "answerQuery", schema: text),
        ])
        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: "query", description: "1 to 6 topical search keywords.", schema: text),
            .init(name: "dimensions", schema: .init(
                arrayOf: dimension, minimumElements: 1,
                maximumElements: AuditLimits.maximumDimensions
            )),
        ]
        if !categories.isEmpty {
            properties.append(.init(name: "categoryCodes", schema: .init(
                arrayOf: .init(name: "CategoryCode", anyOf: categories.map(\.code)),
                minimumElements: 0, maximumElements: 6
            )))
        }
        struct Answer: Decodable {
            let query: String
            let dimensions: [AuditProposal.Dimension]
            let categoryCodes: [String]?
        }
        let answer: Answer = try await generate(
            instructions: AuditBrief.instructions,
            prompt: AuditBrief.prompt(request: request, categories: categories),
            root: .init(name: "AuditBrief", properties: properties),
            tokens: 900
        )
        return AuditProposal(
            query: answer.query, categoryCodes: answer.categoryCodes ?? [],
            dimensions: answer.dimensions
        )
    }

    func checkEvidence(_ check: EvidenceCheck) async throws -> [EvidenceVerdict] {
        let verdict = DynamicGenerationSchema(name: "Verdict", properties: [
            .init(name: "id", schema: .init(name: "QuoteID", anyOf: check.quotes.map(\.id))),
            .init(
                name: "support",
                schema: .init(name: "Support", anyOf: ["meets", "partial", "none"])
            ),
            .init(
                name: "reason",
                description: "Under 20 words.",
                schema: .init(type: String.self)
            ),
        ])
        struct Verdicts: Decodable { let verdicts: [EvidenceVerdict] }
        let result: Verdicts = try await generate(
            instructions: EvidenceCheck.instructions,
            prompt: check.prompt,
            root: .init(name: "Verdicts", properties: [
                .init(name: "verdicts", schema: .init(
                    arrayOf: verdict, minimumElements: 0, maximumElements: check.quotes.count
                )),
            ]),
            tokens: 800
        )
        return result.verdicts
    }
}
