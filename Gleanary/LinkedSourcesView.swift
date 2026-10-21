import SwiftUI

struct LinkedSourcesView: View {
    let document: MarkdownDocument
    let context: LinkedSourceContext
    var openDocument: (UUID) -> Void
    @State private var model: LinkedSourcesModel
    @State private var expanded = false
    @State private var associatingSource: LinkedSource?
    @State private var confirmingSource: LinkedSource?

    init(
        document: MarkdownDocument,
        context: LinkedSourceContext,
        openDocument: @escaping (UUID) -> Void,
        model: LinkedSourcesModel? = nil
    ) {
        self.document = document
        self.context = context
        self.openDocument = openDocument
        _model = State(initialValue: model ?? LinkedSourcesModel())
    }

    private var available: [LinkedSource] {
        model.sources.filter { $0.canAdd && !model.adding.contains($0.id) }
    }

    var body: some View {
        // Keep a real container mounted so the initial local scan runs inside note stacks.
        VStack(alignment: .leading, spacing: 0) {
            if !model.sources.isEmpty || model.error != nil {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Linked sources").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(available.isEmpty ? model.sources.count
                            .formatted() : "\(available.count) to add")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        if available.count > 1 {
                            Button("Add all", systemImage: "plus") { add(available) }
                                .buttonStyle(.borderless)
                                .disabled(!context.canAdd)
                                .help(
                                    "Add all \(available.count) sources using your Capture settings"
                                )
                                .accessibilityLabel("Add all \(available.count) sources")
                        }
                    }
                    if let error = model.error {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button("Check again") {
                            Task { await model.load(document, from: context.store) }
                        }
                    }
                    ForEach(Array(model.sources
                            .prefix(expanded ? model.sources.count : 5)))
                    { source in
                        row(source)
                    }
                    if model.sources.count > 5 {
                        Button(expanded ? "Show fewer links" :
                            "Show all \(model.sources.count) links")
                        {
                            expanded.toggle()
                        }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .confirmationDialog("Create another summary?", isPresented: Binding(
            get: { confirmingSource != nil }, set: {
                if !$0 {
                    confirmingSource = nil
                }
            }
        ), presenting: confirmingSource) { source in
            Button("Create summary") {
                if let id = source.noteID {
                    context.createAnotherSummary?(id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "This creates a new note using the selected AI provider. Existing notes and retained source data stay unchanged."
            )
        }
        .sheet(item: $associatingSource) { source in
            if let id = source.noteID {
                SummaryAssociationView(store: context.store, sourceID: id) {
                    await context.changed()
                    await model.load(document, from: context.store)
                }
            }
        }
        .task(id: "\(document.id)/\(document.revision)/\(context.revision)") {
            await model.load(document, from: context.store)
        }
    }

    private func row(_ source: LinkedSource) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "link").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.link.title).font(.body.weight(.medium)).lineLimit(2)
                Text(source.link.url.host() ?? "Web source")
                    .font(.caption).foregroundStyle(.secondary)
                if source.noteID != nil {
                    Text(source.archived ? "In library, archived" : "In library")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let progress = source
                    .captureProgress ?? (model.adding.contains(source.id) ? "Queuing…" : nil)
                {
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let id = source.noteID {
                    SourceSummaryNavigation(
                        summaries: source.summaries, openSummary: openDocument,
                        viewSource: { (context.viewSource ?? openDocument)(id) }
                    ).buttonStyle(.link).font(.callout)
                    if context.summarizingID == id {
                        HStack(spacing: 6) {
                            ChatWorkingIndicator(color: .secondary)
                            Text("Summarizing…")
                            if let cancel = context.cancelSummary {
                                Button("Cancel", action: cancel).buttonStyle(.link)
                            }
                        }.font(.callout).accessibilityLabel("Summarizing \(source.link.title)")
                    } else if source.summaries.isEmpty, let summarize = context.summarize {
                        Button("Summarize", systemImage: "sparkles") { summarize(id) }
                            .buttonStyle(.link).font(.callout).disabled(!context.canAdd)
                    }
                }
                if let error = model.failures[source.id] ?? source.job?.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if source.noteID != nil {
                Menu {
                    Button("Use as summary for this source…") { associatingSource = source }
                    if !source.summaries.isEmpty, context.createAnotherSummary != nil {
                        Button("Create another summary…") { confirmingSource = source }
                            .disabled(!context.canAdd)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuIndicator(.hidden).menuStyle(.borderlessButton)
                .fixedSize().help("Summary actions for \(source.link.title)")
                .accessibilityLabel("Summary actions for \(source.link.title)")
            } else if model.adding.contains(source.id) || !source.canAdd {
                ChatWorkingIndicator(color: .secondary).frame(width: 24, height: 24)
            } else {
                sourceAction(
                    "\(source.retryID == nil ? "Add source" : "Retry source"): \(source.link.title)",
                    symbol: source.retryID == nil ? "plus" : "arrow.clockwise"
                ) { add([source]) }
                    .disabled(!context.canAdd)
            }
        }
        .padding(10)
        .accessibilityElement(children: .contain)
    }

    private func sourceAction(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(title).accessibilityLabel(title)
    }

    private func add(_ sources: [LinkedSource]) {
        Task { await model.add(sources, for: document, using: context) }
    }
}
