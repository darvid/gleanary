import AppKit
import SwiftUI

/// Observes scroll-wheel events without taking hit testing away from SwiftUI gestures.
struct MouseWheelZoom: NSViewRepresentable {
    let action: @MainActor (CGFloat, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.action = action
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView _: NSView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator: NSObject {
        weak var view: NSView?
        var action: @MainActor (CGFloat, CGPoint) -> Void
        private var monitor: Any?

        init(action: @escaping @MainActor (CGFloat, CGPoint) -> Void) {
            self.action = action
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent
                .addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let view, let window = view.window,
                          window.isKeyWindow else { return event }
                    let windowPoint = event.window == window
                        ? event.locationInWindow
                        : window.convertPoint(fromScreen: NSEvent.mouseLocation)
                    guard abs(event.scrollingDeltaY) > 0 else { return event }
                    let point = view.convert(windowPoint, from: nil)
                    guard view.bounds.contains(point) else { return event }
                    action(
                        event.scrollingDeltaY,
                        CGPoint(
                            x: point.x,
                            y: view.isFlipped ? point.y : view.bounds.height - point.y
                        )
                    )
                    return event
                }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
