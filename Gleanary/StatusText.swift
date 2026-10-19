import SwiftUI

/// Shared motion for text that changes while it's on screen, so every status line and counter
/// moves the same way.
extension View {
    /// Status wording that changes step to step cross-fades briefly, as system status text does.
    /// A fade is also what Reduce Motion asks for, so it needs no separate path.
    func fadesOnChange(_ value: some Equatable) -> some View {
        contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: value)
    }

    /// Counts roll to their new digits, like Apple's own counters.
    func countsOnChange(_ value: some Equatable) -> some View {
        contentTransition(.numericText())
            .animation(.snappy(duration: 0.25), value: value)
    }
}

/// Shared working feedback for the Chat sidebar and composer, steady with Reduce Motion.
struct ChatWorkingIndicator: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(color.opacity(0.85))
            .symbolEffect(
                .pulse,
                options: .repeating.speed(0.6),
                isActive: !reduceMotion && scenePhase == .active
            )
            .frame(width: 14, height: 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A task's progress line. A stage with a count ("Extracting 12 of 37", or "Fetching 2 of 5:
/// example.com") keeps its wording still and rolls the count; the detail after it, and any other
/// change of wording, cross-fades.
struct StageProgressText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        if let match = text.wholeMatch(of: /(.*?\S)\s+(\d+ of \d+)(.*)/) {
            let stage = String(match.1)
            let count = String(match.2)
            let detail = String(match.3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(stage).fadesOnChange(stage)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(count).monospacedDigit().countsOnChange(count)
                    if !detail.isEmpty {
                        Text(detail).lineLimit(1).fadesOnChange(detail)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(text).fadesOnChange(text)
        }
    }
}
