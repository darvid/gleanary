import SwiftUI

struct MindMapInspector: View {
    let library: LibraryModel
    let openNote: (UUID) -> Void
    let openSource: (SourceCitation) -> Void

    private var node: MindMapNode? {
        guard let id = library.graph.selectedMapNodeID else { return nil }
        return library.graph.mindMap.nodes.first { $0.id == id }
    }

    var body: some View {
        if let node {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(node.title).font(.headline).textSelection(.enabled)
                        Text(node.role.rawValue.capitalized)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close Details", systemImage: "xmark") {
                        library.graph.deselectMapNode()
                    }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                Text(node.summary).font(.callout).textSelection(.enabled)
                Label("Generated interpretation. Verify with the source.", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if library.graph.mapEvidence.isEmpty {
                    Text("No source passage is available for this branch.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(library.graph.mapEvidence) { evidence in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(evidence.quote).font(.callout).textSelection(.enabled)
                            Text(
                                "\(evidence.noteName) · \(evidence.citation?.label ?? "Note revision")"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Button("View Evidence") {
                                if let citation = evidence.citation {
                                    openSource(citation)
                                } else {
                                    openNote(evidence.noteID)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(18).frame(width: 350)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
            .accessibilityElement(children: .contain)
        }
    }
}
