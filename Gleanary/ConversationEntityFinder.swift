import Foundation

/// Reads chosen items for people, organizations, tools and concepts when you ask in chat,
/// whether or not background reading is on. Entities are derived data: no item changes.
actor ConversationEntityFinder {
    static let toolName = "find_entities"
    /// On-device reading takes seconds an item, so one request stays bounded.
    static let maximumItems = 200

    struct Report: Sendable {
        let read: Int
        let unavailable: Int
        let failed: Int
        var merged = 0
        var possibleDuplicates = 0
    }

    private let execute: @Sendable ([UUID]) async throws -> Report
    private var started = false

    init(execute: @escaping @Sendable ([UUID]) async throws -> Report) {
        self.execute = execute
    }

    static var definition: [String: Any] {
        ["type": "function",
         "name": toolName,
         "strict": true,
         "description": "When the USER asks to find or extract people, organizations, tools or concepts, read saved items for them on this Mac. Items already read at their current version are not read again. Once per message. Returns how many items were read and the entities found in them, with handles for get_entity.",
         "parameters": ["type": "object", "additionalProperties": false,
                        "required": ["scope", "items", "category_code", "limit"],
                        "properties": [
                            "scope": [
                                "type": "string",
                                "enum": ["items", "category", "recent", "all"],
                            ],
                            "items": ["type": "array", "items": ["type": "string"],
                                      "description": "Item handles when scope is items; otherwise empty."],
                            "category_code": ["type": "string",
                                              "description": "A category code when scope is category; otherwise empty."],
                            "limit": ["type": "integer", "minimum": 1, "maximum": maximumItems,
                                      "description": "Most items to read, newest first."],
                        ]]]
    }

    func run(_ call: AgentCall, toolbox: AgentToolbox) async throws -> String {
        do {
            try Task.checkCancellation()
            guard !started else {
                return try encode(["error": "Entities are already being found in this message."])
            }
            guard call.arguments.utf8.count <= 16000,
                  let object = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8))
                  as? [String: Any],
                  let scope = object["scope"] as? String,
                  let items = object["items"] as? [String],
                  let code = object["category_code"] as? String,
                  let limit = object["limit"] as? Int
            else { return try encode(["error": "Give scope, items, category_code and limit."]) }
            let ids = try await toolbox.entityScope(
                scope,
                items: items,
                categoryCode: code,
                limit: limit
            )
            guard !ids.isEmpty else { return try encode(["error": "No items in that scope."]) }
            started = true
            let report = try await execute(ids)
            try Task.checkCancellation()
            let found = try await toolbox.entitiesFound(in: ids)
            let result = EntityFinderResult(
                items: ids.count, read: report.read,
                couldNotRead: report.unavailable + report.failed,
                mergedAutomatically: report.merged,
                possibleDuplicates: report.possibleDuplicates,
                reason: report.unavailable > 0
                    ?
                    "Apple Intelligence isn't available on this Mac, so some items weren't read." :
                    "",
                entities: found
            )
            return try String(decoding: JSONEncoder().encode(result), as: UTF8.self)
        } catch is CancellationError { throw CancellationError() }
        catch { return try encode(["error": error.localizedDescription]) }
    }

    private func encode(_ object: [String: String]) throws -> String {
        try String(decoding: JSONEncoder().encode(object), as: UTF8.self)
    }
}

private struct EntityFinderResult: Encodable {
    let items: Int
    let read: Int
    let couldNotRead: Int
    let mergedAutomatically: Int
    let possibleDuplicates: Int
    let reason: String
    let entities: [AgentToolbox.EntityRow]

    enum CodingKeys: String, CodingKey {
        case items, read, reason, entities
        case couldNotRead = "could_not_read"
        case mergedAutomatically = "merged_automatically"
        case possibleDuplicates = "possible_duplicates_to_review"
    }
}
