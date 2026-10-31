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
            pageRenderer: WebKitPageRenderer(),
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
    @FocusedValue(\.commandActions) private var windowActions
    private let shortcuts = ShortcutSettings.shared

    var body: some Commands {
        CommandMenu("Go") {
            item("palette", title: "Command Palette…")
            Divider()
            item("back")
            item("forward")
            Divider()
            ForEach(["go-chat", "go-library", "go-tasks", "go-entities", "go-activity",
                     "go-automations"], id: \.self) { item($0) }
        }
        CommandGroup(replacing: .newItem) {
            item("new-item", title: actions?.newItemTitle ?? "New Note")
            item("attach")
            item("bookmarks")
            item("categorize")
        }
        CommandMenu("Chat") {
            item("send")
            item("clear")
        }
        CommandGroup(after: .sidebar) {
            item("toggle-sidebar")
            Divider()
            item("show-map")
            item("show-list")
            item("show-graph")
        }
        CommandGroup(after: .textEditing) {
            item("focus", title: "Focus Input")
        }
    }

    /// A menu item for a command: disabled where the focused window can't run it, with the
    /// shortcut set in Settings › Keyboard.
    private func item(_ id: String, title: String? = nil) -> some View {
        let action = CommandRouter.action(
            id, window: windowActions, actions: actions, navigation: navigation,
            activitySearch: activitySearch
        )
        return Button(title ?? AppCommand.named(id)?.title ?? id) { action?() }
            .keyboardShortcut(shortcuts.keyboardShortcut(for: id))
            .disabled(action == nil)
    }
}

/// Finds what runs a command in the focused window, whichever view published it.
@MainActor enum CommandRouter {
    static func action(
        _ id: String,
        window: [String: () -> Void]?,
        actions: GleanaryActions?,
        navigation: NavigationActions?,
        activitySearch: (() -> Void)?
    ) -> (() -> Void)? {
        let enabled = actions?.enabled == true
        switch id {
        case "back": return navigation?.canGoBack == true ? navigation?.back : nil
        case "forward": return navigation?.canGoForward == true ? navigation?.forward : nil
        case "new-item": return enabled ? actions?.newItem : nil
        case "attach": return enabled ? actions?.attach : nil
        case "bookmarks": return enabled ? actions?.importBookmarks : nil
        case "categorize": return enabled ? actions?.categorize : nil
        case "send": return enabled ? actions?.sendMessage : nil
        case "clear": return enabled ? actions?.clearConversation : nil
        case "focus": return activitySearch ?? actions?.focus
        default: return window?[id]
        }
    }
}
