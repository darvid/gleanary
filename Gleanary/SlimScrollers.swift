import AppKit
import ObjectiveC

/// Gives every scroller in the app AppKit's small size.
///
/// Neither SwiftUI nor `NSAppearance` has a setting for this, and SwiftUI makes its scrollers
/// privately, so the one place that sees them all is the moment each joins a window.
enum SlimScrollers {
    /// A legacy scroller's track at this size.
    static let width: CGFloat = 13

    @MainActor static func install() {
        let selector = #selector(NSView.viewDidMoveToWindow)
        guard let inherited = class_getInstanceMethod(NSScroller.self, selector) else { return }
        typealias ViewDidMoveToWindow = @convention(c) (NSScroller, Selector) -> Void
        let original = unsafeBitCast(
            method_getImplementation(inherited),
            to: ViewDidMoveToWindow.self
        )
        let slimmed: @convention(block) (NSScroller) -> Void = { scroller in
            original(scroller, selector)
            MainActor.assumeIsolated { scroller.controlSize = .small }
        }
        class_replaceMethod(
            NSScroller.self,
            selector,
            imp_implementationWithBlock(slimmed),
            method_getTypeEncoding(inherited)
        )
    }
}
