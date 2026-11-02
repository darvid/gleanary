import AppKit
import Observation
import SwiftUI

/// A key and its modifiers, stored by name so a binding survives app updates.
struct KeyShortcut: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let control = Self(rawValue: 1)
        static let option = Self(rawValue: 2)
        static let shift = Self(rawValue: 4)
        static let command = Self(rawValue: 8)
    }

    /// A lowercased character, or a named key: return, escape, delete, tab, space, up, down,
    /// left, right, or f1 through f20.
    var key: String
    var modifiers: Modifiers

    init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    private static let glyphs: [String: String] = [
        "return": "↩", "escape": "esc", "delete": "⌫", "tab": "⇥", "space": "Space",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
    ]

    /// As macOS menus write it: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) {
            text += "⌃"
        }
        if modifiers.contains(.option) {
            text += "⌥"
        }
        if modifiers.contains(.shift) {
            text += "⇧"
        }
        if modifiers.contains(.command) {
            text += "⌘"
        }
        return text + (Self.glyphs[key] ?? key.uppercased())
    }

    /// Spoken form for VoiceOver, such as "Shift Command P".
    var spoken: String {
        var words: [String] = []
        if modifiers.contains(.control) {
            words.append("Control")
        }
        if modifiers.contains(.option) {
            words.append("Option")
        }
        if modifiers.contains(.shift) {
            words.append("Shift")
        }
        if modifiers.contains(.command) {
            words.append("Command")
        }
        let names = [
            "return": "Return", "escape": "Escape", "delete": "Delete", "tab": "Tab",
            "space": "Space", "up": "Up Arrow", "down": "Down Arrow", "left": "Left Arrow",
            "right": "Right Arrow", "[": "Left Bracket", "]": "Right Bracket", ",": "Comma",
        ]
        words.append(names[key] ?? key.uppercased())
        return words.joined(separator: " ")
    }

    var isFunctionKey: Bool {
        key.hasPrefix("f") && Int(key.dropFirst()) != nil
    }

    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent? = switch key {
        case "return": .return
        case "escape": .escape
        case "delete": .delete
        case "tab": .tab
        case "space": .space
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        default:
            if isFunctionKey, let number = Int(key.dropFirst()),
               let scalar = UnicodeScalar(NSF1FunctionKey + number - 1)
            {
                KeyEquivalent(Character(scalar))
            } else {
                key.count == 1 ? key.first.map { KeyEquivalent($0) } : nil
            }
        }
        guard let equivalent else { return nil }
        var flags: EventModifiers = []
        if modifiers.contains(.control) {
            flags.insert(.control)
        }
        if modifiers.contains(.option) {
            flags.insert(.option)
        }
        if modifiers.contains(.shift) {
            flags.insert(.shift)
        }
        if modifiers.contains(.command) {
            flags.insert(.command)
        }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }

    /// Reads a key press while recording. Nil for a press of modifiers alone.
    init?(event: NSEvent) {
        let named: [UInt16: String] = [
            36: "return", 76: "return", 53: "escape", 51: "delete", 48: "tab", 49: "space",
            126: "up", 125: "down", 123: "left", 124: "right",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
            101: "f9", 109: "f10", 103: "f11", 111: "f12",
        ]
        let key: String
        if let name = named[event.keyCode] {
            key = name
        } else if let character = event.charactersIgnoringModifiers?.lowercased().first,
                  !character.isWhitespace
        {
            // Shifted symbols report their shifted form; keep the key's own character.
            key = (event.characters(byApplyingModifiers: []) ?? String(character)).lowercased()
        } else {
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        self.init(key, modifiers)
    }
}

