import AppKit
import Foundation
@testable import Gleanary
import GRDB
import SwiftUI
import Testing

private struct ActivityFixture {
    let root: URL
    let store: DocumentStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "activity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DocumentStore(url: root.appending(path: "library.sqlite"))
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }

    func events() async throws -> [ActivityEvent] {
        let page = try await store.activityPage(limit: 200)
        var events: [ActivityEvent] = []
        for group in page.days.flatMap(\.groups) {
            events += try await store.activityEvents(in: group, query: ActivityQuery(), limit: 200)
        }
        return events
    }
}

/// Upgrade fixtures must remove newer triggers before dropping columns they reference.
enum ActivityTestSchema {
    static func removeTracking(in db: Database) throws {
        for name in try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name GLOB 'activity_*'"
        ) {
            try db.execute(sql: "DROP TRIGGER \"\(name)\"")
        }
        try db.execute(sql: """
        DROP TABLE activity_events;
        DROP TABLE activity_context;
        DELETE FROM metadata WHERE key = 'activityTrackingSince';
        DELETE FROM grdb_migrations WHERE identifier = 'library-activity-v1';
        """)
    }
}

@Suite(.serialized)
struct ActivityTests {
    @Test func savesAreDurableNoOpsAndConflictsAreNotActivity() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        var note = try await fixture.store.save(MarkdownDocument(
            name: "Synthetic idea",
            markdown: "First"
        ))
        let stale = note
        _ = try await fixture.store.save(note)
        note.markdown = "Second"
        note = try await fixture.store.save(note)
        await #expect(throws: GleanaryError.self) { try await fixture.store.save(stale) }
        let events = try await fixture.events()
        #expect(events.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.created, .updated])
        #expect(events.allSatisfy { $0.actor == "manual" })
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open()
        // Creating and then editing one item is one unit of work.
        let groups = try await reopened.activityPage().days.flatMap(\.groups)
        #expect(groups.count == 1)
        #expect(groups.first?.itemSummary == "Created · Edited")
        let update = try #require(events.first { $0.kind == .updated })
        let inspection = try #require(try await reopened.inspectActivity(update.id))
        #expect(inspection.before == "First")
        #expect(inspection.after == "Second")
        #expect(inspection.current == note)
    }

    @Test func editingSessionsCollapseAndSummaryCountsDistinctItems() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        var note = try await fixture.store.save(MarkdownDocument(name: "Session", markdown: "One"))
        for value in ["Two", "Three", "Four"] {
            note.markdown = value
            note = try await fixture.store.save(note)
        }
        let page = try await fixture.store.activityPage()
        let group = try #require(page.days.first?.groups.first)
        #expect(group.count == 4)
        #expect(group.latest.kind == .updated)
        #expect(group.itemSummary == "Created · Edited")
        #expect(page.days.first?.summary.contains("1 updated") == true)
        let first = try await fixture.store.activityEvents(
            in: group,
            query: ActivityQuery(),
            limit: 2
        )
        let second = try await fixture.store.activityEvents(
            in: group,
            query: ActivityQuery(),
            before: first.last?.id,
            limit: 2
        )
        #expect(first.count == 2)
        #expect(second.count == 2)
        #expect(Set((first + second).map(\.id)).count == 4)
    }

    @Test func filteringSearchAndGroupPaginationAreComplete() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        for name in ["Alpha literal_%", "Beta", "Gamma", "Delta", "Epsilon"] {
            _ = try await fixture.store.save(MarkdownDocument(name: name, markdown: "Text"))
        }
        let first = try await fixture.store.activityPage(limit: 2)
        let second = try await fixture.store.activityPage(offset: 2, limit: 2)
        let third = try await fixture.store.activityPage(offset: 4, limit: 2)
        #expect(first.hasMore && second.hasMore && !third.hasMore)
        #expect(Set((first.days + second.days + third.days).flatMap(\.groups).map(\.id)).count == 5)
        let search = try await fixture.store.activityPage(query: ActivityQuery(search: "_%"))
        #expect(search.days.flatMap(\.groups).count == 1)
        #expect(try await fixture.store.activityPage(query: ActivityQuery(filter: .links)).days
            .isEmpty)
        #expect(try await fixture.store.activityPage(query: ActivityQuery(day: Date())).days
            .count == 1)
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        #expect(try await fixture.store.activityPage(query: ActivityQuery(day: yesterday)).days
            .isEmpty)
    }

    @Test func batchesKeepTheirActualCommitDateNotImportedBookmarkDates() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let original = Artifact(
            hash: String(repeating: "a", count: 64),
            kind: .html,
            name: "Bookmarks.html",
            byteCount: 20
        )
        // The store's existing import fixture shape is constructed from the parser.
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p><DT><A HREF="https://example.org/first" ADD_DATE="946684800">First source</A>
        <DT><A HREF="https://example.org/second" ADD_DATE="946684800">Second source</A></DL>
        """
        let file = try BookmarkParser.parse(Data(html.utf8))
        _ = try await fixture.store.importBookmarks(
            file.bookmarks,
            plan: BookmarkFolderPlan(bookmarks: file.bookmarks, existing: []),
            original: original
        )
        let page = try await fixture.store.activityPage()
        let group = try #require(page.days.first?.groups.first)
        #expect(page.days.count == 1)
        #expect(group.latest.actor == "import")
        #expect(group.latest.batchLabel == "Imported bookmarks")
        #expect(group.count >= 4)
        let events = try await fixture.events()
        #expect(events.filter { $0.kind == .sourceSaved }.count == 2)
        #expect(!events.contains { $0.kind == .sourceLinked })
        #expect(events.allSatisfy { Calendar.current.isDateInToday($0.date) })
    }

    @Test func filingArchiveLinksAndUndoAreRecordedButProposalsAreNot() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let left = try await fixture.store.save(MarkdownDocument(name: "Left", markdown: "One"))
        let right = try await fixture.store.save(MarkdownDocument(name: "Right", markdown: "Two"))
        let categoryID = UUID()
        try await fixture.store.saveCategory(id: categoryID, code: "21", name: "Synthetic filing")
        try await fixture.store.fileNote(left.id, categoryID: categoryID)
        try await fixture.store.archive(left.id, reason: "Synthetic archive")
        try await fixture.store.unarchive(left.id)
        let taskID = UUID()
        try await fixture.store.saveAgentChanges([
            AgentChangeDraft(
                kind: .link,
                noteID: left.id,
                targetID: right.id,
                before: "",
                after: "Right",
                reason: "Synthetic connection"
            ),
        ], taskID: taskID)
        #expect(try await !(fixture.events()).contains { $0.kind == .linkAdded })
        let changes = try await fixture.store.agentChanges(taskID: taskID)
        let report = try await fixture.store.applyAgentChanges(changes.map(\.id))
        #expect(report.applied == 1)
        #expect(try await fixture.store.undoAgentChanges(changes.map(\.id)) == 1)
        let kinds = try await Set(fixture.events().map(\.kind))
        #expect(kinds.isSuperset(of: [.filed, .archived, .unarchived, .linkAdded, .linkRemoved]))
    }

    @Test func failedTransactionsRollBackEventsAndActorContext() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        enum Failure: Error { case expected }
        await #expect(throws: Failure.self) {
            try await fixture.store.activityWrite(
                actor: "automation",
                batchID: UUID(),
                label: "Automation changes"
            ) { db in
                _ = try DocumentStore.writeNote(
                    MarkdownDocument(name: "Rolled back", markdown: "Text"),
                    in: db
                )
                throw Failure.expected
            }
        }
        #expect(try await fixture.events().isEmpty)
        _ = try await fixture.store.save(MarkdownDocument(name: "Committed", markdown: "Text"))
        #expect(try await fixture.events()
            .allSatisfy { $0.actor == "manual" && $0.batchLabel == nil })
        let pool = try await fixture.store.readyDatabase()
        #expect(try await pool.read { try String.fetchOne(
            $0,
            sql: "SELECT actor FROM activity_context"
        ) } == "app")
    }

    @Test func permanentDeletionScrubsBothRelationshipEndsAndOldSnapshots() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let removed = try await fixture.store.save(MarkdownDocument(
            name: "Sensitive synthetic title",
            markdown: "Synthetic body"
        ))
        let kept = try await fixture.store.save(MarkdownDocument(
            name: "Surviving item",
            markdown: "Kept"
        ))
        let pool = try await fixture.store.readyDatabase()
        try await pool.write { db in
            let ids = [removed.id.uuidString, kept.id.uuidString].sorted()
            try db.execute(
                sql: "INSERT INTO note_links VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    ids[0],
                    ids[1],
                    UUID().uuidString,
                    "Connection",
                    Date().timeIntervalSince1970,
                ]
            )
        }
        let snapshot = try #require(try await fixture.events().first { $0.kind == .linkAdded })
        #expect(snapshot.title != nil)
        _ = try await fixture.store.permanentlyRemove(removed)
        let events = try await fixture.events()
        let affected = events.filter { $0.noteID == removed.id || $0.relatedID == removed.id }
        #expect(affected.count >= 3)
        #expect(affected
            .allSatisfy {
                $0.title == nil && $0.detail == nil && $0.revisionID == nil && $0.batchLabel == nil
            })
        #expect(events.contains { $0.kind == .purged })
        let old = try #require(try await fixture.store.inspectActivity(snapshot.id))
        #expect(old.event.title == nil && old.current == nil && old.before == nil && old
            .after == nil)
        #expect(try await fixture.store
            .activityPage(query: ActivityQuery(search: "Sensitive synthetic title")).days.isEmpty)
        #expect(try await fixture.store.history(for: removed.id).isEmpty)
        #expect(try await fixture.store.document(id: kept.id) != nil)
    }

    @Test func softDeletionKeepsReadableHistoryUntilPurged() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let note = try await fixture.store.save(MarkdownDocument(
            name: "Deleted draft",
            markdown: "Retained until purge"
        ))
        try await fixture.store.remove(note)
        let event = try #require(try await fixture.events().first { $0.kind == .deleted })
        let inspection = try #require(try await fixture.store.inspectActivity(event.id))
        #expect(inspection.current == nil)
        #expect(inspection.after == note.markdown)
        #expect(inspection.event.title == note.name)
    }

    @Test @MainActor func observationRefreshesAndScrubsAnOpenInspection() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let model = ActivityModel(store: fixture.store)
        let observation = Task { await model.observe() }
        defer { observation.cancel() }
        let note = try await fixture.store.save(MarkdownDocument(
            name: "Observed synthetic title",
            markdown: "Text"
        ))
        try await settle { !model.days.isEmpty }
        model.selection = try #require(model.days.first?.groups.first?.latest.id)
        await model.inspectSelection()
        #expect(model.inspection?.current?.id == note.id)
        _ = try await fixture.store.permanentlyRemove(note)
        try await settle {
            model.days.flatMap(\.groups).contains { $0.latest.kind == .purged } && model.inspection?
                .event.title == nil
        }
        #expect(model.inspection?.current == nil)
        #expect(model.days.flatMap(\.groups).allSatisfy { $0.latest.title == nil })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_ACTIVITY_SCREENSHOTS"] == "1"))
    @MainActor func activityRendersInBothAppearancesAndAtMinimumWidth() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        var note = try await fixture.store.save(MarkdownDocument(
            name: "Making retries safe",
            markdown: "# Retries\n\nUse a stable request key."
        ))
        note.markdown = "# Retries\n\nUse a stable request key.\n\nStore the result before acknowledging success."
        note = try await fixture.store.save(note)
        // A second note edited several times, so a grouped row renders beside single ones.
        var session = try await fixture.store.save(MarkdownDocument(
            name: "Draft outline",
            markdown: "One"
        ))
        for value in ["Two", "Three"] {
            session.markdown = value
            session = try await fixture.store.save(session)
        }
        let filed = try await fixture.store.save(MarkdownDocument(
            name: "A source worth revisiting",
            markdown: "Saved evidence for another day."
        ))
        // Filed, so the category shows in its colour.
        try await fixture.store.readyDatabase().write { db in
            try db.execute(sql: """
            INSERT INTO decimal_categories(id, code, name) VALUES ('c', '18.01', 'Enterprise sales');
            INSERT INTO note_categories(noteID, categoryID, isPrimary) VALUES (?, 'c', 1);
            """, arguments: [filed.id.uuidString])
        }
        for width in [680.0, 960.0] {
            for dark in [false, true] {
                let model = ActivityModel(store: fixture.store)
                await model.reload()
                model
                    .selection = try #require(model.days.first?.groups
                        .first { $0.latest.kind == .updated }?.latest.id)
                await model.inspectSelection()
                // A failed capture pinned above the timeline, as the window shows it.
                let host = NSHostingView(rootView: ActivityView(
                    store: fixture.store,
                    open: { _ in },
                    intakeCount: 1,
                    model: model
                ) {
                    Section("Needs Attention") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("example.org/synthetic-article")
                            Text("The site took too long to respond.").font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Retry") {}.controlSize(.small)
                        }.padding(.vertical, 8)
                    }
                }
                .preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.contentView = host
                window.orderFront(nil)
                defer { window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
                host.display()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png
                    .write(to: FileManager.default.temporaryDirectory
                        .appending(
                            path: "gleanary-activity-\(Int(width))-\(dark ? "dark" : "light").png"
                        ))
                #expect(abs(host.bounds.width - width) < 1)
            }
        }
    }

    @Test func migrationBackfillsRealRevisionTimesWithoutInventingOtherHistory() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        var note = try await fixture.store.save(MarkdownDocument(
            name: "Earlier note",
            markdown: "One"
        ))
        note.markdown = "Two"
        _ = try await fixture.store.save(note)
        let pool = try await fixture.store.readyDatabase()
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try await pool.write { db in
            try ActivityTestSchema.removeTracking(in: db)
            try db.execute(
                sql: "UPDATE local_changes SET createdAt = ?",
                arguments: [oldDate.timeIntervalSince1970]
            )
        }
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open()
        let page = try await reopened.activityPage()
        let group = try #require(page.days.first?.groups.first)
        #expect(page.days.flatMap(\.groups).count == 1)
        let events = try await reopened.activityEvents(in: group, query: ActivityQuery())
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.actor == "legacy" && $0.date == oldDate })
        #expect(Set(events.map(\.kind)) == [.created, .updated])
        #expect(page.trackingSince > oldDate)
        #expect(try await reopened.history(for: note.id).count == 2)
        _ = try await reopened.open()
        #expect(try await reopened.activityPage().days.flatMap(\.groups).count == 1)
    }

    @Test func largeImportsStayOneExpandableOperationAcrossTransactions() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let bookmarks = try (0 ..< 260).map { index in
            try ImportedBookmark(
                url: #require(URL(string: "https://example.org/bookmark/\(index)")),
                title: "Imported source \(index)"
            )
        }
        let original = Artifact(
            hash: String(repeating: "b", count: 64),
            kind: .html,
            name: "Bookmarks.html",
            byteCount: 100
        )
        let report = try await fixture.store.importBookmarks(
            bookmarks, plan: BookmarkFolderPlan(bookmarks: bookmarks, existing: []),
            original: original
        )
        #expect(report.imported == 260)
        let page = try await fixture.store.activityPage(limit: 1)
        #expect(!page.hasMore)
        let group = try #require(page.days.first?.groups.first)
        #expect(group.count == 520)
        var events: [ActivityEvent] = []
        while events.count < group.count {
            let next = try await fixture.store.activityEvents(
                in: group,
                query: ActivityQuery(),
                before: events.last?.id
            )
            #expect(!next.isEmpty)
            if next.isEmpty {
                break
            }
            events += next
        }
        #expect(Set(events.map(\.id)).count == 520)
        #expect(page.days.first?.summary.contains("260 sources saved") == true)
    }

    @Test func localDayQueriesIncludeBothBoundariesAcrossClockChanges() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let pool = try await fixture.store.readyDatabase()
        for month in [3, 11] {
            let date = try #require(Calendar.current.date(from: DateComponents(
                year: 2026,
                month: month,
                day: month == 3 ? 8 : 1
            )))
            let interval = try #require(Calendar.current.dateInterval(of: .day, for: date))
            var ids: [UUID] = []
            for index in 0 ..< 4 {
                try await ids.append(fixture.store.save(MarkdownDocument(
                    name: "Boundary \(month)-\(index)",
                    markdown: "Text"
                )).id)
            }
            let timestamps = [
                interval.start.timeIntervalSince1970 - 1,
                interval.start.timeIntervalSince1970,
                interval.end.timeIntervalSince1970 - 1,
                interval.end.timeIntervalSince1970,
            ]
            let datedNotes = Array(zip(ids, timestamps))
            try await pool.write { db in
                for (id, time) in datedNotes {
                    try db.execute(
                        sql: "UPDATE activity_events SET occurredAt = ? WHERE noteID = ?",
                        arguments: [time, id.uuidString]
                    )
                }
            }
            let groups = try await fixture.store.activityPage(query: ActivityQuery(day: date)).days
                .flatMap(\.groups)
            #expect(Set(groups.compactMap(\.latest.noteID)) == Set([ids[1], ids[2]]))
        }
    }

    @Test func automationOriginAndUpdatedSourceAddressesAreRecorded() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let run = try await fixture.store.beginAutomationRun(.weeklyDigest, at: Date())
        let note = try await fixture.store.writeAutomationNote(
            MarkdownDocument(name: "Synthetic digest", markdown: "One"), reason: "Weekly digest",
            runID: run, at: Date()
        )
        var changed = note
        changed.markdown = "Two"
        changed = try await fixture.store.save(changed)
        try await fixture.store.recordAppliedChange(
            AgentChangeDraft(
                kind: .summary,
                noteID: note.id,
                before: "One",
                after: "Two",
                reason: "Summary"
            ),
            appliedRevision: changed.revision, runID: run
        )
        let events = try await fixture.events()
        #expect(events.filter { $0.kind == .created || $0.kind == .updated }
            .allSatisfy { $0.actor == "automation" })
        let pool = try await fixture.store.readyDatabase()
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE notes SET sourceURL = 'https://example.org/old' WHERE id = ?",
                arguments: [note.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE notes SET sourceURL = 'https://example.org/new' WHERE id = ?",
                arguments: [note.id.uuidString]
            )
        }
        #expect(try await fixture.events().filter { $0.kind == .sourceUpdated }.count == 1)
    }

    @Test func runsAndAutomaticSavesReadAsGleanarysWorkWithTheirReasons() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let mine = try await fixture.store.save(MarkdownDocument(
            name: "Synthetic origin note", markdown: "Notes."
        ))
        let runID = try await fixture.store.beginAutomationRun(.weeklyDigest, at: Date())
        for name in ["Synthetic digest one", "Synthetic digest two"] {
            _ = try await fixture.store.writeAutomationNote(
                MarkdownDocument(name: name, markdown: "Digest"), reason: "Weekly digest",
                runID: runID, at: Date()
            )
        }
        var run = AutomationRun(id: runID, kind: .weeklyDigest, startedAt: Date())
        run.status = .succeeded
        run.examined = 4
        run.changed = 2
        try await fixture.store.finishAutomationRun(run)
        // A source Gleanary followed from the note above, and one an automation fetched.
        let followed = UUID(), fetched = UUID()
        let pool = try await fixture.store.readyDatabase()
        try await pool.write { db in
            for (job, title) in [(followed, "Synthetic followed source"),
                                 (fetched, "Synthetic fetched source")]
            {
                // Saving a source creates its note in the same transaction.
                let note = UUID().uuidString
                for kind in ["created", "sourceSaved"] {
                    try db.execute(sql: """
                    INSERT INTO activity_events(occurredAt, kind, noteID, title, actor, groupID,
                        batchLabel)
                    VALUES (?, ?, ?, ?, 'app', ?, 'Saved source')
                    """, arguments: [Date().timeIntervalSince1970, kind, note, title,
                                     job.uuidString])
                }
            }
            try db.execute(sql: """
            INSERT INTO acquisition_candidates(id, identity, url, title, foundInNoteID, context,
                provenance, hop, score, state, reason, automatic, captureJobID, createdAt,
                updatedAt)
            VALUES (?, 'url:https://example.org/a', 'https://example.org/a', 'A', ?, '',
                'creatorRecommendation', 1, 1, 'queued', 'Recommended', 1, ?, 0, 0)
            """, arguments: [UUID().uuidString, mine.id.uuidString, followed.uuidString])
        }
        let before = try await fixture.store.activityPage(query: ActivityQuery(scope: .you))
            .days.flatMap(\.groups)
        #expect(before.map(\.latest.displayTitle).sorted()
            == ["Synthetic fetched source", "Synthetic origin note"])
        try await fixture.store.attributeCaptureActivity(fetched, toRun: runID)

        let groups = try await fixture.store.activityPage().days.flatMap(\.groups)
        let digest = try #require(groups.first { $0.automation == .weeklyDigest })
        #expect(!digest.byYou && digest.runID == runID)
        #expect(digest.count == 4)
        #expect(digest.headline == "Weekly digest created 2 notes and saved a source")
        #expect(digest.context == "4 checked · 2 changed")
        let saved = try #require(groups.first { $0.latest.title == "Synthetic followed source" })
        #expect(!saved.byYou)
        #expect(saved.context == "Recommended by the creator in “Synthetic origin note”")
        let yours = try await fixture.store.activityPage(query: ActivityQuery(scope: .you))
            .days.flatMap(\.groups)
        #expect(yours.map(\.latest.displayTitle) == ["Synthetic origin note"])
        let theirs = try await fixture.store.activityPage(query: ActivityQuery(scope: .gleanary))
        #expect(theirs.days.flatMap(\.groups).count == 2)

        let recap = try await fixture.store.activityRecap(since: .distantPast)
        #expect(recap == ActivityRecap(sourcesByYou: 0, sourcesByGleanary: 2, notesCreated: 3))
        #expect(recap.sentence == "2 sources saved (all by Gleanary) and 3 notes created")
        #expect(try await fixture.store.activityRecap(since: .distantFuture).isEmpty)
    }

    @Test func savingSummarizingAndFilingOneSourceIsOneRow() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let source = MarkdownDocument(name: "Synthetic deals talk", markdown: "Transcript")
        let summary = MarkdownDocument(name: "Summary: Synthetic deals talk", markdown: "Gist")
        let sourceID = UUID().uuidString, category = UUID().uuidString
        let store = fixture.store
        // Each step in its own transaction, as capture, summary and filing are in the app.
        _ = try await store
            .activityWrite(actor: "app", batchID: UUID(), label: "Saved source") { db in
                _ = try DocumentStore.writeNote(source, graph: false, in: db)
                try db.execute(sql: """
                INSERT INTO sources(id, identity, createdAt) VALUES (?, 'url:https://example.org/t', 0);
                INSERT INTO captures(id, sourceID, noteID, fingerprint, markdownHash, extractorVersion,
                    document, artifacts, createdAt) VALUES (?, ?, ?, 'f', 'h', '1', x'', x'', 0);
                INSERT INTO decimal_categories(id, code, name) VALUES (?, '18.01', 'Enterprise sales');
                """, arguments: [
                    sourceID,
                    UUID().uuidString,
                    sourceID,
                    source.id.uuidString,
                    category,
                ])
            }
        _ = try await store.activityWrite(actor: "app", label: "Created summary note") { db in
            _ = try DocumentStore.writeNote(summary, graph: false, in: db)
            try db.execute(sql: """
            INSERT INTO note_sources(noteID, sourceID, summaryRole) VALUES (?, ?, 'summary')
            """, arguments: [summary.id.uuidString, sourceID])
        }
        let pool = try await store.readyDatabase()
        for note in [source.id, summary.id] {
            try await pool.write { db in
                try db.execute(sql: """
                INSERT INTO note_categories(noteID, categoryID, isPrimary) VALUES (?, ?, 1)
                """, arguments: [note.uuidString, category])
            }
        }
        let groups = try await store.activityPage().days.flatMap(\.groups)
        #expect(groups.count == 1)
        let row = try #require(groups.first)
        #expect(row.title == "Synthetic deals talk")
        #expect(row.itemSummary == "Saved · Summarized · Filed under 18.01 Enterprise sales")
        #expect(row.actorName == "You and Gleanary")
        #expect(try await store.activityEvents(in: row, query: ActivityQuery()).count == row.count)
    }

    @Test func headlinesNameWhoAndEveryKindOfWork() {
        let event = ActivityEvent(
            id: 1, date: Date(), kind: .sourceSaved, noteID: nil, relatedID: nil,
            title: "Synthetic", detail: nil, actor: "manual", revisionID: nil, groupID: "g",
            batchLabel: nil
        )
        let group = ActivityGroup(
            key: "g", day: "2026-11-03", latest: event, count: 5,
            kinds: [.sourceSaved: 2, .linkAdded: 1]
        )
        #expect(group.headline == "You saved 2 sources and added a link")
        var run = group
        run.automation = .crossLinker
        run.kinds = [.linkAdded: 6]
        #expect(run.headline == "Cross-linker added 6 links")
    }

    @Test func migrationIncludesOldPurgeMarkersWithoutRestoringNames() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let note = try await fixture.store.save(MarkdownDocument(
            name: "Gone before migration",
            markdown: "Gone"
        ))
        _ = try await fixture.store.permanentlyRemove(note)
        let pool = try await fixture.store.readyDatabase()
        try await pool.write { try ActivityTestSchema.removeTracking(in: $0) }
        let reopened = DocumentStore(url: fixture.store.url)
        _ = try await reopened.open()
        let events = try await reopened.activityPage().days.flatMap(\.groups).map(\.latest)
        #expect(events.count == 1)
        #expect(events.first?.kind == .purged && events.first?.title == nil)
        #expect(try await reopened.history(for: note.id).isEmpty)
    }

    @Test func inlineDiffHasAWorkBoundForLargeUnrelatedRevisions() {
        let event = ActivityEvent(
            id: 1,
            date: Date(),
            kind: .updated,
            noteID: UUID(),
            relatedID: nil,
            title: "Large note",
            detail: nil,
            actor: "manual",
            revisionID: nil,
            groupID: "one",
            batchLabel: nil
        )
        let inspection = ActivityInspection(
            event: event,
            current: nil,
            before: String(repeating: "a\n", count: 1001),
            after: String(repeating: "b\n", count: 1001),
            previousTitle: nil
        )
        #expect(!inspection.diffIsBounded)
    }

    @Test func unchangedFilingDoesNotManufactureActivity() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        let note = try await fixture.store.save(MarkdownDocument(
            name: "Filed once",
            markdown: "Text"
        ))
        let category = UUID()
        try await fixture.store.saveCategory(id: category, code: "31", name: "Reading")
        try await fixture.store.fileNote(note.id, categoryID: category)
        let count = try await fixture.events().count
        try await fixture.store.fileNote(note.id, categoryID: category)
        _ = try await fixture.store.makePrimaryHome(note.id, categoryID: category)
        let homes = try await fixture.store.homes(of: note.id)
        try await fixture.store.restoreHomes(note.id, homes)
        #expect(try await fixture.events().count == count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_ACTIVITY_SCREENSHOTS"] == "1"))
    @MainActor func emptyActivityKeepsControlsAtTopAndFooterAtBottom() async throws {
        let fixture = try ActivityFixture(); defer { fixture.clean() }
        _ = try await fixture.store.open()
        for width in [680.0, 960.0] {
            for dark in [false, true] {
                let model = ActivityModel(store: fixture.store)
                model.query.day = Date()
                // A failed capture pinned above the timeline, as the window shows it.
                let host = NSHostingView(rootView: ActivityView(
                    store: fixture.store,
                    open: { _ in },
                    intakeCount: 1,
                    model: model
                ) {
                    Section("Needs Attention") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("example.org/synthetic-article")
                            Text("The site took too long to respond.").font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Retry") {}.controlSize(.small)
                        }.padding(.vertical, 8)
                    }
                }
                .preferredColorScheme(dark ? .dark : .light))
                let window = makeActivityWindow(host: host, width: width, height: 700, dark: dark)
                defer { window.contentView = nil; window.close() }
                try await settle { model.trackingSince != nil && !model.loading }
                try await Task.sleep(for: .milliseconds(350))
                let search = try #require(nativeViews(in: host).compactMap { $0 as? NSTextField }
                    .first { $0.placeholderString == "Search activity" })
                let searchFrame = host.convert(search.bounds, from: search)
                #expect(searchFrame.minY < 130)
                #expect(abs(host.bounds.height - 700) < 1)
                try saveActivityScreenshot(
                    host,
                    name: "empty-\(Int(width))-\(dark ? "dark" : "light")"
                )
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_ACTIVITY_SCREENSHOTS"] == "1"))
    @MainActor func dateJumpPopoverHasNativeFieldAndWorkingActions() async throws {
        let initial = try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 12
        )))
        for dark in [false, true] {
            var shown: Date?
            var cancelled = false
            let controller = NSHostingController(rootView: ActivityDateJump(
                date: initial,
                show: { shown = $0 },
                cancel: { cancelled = true }
            ))
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
            let window = makeActivityWindow(host: anchor, width: 320, height: 80, dark: dark)
            defer { window.contentView = nil; window.close() }
            let popover = NSPopover()
            popover.animates = false
            popover.contentViewController = controller
            popover.appearance = window.appearance
            popover.show(
                relativeTo: NSRect(x: 140, y: 40, width: 30, height: 20),
                of: anchor,
                preferredEdge: .minY
            )
            defer { popover.close() }
            try await Task.sleep(for: .milliseconds(350))
            let popoverWindow = try #require(controller.view.window)
            let field = try #require(nativeDatePicker(in: controller.view))
            #expect(field.datePickerStyle == .textField)
            #expect(Calendar.current.isDate(field.dateValue, inSameDayAs: initial))
            try saveActivityScreenshot(
                controller.view,
                name: "date-jump-\(dark ? "dark" : "light")"
            )
            let editedDate = try #require(Calendar.current.date(
                byAdding: .day,
                value: 3,
                to: initial
            ))
            field.dateValue = editedDate
            #expect(try field.sendAction(#require(field.action), to: field.target))
            let enter = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: popoverWindow.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            ))
            #expect(popoverWindow.performKeyEquivalent(with: enter))
            try await settle { shown != nil }
            #expect(shown.map { Calendar.current.isDate($0, inSameDayAs: editedDate) } == true)
            let escape = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: popoverWindow.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            ))
            #expect(popoverWindow.performKeyEquivalent(with: escape))
            try await settle { cancelled }
            #expect(cancelled)
        }
    }

    @MainActor private func makeActivityWindow(
        host: NSView,
        width: Double,
        height: Double,
        dark: Bool
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    @MainActor private func nativeViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { nativeViews(in: $0) }
    }

    @MainActor private func nativeDatePicker(in view: NSView) -> NSDatePicker? {
        if let picker = view as? NSDatePicker {
            return picker
        }
        return view.subviews.lazy.compactMap { nativeDatePicker(in: $0) }.first
    }

    @MainActor private func saveActivityScreenshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.display()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Popover content has a transparent backing; composite against its native surface.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        let captured = try NSImage(cgImage: #require(bitmap.cgImage), size: view.bounds.size)
        captured.draw(
            in: NSRect(origin: .zero, size: view.bounds.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: data)?.representation(
            using: .png,
            properties: [:]
        ))
        try png
            .write(to: FileManager.default.temporaryDirectory
                .appending(path: "gleanary-activity-\(name).png"))
    }

    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 150 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Activity did not reach the expected state")
    }
}
