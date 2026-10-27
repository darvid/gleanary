import Foundation

/// Presentation groups do not change the persisted transcript or the model's history.
struct ConversationFeedEntry: Identifiable {
    let id: UUID
    var messages: [ConversationMessage]
    /// Set on a response whose reply is still being drafted and has no messages yet.
    var draftingTaskID: UUID?

    var userMessage: ConversationMessage? {
        messages.first.flatMap { $0.author == "user" ? $0 : nil }
    }

    var taskID: UUID? {
        messages.first?.taskID ?? draftingTaskID
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

    /// `drafting` lists tasks whose reply is being generated; each gets a response place even
    /// before any of its messages are saved.
    static func entries(in messages: [ConversationMessage], drafting: Set<UUID> = []) -> [Self] {
        var entries: [Self] = []
        var responseTasks = Set<UUID>()
        for message in messages {
            if message.author != "user", let taskID = message.taskID,
               let last = entries.last, last.userMessage == nil, last.taskID == taskID
            {
                entries[entries.count - 1].messages.append(message)
            } else {
                // A response takes its task's identity, so a drafted reply keeps one view as
                // its messages arrive.
                let taskID = message.author == "user" ? nil : message.taskID
                let id = taskID.flatMap { responseTasks.insert($0).inserted ? $0 : nil }
                entries.append(Self(id: id ?? message.id, messages: [message]))
            }
        }
        for task in drafting.subtracting(responseTasks) {
            guard let request = entries.lastIndex(where: { $0.userMessage?.taskID == task })
            else { continue }
            entries.insert(Self(id: task, messages: [], draftingTaskID: task), at: request + 1)
        }
        return entries
    }
}
