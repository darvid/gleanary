import Foundation
@testable import Gleanary
import Testing

struct EntityLinkTests {
    private let appleton = EntityLinkTarget(EntitySummary(
        id: "person:maggie-appleton", kind: .person, name: "Maggie Appleton", noteCount: 2,
        aliases: [(id: "person:appleton", name: "Appleton")]
    ))
    private let github = EntityLinkTarget(EntitySummary(
        id: "organization:github", kind: .organization, name: "GitHub", noteCount: 1
    ))

    @Test func linksRoundTripTheEntityAndItsName() throws {
        let url = try #require(EntityLink.url(
            id: "person:maggie appleton/x",
            name: "Maggie Appleton"
        ))
        let target = try #require(EntityLink.target(from: url))
        #expect(target.id == "person:maggie appleton/x")
        #expect(target.name == "Maggie Appleton")
        #expect(try EntityLink.target(from: #require(URL(string: "gleanary://note/abc"))) == nil)
        #expect(try EntityLink.target(from: #require(URL(string: "https://entity/abc"))) == nil)
    }

    @Test func namesAreTriedLongestFirstAndShortOnesSkipped() {
        #expect(appleton.names == ["Maggie Appleton", "Appleton"])
        let short = EntityLinkTarget(EntitySummary(
            id: "tool:ai", kind: .tool, name: "AI", noteCount: 1
        ))
        #expect(short.names.isEmpty)
    }

    @Test func onlyWholeWordsMatch() {
        #expect(EntityLinking.mention("GitHub", in: "GitHubber notes") == nil)
        #expect(EntityLinking.mention("GitHub", in: "at github next") != nil)
        #expect(EntityLinking.mention("Maggie Appleton", in: "Maggie Appleton’s practice") != nil)
    }

    @Test func eachEntityLinksOnlyInTheFirstBodyBlockThatMentionsIt() {
        let blocks = [
            "# Maggie Appleton at GitHub",
            "Maggie Appleton argues for speculative design.",
            "She joined GitHub Next. Appleton calls it fortune telling.",
            "```\nGitHub\n```",
        ]
        let mentions = EntityLinking.firstMentions(
            in: blocks, targets: [appleton, github], linkable: MarkdownPreview.linksEntities
        )
        // The heading and code block never link; each entity links once.
        #expect(mentions[0] == nil && mentions[3] == nil)
        #expect(mentions[1] == [appleton])
        #expect(mentions[2] == [github])
    }

    @Test func linkingMarksTheFirstMentionAndLeavesTheTextAlone() throws {
        var text = AttributedString("Maggie Appleton argues that Maggie Appleton is right.")
        EntityLinking.link(in: &text, targets: [appleton])
        let linked = text.runs.filter { $0.link != nil }
        #expect(linked.count == 1)
        let run = try #require(linked.first)
        #expect(String(text[run.range].characters) == "Maggie Appleton")
        #expect(text.runs.first?.link == EntityLink.url(id: appleton.id, name: appleton.name))
        #expect(String(text.characters) == "Maggie Appleton argues that Maggie Appleton is right.")
    }

    @Test func existingLinksAndCodeAreNeverRelinked() {
        var text = AttributedString("GitHub")
        text.link = URL(string: "https://github.com")
        EntityLinking.link(in: &text, targets: [github])
        #expect(text.runs.first?.link == URL(string: "https://github.com"))

        var code = AttributedString("GitHub")
        code.inlinePresentationIntent = .code
        EntityLinking.link(in: &code, targets: [github])
        #expect(code.runs.first?.link == nil)
    }
}
