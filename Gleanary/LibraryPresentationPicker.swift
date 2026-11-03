import SwiftUI

/// Separate native toggles avoid the segmented picker's selection-dependent separators. They
/// share one toolbar glass background, so the three read as a single view switcher, as in
/// Finder; the toolbar marks the selected toggle.
struct LibraryPresentationPicker: View {
    @Binding var selection: LibraryPresentation

    var body: some View {
        HStack(spacing: 2) {
            option(.map, title: "Map", symbol: "square.grid.2x2")
            option(.list, title: "List", symbol: "list.bullet")
            option(.graph, title: "Graph", symbol: "point.3.connected.trianglepath.dotted")
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library presentation")
    }

    private func option(_ value: LibraryPresentation, title: String, symbol: String) -> some View {
        Toggle(isOn: Binding(
            get: { selection == value },
            set: {
                if $0 {
                    selection = value
                }
            }
        )) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
        }
        .toggleStyle(.button)
        .help("Show \(title.lowercased()) view")
        .accessibilityLabel("\(title) view")
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
