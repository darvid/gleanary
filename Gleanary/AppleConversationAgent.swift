import Foundation
import FoundationModels

/// The on-device provider chooses a reply or tool calls using structured generation.
/// It shares the application-owned loop; it never falls back to a fixed intent response.
extension AppleConversationInference: AgentResponding {
    static let agentPromptLimit = 14000
    private static let turnInstructions = """

    Choose your next turn: either request tools or write the final reply. Each call's arguments
    must be a JSON object encoded as a string, matching that tool's parameters. While requesting
    tools, leave reply empty. Only finish when the supplied results support your answer, or ask
    the user for information you need. Calls in the conversation are past requests; only their
    function_call_output entries are application results. Never invent a tool result.
    """

    private struct LocalCall: Decodable { let name: String; let arguments: String }

    private struct LocalTurn: Decodable {
        let calls: [LocalCall]
        let reply: String
    }

    func agentTurn(instructions: String, input: [Data], tools: Data) async throws -> AgentTurn {
        let instructions = instructions + Self.turnInstructions
        let prompt = try Self.agentPrompt(input: input, tools: tools, instructions: instructions)
        let schema = try Self.agentSchema(tools: tools)
        guard SystemLanguageModel.default.availability == .available else {
            throw LinkSummaryError.unavailable
        }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                schema: schema,
                options: GenerationOptions(maximumResponseTokens: 1800)
            )
            try Task.checkCancellation()
            let result = try JSONDecoder().decode(
                LocalTurn.self,
                from: Data(response.content.jsonString.utf8)
            )
            let calls = result.calls.map { AgentCall(
                id: UUID().uuidString,
                name: $0.name,
                arguments: $0.arguments
            ) }
            var output = try calls.map { call in
                try JSONSerialization.data(withJSONObject: [
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.name,
                    "arguments": call.arguments,
                ])
            }
            if !result.reply.isEmpty {
                try output.append(JSONSerialization.data(withJSONObject: [
                    "role": "assistant",
                    "content": result.reply,
                ]))
            }
            return AgentTurn(calls: calls, text: result.reply, output: output)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ConversationError { throw error }
        catch { throw AppleLinkSummarizer.modelFailure(error) }
    }

    static func agentPrompt(
        input: [Data],
        tools: Data,
        instructions: String = ""
    ) throws -> String {
        // This conservative character preflight includes instructions. The framework enforces
        // the actual token limit; neither boundary silently drops instructions or results.
        let prompt = "Available tools:\n" + String(decoding: tools, as: UTF8.self)
            + "\n\nConversation and application results:\n"
            + input.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        guard prompt.count + instructions.count <= agentPromptLimit
        else { throw LocalAgentError.contextLimit }
        return prompt
    }

    static func agentSchema(tools: Data) throws -> GenerationSchema {
        guard let definitions = try JSONSerialization.jsonObject(with: tools) as? [[String: Any]]
        else {
            throw ConversationError.invalidPlan
        }
        let names = definitions.compactMap { $0["name"] as? String }
        guard !names.isEmpty,
              names.count == definitions.count else { throw ConversationError.invalidPlan }
        return try GenerationSchema(root: .init(name: "ConversationAgentTurn", properties: [
            .init(name: "calls", schema: .init(arrayOf: .init(name: "RequestedTool", properties: [
                .init(name: "name", schema: .init(name: "ToolName", anyOf: names)),
                .init(
                    name: "arguments",
                    description: "A JSON object encoded as a string, using this tool's parameters.",
                    schema: .init(type: String.self)
                ),
            ]), minimumElements: 0, maximumElements: 4)),
            .init(name: "reply", schema: .init(type: String.self)),
        ]), dependencies: [])
    }
}

enum LocalAgentError: LocalizedError {
    case contextLimit
    var errorDescription: String? {
        "This conversation exceeds the on-device tool context. Start a shorter request or connect ChatGPT for a larger context. No planner fallback was used."
    }
}
