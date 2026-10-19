import SwiftUI

/// Separate native toggles avoid the segmented picker's selection-dependent separators.
struct LibraryPresentationPicker: View {
    @Binding var selection: LibraryPresentation

    var body: some View {
        HStack(spacing: 4) {
            option(.map, title: "Map", symbol: "square.grid.2x2")
            option(.list, title: "List", symbol: "list.bullet")
            option(.graph, title: "Graph", symbol: "point.3.connected.trianglepath.dotted")
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library presentation")
    }

    private func option(_ value: LibraryPresentation, title: String, symbol: String) -> some View {
        let toggle = Toggle(isOn: Binding(
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
        return Group {
            if selection == value {
                toggle.buttonStyle(.borderedProminent)
            } else {
                toggle.buttonStyle(.bordered)
            }
        }.frame(width: 40, height: 30)
    }
}
