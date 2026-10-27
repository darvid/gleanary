import Foundation

/// Entity and relationship extraction with ChatGPT: the same prompts and validation as on this
/// Mac, with a larger context, so it works when ChatGPT is the AI provider.
extension ChatGPTConversationInference: GraphExtracting {
    /// Each call waits seconds on the model whatever its size, so a few notes run together.
    var concurrentNotes: Int {
        4
    }

    func extract(_ text: String) async throws -> GraphProposal {
        try await extract(text, overview: false)
    }

    func extractOverview(_ text: String) async throws -> GraphProposal {
        try await extract(text, overview: true)
    }

    private func extract(_ text: String, overview: Bool) async throws -> GraphProposal {
        try await graphCall(
            prompt: "Source text:\n" + text,
            instructions: GraphPrompts.extraction(overview: overview),
            name: "graph_candidates",
            schema: GraphJSONSchema.graph(
                maxEntities: GraphPrompts.maximumEntities(overview: overview),
                maxRelations: GraphPrompts.maximumRelations(overview: overview)
            )
        )
    }

    func curate(_ work: GraphCurationWork) async throws -> GraphProposal {
        let selection: CandidateProposal = try await graphCall(
            prompt: GraphPrompts.curationPrompt(work),
            instructions: GraphPrompts.curation,
            name: "graph_curation",
            schema: GraphJSONSchema.candidates(maxEntities: 20)
        )
        return GraphProposal(entities: selection.entities, relations: [])
    }

    func relate(
        _ work: GraphCurationWork,
        entities: [ProposedEntity]
    ) async throws -> [ProposedRelation] {
        let proposal: RelationProposal = try await graphCall(
            prompt: GraphPrompts.relationPrompt(work, entities: entities),
            instructions: GraphPrompts.relation,
            name: "graph_relations",
            schema: GraphJSONSchema.relations(maxRelations: 20)
        )
        return proposal.relations
    }

    func mindMap(
        _ work: GraphCurationWork,
        entities: [ProposedEntity]
    ) async throws -> MindMapProposal {
        guard let prompt = GraphPrompts.mindMapPrompt(work, entities: entities)
        else { return MindMapProposal(nodes: []) }
        return try await graphCall(
            prompt: prompt,
            instructions: GraphPrompts.mindMap,
            name: "mind_map",
            schema: GraphJSONSchema.mindMap(maxNodes: 24)
        )
    }

    private func graphCall<Value: Decodable>(
        prompt: String,
        instructions: String,
        name: String,
        schema: [String: Any]
    ) async throws -> Value {
        let fence = try await session.authorizationFence()
        let value: Value = try await structured(
            prompt: prompt, instructions: instructions, name: name, schema: schema, fence: fence
        )
        try await session.validateFence(fence)
        return value
    }
}

extension ChatGPTConversationInference: EntityMatchJudging {
    func judgeMatches(_ items: [EntityMatchJudgement.Item]) async throws
        -> [Int: EntityMatchJudgement.Verdict]
    {
        let fence = try await session.authorizationFence()
        let answers: EntityMatchJudgement.Answers = try await structured(
            prompt: EntityMatchJudgement.prompt(items),
            instructions: EntityMatchJudgement.instructions,
            name: "entity_matches",
            schema: EntityMatchJudgement.jsonSchema,
            fence: fence
        )
        try await session.validateFence(fence)
        return EntityMatchJudgement.verdicts(answers, items: items)
    }
}

/// JSON schemas matching the on-device generation schemas, for strict structured output.
enum GraphJSONSchema {
    static func object(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object", "properties": properties,
            "required": Array(properties.keys).sorted(), "additionalProperties": false,
        ]
    }

    static func array(_ items: [String: Any], max: Int) -> [String: Any] {
        ["type": "array", "items": items, "maxItems": max]
    }

    static var text: [String: Any] {
        ["type": "string"]
    }

    static var entity: [String: Any] {
        object([
            "name": ["type": "string", "description": "Exact source name, at most 100 characters."],
            "kind": ["type": "string", "enum": ["concept", "person", "organization", "tool"],
                     "description": "Concept: a topic, method, or general idea. Tool: a specifically named product, model, system, dataset, or benchmark. Person: a named human. Organization: a named group."],
            "quote": ["type": "string",
                      "description": "Short verbatim source quotation containing the name."],
        ])
    }

    static var relation: [String: Any] {
        object([
            "source": text, "target": text,
            "predicate": ["type": "string", "enum": [
                "uses", "partOf", "comparesWith", "addresses", "evaluatedOn", "measuredBy",
                "improvesOn", "supports", "limits",
            ]],
            "quote": ["type": "string",
                      "description": "Short verbatim affirmative assertion naming both endpoints."],
        ])
    }

    static func graph(maxEntities: Int, maxRelations: Int) -> [String: Any] {
        object([
            "entities": array(entity, max: maxEntities),
            "relations": array(relation, max: maxRelations),
        ])
    }

    static func candidates(maxEntities: Int) -> [String: Any] {
        object(["entities": array(entity, max: maxEntities)])
    }

    static func relations(maxRelations: Int) -> [String: Any] {
        object(["relations": array(relation, max: maxRelations)])
    }

    static func mindMap(maxNodes: Int) -> [String: Any] {
        object(["nodes": array(object([
            "key": text, "parentKey": text, "title": text, "summary": text,
            "role": ["type": "string", "enum": MindMapRole.allCases.map(\.rawValue)],
            "evidenceID": text,
        ]), max: maxNodes)])
    }
}
