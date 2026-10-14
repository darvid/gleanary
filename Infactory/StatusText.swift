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
