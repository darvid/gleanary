import SwiftUI

struct GraphArrangementControl: View {
    @Bindable var graph: LibraryGraphModel
    @State private var showing = false

    var body: some View {
        Button("Arrange", systemImage: "slider.horizontal.3") { showing.toggle() }
            .buttonStyle(.borderless)
            .disabled(graph.snapshot.nodes.isEmpty)
            .help("Adjust spacing without changing zoom or graph filters")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                GraphArrangementSettings(graph: graph).padding(16)
            }
            .onChange(of: showing) { _, visible in
                if !visible {
                    graph.finishSpacingChange()
                }
            }
    }
}

struct GraphArrangementSettings: View {
    @Bindable var graph: LibraryGraphModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spacing").font(.headline)
                Spacer()
                Button("Reset") { graph.resetSpacing() }
                    .disabled(graph.spacing == .standard)
                    .help("Restore balanced spacing; keep zoom, selection, and filters")
            }
            Slider(value: Binding(
                get: { graph.spacing.value },
                set: { graph.setSpacing($0) }
            ), in: 0 ... 1, onEditingChanged: { editing in
                if !editing {
                    graph.finishSpacingChange()
                }
            }) { Text("Spacing") }
                .labelsHidden()
                .accessibilityLabel("Graph spacing")
                .accessibilityValue(
                    "\(graph.spacing.label), \(Int(graph.spacing.value * 100)) percent"
                )
            HStack {
                Text("Compact")
                Spacer()
                Text("Spacious")
            }.font(.caption).foregroundStyle(.secondary)
            Text(
                "Changes the arrangement, not zoom. Use Fit on the graph to bring offscreen items back into view."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 260)
    }
}
