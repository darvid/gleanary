import SwiftUI

/// Disclosure groups that open from anywhere on their row, not just the small triangle macOS
/// draws. Applied at the top of each window, so every group in the app behaves the same.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        FullRowDisclosure(configuration: configuration)
    }
}

private struct FullRowDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func toggle() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            configuration.isExpanded.toggle()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Selectable text would take the click for itself.
                    .textSelection(.disabled)
                    .onTapGesture(perform: toggle)
            }
            .padding(.vertical, 4)
            // Behind the label rather than around it, because labels can hold controls of their
            // own, such as Accept All. Plain text lets the click through to this.
            .background {
                Button(action: toggle) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                        .padding(.horizontal, -6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(configuration.isExpanded ? "Collapse" : "Expand")
            }
            .onHover { hovering = $0 }
            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20).padding(.vertical, 6)
            }
        }
    }
}
