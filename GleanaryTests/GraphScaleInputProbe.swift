import AppKit
import Foundation
@testable import Gleanary
import SwiftUI

/// Loaded by scripts/graph-input-probe.swift, outside SwiftPM's background test helper.
@objc(GleanaryGraphInputProbe) @MainActor final class GraphScaleInputProbe: NSObject {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    @objc static func start() {
        Task { @MainActor in
            do {
                for count in [5000, 10000] {
                    try await run(count: count)
                }
                print("GRAPH INPUT PROBE PASS")
                exit(0)
            } catch {
                print("GRAPH INPUT PROBE FAIL: \(error)")
                exit(1)
            }
        }
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition {
            throw Failure(description: reason)
        }
    }

    private static func run(count: Int) async throws {
        let fixture = try await GraphScaleFixture(count: count)
        defer { fixture.clean() }
        let graph = LibraryGraphModel()
        graph.reduceMotion = true
        defer { graph.stop() }
        await graph.load(from: fixture.store, request: LibraryGraphRequest())
        let layoutDeadline = ContinuousClock.now + .seconds(10)
        while graph.layingOut,
              ContinuousClock.now < layoutDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!graph.layingOut, "Layout exceeded 10 seconds")
        let size = CGSize(width: 1080, height: 800)
        let camera = Binding<GraphCamera?>(get: { graph.camera }, set: { graph.camera = $0 })
        let host = NSHostingView(rootView: KnowledgeGraphView(
            graph: graph,
            openNote: { _ in },
            camera: camera
        ))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.title = "Synthetic Gleanary graph verification: \(count) items"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        try require(
            NSApplication.shared.isActive && window.isKeyWindow,
            "The synthetic AppKit host could not become active/key"
        )
        guard let initialCamera = graph.camera else { throw Failure(description: "No camera") }
        let viewport = GraphViewport(size: size, scale: initialCamera.scale, pan: initialCamera.pan)
        let center = viewport.world(CGPoint(x: size.width / 2, y: size.height / 2))
        guard let node = graph.geometry.nearestNode(to: center, radius: 1000),
              let world = graph.geometry.point(for: node.id)
        else { throw Failure(description: "No center node") }
        let point = viewport.screen(world)
        let start = ContinuousClock.now
        try mouse(.leftMouseDown, point: point, host: host, window: window)
        try await Task.sleep(for: .milliseconds(10))
        try mouse(.leftMouseUp, point: point, host: host, window: window)
        let deadline = ContinuousClock.now + .milliseconds(150)
        while graph.selectedID != node.id,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(2))
        }
        try require(graph.selectedID == node.id, "Native click did not select the indexed node")
        let selectTime = start.duration(to: .now)
        let positions = graph.positions
        guard let empty = (0 ..< 20).map({ CGPoint(x: 50 + Double($0) * 45, y: 80) })
            .first(where: { graph.geometry.nearestNode(
                to: viewport.world($0),
                radius: 24 / viewport.scale
            ) == nil })
        else { throw Failure(description: "No empty pan target") }
        try mouse(.leftMouseDown, point: empty, host: host, window: window)
        try await Task.sleep(for: .milliseconds(10))
        let panStart = ContinuousClock.now
        try mouse(
            .leftMouseDragged,
            point: CGPoint(x: empty.x + 80, y: empty.y + 50),
            host: host,
            window: window
        )
        let panDeadline = ContinuousClock.now + .milliseconds(150)
        while graph.camera == initialCamera, ContinuousClock.now < panDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let panTime = panStart.duration(to: .now)
        try require(graph.camera != initialCamera, "Native drag did not pan before release")
        try mouse(
            .leftMouseUp,
            point: CGPoint(x: empty.x + 80, y: empty.y + 50),
            host: host,
            window: window
        )
        try await Task.sleep(for: .milliseconds(20))
        let beforeZoom = graph.camera?.scale ?? 0
        guard let zoomFrame = accessibleFrame(in: host, label: "Zoom in"), zoomFrame.width > 0,
              zoomFrame.height > 0
        else {
            throw Failure(description: "No accessible Zoom in control frame")
        }
        let zoomStart = ContinuousClock.now
        let zoomPoint = window.convertPoint(fromScreen: CGPoint(
            x: zoomFrame.midX,
            y: zoomFrame.midY
        ))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: zoomPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else {
                throw Failure(description: "Cannot construct zoom click")
            }
            NSApplication.shared.postEvent(event, atStart: false)
        }
        let zoomDeadline = ContinuousClock.now + .milliseconds(150)
        while graph.camera?.scale == beforeZoom, ContinuousClock.now < zoomDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let zoomTime = zoomStart.duration(to: .now)
        try require(
            (graph.camera?.scale ?? 0) > beforeZoom,
            "Native zoom did not change the camera"
        )
        try require(graph.positions == positions, "Pan/zoom changed the layout")
        try require(graph.selectedID == node.id, "Pan/zoom changed selection")
        print(
            "GRAPH INPUT \(count): click \(selectTime), drag-to-camera \(panTime), zoom \(zoomTime); \(graph.snapshot.edges.count) edges"
        )
        try require(
            selectTime < .milliseconds(150) && panTime < .milliseconds(150) && zoomTime <
                .milliseconds(150),
            "Input observation exceeded 150 ms"
        )
    }

    private static func mouse(
        _ type: NSEvent.EventType,
        point: CGPoint,
        host: NSView,
        window: NSWindow
    ) throws {
        let local = host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: host.convert(local, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
        else { throw Failure(description: "Cannot construct native mouse event") }
        NSApplication.shared.sendEvent(event)
    }

    private static func accessibleFrame(in root: NSView, label: String) -> CGRect? {
        var pending: [Any] = [root]
        var visited = Set<ObjectIdentifier>()
        while let value = pending.popLast() {
            guard visited.insert(ObjectIdentifier(value as AnyObject)).inserted else { continue }
            if let view = value as? NSView {
                if view.accessibilityLabel() == label || view.accessibilityTitle() == label {
                    return view.accessibilityFrame()
                }
                pending += view.accessibilityChildren() ?? []
                pending += view.subviews
            } else if let element = value as? NSAccessibilityElement {
                if element.accessibilityLabel() == label || element.accessibilityTitle() == label {
                    return element.accessibilityFrame()
                }
                if element.accessibilityLabel() != "Knowledge graph" {
                    pending += element.accessibilityChildren() ?? []
                }
            } else if let element = value as? any NSAccessibilityProtocol {
                if element.accessibilityLabel() == label || element.accessibilityTitle() == label {
                    return element.accessibilityFrame()
                }
                if element.accessibilityLabel() != "Knowledge graph" {
                    pending += element.accessibilityChildren() ?? []
                }
            }
        }
        return nil
    }
}
