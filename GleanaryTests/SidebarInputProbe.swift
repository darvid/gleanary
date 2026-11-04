import AppKit
import Foundation
@testable import Gleanary
import SwiftUI

/// Run via the existing isolated AppKit host with
/// GLEANARY_INPUT_PROBE_CLASS=GleanarySidebarInputProbe.
@objc(GleanarySidebarInputProbe) @MainActor final class SidebarInputProbe: NSObject {
    private struct Failure: Error { let reason: String }

    @objc static func start() {
        Task { @MainActor in
            do {
                try await run()
                print("LIBRARY INPUT PROBE PASS")
                exit(0)
            } catch {
                print("LIBRARY INPUT PROBE FAIL: \(error)")
                exit(1)
            }
        }
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        if !condition {
            throw Failure(reason: reason)
        }
    }

    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "synthetic.sqlite"))
        _ = try await store.open(seed: [MarkdownDocument(
            name: "Synthetic sidebar note",
            markdown: "Synthetic local evidence."
        )])
        let suite = "gleanary-sidebar-input-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite)
        else { throw Failure(reason: "No fixture preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LibraryPresentation.list.rawValue, forKey: "libraryPresentation")
        defaults.set(true, forKey: "starterCategoriesOffered")
        defaults.set(220, forKey: "sidebarWidth")
        let library = LibraryModel(store: store)
        library.ready = true
        let atlas = KnowledgeAtlasModel()
        let graph = LibraryGraphModel()
        defer { graph.stop() }
        let host = NSHostingView(rootView: ContentView(
            library: library,
            atlasModel: atlas,
            graphModel: graph
        )
        .defaultAppStorage(defaults).environment(\.scenePhase, .inactive))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.title = "Synthetic Library input verification"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        try require(
            window.isKeyWindow && NSApplication.shared.isActive,
            "Fixture window is not active/key"
        )
        try require(library.documentGrid.kindFilter == .all, "Initial filter not loaded")

        defaults.set(LibraryPresentation.map.rawValue, forKey: "libraryPresentation")
        try await Task.sleep(for: .milliseconds(400))
        try require(atlas.viewport.width > 0, "Map did not mount")
        atlas.zoom(
            by: 2.3,
            around: CGPoint(x: atlas.viewport.width / 2, y: atlas.viewport.height / 2)
        )
        atlas.pan(by: CGSize(width: 24, height: -16))
        let mapCamera = atlas.camera
        defaults.set(LibraryPresentation.graph.rawValue, forKey: "libraryPresentation")
        try await Task.sleep(for: .milliseconds(400))
        graph.includesConcepts = true
        graph.depth = 2
        graph.inspectorVisible = false
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline,
              !graph.request.includesConcepts || graph.request.depth != 2
              || graph.loading || graph.layingOut || graph.positions.isEmpty
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(
            !graph.positions.isEmpty && !graph.layingOut && !graph.loading,
            "Graph did not settle"
        )
        guard let zoom = GraphScaleInputProbe.accessibleFrame(in: host, label: "Zoom in") else {
            throw Failure(reason: "No accessible graph zoom control")
        }
        let initialScale = graph.camera?.scale ?? 0
        try await click(zoom, in: window)
        guard let graphCamera = graph.camera else { throw Failure(reason: "Graph has no camera") }
        try require(graphCamera.scale > initialScale, "Native graph Zoom in did not change camera")
        let positions = graph.positions
        defaults.set(LibraryPresentation.list.rawValue, forKey: "libraryPresentation")
        try await Task.sleep(for: .milliseconds(200))
        defaults.set(LibraryPresentation.map.rawValue, forKey: "libraryPresentation")
        try await Task.sleep(for: .milliseconds(400))
        try require(abs(atlas.camera.scale - mapCamera.scale) < 0.000001, "Map zoom reset")
        try require(abs(atlas.camera.offset.x - mapCamera.offset.x) < 0.000001, "Map pan reset")
        try require(
            abs(atlas.camera.offset.y - mapCamera.offset.y) < 0.000001,
            "Map vertical pan reset"
        )
        defaults.set(LibraryPresentation.graph.rawValue, forKey: "libraryPresentation")
        try await Task.sleep(for: .milliseconds(500))
        try require(graph.camera == graphCamera, "Graph camera reset on return")
        try require(graph.positions == positions, "Graph layout reset on return")
        try require(graph.includesConcepts && graph.depth == 2, "Graph options reset on return")
        try require(!graph.inspectorVisible, "Graph inspector visibility reset on return")

        defaults.set(LibraryKindFilter.notes.rawValue, forKey: "libraryKindFilter")
        let notesDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < notesDeadline,
              graph.request.kind != .notes || graph.loading || graph.layingOut
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(graph.request.kind == .notes && !graph.layingOut, "Notes graph did not load")
        guard let notesZoom = GraphScaleInputProbe.accessibleFrame(in: host, label: "Zoom in")
        else {
            throw Failure(reason: "No Notes graph zoom control")
        }
        try await click(notesZoom, in: window)
        try await click(notesZoom, in: window)
        let notesCamera = graph.camera
        try require(notesCamera != graphCamera, "Notes did not get an independent camera")
        defaults.set(LibraryKindFilter.all.rawValue, forKey: "libraryKindFilter")
        try await Task.sleep(for: .milliseconds(500))
        try require(graph.request.kind == .all, "Library graph did not return")
        try require(graph.camera == graphCamera, "Live canvas overwrote restored Library camera")
        try require(graph.positions == positions, "Live collection switch rearranged Library")
        defaults.set(LibraryKindFilter.notes.rawValue, forKey: "libraryKindFilter")
        try await Task.sleep(for: .milliseconds(500))
        try require(graph.camera == notesCamera, "Live canvas overwrote restored Notes camera")
    }

    private static func click(_ frame: CGRect, in window: NSWindow) async throws {
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
            else { throw Failure(reason: "Could not construct a native click") }
            NSApplication.shared.sendEvent(event)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(180))
    }
}
