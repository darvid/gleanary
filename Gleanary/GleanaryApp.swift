import SwiftUI

@main
struct GleanaryApp: App {
    @State private var library = Self.makeLibrary()
    @State private var conversation: ConversationModel?

    private static func makeLibrary() -> LibraryModel {
        #if DEBUG
            if ProcessInfo.processInfo.environment["GLEANARY_TESTING"] == "1" {
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "Gleanary-test-host-" + UUID().uuidString)
                    .appending(path: "library.sqlite")
                return LibraryModel(store: DocumentStore(url: url))
            }
        #endif
        let library = LibraryModel(
            followsProvider: true, screenshotter: WebPageScreenshotter(),
            captureSettings: CaptureSettings.current,
            schedulesAutomations: true
        )
        library.graphFeaturesEnabled = UserDefaults.standard
            .bool(forKey: LibraryModel.backgroundEntitiesKey)
        return library
    }

    /// The main window and the Settings window can both ask first; only one model is made.
    private func ensureConversation() {
        if conversation == nil {
            conversation = Self.makeConversation(store: library.store)
        }
    }

    private static func makeConversation(store: DocumentStore) -> ConversationModel {
        #if DEBUG
            if ProcessInfo.processInfo.environment["GLEANARY_TESTING"] == "1" {
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
                    WorkingProgress("Opening workspace…")
                        .task { ensureConversation() }
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { GleanaryCommands() }

        // The standard Mac home for settings: Gleanary › Settings… (⌘,).
        Settings {
            if let conversation {
                ConversationSettings(model: conversation, library: library)
            } else {
                WorkingProgress().frame(
                    width: ConversationSettings.size.width,
                    height: ConversationSettings.size.height
                )
                .task { ensureConversation() }
            }
        }
    }
}

struct GleanaryActions {
    let enabled: Bool
    let newItem: () -> Void
    let attach: () -> Void
    let focus: () -> Void
    var newItemTitle = "New Note"
    /// Nil where the Library isn't showing, such as the conversation.
    var importBookmarks: (() -> Void)?
    var categorize: (() -> Void)?
    var clearConversation: (() -> Void)?
    var sendMessage: (() -> Void)?
}

private struct GleanaryActionsKey: FocusedValueKey {
    typealias Value = GleanaryActions
}

extension FocusedValues {
    var gleanaryActions: GleanaryActions? {
        get { self[GleanaryActionsKey.self] }
        set { self[GleanaryActionsKey.self] = newValue }
    }
}

private struct GleanaryCommands: Commands {
    @FocusedValue(\.gleanaryActions) private var actions
    @FocusedValue(\.navigationActions) private var navigation
    @FocusedValue(\.activitySearch) private var activitySearch
    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { navigation?.back() }.keyboardShortcut("[")
                .disabled(navigation?.canGoBack != true)
            Button("Forward") { navigation?.forward() }.keyboardShortcut("]")
                .disabled(navigation?.canGoForward != true)
        }
        CommandGroup(replacing: .newItem) {
            Button(actions?.newItemTitle ?? "New Note") { actions?.newItem() }.keyboardShortcut("n")
                .disabled(actions?.enabled != true)
            Button("Attach Documents…") { actions?.attach() }.keyboardShortcut("o")
                .disabled(actions?.enabled != true)
            Button("Import Bookmarks…") { actions?.importBookmarks?() }
                .disabled(actions?.enabled != true || actions?.importBookmarks == nil)
            Button("Categorize Unfiled…") { actions?.categorize?() }
                .disabled(actions?.enabled != true || actions?.categorize == nil)
        }
        CommandMenu("Chat") {
            Button("Send Message") { actions?.sendMessage?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.enabled != true || actions?.sendMessage == nil)
            Button("Clear Conversation…") { actions?.clearConversation?() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(actions?.enabled != true || actions?.clearConversation == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Focus Input") {
                if let activitySearch {
                    activitySearch()
                } else {
                    actions?.focus()
                }
            }.keyboardShortcut("f")
        }
    }
}
