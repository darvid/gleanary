import AppKit
import MarkdownEngine
import MarkdownEngineLatex
import SwiftUI

/// LaTeX in Markdown, written as the note editor reads it: `$…$` and `\(…\)` inline, and
/// `$$…$$`, `\[…\]` or a `math` code fence as a display block.
enum MathMarkdown {
    struct Formula: Equatable {
        let latex: String
        let display: Bool
    }

    /// One renderer for the editor and every reading view, so a formula typesets once.
    @MainActor static let renderer = SwiftMathBridge()

    /// The text with each inline formula swapped for one placeholder character, and the formulas
    /// in order. Markdown parsing then can't read a formula's `_`, `*` or `\` as formatting, and
    /// emphasis and links around a formula still parse.
    nonisolated static func extractingInline(_ text: String)
        -> (text: String, formulas: [Formula])
    {
        let characters = Array(text)
        var output = ""
        var formulas: [Formula] = []
        var index = 0
        func take(_ latex: String, display: Bool, next: Int) {
            output.append(Character(placeholder(formulas.count)))
            formulas.append(Formula(latex: latex, display: display))
            index = next
        }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "\\", next == "$" {
                output.append("\\$")
                index += 2
            } else if character == "\\", next == "(",
                      let close = find(["\\", ")"], in: characters, from: index + 2),
                      let latex = content(characters, index + 2 ..< close)
            {
                take(latex, display: false, next: close + 2)
            } else if character == "`" {
                // Code spans keep their dollars.
                let ticks = characters[index...].prefix(while: { $0 == "`" }).count
                let fence = Array(repeating: Character("`"), count: ticks)
                let end = find(fence, in: characters, from: index + ticks).map { $0 + ticks }
                    ?? index + ticks
                output.append(contentsOf: characters[index ..< end])
                index = end
            } else if character == "$", next == "$",
                      let close = find(["$", "$"], in: characters, from: index + 2),
                      let latex = content(characters, index + 2 ..< close)
            {
                take(latex, display: true, next: close + 2)
            } else if character == "$", let next, !next.isWhitespace, next != "$",
                      let close = inlineClose(characters, from: index + 1),
                      let latex = content(characters, index + 1 ..< close)
            {
                take(latex, display: false, next: close + 1)
            } else {
                output.append(character)
                index += 1
            }
        }
        return (output, formulas)
    }

    /// The formula a placeholder from `extractingInline` stands for.
    nonisolated static func formula(at character: Character, in formulas: [Formula]) -> Formula? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              scalar.value >= placeholderBase
        else { return nil }
        let index = Int(scalar.value - placeholderBase)
        return index < formulas.count ? formulas[index] : nil
    }

    /// The formula of a display block, or nil when the block isn't one.
    nonisolated static func displayFormula(_ block: String) -> String? {
        let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces) == "```math",
           lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        {
            return nonEmpty(lines.dropFirst().dropLast().joined(separator: "\n"))
        }
        for (open, close) in [("$$", "$$"), ("\\[", "\\]")]
            where text.count >= open.count + close.count && text.hasPrefix(open) && text
            .hasSuffix(close)
        {
            let inner = text.dropFirst(open.count).dropLast(close.count)
            guard !inner.contains(open) else { return nil }
            return nonEmpty(String(inner))
        }
        return nil
    }

    /// Whether a line starts a display formula that runs over the following lines.
    nonisolated static func opensDisplay(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return (text.hasPrefix("$$") && !text.dropFirst(2).contains("$$"))
            || (text.hasPrefix("\\[") && !text.contains("\\]"))
    }

    /// Whether a line ends a display formula `opensDisplay` started.
    nonisolated static func closesDisplay(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.hasSuffix("$$") || text.hasSuffix("\\]")
    }

    /// A typeset formula in the reading colour, or nil when SwiftMath can't parse it.
    /// `dark` is the view's own scheme: the renderer would otherwise follow the app's, which
    /// a view can differ from.
    @MainActor static func render(
        _ formula: Formula, size: CGFloat, secondary: Bool = false, dark: Bool
    ) -> LatexRenderResult? {
        // The renderer reads the app's appearance, which a process without one lacks.
        guard (NSApp as NSApplication?) != nil else { return nil }
        // Opaque greys near the label colours, since the renderer's cache key ignores alpha.
        let white: CGFloat = switch (secondary, dark) {
        case (false, false): 0.12
        case (false, true): 0.9
        case (true, false): 0.45
        case (true, true): 0.62
        }
        let color = NSColor(white: white, alpha: 1)
        let theme = MarkdownEditorTheme(latexLightModeText: color, latexDarkModeText: color)
        return renderer.render(
            latex: formula.latex,
            mode: formula.display ? .display : .inline,
            fontSize: size,
            theme: theme
        )
    }

    /// Inline text with its formulas typeset in place; one that won't typeset stays as written.
    @MainActor static func text(
        _ text: AttributedString, formulas: [Formula], size: CGFloat, secondary: Bool = false,
        dark: Bool
    ) -> Text {
        guard !formulas.isEmpty else { return Text(text) }
        var result = Text(verbatim: "")
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            let following = text.characters.index(after: index)
            if let formula = formula(at: text.characters[index], in: formulas) {
                let before = Text(AttributedString(text[start ..< index]))
                result =
                    Text(
                        "\(result)\(before)\(formulaText(formula, size: size, secondary: secondary, dark: dark))"
                    )
                start = following
            }
            index = following
        }
        return Text("\(result)\(Text(AttributedString(text[start...])))")
    }

    /// The same, for AppKit-drawn text: each placeholder becomes an image attachment.
    @MainActor static func attach(
        _ formulas: [Formula], in content: NSMutableAttributedString, size: CGFloat, dark: Bool
    ) {
        guard !formulas.isEmpty else { return }
        let string = content.string as NSString
        for location in (0 ..< string.length).reversed() {
            let range = string.rangeOfComposedCharacterSequence(at: location)
            guard range.location == location,
                  let formula = formula(at: Character(string.substring(with: range)), in: formulas)
            else { continue }
            let attributes = content.attributes(at: location, effectiveRange: nil)
            guard let rendered = render(formula, size: size, dark: dark) else {
                content.replaceCharacters(
                    in: range,
                    with: NSAttributedString(string: source(formula), attributes: attributes)
                )
                continue
            }
            let attachment = NSTextAttachment()
            attachment.image = rendered.image
            attachment.bounds = CGRect(
                origin: CGPoint(x: 0, y: -rendered.baselineOffset), size: rendered.size
            )
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttributes(attributes, range: NSRange(location: 0, length: 1))
            content.replaceCharacters(in: range, with: replacement)
        }
    }

    @MainActor private static func formulaText(
        _ formula: Formula, size: CGFloat, secondary: Bool, dark: Bool
    ) -> Text {
        guard let rendered = render(formula, size: size, secondary: secondary, dark: dark) else {
            return Text(verbatim: source(formula))
        }
        return Text(Image(nsImage: rendered.image))
            .baselineOffset(-rendered.baselineOffset)
            .accessibilityLabel(formula.latex)
    }

    private static func source(_ formula: Formula) -> String {
        formula.display ? "$$\(formula.latex)$$" : "$\(formula.latex)$"
    }

    /// Private-use characters, which Markdown leaves alone and real text doesn't carry.
    private nonisolated static let placeholderBase: UInt32 = 0xF0000

    private nonisolated static func placeholder(_ index: Int) -> Unicode.Scalar {
        Unicode.Scalar(placeholderBase + UInt32(index)) ?? "\u{FFFD}"
    }

    /// A closing `$` hugs the formula and isn't followed by a digit, so "$5 and $10" stays text.
    private nonisolated static func inlineClose(
        _ characters: [Character],
        from start: Int
    ) -> Int? {
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character == "\n", index + 1 < characters.count, characters[index + 1] == "\n" {
                return nil
            }
            if character == "$", !characters[index - 1].isWhitespace, characters[index - 1] != "\\",
               index + 1 >= characters.count || !characters[index + 1].isNumber
            {
                return index
            }
            index += 1
        }
        return nil
    }

    private nonisolated static func find(
        _ needle: [Character], in characters: [Character], from start: Int
    ) -> Int? {
        guard start <= characters.count - needle.count else { return nil }
        return (start ... characters.count - needle.count).first { index in
            characters[index ..< index + needle.count].elementsEqual(needle)
        }
    }

    private nonisolated static func content(
        _ characters: [Character],
        _ range: Range<Int>
    ) -> String? {
        nonEmpty(String(characters[range]))
    }

    private nonisolated static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A display formula on its own line, scrolling sideways when it's wider than the text.
struct MathBlock: View {
    let latex: String
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let rendered = MathMarkdown.render(
            .init(latex: latex, display: true), size: size, dark: colorScheme == .dark
        ) {
            let image = Image(nsImage: rendered.image)
                .frame(width: rendered.size.width, height: rendered.size.height)
            ViewThatFits(in: .horizontal) {
                image
                ScrollView(.horizontal, showsIndicators: false) { image }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel(latex)
        } else {
            Text(verbatim: "$$\(latex)$$").font(.body.monospaced()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
