import GRDB

enum ConversationSchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE conversation_tasks (
            id TEXT PRIMARY KEY NOT NULL, owner TEXT NOT NULL, request TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('queued','running','awaiting_user','succeeded','failed','cancelled')),
            progress TEXT NOT NULL DEFAULT '', captureID TEXT,
            createdAt REAL NOT NULL, updatedAt REAL NOT NULL
        );
        CREATE TABLE conversation_messages (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
            author TEXT NOT NULL, text TEXT NOT NULL, refs BLOB NOT NULL,
            taskID TEXT REFERENCES conversation_tasks(id), createdAt REAL NOT NULL
        );
        CREATE TABLE conversation_events (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            taskID TEXT NOT NULL REFERENCES conversation_tasks(id), kind TEXT NOT NULL,
            detail TEXT NOT NULL, createdAt REAL NOT NULL
        );
        CREATE TABLE decimal_categories (
            id TEXT PRIMARY KEY NOT NULL, code TEXT UNIQUE NOT NULL, name TEXT NOT NULL
        );
        CREATE TABLE note_categories (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            categoryID TEXT NOT NULL REFERENCES decimal_categories(id),
            isPrimary INTEGER NOT NULL CHECK(isPrimary IN (0,1)),
            PRIMARY KEY(noteID, categoryID)
        );
        CREATE UNIQUE INDEX note_primary_category ON note_categories(noteID) WHERE isPrimary = 1;
        CREATE TABLE source_categories (
            sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            categoryID TEXT NOT NULL REFERENCES decimal_categories(id),
            isPrimary INTEGER NOT NULL CHECK(isPrimary IN (0,1)),
            PRIMARY KEY(sourceID, categoryID)
        );
        CREATE UNIQUE INDEX source_primary_category ON source_categories(sourceID) WHERE isPrimary = 1;
        CREATE TABLE note_sources (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            PRIMARY KEY(noteID, sourceID)
        );
        INSERT INTO note_sources SELECT DISTINCT noteID, sourceID FROM captures;
        CREATE TABLE authored_artifacts (
            noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            taskID TEXT UNIQUE NOT NULL REFERENCES conversation_tasks(id),
            kind TEXT NOT NULL, provider TEXT NOT NULL, createdAt REAL NOT NULL
        );
        CREATE TABLE knowledge_proposals (
            id TEXT PRIMARY KEY NOT NULL, taskID TEXT NOT NULL REFERENCES conversation_tasks(id),
            leftID TEXT NOT NULL, rightID TEXT NOT NULL,
            leftRevision TEXT NOT NULL, rightRevision TEXT NOT NULL,
            rationale TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('pending','applied','rejected','stale','undone')),
            createdAt REAL NOT NULL
        );
        CREATE TABLE knowledge_links (
            leftID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            rightID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            proposalID TEXT NOT NULL UNIQUE REFERENCES knowledge_proposals(id),
            PRIMARY KEY(leftID, rightID), CHECK(leftID != rightID)
        );
        -- Only the Inbox fallback is built in; users define their own filing scheme.
        -- (remove-inbox-v1 later removes it: unsorted items are unfiled.)
        -- Libraries created before this change keep the categories they already have.
        INSERT INTO decimal_categories VALUES
            ('10000000-0000-0000-0000-000000000001', '10', 'Inbox');
        """)
    }
}
