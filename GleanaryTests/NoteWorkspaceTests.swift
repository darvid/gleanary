import Foundation
@testable import Gleanary
import GRDB
import Testing

struct WorkspaceFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store: DocumentStore

    init() async throws {
        store = DocumentStore(url: root.appending(path: "synthetic.sqlite"))
        _ = try await store.open(seed: [])
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }

    func note(
        _ name: String,
        type: NoteRecordType = .note,
        body: String = "Synthetic text."
    ) async throws -> MarkdownDocument {
        try await store.save(
            MarkdownDocument(name: name, markdown: body),
            profile: NoteProfile(type: type)
        )
    }

    func counts() throws -> [String: Int] {
        let db = try DatabaseQueue(path: root.appending(path: "synthetic.sqlite").path)
        return try db.read { db in
            try Dictionary(uniqueKeysWithValues: [
                "notes",
                "note_revisions",
                "workspace_tasks",
                "task_placements",
                "graph_jobs",
                "captures",
                "ingestion_jobs",
                "note_templates",
            ].map {
                try ($0, Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)") ?? 0)
            })
        }
    }
}

@Suite(.serialized) struct NoteWorkspaceTests {
    @Test func calendarDaysAreValidatedAndPortable() throws {
        #expect(WorkspaceDay(rawValue: "2024-02-29") != nil)
        for invalid in [
            "2025-02-29",
            "2026-04-31",
            "2026-00-01",
            "2026-13-01",
            "0000-01-01",
            "2026-1-01",
            "2026-01-00",
            "xxxx-01-01",
        ] {
            #expect(WorkspaceDay(rawValue: invalid) == nil)
        }
        let day = try #require(WorkspaceDay(rawValue: "2026-10-22"))
        #expect(try JSONDecoder().decode(WorkspaceDay.self, from: JSONEncoder().encode(day)) == day)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(
            WorkspaceDay.self,
            from: Data("\"2026-99-99\"".utf8)
        ) }
        let west = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        let east = try #require(TimeZone(secondsFromGMT: 12 * 3600))
        #expect(WorkspaceDay(date: Date(timeIntervalSince1970: 0), timeZone: west)
            .rawValue == "1969-12-31")
        #expect(WorkspaceDay(date: Date(timeIntervalSince1970: 0), timeZone: east)
            .rawValue == "1970-01-01")
    }

    @Test func templatesCreateOnlyDraftsUntilAnExplicitSave() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let before = try fixture.counts()
        let templates = try await fixture.store.noteTemplates()
        #expect(templates.count == 5)
        let meeting = try #require(templates.first { $0.defaults.type == .meeting })
        let (draft, profile) = meeting.draft(at: Date(timeIntervalSince1970: 1_792_627_200))
        #expect(draft.revision == nil)
        #expect(!draft.name.contains("{{date}}"))
        #expect(profile.type == .meeting && profile.templateID == meeting.id)
        #expect(try fixture.counts() == before)
        #expect(try await fixture.store.workspaceTasks().tasks.isEmpty)
        let saved = try await fixture.store.save(draft, profile: profile)
        #expect(saved.revision != nil)
        #expect(try await fixture.store.noteProfile(saved.id) == profile)
        #expect(try await fixture.store.noteProfileRevision(#require(saved.revision)) == profile)
        #expect(try await fixture.store.libraryItemDetails(for: saved.id).kind == "note")
        #expect(try await fixture.store.workspaceTasks().tasks.isEmpty)
    }

    @Test @MainActor func sourceAnnotationsPreserveIdentityAndRetainedEvidence() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let url = try #require(URL(string: "https://fixture.example/synthetic-meeting"))
        _ = try await fixture.store.enqueueCapture(CaptureRequest.webLink(url))
        let job = try #require(try await fixture.store.claimCapture())
        let id = try await fixture.store.publishCapture(job, document: CapturedDocument(
            title: "Synthetic meeting transcript", sourceURL: url, coverage: .article,
            blocks: [.init(
                kind: .paragraph,
                markdown: "- [ ] Send proposal",
                text: "Send proposal"
            )]
        ), artifacts: [])
        let source = try #require(try await fixture.store.document(id: id))
        let preview = DocumentPreviewModel()
        preview.selectedID = id
        await preview.load(from: fixture.store)
        let retained = try #require(preview.retainedSource?.markdown)
        let saved = try await fixture.store.save(source, profile: NoteProfile(type: .meeting))
        let item = try #require(MarkdownChecklist.items(in: saved.markdown).first)
        _ = try await fixture.store.trackChecklist(item, in: saved)
        await preview.load(from: fixture.store)
        #expect(preview.details.kind == "source")
        #expect(preview.retainedSource?.markdown == retained)
        #expect(preview.canViewCapturedSource)
        preview.showsCapturedSource = true
        #expect(preview.displayedMarkdown == retained)
        #expect(try await fixture.store.noteProfile(id).type == .meeting)
        #expect(try await fixture.store.workspaceTasks(noteID: id).tasks.count == 1)
    }

    @Test func personalTemplatesAreVersionedAndDoNotRewriteNotes() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let stock = try #require(try await fixture.store.noteTemplates().first)
        await #expect(throws: WorkspaceError.self) {
            try await fixture.store.saveNoteTemplate(stock)
        }
        var copy = stock
        copy.id = UUID(); copy.version = 0; copy.stock = false; copy.name = "Weekly review"
        copy.body = "{{title}} on {{date}}. {{shell}} stays literal.\n- [ ] Review"
        let personal = try await fixture.store.saveNoteTemplate(copy)
        let (draft, profile) = personal.draft()
        let saved = try await fixture.store.save(draft, profile: profile)
        var changed = personal
        changed.body = "Future notes only."
        _ = try await fixture.store.saveNoteTemplate(changed)
        await #expect(throws: WorkspaceError.self) {
            try await fixture.store.saveNoteTemplate(personal)
        }
        #expect(try await fixture.store.document(id: saved.id)?.markdown == draft.markdown)
        #expect(draft.markdown.contains("{{shell}}"))
        let newest = try #require(try await fixture.store.noteTemplates()
            .first { $0.id == personal.id })
        try await fixture.store.deleteNoteTemplate(newest)
        #expect(try await fixture.store.document(id: saved.id) != nil)
        #expect(try await fixture.store.noteProfile(saved.id).templateID == personal.id)
        var unsafe = NoteTemplate(name: "Shared old task")
        unsafe.body = WorkspaceTask(title: "Synthetic action").reference
        #expect(NoteTemplate.starterBody(from: "- " + unsafe.body) == "- [ ] ")
        await #expect(throws: WorkspaceError.self) {
            try await fixture.store.saveNoteTemplate(unsafe)
        }
    }

    @Test func propertiesAndBodyCommitAtomicallyWithTypedLinks() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let person = try await fixture.note("Taylor Example", type: .person)
        let project = try await fixture.note("Synthetic project", type: .project)
        let meeting = try await fixture.note("Synthetic meeting", type: .meeting)
        var profile = NoteProfile(
            type: .meeting,
            values: ["date": "2026-10-22"],
            links: ["participants": [person.id], "project": [project.id]]
        )
        let saved = try await fixture.store.save(meeting, profile: profile)
        #expect(try await fixture.store.noteProfile(saved.id) == profile)
        #expect(try await fixture.store.workspaceLinkNames([person.id, project.id]) == [
            person.id: person.name,
            project.id: project.name,
        ])
        #expect(try await fixture.store.workspaceNoteLinks(to: person.id).map(\.id) == [meeting.id])
        #expect(try await fixture.store.workspaceNoteLinks(type: .project)
            .map(\.id) == [project.id])
        let count = try await fixture.store.history(for: meeting.id).count
        profile.values["date"] = "2026-02-31"
        var invalid = saved; invalid.markdown = "Must roll back."
        await #expect(throws: WorkspaceError.self) { try await fixture.store.save(
            invalid,
            profile: profile
        ) }
        #expect(try await fixture.store.document(id: meeting.id) == saved)
        #expect(try await fixture.store.history(for: meeting.id).count == count)
        profile.values["date"] = "2026-10-22"
        profile.links["participants"] = [project.id]
        await #expect(throws: WorkspaceError.self) { try await fixture.store.save(
            saved,
            profile: profile
        ) }
        profile.links["participants"] = [person.id, person.id]
        await #expect(throws: WorkspaceError.self) { try await fixture.store.save(
            saved,
            profile: profile
        ) }
    }

    @Test func unchangedTypedNotesDoNotCreateSpuriousRevisions() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note("Synthetic meeting", type: .meeting)
        let before = try fixture.counts()
        let saved = try await fixture.store.save(note, profile: NoteProfile(type: .meeting))
        #expect(saved == note)
        #expect(try fixture.counts() == before)
    }

    @Test func propertyLinksAppearInCanonicalReadOnlyGraph() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let project = try await fixture.note("Synthetic project", type: .project)
        let meeting = try await fixture.note("Synthetic meeting", type: .meeting)
        _ = try await fixture.store.save(
            meeting,
            profile: NoteProfile(type: .meeting, links: ["project": [project.id]])
        )
        let before = try fixture.counts()
        let snapshot = try await fixture.store.libraryGraph(LibraryGraphRequest())
        let edge = try #require(snapshot.graph.edges
            .first {
                $0.source == "note:" + meeting.id.uuidString && $0.target == "note:" + project.id
                    .uuidString
            })
        #expect(edge.predicate == .linksTo)
        let reasons = try await fixture.store.libraryGraphReasons(
            for: edge,
            request: LibraryGraphRequest()
        )
        #expect(reasons.first?.label == "Note property")
        #expect(reasons.first?.text == "Project")
        #expect(try fixture.counts() == before)
        try await fixture.store.archive(project.id, reason: "Synthetic archive")
        #expect(try await fixture.store.libraryGraph(LibraryGraphRequest()).graph.edges.isEmpty)
    }

    @Test func checklistsRemainLocalAndSkipCode() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let text = """
        - [ ] Send proposal
        ```markdown
        - [ ] Code example
        ````
        > - [ ] Quoted example
            - [ ] Indented code
        ~~~text
        - [x] Another example
        ~~~
        - [X] Approved

        <!--
        - [ ] Hidden comment
        -->

        <div>
        - [ ] HTML example
        </div>

        - [ ]
        """
        let items = MarkdownChecklist.items(in: text)
        #expect(items.map(\.title) == ["Send proposal", "Approved"])
        let note = try await fixture.note("Local list", body: text)
        let toggled = try await fixture.store.toggleChecklist(#require(items.first), in: note)
        #expect(toggled.markdown.hasPrefix("- [x] Send proposal"))
        #expect(toggled.markdown.contains("- [ ] Code example"))
        #expect(try await fixture.store.workspaceTasks().tasks.isEmpty)
        await #expect(throws: WorkspaceError.self) { try await fixture.store.toggleChecklist(
            items[0],
            in: note
        ) }
    }

    @Test func promotingACheckboxIsAtomicAndCannotDuplicateTheTask() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let project = try await fixture.note("Synthetic project", type: .project)
        let note = try await fixture.note(
            "Meeting",
            type: .meeting,
            body: "## Actions\n\n- [ ] Send proposal\n- [ ] Local only"
        )
        let saved = try await fixture.store.save(
            note,
            profile: NoteProfile(type: .meeting, links: ["project": [project.id]])
        )
        let item = try #require(MarkdownChecklist.items(in: saved.markdown).first)
        let task = try await fixture.store.trackChecklist(item, in: saved)
        #expect(task.originID == saved.id && task.projectID == project.id)
        let updated = try #require(try await fixture.store.document(id: saved.id))
        #expect(updated.markdown.contains(task.reference))
        #expect(!updated.markdown.contains("[ ] Send proposal"))
        #expect(MarkdownChecklist.items(in: updated.markdown).map(\.title) == ["Local only"])
        #expect(try await fixture.store.workspaceTasks(noteID: saved.id).tasks == [task])
        await #expect(throws: WorkspaceError.self) { try await fixture.store.trackChecklist(
            item,
            in: saved
        ) }
        #expect(try await fixture.store.workspaceTasks().tasks.count == 1)
        let bad = MarkdownChecklistItem(
            line: 99,
            raw: "- [ ] Imaginary",
            title: "Imaginary",
            checked: false
        )
        await #expect(throws: WorkspaceError.self) { try await fixture.store.trackChecklist(
            bad,
            in: updated
        ) }
        #expect(try await fixture.store.workspaceTasks().tasks.count == 1)
    }

    @Test func tasksShareIdentityAndRejectStaleEditsAcrossPlacements() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note("Origin")
        let another = try await fixture.note("Another placement")
        let task = try await fixture.store.saveWorkspaceTask(
            WorkspaceTask(title: "Send proposal", originID: note.id),
            placingIn: note.id
        )
        try await fixture.store.addTaskPlacement(task.id, in: another.id)
        try await fixture.store.addTaskPlacement(task.id, in: another.id)
        var updated = task; updated.title = "Send revised proposal"; updated.status = .completed
        let saved = try await fixture.store.saveWorkspaceTask(updated)
        #expect(try await fixture.store.workspaceTasks(noteID: note.id).tasks == [saved])
        #expect(try await fixture.store.workspaceTasks(noteID: another.id).tasks == [saved])
        await #expect(throws: WorkspaceError.self) {
            try await fixture.store.saveWorkspaceTask(task)
        }
        try await fixture.store.removeTaskPlacement(task.id, from: note.id)
        #expect(try await fixture.store.workspaceTasks(noteID: note.id).tasks.isEmpty)
        #expect(try await fixture.store.workspaceTask(task.id) == saved)
        #expect(try await fixture.store.workspaceTasks(noteID: another.id).tasks == [saved])
    }

    @Test func unlinkingRemovesReferencesAndProjectAssignmentButKeepsTheTask() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let project = try await fixture.note(
            "Synthetic project",
            type: .project,
            body: "## Next\n\n- [ ] Send proposal"
        )
        let other = try await fixture.note("Another placement")
        let item = try #require(MarkdownChecklist.items(in: project.markdown).first)
        let task = try await fixture.store.trackChecklist(item, in: project)
        try await fixture.store.addTaskPlacement(task.id, in: other.id)
        let current = try #require(try await fixture.store.document(id: project.id))
        await #expect(throws: WorkspaceError.self) { try await fixture.store.unlinkWorkspaceTask(
            task,
            from: project
        ) }
        #expect(try await fixture.store.workspaceTask(task.id)?.projectID == project.id)
        try await fixture.store.unlinkWorkspaceTask(task, from: current)
        let retained = try #require(try await fixture.store.workspaceTask(task.id))
        #expect(retained.projectID == nil && retained.originID == project.id && retained
            .status == .open)
        #expect(try await fixture.store.workspaceTasks(noteID: project.id).tasks.isEmpty)
        #expect(try await fixture.store.workspaceTasks(noteID: other.id).tasks
            .map(\.id) == [task.id])
        #expect(try await fixture.store.document(id: project.id)?.markdown
            .contains(task.reference) == false)
        #expect(try await fixture.store.workspaceTasks().tasks.count == 1)
    }

    @Test func planningAndDeadlinesHaveDistinctDaySemantics() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let today = try #require(WorkspaceDay(rawValue: "2026-10-22"))
        let yesterday = try #require(WorkspaceDay(rawValue: "2026-10-21"))
        let tomorrow = try #require(WorkspaceDay(rawValue: "2026-10-23"))
        let unplanned = try await fixture.store.saveWorkspaceTask(WorkspaceTask(title: "Inbox"))
        let planned = try await fixture.store.saveWorkspaceTask(WorkspaceTask(
            title: "Planned",
            planned: today
        ))
        let carried = try await fixture.store.saveWorkspaceTask(WorkspaceTask(
            title: "Carry forward",
            planned: yesterday
        ))
        let overdue = try await fixture.store.saveWorkspaceTask(WorkspaceTask(
            title: "Deadline",
            due: yesterday,
            planned: tomorrow
        ))
        let upcoming = try await fixture.store.saveWorkspaceTask(WorkspaceTask(
            title: "Future",
            due: tomorrow
        ))
        _ = try await fixture.store.saveWorkspaceTask(WorkspaceTask(
            title: "Done",
            status: .completed,
            due: yesterday
        ))
        #expect(try await fixture.store.workspaceTasks(view: .inbox, today: today).tasks
            .map(\.id) == [unplanned.id])
        #expect(try await Set(fixture.store.workspaceTasks(view: .today, today: today).tasks
                .map(\.id)) == [
            planned.id,
            carried.id,
            overdue.id,
        ])
        #expect(try await fixture.store.workspaceTasks(view: .upcoming, today: today).tasks
            .map(\.id) == [upcoming.id])
        #expect(planned.due == nil && carried.due == nil)
        #expect(try await fixture.store.workspaceTasks(view: .completed, today: today).tasks
            .count == 1)
    }

    @Test func deletingOriginKeepsActionableTasksAndCleansPropertyLinks() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let origin = try await fixture.note("Origin project", type: .project)
        let meeting = try await fixture.note("Meeting", type: .meeting)
        _ = try await fixture.store.save(
            meeting,
            profile: NoteProfile(type: .meeting, links: ["project": [origin.id]])
        )
        let task = try await fixture.store.saveWorkspaceTask(
            WorkspaceTask(title: "Keep task", projectID: origin.id, originID: origin.id),
            placingIn: origin.id
        )
        try await fixture.store.remove(origin)
        var done = task; done.status = .completed
        _ = try await fixture.store.saveWorkspaceTask(done)
        var deleted = origin
        deleted
            .revision = try #require(try await fixture.store.history(for: origin.id)
                .first { $0.isDeleted }?.id)
        _ = try await fixture.store.permanentlyRemove(deleted)
        let retained = try #require(try await fixture.store.workspaceTask(task.id))
        #expect(retained.status == .completed && retained.originID == nil && retained
            .projectID == nil)
        #expect(try await fixture.store.workspaceTasks(noteID: origin.id).tasks.isEmpty)
        #expect(try await fixture.store.noteProfile(meeting.id).links.isEmpty)
        #expect(try await fixture.store.workspaceNoteLinks(to: origin.id).isEmpty)
    }

    @Test func taskPagingAndExportsPreserveCanonicalFields() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let note = try await fixture.note("Synthetic meeting", type: .meeting)
        var first: WorkspaceTask?
        for number in 0 ..< 85 {
            let task = try await fixture.store.saveWorkspaceTask(
                WorkspaceTask(title: "Action \(number)", originID: note.id),
                placingIn: note.id
            )
            if first == nil {
                first = task
            }
        }
        let page = try await fixture.store.workspaceTasks(noteID: note.id)
        #expect(page.tasks.count == 80 && page.hasMore)
        let rest = try await fixture.store.workspaceTasks(noteID: note.id, offset: 80)
        #expect(rest.tasks.count == 5 && !rest.hasMore)
        #expect(Set(page.tasks.map(\.id)).isDisjoint(with: Set(rest.tasks.map(\.id))))
        var task = try #require(first); task.status = .completed
        let saved = try await fixture.store.saveWorkspaceTask(task)
        let text = try await fixture.store.workspaceExport("- " + saved.reference, noteID: note.id)
        #expect(text.contains("- [x] Action 0"))
        #expect(text.contains("- [ ] Action 84"))
        #expect(!text.contains(saved.reference))
        #expect(text.contains("gleanary_tasks:") && text.contains(saved.id.uuidString))
        #expect(text.contains("gleanary:") && text.contains("meeting"))
        let reopened = DocumentStore(url: fixture.root.appending(path: "synthetic.sqlite"))
        _ = try await reopened.open(seed: [])
        #expect(try await reopened.workspaceTask(saved.id) == saved)
        #expect(try await reopened.noteTemplates().count == 5)
    }

    @Test @MainActor func quickEntryIsTransientAndReturnCreatesExactlyOneTask() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let workspace = NoteWorkspaceModel(store: fixture.store)
        let entry = WorkspaceTaskEntryModel()
        let before = try fixture.counts()
        entry.title = "   "
        #expect(await entry.submit(to: workspace, view: .inbox) == nil)
        #expect(try fixture.counts() == before)
        entry.title = "  Send synthetic proposal  "
        #expect(await entry.submit(to: workspace, view: .inbox) == .inbox)
        #expect(entry.title.isEmpty && !entry.submitting)
        #expect(await entry.submit(to: workspace, view: .inbox) == nil)
        let tasks = try await fixture.store.workspaceTasks().tasks
        #expect(tasks.count == 1 && tasks.first?.title == "Send synthetic proposal")
        #expect(tasks.first?.planned == nil && tasks.first?.due == nil)
        #expect(try fixture.counts()["notes"] == before["notes"])
        #expect(workspace.generation == 1 && workspace.noteGeneration == 0)
    }

    @Test @MainActor func quickEntryUsesTodayWithoutInventingDeadlinesOrFutureDates() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let workspace = NoteWorkspaceModel(store: fixture.store)
        let entry = WorkspaceTaskEntryModel()
        let today = try #require(WorkspaceDay(rawValue: "2026-10-22"))
        entry.title = "Today's synthetic action"
        #expect(await entry.submit(to: workspace, view: .today, today: today) == .today)
        let task = try #require(try await fixture.store.workspaceTasks(view: .today, today: today)
            .tasks.first)
        #expect(task.planned == today && task.due == nil)
        for view in [WorkspaceTaskView.upcoming, .completed] {
            entry.title = "Unplanned action from " + view.rawValue
            #expect(await entry.submit(to: workspace, view: view, today: today) == .inbox)
        }
        let inbox = try await fixture.store.workspaceTasks(view: .inbox, today: today).tasks
        #expect(inbox.count == 2 && inbox
            .allSatisfy { $0.status == .open && $0.planned == nil && $0.due == nil })
    }

    @Test @MainActor func quickEntryKeepsFailedTextAndAllowsRetry() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let workspace = NoteWorkspaceModel(store: fixture.store)
        let entry = WorkspaceTaskEntryModel()
        entry.title = String(repeating: "x", count: 501)
        #expect(await entry.submit(to: workspace, view: .all) == nil)
        #expect(entry.title.count == 501 && !entry.submitting && workspace.error != nil)
        #expect(try await fixture.store.workspaceTasks().tasks.isEmpty)
        entry.title = "Corrected synthetic action"
        #expect(await entry.submit(to: workspace, view: .all) == .all)
        #expect(entry.title.isEmpty && workspace.error == nil)
        #expect(try await fixture.store.workspaceTasks().tasks.count == 1)
    }

    @Test @MainActor func templateChangesDoNotInvalidateNoteContent() async throws {
        let fixture = try await WorkspaceFixture(); defer { fixture.clean() }
        let workspace = NoteWorkspaceModel(store: fixture.store)
        let changed = await workspace
            .change { _ = try await fixture.store.saveNoteTemplate(NoteTemplate(name: "Synthetic"))
            }
        #expect(changed && workspace.generation == 1 && workspace.noteGeneration == 0)
        _ = await workspace.change(changesNote: true) { _ = try await fixture.note("Changed note") }
        #expect(workspace.generation == 2 && workspace.noteGeneration == 1)
    }
}
