import Foundation

/// Presentation groups do not change the persisted transcript or the model's history.
struct ConversationFeedEntry: Identifiable {
    let id: UUID
    var messages: [ConversationMessage]

    var userMessage: ConversationMessage? {
        messages.first.flatMap { $0.author == "user" ? $0 : nil }
    }

    var taskID: UUID? {
        messages.first?.taskID
    }

    var referenceIDs: [UUID] {
        var seen = Set<UUID>()
        return messages.flatMap(\.references).filter { seen.insert($0).inserted }
    }

    var specialistMessages: [ConversationMessage] {
        messages.filter { message in
            guard let role = AgentRole(rawValue: message.author) else { return false }
            return role != .assistant
        }
    }

    func replies(working: Bool) -> [ConversationMessage] {
        let replies = messages.filter { message in
            message.author != "user" &&
                (AgentRole(rawValue: message.author) == nil || message.author == "assistant")
        }
        // Older conversations and direct specialist requests may have no coordinating reply.
        // Keep their final answer readable rather than hiding the only answer in activity.
        if replies.isEmpty, !working, let last = specialistMessages.last {
            return [last]
        }
        return replies
    }

    func activity(working: Bool) -> [ConversationMessage] {
        let visible = Set(replies(working: working).map(\.id))
        return specialistMessages.filter { !visible.contains($0.id) }
    }

    static func entries(in messages: [ConversationMessage]) -> [Self] {
        var entries: [Self] = []
        for message in messages {
            if message.author != "user", let taskID = message.taskID,
               let last = entries.last, last.userMessage == nil, last.taskID == taskID
            {
                entries[entries.count - 1].messages.append(message)
            } else {
                entries.append(Self(id: message.id, messages: [message]))
            }
        }
        return entries
    }
}
