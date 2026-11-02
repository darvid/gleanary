import AppKit
@testable import Gleanary
import Testing

struct MermaidTests {
    @Test func onlyCompleteMermaidFencesAreDiagrams() {
        #expect(MermaidDiagram.source("```mermaid\nflowchart LR\n  A --> B\n```")
            == "flowchart LR\n  A --> B")
        #expect(MermaidDiagram.source("``` Mermaid \ngraph TD\nA-->B\n```") == "graph TD\nA-->B")
        #expect(MermaidDiagram.source("```swift\nlet a = 1\n```") == nil)
        #expect(MermaidDiagram.source("```mermaid\n\n```") == nil)
        #expect(MermaidDiagram.source("```mermaid\n```") == nil)
    }

    @Test func fencesStayOneBlockWithTheirBlankLines() {
        let blocks = MarkdownPreview.blocks(
            "Intro.\n\n```mermaid\nflowchart LR\n\n  A --> B\n```\n\nAfter."
        )
        #expect(blocks.count == 3)
        #expect(MermaidDiagram.source(blocks[1]) == "flowchart LR\n\n  A --> B")
    }

    @Test @MainActor func drawsDiagramsAndRejectsInvalidOnes() async throws {
        let renderer = MermaidRenderer()
        let style = MermaidRenderer.Style(dark: false, background: "#ffffff")
        let image = try await renderer.render(
            "flowchart LR\n  Capture --> Summarize --> File",
            style: style
        )
        #expect(image.size.width > image.size.height)
        #expect(image.size.width > 100)
        #expect(renderer.cached("flowchart LR\n  Capture --> Summarize --> File", style: style)
            != nil)
        let sequence = try await renderer.render(
            "sequenceDiagram\n  Reader->>Gleanary: Paste a link\n  Gleanary-->>Reader: Summary",
            style: MermaidRenderer.Style(dark: true, background: "#1e1e1e")
        )
        #expect(sequence.size.height > 50)
        await #expect(throws: (any Error).self) {
            try await renderer.render("flowchart LR\n  A -->", style: style)
        }
        // A failure leaves the page able to draw the next diagram.
        _ = try await renderer.render("graph TD\n  A --> B", style: style)
    }
}