/// Everything a menu item, the command palette or a shortcut can run, in one list. The id is
/// what bindings are stored under, so it never changes when a title does.
struct AppCommand: Identifiable, Hashable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case general = "General", go = "Go", file = "File", chat = "Chat", library = "Library"
    }

    let id: String
    let title: String
    let group: Group
    let symbol: String
    var defaultShortcut: KeyShortcut?
    /// Set by macOS or by the screen it belongs to, so it can't be rebound.
    var locked = false
    /// Other words the palette matches, such as "preferences" for Settings.
    var keywords = ""

    static let palette = Self(
        id: "palette", title: "Command Palette", group: .general, symbol: "command",
        defaultShortcut: KeyShortcut("p", [.shift, .command])
    )

    static let all: [Self] = [
        palette,
        Self(
            id: "settings", title: "Settings…", group: .general, symbol: "gearshape",
            defaultShortcut: KeyShortcut(","), locked: true, keywords: "preferences"
        ),
        Self(
            id: "focus", title: "Focus Search or Composer", group: .general,
            symbol: "character.cursor.ibeam", defaultShortcut: KeyShortcut("f")
        ),
        Self(
            id: "toggle-sidebar", title: "Toggle Sidebar", group: .general,
            symbol: "sidebar.left", defaultShortcut: KeyShortcut("s", [.control, .command])
        ),
        Self(
            id: "back", title: "Back", group: .go, symbol: "chevron.left",
            defaultShortcut: KeyShortcut("[")
        ),
        Self(
            id: "forward", title: "Forward", group: .go, symbol: "chevron.right",
            defaultShortcut: KeyShortcut("]")
        ),
        Self(id: "go-chat", title: "Go to Chat", group: .go, symbol: "bubble.left"),
        Self(id: "go-library", title: "Go to Library", group: .go, symbol: "books.vertical"),
        Self(id: "go-tasks", title: "Go to Tasks", group: .go, symbol: "checklist"),
        Self(id: "go-entities", title: "Go to Entities", group: .go, symbol: "person.2"),
        Self(id: "go-activity", title: "Go to Activity", group: .go, symbol: "clock"),
        Self(
            id: "go-automations", title: "Go to Automations", group: .go,
            symbol: "gearshape.2"
        ),
        Self(
            id: "new-item", title: "New Note or Topic", group: .file, symbol: "square.and.pencil",
            defaultShortcut: KeyShortcut("n"), keywords: "chat subject"
        ),
        Self(
            id: "attach", title: "Attach Documents…", group: .file, symbol: "paperclip",
            defaultShortcut: KeyShortcut("o"), keywords: "import file pdf"
        ),
        Self(
            id: "bookmarks", title: "Import Bookmarks…", group: .file, symbol: "bookmark",
            keywords: "browser raindrop"
        ),
        Self(
            id: "send", title: "Send Message", group: .chat, symbol: "arrow.up.circle",
            defaultShortcut: KeyShortcut("return")
        ),
        Self(
            id: "clear", title: "Clear Conversation…", group: .chat, symbol: "trash",
            defaultShortcut: KeyShortcut("k"), keywords: "delete reset"
        ),
        Self(
            id: "stop", title: "Stop Current Request", group: .chat, symbol: "stop.circle",
            defaultShortcut: KeyShortcut("escape", []), locked: true
        ),
        Self(
            id: "show-map", title: "Show as Map", group: .library, symbol: "square.grid.2x2",
            keywords: "atlas view"
        ),
        Self(
            id: "show-list", title: "Show as List", group: .library, symbol: "list.bullet",
            keywords: "view"
        ),
        Self(
            id: "show-graph", title: "Show as Graph", group: .library,
            symbol: "point.3.connected.trianglepath.dotted", keywords: "connections view"
        ),
        Self(
            id: "categorize", title: "Categorize Unfiled…", group: .library, symbol: "folder",
            keywords: "file filing"
        ),
    ]

    static func named(_ id: String) -> Self? {
        all.first { $0.id == id }
    }
}

/// The person's shortcut for each command, falling back to its default.
@MainActor @Observable
final class ShortcutSettings {
    static let shared = ShortcutSettings()
    static let defaultsKey = "keyboardShortcuts"

    /// Shortcuts macOS or text editing already uses, with what they do.
    static let reserved: [KeyShortcut: String] = [
        KeyShortcut("q"): "Quit", KeyShortcut("w"): "Close Window", KeyShortcut("h"): "Hide",
        KeyShortcut("m"): "Minimize", KeyShortcut("tab"): "the app switcher",
        KeyShortcut("space"): "Spotlight", KeyShortcut(","): "Settings",
        KeyShortcut("c"): "Copy", KeyShortcut("v"): "Paste", KeyShortcut("x"): "Cut",
        KeyShortcut("a"): "Select All", KeyShortcut("z"): "Undo",
        KeyShortcut("z", [.shift, .command]): "Redo",
    ]

    @ObservationIgnored private let defaults: UserDefaults
    /// Changes from the defaults; a nil value means the shortcut was removed.
    private(set) var overrides: [String: KeyShortcut?]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: KeyShortcut?].self, from: $0) } ?? [:]
    }

    func shortcut(for command: AppCommand) -> KeyShortcut? {
        guard !command.locked, let override = overrides[command.id] else {
            return command.defaultShortcut
        }
        return override
    }

    func shortcut(for id: String) -> KeyShortcut? {
        AppCommand.named(id).flatMap(shortcut(for:))
    }

    func keyboardShortcut(for id: String) -> KeyboardShortcut? {
        shortcut(for: id)?.keyboardShortcut
    }

    func isChanged(_ command: AppCommand) -> Bool {
        shortcut(for: command) != command.defaultShortcut
    }

    /// The other command using this shortcut, if any.
    func owner(of shortcut: KeyShortcut, excluding id: String) -> AppCommand? {
        AppCommand.all.first { $0.id != id && self.shortcut(for: $0) == shortcut }
    }

    /// Binds the shortcut, taking it from any other command that had it.
    func set(_ shortcut: KeyShortcut?, for command: AppCommand) {
        guard !command.locked else { return }
        if let shortcut, let other = owner(of: shortcut, excluding: command.id) {
            store(nil, for: other)
        }
        store(shortcut, for: command)
        save()
    }

    func reset(_ command: AppCommand) {
        if let shortcut = command.defaultShortcut,
           let other = owner(of: shortcut, excluding: command.id)
        {
            store(nil, for: other)
        }
        overrides[command.id] = nil
        save()
    }

    func restoreDefaults() {
        overrides = [:]
        save()
    }

    private func store(_ shortcut: KeyShortcut?, for command: AppCommand) {
        if shortcut == command.defaultShortcut {
            overrides.removeValue(forKey: command.id)
        } else {
            overrides[command.id] = .some(shortcut)
        }
    }

    private func save() {
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// What the focused window can do right now, by command id. Menus, shortcuts and the palette
/// all run commands through this, so none offers something the screen can't do.
extension FocusedValues {
    @Entry var commandActions: [String: () -> Void]?
}
