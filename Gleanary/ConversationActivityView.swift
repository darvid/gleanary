import SwiftUI

struct ConversationActivityView<Content: View>: View {
    let messages: [ConversationMessage]
    let working: Bool
    let progress: String?
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    private var participants: String {
        var names: [String] = []
        for message in messages {
            let name = AgentRole(rawValue: message.author)?.title ?? message.author.capitalized
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names.joined(separator: ", ")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
                .padding(.top, 12)
                .padding(.bottom, 4)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if working {
                        ChatWorkingIndicator(color: .secondary)
                    }
                    Text(working ? "Working" : "Activity").fontWeight(.medium)
                    Text(messages.count == 1 ? "1 update" : "\(messages.count) updates")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Text(working ? progress ?? participants : participants)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
        .accessibilityHint(
            "Show or hide specialist messages. Results and review actions remain below."
        )
    }
}
