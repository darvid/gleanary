import AppKit
import Foundation
@testable import Gleanary
import SwiftUI
import Testing

@Suite(.serialized) struct ConversationPresentationTests {
    private func message(
        _ author: String, task: UUID? = nil, text: String = "Synthetic reply",
        references: [UUID] = []
    )
        -> ConversationMessage
    {
        ConversationMessage(
            sequence: 1, id: UUID(), author: author, text: text, references: references,
            taskID: task, createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    @Test func groupsSpecialistsWithTheirCoordinatingReplyWithoutChangingHistory() throws {
        let task = UUID()
        let messages = [message("user", task: task), message("researcher", task: task),
                        message("librarian", task: task), message("assistant", task: task)]
        let entries = ConversationFeedEntry.entries(in: messages)
        #expect(entries.count == 2)
        #expect(entries.flatMap(\.messages).map(\.id) == messages.map(\.id))
        #expect(entries.first?.userMessage?.id == messages[0].id)
        let response = try #require(entries.last)
        #expect(response.replies(working: false).map(\.id) == [messages[3].id])
        #expect(response.activity(working: false).map(\.id) == [messages[1].id, messages[2].id])
        #expect(response.id == task)
    }

    @Test func neverGroupsAcrossUsersTasksOrUnassociatedMessages() {
        let first = UUID(), second = UUID()
        let messages = [message("researcher", task: first), message("user", task: second),
                        message("assistant", task: first), message("writer", task: second),
                        message("researcher"), message("assistant")]
        #expect(ConversationFeedEntry.entries(in: messages).count == messages.count)
    }

    @Test func preservesTheOnlyAnswerForLegacyAndDirectSpecialistConversations() throws {
        let task = UUID()
        let messages = [message("researcher", task: task), message("writer", task: task)]
        let entry = try #require(ConversationFeedEntry.entries(in: messages).first)
        #expect(entry.replies(working: false).map(\.id) == [messages[1].id])
        #expect(entry.activity(working: false).map(\.id) == [messages[0].id])
        #expect(entry.replies(working: true).isEmpty)
        #expect(entry.activity(working: true).count == 2)
    }

    @Test func keepsUnknownAuthorsVisibleRatherThanTreatingThemAsSpecialistActivity() throws {
        let entry = try #require(ConversationFeedEntry.entries(in: [message("system")]).first)
        #expect(entry.replies(working: true).count == 1)
        #expect(entry.activity(working: true).isEmpty)
    }

    @Test func streamingReplyKeepsItsGroupIdentityAndAllOriginalReferences() throws {
        let task = UUID()
        let source = UUID(), artifact = UUID()
        let research = message("researcher", task: task, references: [artifact, source])
        let initial = try #require(ConversationFeedEntry.entries(in: [research]).first)
        let reply = message("assistant", task: task, references: [artifact])
        let updated = try #require(ConversationFeedEntry.entries(in: [research, reply]).first)
        #expect(initial.id == updated.id)
        #expect(updated.messages.map(\.id) == [research.id, reply.id])
        #expect(updated.referenceIDs == [artifact, source])
        #expect(updated.messages[0].references == [artifact, source])
        #expect(updated.messages[1].references == [artifact])
        #expect(updated.replies(working: true).map(\.id) == [reply.id])
    }

    @Test func draftedReplyHasAResponsePlaceThatKeepsItsIdentity() {
        let task = UUID(), other = UUID()
        let request = message("user", task: task)
        let later = message("user", task: other)
        let drafting = ConversationFeedEntry.entries(in: [request, later], drafting: [task])
        #expect(drafting.map(\.id) == [request.id, task, later.id])
        #expect(drafting[1].messages.isEmpty)
        #expect(drafting[1].taskID == task)
        let reply = message("assistant", task: task)
        let posted = ConversationFeedEntry.entries(in: [request, reply], drafting: [task])
        #expect(posted.map(\.id) == [request.id, task])
        #expect(posted[1].messages.map(\.id) == [reply.id])
    }

    @Test @MainActor func revealPacerSettlesPastTheEndOnceStreamingStops() async {
        let pacer = RevealPacer()
        pacer.count = 12
        pacer.streaming = false
        await pacer.run()
        #expect(pacer.frontier >= 12 + RevealPacer.fadeLength)
    }

    @Test @MainActor func nativeActivityExpandsAndKeepsResultsAndReviewVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentStore(url: root.appending(path: "library.sqlite"))
        _ = try await store.open()
        let task = try await store.beginConversation(
            "Find synthetic design references",
            owner: .assistant
        )
        let note = try await store.saveResearch(
            "Synthetic evidence for a design reference.", name: "Synthetic design references",
            sources: [], taskID: task, provider: "fixture", kind: "note"
        )
        let related = try await store.save(MarkdownDocument(
            name: "Synthetic related note", markdown: "Related synthetic evidence."
        ))
        try await store.postConversation(
            author: .researcher, text: "Specialist detail that belongs in activity.",
            references: [note.id], taskID: task
        )
        _ = try await store.proposeLink(
            note, related, rationale: "A synthetic connection for review.", taskID: task
        )
        try await store.postConversation(
            author: .curator, text: "A connection is ready for review.",
            references: [note.id, related.id], taskID: task
        )
        try await store.postConversation(
            author: .assistant,
            text: "Saved the research note. The suggested connection needs your approval.",
            references: [], taskID: task
        )
        try await store.updateConversationTask(task, state: "succeeded", progress: "Research saved")
        let model = ConversationModel(store: store, coordinator: AgentCoordinator(store: store))
        await model.refresh()
        let entry = try #require(ConversationFeedEntry.entries(in: model.messages).last)
        let view = ConversationView(model: model, library: LibraryModel(store: store))
        let before = model.messages.map(\.id)
        for dark in [false, true] {
            for width in [360.0, 760.0] {
                let host = NSHostingView(rootView: ScrollView {
                    view.response(entry).padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: width, height: 640))
                host.sizingOptions = []
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                    styleMask: [.titled], backing: .buffered, defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                try capture(host, name: "collapsed-\(Int(width))-\(dark ? "dark" : "light")")
                let collapsed = try bitmapData(host)
                try await clickActivity(in: host, window: window)
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                try capture(host, name: "expanded-\(Int(width))-\(dark ? "dark" : "light")")
                #expect(try bitmapData(host) != collapsed)
                try await clickActivity(in: host, window: window)
                try await Task.sleep(for: .milliseconds(100))
                #expect(model.messages.map(\.id) == before)
                #expect(model.proposals.count == 1)
                #expect(model.proposals.first?.status == "pending")
            }
        }
    }

    @MainActor private func clickActivity(in host: NSView, window: NSWindow) async throws {
        // The native disclosure triangle sits in the fixed header of this synthetic fixture.
        let point = host.convert(
            NSPoint(x: 52, y: host.isFlipped ? 64 : host.bounds.height - 64),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ))
            NSApplication.shared.sendEvent(event)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private func bitmapData(_ host: NSView) throws -> Data {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor private func capture(_ host: NSView, name: String) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(host.bounds.width))
        if let directory = ProcessInfo.processInfo.environment["GLEANARY_ACTIVITY_SCREENSHOTS"] {
            let root = URL(filePath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: root.appending(path: name + ".png"))
        }
    }
}
