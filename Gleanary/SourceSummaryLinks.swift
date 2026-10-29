import SwiftUI

/// Direct navigation to existing notes; opening a summary never starts inference.
struct SourceSummaryLinks: View {
    let summaries: [DocumentSummary]
    var openDocument: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(summaries) { summary in
                Button { openDocument(summary.id) } label: {
                    Label(
                        summaries.count == 1 ? "Open Summary" : "Summary: \(summary.name)",
                        systemImage: "note.text"
                    )
                    .lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.link).font(.callout)
                .help("Open saved summary: \(summary.name)")
                .accessibilityLabel("Open summary: \(summary.name)")
            }
        }
    }
}
