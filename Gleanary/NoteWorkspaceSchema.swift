import Foundation
import GRDB

enum NoteWorkspaceSchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE note_profiles (
            noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            profile BLOB NOT NULL
        );
        CREATE TABLE note_property_links (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            propertyID TEXT NOT NULL,
            targetID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            PRIMARY KEY(noteID, propertyID, targetID)
        );
        CREATE INDEX note_property_links_target ON note_property_links(targetID, noteID);
        CREATE TABLE note_profile_revisions (
            revision TEXT PRIMARY KEY NOT NULL REFERENCES note_revisions(id) ON DELETE CASCADE,
            profile BLOB NOT NULL
        );
        CREATE TABLE note_templates (
            id TEXT PRIMARY KEY NOT NULL,
            definition BLOB NOT NULL,
            version INTEGER NOT NULL,
            stock INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE workspace_tasks (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('open','completed','canceled')),
            dueDay TEXT,
            plannedDay TEXT,
            projectID TEXT REFERENCES notes(id) ON DELETE SET NULL,
            originID TEXT REFERENCES notes(id) ON DELETE SET NULL,
            version INTEGER NOT NULL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE INDEX workspace_tasks_schedule ON workspace_tasks(status, plannedDay, dueDay);
        CREATE INDEX workspace_tasks_project ON workspace_tasks(projectID, status);
        CREATE TABLE task_placements (
            taskID TEXT NOT NULL REFERENCES workspace_tasks(id) ON DELETE CASCADE,
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            PRIMARY KEY(taskID, noteID)
        );
        CREATE INDEX task_placements_note ON task_placements(noteID, taskID);
        CREATE TABLE workspace_task_history (
            taskID TEXT NOT NULL REFERENCES workspace_tasks(id) ON DELETE CASCADE,
            version INTEGER NOT NULL,
            record BLOB NOT NULL,
            changedAt REAL NOT NULL,
            PRIMARY KEY(taskID, version)
        );
        """)
        for template in NoteTemplate.starters {
            try db.execute(sql: "INSERT INTO note_templates VALUES (?, ?, ?, 1)", arguments: [
                template.id.uuidString, JSONEncoder().encode(template), template.version,
            ])
        }
    }
}
