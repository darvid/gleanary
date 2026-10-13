import SwiftUI

@main
struct InfactoryApp: App {
    @State private var library = Self.makeLibrary()
    @State private var conversation: ConversationModel?

    private static func makeLibrary() -> LibraryModel {
        #if DEBUG
            if ProcessInfo.processInfo.environment["INFACTORY_TESTING"] == "1" {
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "Infactory-test-host-" + UUID().uuidString)
                    .appending(path: "library.sqlite")
                return LibraryModel(store: DocumentStore(url: url))
            }
        #endif
        return LibraryModel(screenshotter: WebPageScreenshotter())
    }

    private static func makeConversation(store: DocumentStore) -> ConversationModel {
        #if DEBUG
            if ProcessInfo.processInfo.environment["INFACTORY_TESTING"] == "1" {
                // The Xcode app host must not read a person's production OAuth credentials.
                return ConversationModel(store: store, coordinator: AgentCoordinator(store: store))
            }
        #endif
        return ConversationModel(store: store)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let conversation {
                    ContentView(library: library, conversation: conversation)
                } else {
                    ProgressView("Opening workspace…")
                        .task { conversation = Self.makeConversation(store: library.store) }
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { InfactoryCommands() }
    }
}

struct InfactoryActions {
    let enabled: Bool
    let newNote: () -> Void
    let attach: () -> Void
    let focus: () -> Void
}

private struct InfactoryActionsKey: FocusedValueKey {
    typealias Value = InfactoryActions
}

extension FocusedValues {
    var infactoryActions: InfactoryActions? {
        get { self[InfactoryActionsKey.self] }
        set { self[InfactoryActionsKey.self] = newValue }
    }
}

private struct InfactoryCommands: Commands {
    @FocusedValue(\.infactoryActions) private var actions
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
