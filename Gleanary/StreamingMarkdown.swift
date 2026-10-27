import SwiftUI

/// Reveals a reply at a steady pace however the provider delivers it, fading in the newest
/// glyphs. Text that was already complete when the view appeared shows at once.
struct StreamingMarkdown: View {
    let markdown: String
    /// True while the provider may still extend the text. Whether it is true when the view
    /// appears decides if the text is revealed at all.
    let streaming: Bool
    @State private var pacer: RevealPacer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ markdown: String, streaming: Bool) {
        self.markdown = markdown
        self.streaming = streaming
        _pacer = State(initialValue: streaming ? RevealPacer() : nil)
    }

    var body: some View {
        Group {
            if let pacer, !reduceMotion {
                let shown = min(markdown.count, Int(pacer.frontier))
                MarkdownPreview(
                    markdown: String(markdown.prefix(shown)),
                    trailingFade: TrailingFade(
                        length: RevealPacer.fadeLength,
                        overshoot: pacer.frontier - Double(shown)
                    )
                )
                .accessibilityAddTraits(.updatesFrequently)
            } else {
                MarkdownPreview(markdown: markdown)
            }
        }
        .onChange(of: markdown.count, initial: true) { _, count in pacer?.count = count }
        .onChange(of: streaming, initial: true) { _, streaming in pacer?.streaming = streaming }
        .task {
            guard let pacer else { return }
            await pacer.run()
            guard !Task.isCancelled else { return }
            self.pacer = nil
            // Announce the finished reply once instead of every streamed word.
            AccessibilityNotification.Announcement(markdown).post()
        }
    }
}

/// Moves a reveal frontier toward the end of the text, faster as the backlog grows, so bursts
/// from the network become a smooth stream and the reveal never falls far behind.
@MainActor @Observable
final class RevealPacer {
    /// Glyphs still fading in behind the frontier.
    static let fadeLength = 18.0
    private static let minimumRate = 90.0
    /// Fraction of the backlog left after one 60 Hz frame.
    private static let backlogDecay = 0.9

    private(set) var frontier = 0.0
    @ObservationIgnored var count = 0
    @ObservationIgnored var streaming = true

    func run() async {
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = clock.now
            let elapsed = min(0.1, (now - last) / .seconds(1))
            last = now
            // Overshooting the end by the fade length leaves the last glyphs fully opaque.
            let backlog = Double(count) + Self.fadeLength - frontier
            guard backlog > 0 else {
                if !streaming {
                    return
                }
                continue
            }
            let eased = backlog * (1 - pow(Self.backlogDecay, elapsed * 60))
            frontier += min(backlog, max(Self.minimumRate * elapsed, eased))
        }
    }
}

/// Fades the last `length` glyphs of a text in, as if each had just appeared. `overshoot` is
/// how far the reveal has moved past the final glyph, which lets the tail settle to opaque.
struct TrailingFade: TextRenderer, Equatable {
    var length: Double
    var overshoot: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let total = layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        var index = 0
        for line in layout {
            let glyphs = line.reduce(0) { $0 + $1.count }
            // Lines wholly behind the fade draw in one call.
            if Double(total - index - glyphs) + overshoot >= length {
                context.draw(line)
                index += glyphs
                continue
            }
            for run in line {
                for slice in run {
                    let distance = Double(total - 1 - index) + overshoot
                    var glyph = context
                    glyph.opacity = min(1, max(0, (distance + 1) / (length + 1)))
                    glyph.draw(slice)
                    index += 1
                }
            }
        }
    }
}
