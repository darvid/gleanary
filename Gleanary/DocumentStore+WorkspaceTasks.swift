import Foundation
import GRDB

extension DocumentStore {
    /// What was finished on a day, most recent first. Task rows keep only their last update, so
    /// a finished task edited later moves to that day.
    func workspaceTasksDone(on day: WorkspaceDay) throws -> [WorkspaceTask] {
        let start = day.date.timeIntervalSince1970
        return try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT t.* FROM workspace_tasks t
            WHERE t.status = 'completed' AND t.updatedAt >= ? AND t.updatedAt < ?
            ORDER BY t.updatedAt DESC, t.id LIMIT 50
            """, arguments: [start, start + 86400]).map(Self.workspaceTask)
        }
    }

    func workspaceTasks(
        view: WorkspaceTaskView = .all,
        query: String = "",
        noteID: UUID? = nil,
        projectID: UUID? = nil,
        includeProjectPlacements: Bool = false,
        today: WorkspaceDay = WorkspaceDay(date: .now),
        offset: Int = 0,
        limit: Int = 80
    ) throws -> WorkspaceTaskPage {
        try readyDatabase().read { db in
            var predicate = "1 = 1"
            var arguments = StatementArguments()
            switch view {
            case .inbox: predicate += " AND t.status = 'open' AND t.plannedDay IS NULL AND t.dueDay IS NULL"
            case .today:
                predicate += " AND t.status = 'open' AND (t.plannedDay <= ? OR t.dueDay <= ?)"
                arguments += [today.rawValue, today.rawValue]
            case .upcoming:
                predicate += " AND t.status = 'open' AND (t.plannedDay > ? OR t.dueDay > ?) AND (t.plannedDay IS NULL OR t.plannedDay > ?) AND (t.dueDay IS NULL OR t.dueDay > ?)"
                arguments += [today.rawValue, today.rawValue, today.rawValue, today.rawValue]
            case .completed: predicate += " AND t.status = 'completed'"
            case .all: break
            }
            if let noteID {
                predicate += " AND EXISTS(SELECT 1 FROM task_placements p WHERE p.taskID = t.id AND p.noteID = ?)"
                arguments += [noteID.uuidString]
            }
            if let projectID {
                if includeProjectPlacements {
                    predicate += " AND (t.projectID = ? OR EXISTS(SELECT 1 FROM task_placements p WHERE p.taskID = t.id AND p.noteID = ?))"
                    arguments += [projectID.uuidString, projectID.uuidString]
                } else {
                    predicate += " AND t.projectID = ?"
                    arguments += [projectID.uuidString]
                }
            }
            if !query.isEmpty {
                predicate += " AND instr(lower(t.title), lower(?)) > 0"
                arguments += [query]
            }
            let size = max(1, min(limit, 200))
            arguments += [size + 1, max(0, offset)]
            let rows = try Row.fetchAll(db, sql: """
            SELECT t.* FROM workspace_tasks t WHERE \(predicate)
            ORDER BY CASE t.status WHEN 'open' THEN 0 ELSE 1 END,
                CASE WHEN t.dueDay IS NULL THEN 1 ELSE 0 END, t.dueDay,
                t.plannedDay, t.createdAt, t.id LIMIT ? OFFSET ?
            """, arguments: arguments)
            return try WorkspaceTaskPage(
                tasks: rows.prefix(size).map(Self.workspaceTask),
                hasMore: rows.count > size
            )
        }
    }

    func workspaceTask(_ id: UUID) throws -> WorkspaceTask? {
        try readyDatabase().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM workspace_tasks WHERE id = ?",
                arguments: [id.uuidString]
            ).map(Self.workspaceTask)
        }
    }

    func saveWorkspaceTask(
        _ task: WorkspaceTask,
        placingIn noteID: UUID? = nil
    ) throws -> WorkspaceTask {
        try readyDatabase().write { db in
            let saved = try Self.writeWorkspaceTask(task, in: db)
            if let noteID {
                try Self.placeWorkspaceTask(saved.id, in: noteID, database: db)
            }
            return saved
        }
    }

    func addTaskPlacement(_ taskID: UUID, in noteID: UUID) throws {
        try readyDatabase().write { db in
            try Self.placeWorkspaceTask(taskID, in: noteID, database: db)
        }
    }

    /// Removing a placement does not complete, cancel, or delete the underlying task.
    func removeTaskPlacement(_ taskID: UUID, from noteID: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "DELETE FROM task_placements WHERE taskID = ? AND noteID = ?",
                arguments: [taskID.uuidString, noteID.uuidString]
            )
        }
    }

    /// Removing a note's task references never deletes the canonical task.
    func unlinkWorkspaceTask(_ task: WorkspaceTask, from document: MarkdownDocument) throws {
        try activityWrite(actor: "manual") { db in
            try Self.requireWorkspaceNote(document.id, in: db)
            let revision = try String.fetchOne(
                db,
                sql: "SELECT revision FROM notes WHERE id = ?",
                arguments: [document.id.uuidString]
            )
            guard revision == document.revision?.uuidString else { throw WorkspaceError.stale }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM workspace_tasks WHERE id = ?",
                arguments: [task.id.uuidString]
            )
            else { throw WorkspaceError.stale }
            var current = try Self.workspaceTask(row)
            if current.projectID == document.id {
                guard current.version == task.version else { throw WorkspaceError.stale }
                current.projectID = nil
                _ = try Self.writeWorkspaceTask(current, in: db)
            }
            try db.execute(
                sql: "DELETE FROM task_placements WHERE taskID = ? AND noteID = ?",
                arguments: [task.id.uuidString, document.id.uuidString]
            )
            var updated = document
            updated.markdown = document.markdown.components(separatedBy: "\n").compactMap { line in
                if line.trimmingCharacters(in: .whitespaces).lowercased() == ("- " + task.reference)
                    .lowercased()
                {
                    return nil
                }
                return line.replacingOccurrences(
                    of: task.reference,
                    with: "",
                    options: .caseInsensitive
                )
            }.joined(separator: "\n")
            if updated.markdown != document.markdown {
                _ = try Self.writeNote(updated, in: db)
            }
        }
    }

    func workspaceExport(
        _ markdown: String,
        noteID: UUID,
        profile: NoteProfile? = nil
    ) throws -> String {
        try readyDatabase().read { db in
            // One consistent snapshot, including every placement rather than a truncated UI page.
            let tasks = try Row.fetchAll(db, sql: """
            SELECT t.* FROM workspace_tasks t JOIN task_placements p ON p.taskID = t.id
            WHERE p.noteID = ? ORDER BY t.createdAt, t.id
            """, arguments: [noteID.uuidString]).map(Self.workspaceTask)
            var text = markdown
            var remaining: [WorkspaceTask] = []
            for task in tasks {
                if text.contains(task.reference) {
                    text = text.replacingOccurrences(of: task.reference, with: task.markdown)
                } else {
                    remaining.append(task)
                }
            }
            if !remaining.isEmpty {
                text += "\n\n## Tracked tasks\n\n" + remaining.map { "- " + $0.markdown }
                    .joined(separator: "\n")
            }
            let fields = try profile ?? Self.noteProfile(noteID, in: db)
            var metadata: [String] = []
            if fields.type != .note || !fields.values.isEmpty || !fields.links.isEmpty {
                try metadata.append("gleanary: " + String(
                    decoding: JSONEncoder().encode(fields),
                    as: UTF8.self
                ))
            }
            if !tasks.isEmpty {
                try metadata.append("gleanary_tasks: " + String(
                    decoding: JSONEncoder().encode(tasks),
                    as: UTF8.self
                ))
            }
            if !metadata
                .isEmpty
            {
                text = "---\n" + metadata.joined(separator: "\n") + "\n---\n\n" + text
            }
            return text
        }
    }

    static func writeWorkspaceTask(_ task: WorkspaceTask, in db: Database) throws -> WorkspaceTask {
        try workspaceTitle(task.title)
        let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM workspace_tasks WHERE id = ?",
            arguments: [task.id.uuidString]
        )
        let stored = try row.map(workspaceTask)
        guard stored == nil ? task.version == 0 : stored?.version == task.version
        else { throw WorkspaceError.stale }
        if let origin = task.originID, stored?.originID != origin {
            try requireWorkspaceNote(
                origin,
                in: db
            )
        }
        if let project = task.projectID, stored?.projectID != project {
            try requireWorkspaceNote(project, in: db)
            guard try noteProfile(project, in: db).type == .project
            else { throw WorkspaceError.invalidProperties }
        }
        var saved = task
        saved.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.version += 1
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
        INSERT INTO workspace_tasks(id, title, status, dueDay, plannedDay, projectID, originID, version, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET title = excluded.title, status = excluded.status,
            dueDay = excluded.dueDay, plannedDay = excluded.plannedDay,
            projectID = excluded.projectID, originID = excluded.originID,
            version = excluded.version, updatedAt = excluded.updatedAt
        """, arguments: [
            saved.id.uuidString,
            saved.title,
            saved.status.rawValue,
            saved.due?.rawValue,
            saved.planned?.rawValue,
            saved.projectID?.uuidString,
            saved.originID?.uuidString,
            saved.version,
            now,
            now,
        ])
        try db.execute(
            sql: "INSERT INTO workspace_task_history VALUES (?, ?, ?, ?)",
            arguments: [
                saved.id.uuidString,
                saved.version,
                JSONEncoder().encode(saved),
                now,
            ]
        )
        return saved
    }

    static func placeWorkspaceTask(_ taskID: UUID, in noteID: UUID, database db: Database) throws {
        try requireWorkspaceNote(noteID, in: db)
        try db.execute(
            sql: "INSERT OR IGNORE INTO task_placements VALUES (?, ?)",
            arguments: [taskID.uuidString, noteID.uuidString]
        )
    }

    private static func workspaceTask(_ row: Row) throws -> WorkspaceTask {
        guard let status = WorkspaceTask.Status(rawValue: row["status"])
        else { throw GleanaryError.invalidDatabase }
        let due: String? = row["dueDay"], planned: String? = row["plannedDay"]
        if due.map({ WorkspaceDay(rawValue: $0) == nil }) == true || planned
            .map({ WorkspaceDay(rawValue: $0) == nil }) == true
        {
            throw GleanaryError.invalidDatabase
        }
        return try WorkspaceTask(
            id: Self.uuid(row["id"]),
            title: row["title"],
            status: status,
            due: due.flatMap(WorkspaceDay.init(rawValue:)),
            planned: planned.flatMap(WorkspaceDay.init(rawValue:)),
            projectID: (row["projectID"] as String?).map(Self.uuid),
            originID: (row["originID"] as String?).map(Self.uuid),
            version: row["version"]
        )
    }
}
