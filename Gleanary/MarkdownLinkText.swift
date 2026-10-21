import AppKit
import SwiftUI

/// Native linked text gives each link its own cursor without changing surrounding text.
struct MarkdownLinkText: NSViewRepresentable {
    let text: AttributedString
    let font: NSFont
    var color = NSColor.labelColor
    var lineSpacing: CGFloat = 0
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL)
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openURL = openURL
        let content = Self.content(text, font: font, color: color, lineSpacing: lineSpacing)
        if view.textStorage?.isEqual(to: content) != true {
            view.textStorage?.setAttributedString(content)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    static func content(
        _ text: AttributedString, font: NSFont, color: NSColor, lineSpacing: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let content = NSMutableAttributedString(string: "")
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            if intent.contains(.stronglyEmphasized) {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.cursor] = NSCursor.pointingHand
                attributes[.foregroundColor] = NSColor.linkColor
            }
            content.append(NSAttributedString(
                string: String(text[run.range].characters),
                attributes: attributes
            ))
        }
        return content
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction

        init(openURL: OpenURLAction) {
            self.openURL = openURL
        }

        func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
            guard let url = link as? URL else { return false }
            openURL(url)
            return true
        }
    }
}
