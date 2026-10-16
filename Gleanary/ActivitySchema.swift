import Foundation
import GRDB

/// Triggers keep activity atomic with every mutation, including cascades and undo.
/// They deliberately ignore derived graph extraction, indexing and capture job state.
enum ActivitySchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE activity_context (
            id INTEGER PRIMARY KEY CHECK(id = 1), actor TEXT NOT NULL,
            batchID TEXT, batchLabel TEXT, version INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO activity_context(id, actor) VALUES (1, 'app');
        CREATE TABLE activity_events (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            occurredAt REAL NOT NULL, kind TEXT NOT NULL, noteID TEXT, relatedID TEXT,
            title TEXT, detail TEXT, actor TEXT NOT NULL, revisionID TEXT,
            groupID TEXT NOT NULL, batchLabel TEXT
        );
        CREATE INDEX activity_recent ON activity_events(occurredAt DESC, sequence DESC);
        CREATE INDEX activity_note ON activity_events(noteID, kind, occurredAt DESC);
        CREATE INDEX activity_related ON activity_events(relatedID);
        CREATE INDEX activity_group ON activity_events(groupID, sequence DESC);
        CREATE TRIGGER activity_event_inserted AFTER INSERT ON activity_events BEGIN
            UPDATE activity_context SET version = version + 1 WHERE id = 1;
        END;
        CREATE TRIGGER activity_event_updated AFTER UPDATE ON activity_events BEGIN
            UPDATE activity_context SET version = version + 1 WHERE id = 1;
        END;
        CREATE TRIGGER activity_event_removed AFTER DELETE ON activity_events BEGIN
            UPDATE activity_context SET version = version + 1 WHERE id = 1;
        END;
        CREATE TRIGGER activity_automation_revision AFTER INSERT ON agent_changes
            WHEN new.status = 'applied' AND new.appliedRevision IS NOT NULL
                AND EXISTS(SELECT 1 FROM automation_runs WHERE id = new.taskID) BEGIN
            UPDATE activity_events SET actor = 'automation', groupID = new.taskID,
                batchLabel = 'Automation changes'
                WHERE revisionID = new.appliedRevision AND noteID = new.noteID;
        END;
        INSERT INTO metadata(key, value) VALUES ('activityTrackingSince',
            CAST(\(now) AS TEXT));
        INSERT INTO activity_events(occurredAt, kind, noteID, title, actor, revisionID, groupID)
        SELECT c.createdAt,
            CASE WHEN c.kind = 'delete' THEN 'deleted'
                WHEN r.parentID IS NULL THEN 'created' ELSE 'updated' END,
            c.noteID, r.name, 'legacy', r.id, c.changeID
        FROM local_changes c JOIN note_revisions r ON r.id = c.revision
        WHERE c.kind IN ('save', 'delete');
        INSERT INTO activity_events(occurredAt, kind, noteID, actor, groupID)
            SELECT deletedAt, 'purged', noteID, 'legacy', deletionID FROM purged_notes;
        """)
        try trigger(
            db,
            name: "note_created",
            on: "AFTER INSERT ON notes",
            kind: "'created'",
            note: "new.id",
            title: "new.name",
            revision: "new.revision"
        )
        try trigger(
            db,
            name: "note_updated",
            on: "AFTER UPDATE OF name, markdown ON notes",
            condition: "new.name != old.name OR new.markdown != old.markdown",
            kind: "'updated'",
            note: "new.id",
            title: "new.name",
            revision: "new.revision",
            session: true
        )
        try trigger(
            db,
            name: "note_deleted",
            on: "AFTER UPDATE OF deletedAt ON notes",
            condition: "old.deletedAt IS NULL AND new.deletedAt IS NOT NULL",
            kind: "'deleted'",
            note: "new.id",
            title: "new.name",
            revision: "new.revision"
        )
        try trigger(
            db,
            name: "note_archived",
            on: "AFTER UPDATE OF archivedAt ON notes",
            condition: "old.archivedAt IS NOT new.archivedAt",
            kind: "CASE WHEN new.archivedAt IS NULL THEN 'unarchived' ELSE 'archived' END",
            note: "new.id",
            title: "new.name"
        )
        try trigger(
            db,
            name: "source_updated",
            on: "AFTER UPDATE OF sourceURL ON notes",
            condition: "old.sourceURL IS NOT NULL AND old.sourceURL IS NOT new.sourceURL",
            kind: "'sourceUpdated'",
            note: "new.id",
            title: "new.name"
        )
        try trigger(
            db,
            name: "source_saved",
            on: "AFTER INSERT ON captures",
            kind: "'sourceSaved'",
            note: "new.noteID",
            title: noteTitle("new.noteID")
        )
        for (operation, prefix, kind) in [("INSERT", "new", "sourceLinked"),
                                          ("DELETE", "old", "sourceUnlinked")]
        {
            // A capture's own association is already represented by Source saved.
            try trigger(
                db,
                name: "source_\(operation.lowercased())",
                on: "AFTER \(operation) ON note_sources",
                condition: "EXISTS (SELECT 1 FROM notes WHERE id = \(prefix).noteID AND deletedAt IS NULL) AND NOT EXISTS (SELECT 1 FROM captures WHERE noteID = \(prefix).noteID AND sourceID = \(prefix).sourceID)",
                kind: "'\(kind)'",
                note: "\(prefix).noteID",
                title: noteTitle("\(prefix).noteID")
            )
        }
        for table in ["note_links", "knowledge_links"] {
            for (operation, prefix, kind) in [("INSERT", "new", "linkAdded"),
                                              ("DELETE", "old", "linkRemoved")]
            {
                try trigger(
                    db,
                    name: "\(table)_\(operation.lowercased())",
                    on: "AFTER \(operation) ON \(table)",
                    condition: "EXISTS (SELECT 1 FROM notes WHERE id = \(prefix).leftID AND deletedAt IS NULL) AND EXISTS (SELECT 1 FROM notes WHERE id = \(prefix).rightID AND deletedAt IS NULL)",
                    kind: "'\(kind)'",
                    note: "\(prefix).leftID",
                    related: "\(prefix).rightID",
                    title: noteTitle("\(prefix).leftID"),
                    detail: noteTitle("\(prefix).rightID")
                )
            }
        }
        for (operation, prefix, kind) in [("INSERT", "new", "filed"), (
            "DELETE",
            "old",
            "unfiled"
        )] {
            try trigger(
                db,
                name: "filing_\(operation.lowercased())",
                on: "AFTER \(operation) ON note_categories",
                condition: "EXISTS (SELECT 1 FROM notes WHERE id = \(prefix).noteID AND deletedAt IS NULL)",
                kind: "'\(kind)'",
                note: "\(prefix).noteID",
                title: noteTitle("\(prefix).noteID"),
                detail: "(SELECT code || ' ' || name FROM decimal_categories WHERE id = \(prefix).categoryID)"
            )
        }
        try trigger(
            db,
            name: "primary_home",
            on: "AFTER UPDATE OF isPrimary ON note_categories",
            condition: "new.isPrimary = 1 AND old.isPrimary = 0",
            kind: "'primaryHome'",
            note: "new.noteID",
            title: noteTitle("new.noteID"),
            detail: "(SELECT code || ' ' || name FROM decimal_categories WHERE id = new.categoryID)"
        )
        // No names, destinations, revision pointers, or batch labels may survive a purge.
        // Scrub both ends of relationships, not just events owned by the deleted item.
        try db.execute(sql: """
        CREATE TRIGGER activity_note_purged AFTER DELETE ON notes BEGIN
            UPDATE activity_events SET title = NULL, detail = NULL, revisionID = NULL,
                batchLabel = NULL, groupID = 'purged-' || sequence
                WHERE noteID = old.id OR relatedID = old.id;
            \(insert(kind: "'purged'", note: "old.id"))
        END;
        """)
    }

    private static let now = "((julianday('now') - 2440587.5) * 86400.0)"

    private static func noteTitle(_ id: String) -> String {
        "(SELECT name FROM notes WHERE id = \(id))"
    }

    private static func trigger(
        _ db: Database, name: String, on clause: String, condition: String? = nil,
        kind: String, note: String, related: String = "NULL", title: String = "NULL",
        detail: String = "NULL", revision: String = "NULL", session: Bool = false
    ) throws {
        let when = condition.map { " WHEN \($0)" } ?? ""
        try db.execute(sql: """
        CREATE TRIGGER activity_\(name) \(clause)\(when) BEGIN
            \(insert(kind: kind, note: note, related: related, title: title,
                     detail: detail, revision: revision, session: session))
        END;
        """)
    }

    private static func insert(
        kind: String, note: String, related: String = "NULL", title: String = "NULL",
        detail: String = "NULL", revision: String = "NULL", session: Bool = false
    ) -> String {
        let previous = session ? """
        (SELECT groupID FROM activity_events
            WHERE noteID = \(note) AND kind = 'updated' AND actor = context.actor
                AND batchLabel IS NULL AND occurredAt >= \(now) - 300
                AND date(occurredAt, 'unixepoch', 'localtime') = date('now', 'localtime')
            ORDER BY sequence DESC LIMIT 1),
        """ : ""
        return """
        INSERT INTO activity_events(occurredAt, kind, noteID, relatedID, title, detail,
            actor, revisionID, groupID, batchLabel)
        SELECT \(now), \(kind), \(note), \(related), \(title), \(detail),
            context.actor, \(revision), coalesce(context.batchID, \(previous)lower(hex(randomblob(16)))),
            context.batchLabel FROM activity_context context WHERE id = 1;
        """
    }
}
