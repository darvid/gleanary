import SwiftUI

@main
struct SinkApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 900, minHeight: 600)
                .containerBackground(Color.black, for: .window)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { SinkCommands() }
    }
}

struct SinkActions {
    let enabled: Bool
    let newNote: () -> Void
    let attach: () -> Void
    let focus: () -> Void
}

private struct SinkActionsKey: FocusedValueKey {
    typealias Value = SinkActions
}

extension FocusedValues {
    var sinkActions: SinkActions? {
        get { self[SinkActionsKey.self] }
        set { self[SinkActionsKey.self] = newValue }
    }
}

private struct SinkCommands: Commands {
    @FocusedValue(\.sinkActions) private var actions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }.keyboardShortcut("n")
                .disabled(actions?.enabled != true)
            Button("Attach Documents…") { actions?.attach() }.keyboardShortcut("o")
                .disabled(actions?.enabled != true)
        }
        CommandGroup(after: .textEditing) {
            Button("Focus Input") { actions?.focus() }.keyboardShortcut("f")
        }
    }
}
