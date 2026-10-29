import Foundation
import SwiftSoup

/// Formulas on web pages, kept as LaTeX so a capture holds real math rather than the text of a
/// rendered formula's glyphs. Each becomes `<code data-math>`, which CaptureArticle.js writes
/// as `$…$` or `$$…$$` without Markdown escapes.
enum PageMath {
    static func normalize(_ document: Document) throws {
        let scripts = try document.select("script[type^=math/tex]").array()
        if !scripts.isEmpty {
            // MathJax 2 keeps each formula's TeX in a script beside its rendering.
            try document.select(
                ".MathJax_Preview, .MathJax, .MathJax_Display, .MathJax_SVG, .MathJax_SVG_Display, "
                    + ".MathJax_CHTML, .MJX_Assistive_MathML"
            ).remove()
        }
        for script in scripts {
            try replace(
                script,
                latex: script.data(),
                display: script.attr("type").contains("mode=display")
            )
        }
        let rendered = try document.select(
            ".katex-display, .katex, .mwe-math-element, mjx-container, math"
        ).array()
        for element in rendered where attached(element, to: document) {
            guard let latex = try source(element) else { continue }
            try replace(element, latex: latex, display: display(element))
        }
    }

    /// The formula's TeX: a KaTeX or MathML annotation, the `alttext` arXiv and Wikipedia carry,
    /// Wikipedia's fallback image text, or failing those the MathML itself.
    private static func source(_ element: Element) throws -> String? {
        if let annotation = try element.select("annotation[encoding=application/x-tex]").first() {
            return try unwrapped(annotation.text())
        }
        let math = element.tagName() == "math" ? element : try element.select("math").first()
        if let math, math.hasAttr("alttext") {
            return try unwrapped(math.attr("alttext"))
        }
        if let image = try element.select("img[alt]").first() {
            return try unwrapped(image.attr("alt"))
        }
        return try math.flatMap { try MathMLToLaTeX.convert($0) }.flatMap(unwrapped)
    }

    private static func display(_ element: Element) throws -> Bool {
        if try element.hasClass("katex-display") || element.attr("display") == "true" {
            return true
        }
        let math = element.tagName() == "math" ? element : try element.select("math").first()
        return try math?.attr("display") == "block"
            || !element.select(".mwe-math-fallback-image-display, .mwe-math-mathml-display")
            .isEmpty()
    }

    private static func replace(_ element: Element, latex: String, display: Bool) throws {
        let latex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty, let document = element.ownerDocument() else { return }
        let code = try document.createElement("code")
            .attr("data-math", display ? "display" : "inline")
            .text(latex)
        // A display formula is its own paragraph unless it sits inside one already.
        let inParagraph = element.parents().contains { $0.tagName() == "p" }
        let replacement = display && !inParagraph
            ? try document.createElement("p").appendChild(code) : code
        try element.replaceWith(replacement)
    }

    /// Wikipedia wraps its TeX in `{\displaystyle …}`.
    private static func unwrapped(_ latex: String) -> String? {
        var text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        for style in ["{\\displaystyle", "{\\textstyle"]
            where text.hasPrefix(style) && text.hasSuffix("}")
        {
            text = String(text.dropFirst(style.count).dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }

    private static func attached(_ element: Element, to document: Document) -> Bool {
        var node: Node = element
        while let parent = node.parent() {
            node = parent
        }
        return node === document
    }
}

/// Presentation MathML as LaTeX, for MathJax 3 pages that keep only MathML. It covers the
/// common layout elements; anything else contributes its text.
enum MathMLToLaTeX {
    static func convert(_ math: Element) throws -> String? {
        let latex = try children(math).trimmingCharacters(in: .whitespaces)
        return latex.isEmpty ? nil : latex
    }

    private static func children(_ element: Element) throws -> String {
        try element.children().array().map(node).joined()
    }

    // One case per MathML element.
    // swiftlint:disable:next cyclomatic_complexity
    private static func node(_ element: Element) throws -> String {
        let parts = try element.children().array().map(node)
        func part(_ index: Int) -> String {
            index < parts.count ? parts[index] : ""
        }
        switch element.tagName() {
        case "mi", "mn":
            let text = try element.text()
            return text.count > 1 && element.tagName() == "mi" ? "\\mathrm{\(text)}" : symbols(text)
        case "mo": return try symbols(element.text())
        case "mtext": return try "\\text{\(element.text())}"
        case "msup": return "{\(part(0))}^{\(part(1))}"
        case "msub": return "{\(part(0))}_{\(part(1))}"
        case "msubsup", "munderover": return "{\(part(0))}_{\(part(1))}^{\(part(2))}"
        case "munder": return "{\(part(0))}_{\(part(1))}"
        case "mover": return "{\(part(0))}^{\(part(1))}"
        case "mfrac": return "\\frac{\(part(0))}{\(part(1))}"
        case "msqrt": return "\\sqrt{\(parts.joined())}"
        case "mroot": return "\\sqrt[\(part(1))]{\(part(0))}"
        case "mfenced":
            let open = element.hasAttr("open") ? try element.attr("open") : "("
            let close = element.hasAttr("close") ? try element.attr("close") : ")"
            return "\\left\(open)\(parts.joined(separator: ","))\\right\(close)"
        case "mtable":
            return "\\begin{matrix}\(parts.joined(separator: " \\\\ "))\\end{matrix}"
        case "mtr", "mlabeledtr": return parts.joined(separator: " & ")
        case "semantics": return part(0)
        case "annotation", "annotation-xml", "mphantom": return ""
        case "mspace": return " "
        default: return try parts.isEmpty ? symbols(element.text()) : parts.joined()
        }
    }

    /// Unicode symbols as TeX commands, which typeset with the math font's spacing.
    private static func symbols(_ text: String) -> String {
        text.map { character in
            table[character].map { $0.hasPrefix("\\") ? "\($0) " : $0 } ?? String(character)
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    private static let table: [Character: String] = [
        "α": "\\alpha", "β": "\\beta", "γ": "\\gamma", "δ": "\\delta", "ε": "\\epsilon",
        "θ": "\\theta", "λ": "\\lambda", "μ": "\\mu", "π": "\\pi", "ρ": "\\rho", "σ": "\\sigma",
        "τ": "\\tau", "φ": "\\phi", "χ": "\\chi", "ψ": "\\psi", "ω": "\\omega", "Δ": "\\Delta",
        "Σ": "\\Sigma", "Ω": "\\Omega", "∑": "\\sum", "∏": "\\prod", "∫": "\\int", "∂": "\\partial",
        "∞": "\\infty", "×": "\\times", "·": "\\cdot", "⋅": "\\cdot", "±": "\\pm", "≤": "\\leq",
        "≥": "\\geq", "≠": "\\neq", "≈": "\\approx", "→": "\\to", "∈": "\\in", "∇": "\\nabla",
        "−": "-", "\u{2061}": "", "\u{2062}": "",
    ]
}
