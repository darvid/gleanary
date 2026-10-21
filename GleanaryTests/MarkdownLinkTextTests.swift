import AppKit
@testable import Gleanary
import SwiftUI
import Testing

@Suite(.serialized) @MainActor struct MarkdownLinkTextTests {
    @Test func onlyLinkedCharactersReceiveTheHandCursorAndFormattingIsPreserved() throws {
        let text =
            try AttributedString(
                markdown: "Plain 🙂 [linked text](https://example.org/guide) and **bold** *italic* `code`."
            )
        let font = NSFont.systemFont(ofSize: 17)
        let content = MarkdownLinkText.content(text, font: font, color: .labelColor, lineSpacing: 4)
        let plain = (content.string as NSString).range(of: "Plain")
        let link = (content.string as NSString).range(of: "linked")
        let bold = (content.string as NSString).range(of: "bold")
        let italic = (content.string as NSString).range(of: "italic")
        let code = (content.string as NSString).range(of: "code")
        #expect(content.attribute(.cursor, at: plain.location, effectiveRange: nil) == nil)
        #expect(content.attribute(.link, at: plain.location, effectiveRange: nil) == nil)
        #expect((content.attribute(.cursor, at: link.location, effectiveRange: nil) as? NSCursor)?
            .isEqual(NSCursor.pointingHand) == true)
        #expect(content
            .attribute(.link, at: link.location, effectiveRange: nil) as? URL ==
            URL(string: "https://example.org/guide"))
        let boldFont = try #require(content.attribute(
            .font,
            at: bold.location,
            effectiveRange: nil
        ) as? NSFont)
        let italicFont = try #require(content.attribute(
            .font,
            at: italic.location,
            effectiveRange: nil
        ) as? NSFont)
        let codeFont = try #require(content.attribute(
            .font,
            at: code.location,
            effectiveRange: nil
        ) as? NSFont)
        #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        #expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
        #expect(codeFont.isFixedPitch)
        #expect(boldFont.pointSize == 17)
    }

    @Test func nativeLinksUseTheAppsURLHandlerForBothWebAndSavedNotes() throws {
        var opened: [URL] = []
        let coordinator = MarkdownLinkText.Coordinator(openURL: OpenURLAction { url in
            opened.append(url)
            return .handled
        })
        let view = NSTextView()
        for value in [
            "https://example.org/guide",
            "gleanary://note/00000000-0000-0000-0000-000000000001",
        ] {
            let url = try #require(URL(string: value))
            #expect(coordinator.textView(view, clickedOnLink: url, at: 0))
            #expect(opened.last == url)
        }
        #expect(!coordinator.textView(view, clickedOnLink: 42, at: 0))
        #expect(opened.count == 2)
    }

    @Test func linkedParagraphsWrapAtTheAvailableWidthAndKeepTextSelection() async throws {
        let markdown =
            "Before [a descriptive **linked source**](https://example.org/guide), after. " + String(
                repeating: "More readable text. ",
                count: 12
            )
        let host = NSHostingView(rootView: MarkdownPreview(
            markdown: markdown,
            readingFont: ReadingKind.notes.defaultFont
        )
        .textSelection(.enabled).frame(width: 300))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let view = try #require(textView(in: host))
        #expect(view.isSelectable)
        #expect(!view.isEditable)
        #expect(view.bounds.width <= 300)
        #expect(view.bounds.height > 40)
        #expect((view.linkTextAttributes?[.cursor] as? NSCursor)?
            .isEqual(NSCursor.pointingHand) == true)
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView {
            return text
        }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
