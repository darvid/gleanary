import AppKit
import SwiftUI

/// Where the window is showing: Chat or a library scope, the Atlas region, and an item opened
/// from the Atlas.
struct NavigationLocation: Equatable {
    var chatting: Bool
    var scope: LibraryScope?
    var atlasFocus: AtlasNodeID
    var atlasItem: UUID?
    var automations = false
    var activity = false
    var kindFilter = LibraryKindFilter.all
}

/// Back and forward through visited locations, like a browser: visiting after going back drops
/// the forward entries.
struct NavigationHistory<Location: Equatable> {
    private(set) var entries: [Location] = []
    private(set) var index = 0
    var limit = 100

    var current: Location? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    var canGoBack: Bool {
        index > 0
    }

    var canGoForward: Bool {
        index + 1 < entries.count
    }

    mutating func visit(_ location: Location) {
        guard location != current else { return }
        if !entries.isEmpty {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(location)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        index = entries.count - 1
    }

    /// Updates where the current entry returns to without adding one.
    mutating func replace(_ location: Location) {
        guard current != nil else { visit(location); return }
        entries[index] = location
    }

    mutating func back() -> Location? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    mutating func forward() -> Location? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}

struct NavigationActions {
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void
}

private struct NavigationActionsKey: FocusedValueKey {
    typealias Value = NavigationActions
}

extension FocusedValues {
    var navigationActions: NavigationActions? {
        get { self[NavigationActionsKey.self] }
        set { self[NavigationActionsKey.self] = newValue }
    }
}

/// A mouse's back and forward buttons (buttons 4 and 5), anywhere in the window. SwiftUI
/// delivers no events for them.
struct MouseNavigationMonitor: NSViewRepresentable {
    let back: @MainActor () -> Void
    let forward: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.parent = self
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.parent = self
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var parent: MouseNavigationMonitor?
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent
                .addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                    self?.route(event) ?? event
                }
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window, event.window === window, let parent else {
                return event
            }
            switch event.buttonNumber {
            case 3: parent.back()
            case 4: parent.forward()
            default: return event
            }
            return nil
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
