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
        return LibraryModel(
            followsProvider: true, screenshotter: WebPageScreenshotter(),
            captureSettings: CaptureSettings.current,
            schedulesAutomations: true
        )
    }

    /// The main window and the Settings window can both ask first; only one model is made.
    private func ensureConversation() {
        if conversation == nil {
            conversation = Self.makeConversation(store: library.store)
        }
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
                        .task { ensureConversation() }
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { InfactoryCommands() }

        // The standard Mac home for settings: Infactory › Settings… (⌘,).
        Settings {
            if let conversation {
                ConversationSettings(model: conversation, library: library)
            } else {
                ProgressView().frame(
                    width: ConversationSettings.size.width,
                    height: ConversationSettings.size.height
                )
                .task { ensureConversation() }
            }
        }
    }
}

struct InfactoryActions {
    let enabled: Bool
    let newNote: () -> Void
    let attach: () -> Void
    let focus: () -> Void
    /// Nil where the Library isn't showing, such as the conversation.
    var importBookmarks: (() -> Void)?
    var categorize: (() -> Void)?
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
    @FocusedValue(\.navigationActions) private var navigation
    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { navigation?.back() }.keyboardShortcut("[")
                .disabled(navigation?.canGoBack != true)
            Button("Forward") { navigation?.forward() }.keyboardShortcut("]")
                .disabled(navigation?.canGoForward != true)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }.keyboardShortcut("n")
                .disabled(actions?.enabled != true)
            Button("Attach Documents…") { actions?.attach() }.keyboardShortcut("o")
                .disabled(actions?.enabled != true)
            Button("Import Bookmarks…") { actions?.importBookmarks?() }
                .disabled(actions?.enabled != true || actions?.importBookmarks == nil)
            Button("Categorize Unfiled…") { actions?.categorize?() }
                .disabled(actions?.enabled != true || actions?.categorize == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Focus Input") { actions?.focus() }.keyboardShortcut("f")
        }
    }
}
