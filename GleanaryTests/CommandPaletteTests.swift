import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

struct CommandPaletteTests {
    @Test func matcherPrefersWordStartsAndRunsOverScatteredLetters() throws {
        let title = "Guillermo Rauch on agentic infrastructure"
        let run = try #require(PaletteMatcher.match(title, query: "rauch"))
        #expect(run.indices == Array(10 ..< 15))
        let scattered = try #require(PaletteMatcher.match(title, query: "grai"))
        #expect(run.score > scattered.score)
        #expect(PaletteMatcher.match(title, query: "zzz") == nil)
        // A word start beats the same letters inside a word.
        let start = try #require(PaletteMatcher.match("Graph view", query: "gra"))
        let inside = try #require(PaletteMatcher.match("Autograph", query: "gra"))
        #expect(start.score > inside.score)
    }

    @Test func shortcutsDisplayAndSpeakAsMenusDo() throws {
        let palette = KeyShortcut("p", [.shift, .command])
        #expect(palette.display == "⇧⌘P")
        #expect(palette.spoken == "Shift Command P")
        #expect(KeyShortcut("return").display == "⌘↩")
        #expect(KeyShortcut("s", [.control, .command]).display == "⌃⌘S")
        let menu = try #require(palette.keyboardShortcut)
        #expect(menu.key == KeyEquivalent("p"))
        #expect(menu.modifiers == [.shift, .command])
        #expect(KeyShortcut("f5", []).isFunctionKey)
        #expect(KeyShortcut("f5", []).keyboardShortcut != nil)
    }

    @MainActor @Test func bindingsPersistTakeOverConflictsAndReset() throws {
        let suite = "CommandPaletteTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults)
        let palette = try #require(AppCommand.named("palette"))
        let clear = try #require(AppCommand.named("clear"))
        let graph = try #require(AppCommand.named("show-graph"))
        #expect(settings.shortcut(for: palette) == KeyShortcut("p", [.shift, .command]))
        #expect(settings.shortcut(for: graph) == nil)

        // Giving ⌘K to Show as Graph takes it from Clear Conversation.
        settings.set(KeyShortcut("k"), for: graph)
        #expect(settings.shortcut(for: graph) == KeyShortcut("k"))
        #expect(settings.shortcut(for: clear) == nil)

        let relaunched = ShortcutSettings(defaults: defaults)
        #expect(relaunched.shortcut(for: graph) == KeyShortcut("k"))
        #expect(relaunched.shortcut(for: clear) == nil)

        // Resetting Clear takes its default back from Show as Graph.
        relaunched.reset(clear)
        #expect(relaunched.shortcut(for: clear) == KeyShortcut("k"))
        #expect(relaunched.shortcut(for: graph) == nil)
        relaunched.restoreDefaults()
        #expect(defaults.data(forKey: ShortcutSettings.defaultsKey) == nil)
        #expect(!relaunched.isChanged(palette))
    }

    @MainActor @Test func recordingRefusesBareKeysReservedKeysAndLockedOwners() throws {
        let suite = "CommandPaletteTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults)
        let graph = try #require(AppCommand.named("show-graph"))
        let check = { (shortcut: KeyShortcut) in
            KeyboardSettingsView.validate(shortcut, for: graph, in: settings)
        }
        guard case .refused = check(KeyShortcut("g", [])) else {
            Issue.record("A bare letter must need a modifier"); return
        }
        guard case .refused = check(KeyShortcut("g", [.shift])) else {
            Issue.record("Shift alone must not be enough"); return
        }
        guard case .refused = check(KeyShortcut("q")) else {
            Issue.record("⌘Q is reserved"); return
        }
        guard case .refused = check(KeyShortcut(",")) else {
            Issue.record("⌘, belongs to Settings"); return
        }
        guard case let .conflict(owner) = check(KeyShortcut("k")) else {
            Issue.record("⌘K belongs to Clear Conversation"); return
        }
        #expect(owner.id == "clear")
        #expect(check(KeyShortcut("g", [.option, .command])) == .accepted)
        #expect(check(KeyShortcut("f6", [])) == .accepted)
    }

    @MainActor @Test func paletteAndKeyboardSettingsRender() async throws {
        let items = [
            PaletteItem(
                id: "place-Library", section: .places, title: "Library", subtitle: "Go to",
                symbol: "books.vertical", run: {}
            ),
            PaletteItem(
                id: "command-show-graph", section: .commands, title: "Show as Graph",
                symbol: "point.3.connected.trianglepath.dotted",
                shortcut: KeyShortcut("g", [.option, .command]), run: {}
            ),
            PaletteItem(
                id: "category-a", section: .categories, title: "20.03 AI agents & automation",
                subtitle: "Show in Library", symbol: "number", run: {}
            ),
        ]
        let documents: (String) async -> [PaletteItem] = { _ in [
            PaletteItem(
                id: "document-a", section: .documents,
                title: "Guillermo Rauch on agentic infrastructure and verification",
                subtitle: "Summary", symbol: "note.text", filing: "20.03 AI agents & automation",
                run: {}, runBeside: {}
            ),
        ] }
        let views: [(String, AnyView, CGSize)] = try [
            ("palette", AnyView(CommandPaletteView(
                items: items, suggested: ["place-Library", "command-show-graph"],
                recent: { await documents("") }, documents: documents,
                ask: { PaletteItem(
                    id: "ask", section: .ask, title: "Ask Gleanary “\($0)”",
                    subtitle: "Sends to Chat", symbol: "bubble.left", run: {}
                ) },
                close: {}
            ).padding(40)), CGSize(width: 760, height: 620)),
            ("keyboard", AnyView(KeyboardSettingsView(
                settings: ShortcutSettings(defaults: #require(UserDefaults(
                    suiteName: "CommandPaletteRender-" + UUID().uuidString
                )))
            )), ConversationSettings.size),
        ]
        for (name, view, size) in views {
            for dark in [false, true] {
                let host = NSHostingView(rootView: view
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo
                    .environment["GLEANARY_PALETTE_SCREENSHOTS"]
                {
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try FileManager.default.createDirectory(
                        at: URL(filePath: directory), withIntermediateDirectories: true
                    )
                    try png.write(to: URL(filePath: directory)
                        .appending(path: "\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test func everyCommandHasAStableUniqueID() {
        let ids = AppCommand.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let defaults = AppCommand.all.compactMap(\.defaultShortcut)
        #expect(Set(defaults).count == defaults.count)
    }
}
