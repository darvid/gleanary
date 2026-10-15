import SwiftUI

struct GraphSearchResults: View {
    let library: LibraryModel
    let focusNote: (UUID) -> Void
    let openNote: (UUID) -> Void
    let openSource: (SourceCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search evidence").font(.title3.weight(.semibold))
            if let notice = library
                .searchNotice
            {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if library.matches.isEmpty {
                Text("No passages matched. Named entities can still appear in the graph.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(library.matches.enumerated()), id: \.element.id) { index, match in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("[\(index + 1)] \(match.passage.documentName)").font(.headline)
                            Text(match.explanation).font(.caption).foregroundStyle(.secondary)
                            Text(match.passage.text).textSelection(.enabled)
                            HStack {
                                Button("Focus in graph") { focusNote(match.passage.documentID) }
                                Button("Open note") { openNote(match.passage.documentID) }
                                if let citation = match.passage.citation {
                                    Button("Source: \(citation.label)") { openSource(citation) }
                                }
                            }.controlSize(.small)
                            if let score = match.semanticScore {
                                Text(
                                    "Cosine similarity: \(score.formatted(.number.precision(.fractionLength(3)))). Similarity is not confidence or a factual relationship."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 330)
            Divider()
            HStack {
                Text(library.intelligenceStatus).font(.caption).foregroundStyle(.secondary)
                    .fadesOnChange(library.intelligenceStatus)
                Spacer()
                Button("Summarize top 3") { Task { await library.summarize() } }
                    .disabled(library.busy || library.matches.isEmpty || !library
                        .intelligenceAvailable)
            }
            if !library.summary.isEmpty {
                ScrollView { Text(library.summary).textSelection(.enabled) }.frame(maxHeight: 120)
                Text("Verify generated claims against the numbered passages above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 580)
    }
}
