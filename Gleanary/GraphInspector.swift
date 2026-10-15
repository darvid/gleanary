import SwiftUI

struct GraphInspector: View {
    let library: LibraryModel
    let openNote: (UUID) -> Void
    let openSource: (SourceCitation) -> Void
    private var graph: KnowledgeGraphModel {
        library.graph
    }

    var body: some View {
        if let node = graph.selection {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.label).font(.headline).lineLimit(3).help(node.label)
                            .textSelection(.enabled)
                        Text(node.kind.rawValue.capitalized).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close details", systemImage: "xmark") { graph.deselect() }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                if let id = node.noteID, let job = graph.jobs.first(where: { $0.noteID == id }),
                   job.state != "ready"
                {
                    Text(job
                        .error ??
                        "Connections are incomplete: \(job.completed) of \(job.total) sections, \(job.state)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if graph.displayedEvidence.isEmpty {
                    Text(
                        "No supported connections yet. Extracted relationships appear here with their source quotations."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(graph.displayedEvidence) { item in
                                evidenceRow(item)
                            }
                            if graph.evidence.count == graph.evidenceLimit {
                                if graph.evidenceLimit < 1000 {
                                    Button("Load more evidence") { graph.moreEvidence() }
                                } else {
                                    Text(
                                        "Showing the first 1,000 quotations. Focus a related node to narrow the view."
                                    )
                                    .font(.caption)
                                }
                            }
                        }
                    }.frame(maxHeight: 270)
                }
            }
            .padding(18).frame(width: 340)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 6)
            .accessibilityElement(children: .contain)
        }
    }

    private func evidenceRow(_ item: GraphEvidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(item.sourceLabel) **\(item.edge.predicate.label)** \(item.targetLabel)")
                .font(.callout)
            Text(item.quote).font(.callout).textSelection(.enabled)
            Text("\(item.noteName) · \(item.citation?.label ?? "Note revision")")
                .font(.caption).foregroundStyle(.secondary)
            Button("View evidence") {
                if let citation = item.citation {
                    openSource(citation)
                } else {
                    openNote(item.noteID)
                }
            }.controlSize(.small)
        }
    }
}

struct GraphActivityView: View {
    let library: LibraryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity").font(.title3.weight(.semibold))
            CaptureQueueView(library: library)
            HStack {
                Text(library.status).font(.caption).fadesOnChange(library.status)
                Spacer()
                if library.indexingError != nil {
                    Button("Retry indexing") { library.startIndexing() }.disabled(library.indexing)
                }
            }
            if let error = library
                .indexingError
            {
                Text(error).font(.caption).textSelection(.enabled)
            }
            Divider()
            Text("Knowledge graph").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(library.graph.jobs) { job in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.name).lineLimit(1)
                                Text(job
                                    .error ??
                                    "\(job.completed) of \(job.total) sections, \(job.state)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if ["queued", "running"].contains(job.state) {
                                Button("Pause") { Task { await library.graph.pause(job.noteID) } }
                            } else if job.state != "ready" {
                                Button("Retry") {
                                    Task { await library.graph.retry(job.noteID) }
                                }
                            }
                        }
                    }
                }
            }.frame(maxHeight: 260)
        }.padding(20).frame(width: 520)
    }
}
