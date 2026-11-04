import AppKit
@testable import Gleanary
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct NoteEditorTests {
    @Test func readingFontsHaveIndependentPersistentDefaults() throws {
        let suite = "gleanary-appearance-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = ReadingAppearance(defaults: defaults)
        #expect(appearance[.notes] == ReadingKind.notes.defaultFont)
        #expect(appearance[.sources] == ReadingKind.sources.defaultFont)
        #expect(appearance[.notes].family == ReadingFont.systemSerif)
        #expect(appearance[.notes].available)
        #expect(!ReadingFont(family: "No Such Synthetic Serif", size: 14).available)
        let serif = appearance[.notes].nativeFont
        #expect(serif.familyName != NSFont.systemFont(ofSize: 14).familyName)
        // The editor reaches it by name, and has to land on the same family.
        #expect(
            NSFont(name: appearance[.notes].editorFontName, size: 14)?.familyName == serif
                .familyName
        )
        #expect(appearance[.sources].family.isEmpty)
        #expect(appearance[.notes].nativeFont.familyName != appearance[.sources].nativeFont
            .familyName)
        appearance[.notes] = ReadingFont(family: "Georgia", size: 19)
        let reopened = ReadingAppearance(defaults: defaults)
        #expect(reopened[.notes] == ReadingFont(family: "Georgia", size: 19))
        #expect(reopened[.sources] == ReadingKind.sources.defaultFont)
        reopened[.sources] = ReadingFont(family: "Helvetica", size: 17)
        #expect(appearance[.notes].size == 19)
        #expect(appearance[.sources] == ReadingFont(family: "Helvetica", size: 17))
        reopened[.notes] = ReadingKind.notes.defaultFont
        #expect(ReadingAppearance(defaults: defaults)[.notes] == ReadingKind.notes.defaultFont)
        #expect(ReadingAppearance(defaults: defaults)[.sources].size == 17)
        for kind in ["note", "summary", "comparison", "document"] {
            #expect(ReadingKind(libraryKind: kind) == .notes)
        }
        #expect(ReadingKind(libraryKind: "source") == .sources)
    }

    @Test func invalidReadingFontsFallBackSafely() {
        let missing = ReadingFont(family: "Synthetic Missing Font", size: 18)
        #expect(!missing.available)
        #expect(missing.nativeFont == NSFont.systemFont(ofSize: 18))
        #expect(ReadingFont(family: "", size: .nan).size == 14)
        #expect(ReadingFont(family: "", size: .infinity).size == 14)
        #expect(ReadingFont(family: "", size: -100).size == 10)
        #expect(ReadingFont(family: "", size: 1000).size == 32)
    }

    @Test(arguments: [ReadingKind.notes, .sources])
    func editorFontUpdatesWithoutChangingText(kind: ReadingKind) async throws {
        let suite = "gleanary-editor-appearance-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = ReadingAppearance(defaults: defaults)
        let box = TextBox(text: "Synthetic saved text.")
        let host = NSHostingView(rootView: MarkdownSourceEditor(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            documentID: UUID(), readingKind: kind
        ).defaultAppStorage(defaults))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle {
            Self.textView(in: host)?.font?.familyName == appearance[kind].nativeFont.familyName
        }
        let editor = try #require(Self.textView(in: host))
        #expect(editor.font?.familyName == appearance[kind].nativeFont.familyName)
        appearance[kind] = ReadingFont(family: kind == .notes ? "Helvetica" : "Georgia", size: 19)
        try await settle { editor.font == appearance[kind].nativeFont }
        #expect(editor.font == appearance[kind].nativeFont)
        #expect(box.text == "Synthetic saved text.")
        #expect(editor.string == box.text)
    }

    /// Notes are stored as Markdown text, so editing one must hand back exactly what was there
    /// apart from the edit itself, whatever the editor shows while styling it.
    @Test(arguments: [
        "# Heading\n\nSome **bold**, _italic_ and `code`.\n",
        "- one\n- two\n  - nested\n1. first\n2. second\n- [ ] open task\n- [x] done task",
        "> quoted\n> > nested quote\n\n---\n\n```swift\nlet value = 1\n    indented()\n```\n",
        "| A | B |\n| --- | :-: |\n| 1 | 2 \\| 3 |\n",
        "[link](https://example.org) ![image](https://example.org/a.png) <https://example.org>",
        "[[Wiki Note]] and [[Aliased|shown]] and ==mark== ~~struck~~ $x^2$",
        "Trailing spaces  \nhard break\twith tab\r\nwindows line\n\n\n\nGaps",
        "Émoji 🧪 and combining é, ZWJ 👩‍💻",
    ])
    func editingKeepsMarkdownVerbatim(_ markdown: String) async throws {
        let box = TextBox(text: markdown)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: MarkdownSourceEditor(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            documentID: UUID()
        ))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try await settle { Self.textView(in: window.contentView) != nil }
        let textView = try #require(Self.textView(in: window.contentView))

        textView.setSelectedRange(NSRange(
            location: (textView.string as NSString).length,
            length: 0
        ))
        textView.insertText("!", replacementRange: textView.selectedRange())
        try await settle { box.text == markdown + "!" }
        #expect(box.text == markdown + "!")

        textView.deleteBackward(nil)
        try await settle { box.text == markdown }
        #expect(box.text == markdown)
    }

    /// The editor writes its binding back on a later main-queue turn, which needs the main actor
    /// free rather than a nested run loop.
    private func settle(until done: () -> Bool) async throws {
        for _ in 0 ..< 100 where !done() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView {
            return textView
        }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}

@MainActor
private final class TextBox {
    var text: String

    init(text: String) {
        self.text = text
    }
}
