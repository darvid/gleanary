import AppKit

/// Gleanary › About Gleanary: the standard About panel, with the tagline, the open-source
/// projects Gleanary builds on, and its license under the name and version.
@MainActor enum AboutPanel {
    static let acknowledgements: [(name: String, url: String)] = [
        ("GRDB.swift", "https://github.com/groue/GRDB.swift"),
        ("Grape", "https://github.com/SwiftGraphs/Grape"),
        ("SwiftSoup", "https://github.com/scinfu/SwiftSoup"),
        ("Swift Markdown Engine", "https://github.com/nodes-app/swift-markdown-engine"),
        ("Swift YouTube Metadata", "https://github.com/arraypress/swift-youtube-metadata"),
        ("YouTubeKit", "https://github.com/alexeichhorn/YouTubeKit"),
    ]

    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits()]
        // The build number matches the version, so AppKit would show "0.1.0 (0.1.0)".
        let info = Bundle.main.infoDictionary
        if info?["CFBundleVersion"] as? String == info?["CFBundleShortVersionString"] as? String {
            options[.version] = ""
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate()
    }

    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        func append(_ string: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            text.append(NSAttributedString(
                string: string, attributes: base.merging(extra) { $1 }
            ))
        }

        append("A personal knowledge library you can talk to.\n", [
            .foregroundColor: NSColor.labelColor,
        ])
        append("Built with ")
        for (index, project) in acknowledgements.enumerated() {
            if index > 0 {
                append(index == acknowledgements.count - 1 ? " and " : ", ")
            }
            // Non-breaking spaces keep each linked name on one line.
            append(
                project.name.replacingOccurrences(of: " ", with: "\u{00A0}"),
                [.link: URL(string: project.url) as Any]
            )
        }
        append(".\n")
        append("Released under the MIT License.")
        return text
    }
}
