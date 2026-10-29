import AppKit
@testable import Gleanary
import Testing

@MainActor struct MathMarkdownTests {
    private func extracted(_ text: String) -> (String, [String]) {
        let (output, formulas) = MathMarkdown.extractingInline(text)
        // Placeholders print as their formula so expectations read like the source.
        let readable = output.map { character in
            MathMarkdown.formula(at: character, in: formulas).map { "⟨\($0.latex)⟩" }
                ?? String(character)
        }.joined()
        return (readable, formulas.map(\.latex))
    }

    @Test func inlineFormulasAreTakenOutBeforeMarkdownReadsThem() {
        #expect(extracted("Energy is $E = mc^2$ and \\(a_i * b_i\\).").0
            == "Energy is ⟨E = mc^2⟩ and ⟨a_i * b_i⟩.")
        #expect(extracted("**Bold $x_1$ text**").0 == "**Bold ⟨x_1⟩ text**")
        #expect(extracted("Inline $$\\sum_i x_i$$ display").1 == ["\\sum_i x_i"])
    }

    @Test func dollarsThatAreNotMathStayText() {
        #expect(extracted("It costs $5 and $10 today.").1.isEmpty)
        #expect(extracted("Between $5 and $6, roughly").1.isEmpty)
        #expect(extracted("A \\$x\\$ escape").1.isEmpty)
        #expect(extracted("Code `$x$` keeps dollars").1.isEmpty)
        #expect(extracted("$ x $ needs no spaces").1.isEmpty)
        #expect(extracted("Open $x\n\nnever closed$").1.isEmpty)
    }

    @Test func displayFormulasAreBlocksOfTheirOwn() {
        #expect(MathMarkdown.displayFormula("$$\n\\int_0^1 x\\,dx\n$$") == "\\int_0^1 x\\,dx")
        #expect(MathMarkdown.displayFormula("\\[ a^2 + b^2 \\]") == "a^2 + b^2")
        #expect(MathMarkdown.displayFormula("```math\nx = 1\n```") == "x = 1")
        #expect(MathMarkdown.displayFormula("$$a$$ and $$b$$") == nil)
        #expect(MathMarkdown.displayFormula("Plain text") == nil)

        #expect(MarkdownPreview.blocks("Before\n$$\nx = 1\n\ny = 2\n$$\nAfter") == [
            "Before", "$$\nx = 1\n\ny = 2\n$$", "After",
        ])
        #expect(MarkdownPreview.blocks("Text\n$$x^2$$\nMore") == ["Text", "$$x^2$$", "More"])
    }

    @Test func formulasTypesetAndLinkedTextAttachesThem() throws {
        _ = NSApplication.shared
        let formula = MathMarkdown.Formula(latex: "\\frac{a}{b}", display: false)
        let rendered = try #require(MathMarkdown.render(formula, size: 14, dark: false))
        #expect(rendered.size.width > 0 && rendered.size.height > 0)

        let (text, formulas) = MathMarkdown
            .extractingInline("See [this](https://example.org) $x^2$")
        let content = NSMutableAttributedString(string: text)
        MathMarkdown.attach(formulas, in: content, size: 14, dark: false)
        #expect(content.containsAttachments(in: NSRange(location: 0, length: content.length)))
    }
}

struct SummaryFormulaTests {
    private func point(_ text: String, quoting quote: String) -> SummaryDraft.Point {
        SummaryDraft.Point(text: text, quotes: [quote], section: nil)
    }

    @Test func aPointMayOnlyWriteFormulasItsQuotationsContain() throws {
        let quote = "The loss is $L = \\sum_i (y_i - \\hat{y}_i)^2$ over the batch."
        #expect(point("The loss is $L=\\sum_i (y_i-\\hat{y}_i)^2$.", quoting: quote)
            .unquotedFormulas.isEmpty)
        #expect(point("The loss is $L = \\sum_i |y_i|$.", quoting: quote)
            .unquotedFormulas == ["L = \\sum_i |y_i|"])

        let draft = SummaryDraft(
            overview: point("A squared loss, $L = \\sum_i (y_i - \\hat{y}_i)^2$.", quoting: quote),
            takeaways: [point("It also uses $\\lambda \\|w\\|^2$.", quoting: quote)]
        )
        let applied = try SummaryVerification(supported: [true, true]).applied(to: draft)
        #expect(applied.takeaways.isEmpty)

        let invented = SummaryDraft(overview: point("Uses $e^x$.", quoting: quote), takeaways: [])
        #expect(throws: LinkSummaryError.unsupportedSummary) {
            try SummaryVerification(supported: [true]).applied(to: invented)
        }
    }

    @Test func evidenceKeepsADisplayFormulaInOneExcerpt() {
        let evidence = SummaryEvidence("The update is $$w. Then w = w - \\eta g.$$ It converges.")
        #expect(evidence.items.contains { $0.text.contains("$$w. Then w = w - \\eta g.$$") })
    }

    @Test func summaryPromptsAskForFormulasAsWritten() {
        let prompt = AppleLinkSummarizer.summaryPrompt(
            context: "Title: Fixture", evidence: SummaryEvidence("A fixture sentence here.")
        )
        #expect(prompt.contains("TeX between $ signs, copied exactly"))
        #expect(AppleLinkSummarizer.verificationInstructions
            .contains("A formula is supported only"))
    }
}
