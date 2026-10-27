import SwiftUI

struct ConversationActivityView<Content: View>: View {
    let messages: [ConversationMessage]
    let working: Bool
    let progress: String?
    let agent: AgentRole?
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    /// Each participant once, in order of first update, with its role's symbol.
    private var participants: Text {
        var authors: [String] = []
        for message in messages where !authors.contains(message.author) {
            authors.append(message.author)
        }
        let names = authors.map { author in
            guard let role = AgentRole(rawValue: author) else { return Text(author.capitalized) }
            return Text("\(Image(systemName: role.symbol)) \(role.title)")
        }
        return names.enumerated().reduce(Text("")) { list, item in
            let separator = item.offset == 0 ? ""
                : item.offset < names.count - 1 ? ", "
                : names.count == 2 ? " and " : ", and "
            return Text("\(list)\(separator)\(item.element)")
        }
    }

    private var updates: String {
        messages.count == 1 ? "1 update" : "\(messages.count) updates"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // A rule and muted text keep agent work visibly inside the row, apart from the
            // reply that follows it.
            content()
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule().fill(.separator).frame(width: 2)
                }
                .padding(.top, 10)
                .padding(.bottom, 6)
        } label: {
            // One quiet line: who worked, and how much, or what is happening now.
            HStack(spacing: 6) {
                if working {
                    ChatWorkingIndicator(color: .secondary)
                }
                // The spinner stands in for the role symbol while an agent works.
                Group {
                    if working {
                        Text(agent.map { "\($0.title) working" } ?? "Working")
                    } else {
                        participants
                    }
                }
                .fontWeight(.medium).lineLimit(1)
                .layoutPriority(1)
                Text(working ? progress ?? updates : updates)
                    .monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.vertical, 2)
        }
        .accessibilityHint(
            "Show or hide specialist messages. Results and review actions remain below."
        )
    }
}
