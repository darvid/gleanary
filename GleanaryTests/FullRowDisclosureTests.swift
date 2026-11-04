import AppKit
@testable import Gleanary
import SwiftUI
import Testing

/// Real clicks reach whichever window is under them, and suites run in parallel, so these and the
/// other click-driven tests disturb each other. Run them alone:
/// `GLEANARY_CLICK_TESTS=1 swift test --filter FullRowDisclosureTests`
@MainActor @Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GLEANARY_CLICK_TESTS"] != nil)
) struct FullRowDisclosureTests {
    private struct Row: View {
        @Binding var expanded: Bool

        var body: some View {
            VStack(alignment: .leading) {
                DisclosureGroup(isExpanded: $expanded) {
                    Text("Details")
                } label: {
                    // Built like the research audit's rows, in a selectable feed like Chat's.
                    HStack(spacing: 8) {
                        Circle().frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Capture and selection")
                            Text("3 quotes from 2 items").font(.caption)
                        }
                        Spacer(minLength: 8)
                        Text("Supported")
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
            }
            .frame(width: 400, height: 120)
            .disclosureGroupStyle(FullRowDisclosureStyle())
            .textSelection(.enabled)
        }
    }

    /// A row with a control of its own, like Filing suggestions' Accept All.
    private struct RowWithButton: View {
        @Binding var expanded: Bool
        @Binding var pressed: Bool

        var body: some View {
            VStack(alignment: .leading) {
                DisclosureGroup(isExpanded: $expanded) {
                    Text("Details")
                } label: {
                    HStack {
                        Text("Engineering")
                        Spacer()
                        Button("Accept All") { pressed = true }.buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .frame(width: 400, height: 120)
            .disclosureGroupStyle(FullRowDisclosureStyle())
        }
    }

    /// Clicks a point on the row, measured from the window's top leading corner.
    private func click(_ x: CGFloat, in window: NSWindow) async throws {
        let point = NSPoint(x: x, y: window.frame.height - 12)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    @Test(arguments: [6.0, 60.0, 200.0, 370.0])
    func aClickAnywhereOnTheRowOpensIt(x: Double) async throws {
        var expanded = false
        let binding = Binding { expanded } set: { expanded = $0 }
        let host = NSHostingView(rootView: Row(expanded: binding))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        // Well away from the origin, where other suites' windows take clicks at the same time.
        window.setFrameOrigin(NSPoint(x: 6000, y: 6000))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try await click(x, in: window)
        #expect(expanded, "clicking \(x)pt along the row")
    }

    @Test func aControlInTheRowKeepsItsClick() async throws {
        var expanded = false
        var pressed = false
        let host = NSHostingView(rootView: RowWithButton(
            expanded: Binding { expanded } set: { expanded = $0 },
            pressed: Binding { pressed } set: { pressed = $0 }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        // Well away from the origin, where other suites' windows take clicks at the same time.
        window.setFrameOrigin(NSPoint(x: 6000, y: 6000))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try await click(370, in: window)
        #expect(pressed)
        #expect(!expanded)
    }
}
