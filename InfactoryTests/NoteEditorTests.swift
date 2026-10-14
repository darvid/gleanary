import AppKit
@testable import Infactory
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct NoteEditorTests {
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
