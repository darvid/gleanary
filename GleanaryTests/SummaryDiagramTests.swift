@testable import Gleanary
import Testing

struct SummaryDiagramTests {
    private let evidence = SummaryEvidence(
        "The client sends a request. The server checks the token. Valid tokens get a reply."
    )

    private func proposal(
        _ kind: SummaryDiagramProposal.Kind = .sequence,
        nodes: [(String, String)] = [("c", "Client"), ("s", "Server")],
        links: [(String, String, String?)] = [("c", "s", "Request"), ("s", "c", "Reply")],
        ids: [String]? = nil
    ) -> SummaryDiagramProposal {
        let ids = ids ?? [evidence.items[0].id]
        return SummaryDiagramProposal(
            kind: kind,
            nodes: nodes.map { .init(id: $0.0, label: $0.1) },
            links: links.map { .init(from: $0.0, to: $0.1, label: $0.2, evidenceIDs: ids) }
        )
    }

    @Test func anchoredDiagramsWriteTheirOwnMermaid() throws {
        let diagram = try #require(proposal().anchored(in: evidence))
        #expect(diagram.mermaid == """
        sequenceDiagram
          participant p0 as Client
          participant p1 as Server
          p0->>p1: Request
          p1->>p0: Reply
        """)
        #expect(diagram.claims.map(\.text) == [
            "“Client” sends “Request” to “Server”.", "“Server” sends “Reply” to “Client”.",
        ])
        #expect(diagram.links[0].quotes == ["The client sends a request."])
    }

    @Test func diagramsThatBreakARuleAreLeftOut() {
        // Unknown node, a node no link uses, an unlabelled message, unknown evidence, a
        // self-link, a single link and duplicate labels.
        #expect(proposal(links: [("c", "x", "Request"), ("s", "c", "Reply")])
            .anchored(in: evidence) == nil)
        #expect(proposal(nodes: [("c", "Client"), ("s", "Server"), ("d", "Database")])
            .anchored(in: evidence) == nil)
        #expect(proposal(links: [("c", "s", nil), ("s", "c", "Reply")]).anchored(in: evidence)
            == nil)
        #expect(proposal(ids: ["E999"]).anchored(in: evidence) == nil)
        #expect(proposal(.flowchart, links: [("c", "c", nil), ("c", "s", nil)])
            .anchored(in: evidence) == nil)
        #expect(proposal(links: [("c", "s", "Request")]).anchored(in: evidence) == nil)
        #expect(proposal(nodes: [("c", "Client"), ("s", "Client")]).anchored(in: evidence) == nil)
        #expect(proposal(.flowchart, links: [("c", "s", nil), ("s", "c", "")])
            .anchored(in: evidence) != nil)
    }

    @Test func labelsCantBreakOutOfMermaidSyntax() {
        #expect(SummaryDiagram.escaped(#"A "quoted"; 50% <b>|x|</b> #1 `code`"#)
            == "A #quot;quoted#quot;#59; 50#37; #lt;b#gt;#124;x#124;#lt;/b#gt; #35;1 #96;code#96;")
    }

    @Test @MainActor func escapedLabelsStillDraw() async throws {
        let labels = [#"Check "token"; 50%"#, "<script>|end|", "#1 `retry`"]
        for kind in [SummaryDiagramProposal.Kind.flowchart, .sequence] {
            let diagram = try #require(proposal(
                kind,
                nodes: [("a", labels[0]), ("b", labels[1]), ("c", labels[2])],
                links: [("a", "b", "end"), ("b", "c", "graph TD")]
            ).anchored(in: evidence))
            let image = try await MermaidRenderer().render(
                diagram.mermaid, style: .init(dark: false, background: "#ffffff")
            )
            #expect(image.size.width > 50)
        }
    }

    @Test func summariesPutTheDiagramAfterTheOverview() throws {
        let quote = "The client sends a request."
        let draft = try SummaryDraft(
            overview: .init(text: "Clients ask; servers check.", quotes: [quote]),
            takeaways: [.init(text: "Valid tokens get a reply.", quotes: [quote])],
            diagram: #require(proposal().anchored(in: evidence))
        )
        let markdown = try draft.markdown(source: evidence.items.map(\.text).joined(separator: " "))
        #expect(markdown.hasPrefix("Clients ask; servers check.\n\n```mermaid\nsequenceDiagram\n"))
        #expect(markdown.hasSuffix("```\n\n## Key takeaways\n\n- Valid tokens get a reply."))
        #expect(MarkdownPreview.blocks(markdown).compactMap(MermaidDiagram.source).count == 1)
    }
}
