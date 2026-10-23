import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

@Suite(.serialized) struct NoteWorkspaceLayoutTests {
    @Test @MainActor func nativeWorkspaceSurfacesUseCanonicalRecordsWithoutMutation() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let person = try await fixture.note("Taylor Example", type: .person)
        let project = try await fixture.note("Synthetic launch", type: .project)
        let original = try await fixture.note(
            "Synthetic planning meeting",
            type: .meeting,
            body: "## Actions\n\n- [ ] Keep this local"
        )
        let note = try await fixture.store.save(original, profile: NoteProfile(
            type: .meeting,
            values: ["date": "2026-10-22"],
            links: [
                "project": [project
                    .id],
                "participants": [person
                    .id],
            ]
        ))
        let day = try #require(WorkspaceDay(rawValue: "2026-10-22"))
        _ = try await fixture.store.saveWorkspaceTask(
            WorkspaceTask(
                title: "Send the revised synthetic proposal to the review group",
                due: day,
                planned: day,
                projectID: project.id,
                originID: note.id
            ),
            placingIn: note.id
        )
        _ = try await fixture.store.saveWorkspaceTask(
            WorkspaceTask(title: "Check the synthetic decision log", originID: note.id),
            placingIn: note.id
        )
        let before = try fixture.counts()
        let workspace = NoteWorkspaceModel(store: fixture.store)
        let emptyFixture = try await WorkspaceFixture(); defer { emptyFixture.clean() }
        let emptyWorkspace = NoteWorkspaceModel(store: emptyFixture.store)
        for dark in [false, true] {
            for width in [320.0, 680.0] {
                try await render(
                    NoteWorkspaceSection(document: note, workspace: workspace, openNote: { _ in }),
                    width: width,
                    height: 720,
                    dark: dark,
                    name: "note-\(Int(width))"
                )
            }
            try await render(
                WorkspaceTasksView(workspace: workspace),
                width: 760,
                height: 560,
                dark: dark,
                name: "tasks"
            )
            try await render(
                WorkspaceTasksView(workspace: emptyWorkspace),
                width: 760,
                height: 560,
                dark: dark,
                name: "tasks-empty"
            )
            try await render(
                NoteTemplatesView(workspace: workspace, use: { _ in }),
                width: 760,
                height: 560,
                dark: dark,
                name: "templates"
            )
            let task = try #require(try await fixture.store.workspaceTasks().tasks.first)
            try await render(
                WorkspaceTaskEditor(workspace: workspace, task: task),
                width: 560,
                height: 440,
                dark: dark,
                name: "task-editor"
            )
        }
        #expect(try fixture.counts() == before)
    }

    @Test @MainActor func nativeQuickEntrySavesOnReturnAndStaysReadyForTheNextTask() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let workspace = NoteWorkspaceModel(store: fixture.store)
        let host = NSHostingView(rootView: WorkspaceTasksView(workspace: workspace).frame(
            width: 760,
            height: 560
        ))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        let field = try #require(entryField(in: host))
        #expect(field.isEnabled)
        #expect(try await fixture.store.workspaceTasks().tasks.isEmpty)
        #expect(window.makeFirstResponder(field))
        for (index, title) in ["First synthetic action", "Second synthetic action"].enumerated() {
            let input = try #require(window.firstResponder as? NSTextView)
            input.insertText(title, replacementRange: input.selectedRange())
            #expect(try await fixture.store.workspaceTasks().tasks.count == index)
            input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            for _ in 0 ..< 50 {
                if try await fixture.store.workspaceTasks().tasks.count == index + 1 {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(100))
            let saved = try await fixture.store.workspaceTasks().tasks
            #expect(saved.count == index + 1 && saved.contains { $0.title == title })
            let current = try #require(entryField(in: host))
            #expect(current.stringValue.isEmpty)
            #expect(current.currentEditor() === window.firstResponder)
        }
    }

    @MainActor private func entryField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable,
           field.placeholderString == "Add a task…"
        {
            return field
        }
        return view.subviews.lazy.compactMap { entryField(in: $0) }.first
    }

    @MainActor private func render(
        _ content: some View,
        width: Double,
        height: Double,
        dark: Bool,
        name: String
    ) async throws {
        let host = NSHostingView(rootView: content
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(20).frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.width <= width + 1)
        #expect(host.frame.height <= height + 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if name.hasPrefix("tasks") {
            let scale = Double(bitmap.pixelsWide) / width
            let outside = try #require(bitmap.colorAt(x: Int(10 * scale), y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB))
            let inside = try #require(bitmap.colorAt(x: Int(60 * scale), y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB))
            #expect(abs(outside.redComponent - inside.redComponent) < 0.01)
            #expect(abs(outside.greenComponent - inside.greenComponent) < 0.01)
            #expect(abs(outside.blueComponent - inside.blueComponent) < 0.01)
        }
        if let directory = ProcessInfo.processInfo.environment["GLEANARY_WORKSPACE_SCREENSHOTS"] {
            let root = URL(filePath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: root.appending(path: name + (dark ? "-dark.png" : "-light.png")))
        }
    }
}
