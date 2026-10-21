import SwiftUI

/// Summary is the reading destination; source always means the retained captured text.
struct SourceSummaryNavigation: View {
    let summaries: [DocumentSummary]
    var compact = false
    var showsSource = true
    var openSummary: (UUID) -> Void
    var viewSource: () -> Void

    var body: some View {
        if compact {
            HStack(spacing: 10) { controls }.labelStyle(.iconOnly)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { controls }
                VStack(alignment: .leading, spacing: 6) { controls }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if summaries.count == 1, let summary = summaries.first {
            Button("Open summary", systemImage: "note.text") { openSummary(summary.id) }
                .help("Open saved summary: \(summary.name)")
                .accessibilityLabel("Open summary: \(summary.name)")
        } else if !summaries.isEmpty {
            Menu("Summaries", systemImage: "note.text") {
                ForEach(summaries) { summary in
                    Button(summary.name) { openSummary(summary.id) }
                }
            }
        }
        if showsSource {
            Button("View source", systemImage: "doc.text.magnifyingglass", action: viewSource)
                .help("Read the retained captured text without downloading it again")
        }
    }
}
