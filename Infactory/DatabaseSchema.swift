import Foundation
import GRDB

/// Notes, revisions, captures, source blocks and artifact manifests are canonical.
/// Search indexes and embeddings are replaceable. Capture publication shares the note's
/// transactional change event; no cloud account or transport is needed to save knowledge.
enum DatabaseSchema {
    static func migrate(_ database: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("local-first-library-v1") { db in
            try db.execute(sql: """
            CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            CREATE TABLE notes (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                markdown TEXT NOT NULL,
                revision TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                deletedAt REAL
            );
            CREATE TABLE note_revisions (
                id TEXT PRIMARY KEY NOT NULL,
                noteID TEXT NOT NULL REFERENCES notes(id),
                parentID TEXT,
                name TEXT NOT NULL,
                markdown TEXT NOT NULL,
                createdAt REAL NOT NULL,
                isDeleted INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX note_revisions_note ON note_revisions(noteID, createdAt);
            CREATE TABLE local_changes (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                changeID TEXT NOT NULL UNIQUE,
                noteID TEXT NOT NULL REFERENCES notes(id),
                revision TEXT NOT NULL REFERENCES note_revisions(id),
                kind TEXT NOT NULL CHECK(kind IN ('save', 'delete', 'conflict')),
                createdAt REAL NOT NULL
            );
            CREATE TABLE embedding_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                descriptor BLOB NOT NULL
            );
            CREATE TABLE embeddings (
                profileID TEXT NOT NULL REFERENCES embedding_profiles(id),
                contentHash TEXT NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY(profileID, contentHash)
            );
            CREATE TABLE passages (
                rowid INTEGER PRIMARY KEY,
                id TEXT NOT NULL UNIQUE,
                noteID TEXT NOT NULL REFERENCES notes(id),
                name TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                text TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                UNIQUE(noteID, ordinal)
            );
            CREATE INDEX passages_hash ON passages(contentHash);
            CREATE VIRTUAL TABLE passage_fts USING fts5(
                name, text, content='passages', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER passages_insert AFTER INSERT ON passages BEGIN
                INSERT INTO passage_fts(rowid, name, text) VALUES (new.rowid, new.name, new.text);
            END;
            CREATE TRIGGER passages_delete AFTER DELETE ON passages BEGIN
                INSERT INTO passage_fts(passage_fts, rowid, name, text)
                VALUES ('delete', old.rowid, old.name, old.text);
            END;
            CREATE TRIGGER passages_update AFTER UPDATE ON passages BEGIN
                INSERT INTO passage_fts(passage_fts, rowid, name, text)
                VALUES ('delete', old.rowid, old.name, old.text);
                INSERT INTO passage_fts(rowid, name, text) VALUES (new.rowid, new.name, new.text);
            END;
            CREATE TABLE index_jobs (
                noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id),
                revision TEXT NOT NULL,
                profileID TEXT REFERENCES embedding_profiles(id),
                lastError TEXT
            );
            """)
        }
        migrator.registerMigration("document-capture-v1") { db in
            try db.execute(sql: """
            ALTER TABLE passages ADD COLUMN citation BLOB;
            CREATE TABLE sources (
                id TEXT PRIMARY KEY NOT NULL,
                identity TEXT NOT NULL UNIQUE,
                createdAt REAL NOT NULL
            );
            CREATE TABLE artifacts (
                hash TEXT PRIMARY KEY NOT NULL,
                descriptor BLOB NOT NULL,
                createdAt REAL NOT NULL
            );
            CREATE TABLE captures (
                id TEXT PRIMARY KEY NOT NULL,
                sourceID TEXT NOT NULL REFERENCES sources(id),
                noteID TEXT NOT NULL REFERENCES notes(id),
                fingerprint TEXT NOT NULL,
                markdownHash TEXT NOT NULL,
                extractorVersion TEXT NOT NULL,
                document BLOB NOT NULL,
                artifacts BLOB NOT NULL,
                createdAt REAL NOT NULL,
                UNIQUE(sourceID, fingerprint, extractorVersion)
            );
            CREATE INDEX captures_note ON captures(noteID);
            CREATE TABLE content_blocks (
                captureID TEXT NOT NULL REFERENCES captures(id),
                ordinal INTEGER NOT NULL,
                block BLOB NOT NULL,
                PRIMARY KEY(captureID, ordinal)
            );
            CREATE TABLE ingestion_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                token TEXT NOT NULL,
                request BLOB NOT NULL,
                acquired BLOB NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('queued','fetching','extracting','ready','failed','cancelled')),
                progress TEXT NOT NULL DEFAULT '',
                error TEXT,
                noteID TEXT REFERENCES notes(id),
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL
            );
            CREATE INDEX ingestion_jobs_state ON ingestion_jobs(state, createdAt);
            """)
        }
        migrator.registerMigration("media-capture-v1") { db in
            try db.execute(sql: "ALTER TABLE ingestion_jobs ADD COLUMN recovery TEXT")
        }
        migrator.registerMigration("permanent-delete-v1") { db in
            try db.execute(sql: """
            CREATE TABLE purged_notes (
                noteID TEXT PRIMARY KEY NOT NULL,
                deletionID TEXT NOT NULL,
                deletedAt REAL NOT NULL
            );
            CREATE TABLE artifact_deletions (hash TEXT PRIMARY KEY NOT NULL);
            """)
        }
        migrator.registerMigration("knowledge-graph-v1", migrate: GraphSchema.create)
        migrator.registerMigration("knowledge-graph-passage-cache-v1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS graph_passage_cache (
                noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                contentHash TEXT NOT NULL, version TEXT NOT NULL, mode TEXT NOT NULL,
                proposal BLOB NOT NULL, createdAt REAL NOT NULL,
                PRIMARY KEY(noteID, contentHash, version, mode)
            );
            """)
        }
        migrator.registerMigration("knowledge-mind-map-v1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mind_maps (
                noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                revision TEXT NOT NULL, version TEXT NOT NULL, rootID TEXT NOT NULL,
                generatedAt REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS mind_map_nodes (
                id TEXT PRIMARY KEY NOT NULL,
                noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                parentID TEXT, title TEXT NOT NULL, summary TEXT NOT NULL,
                role TEXT NOT NULL, ordinal INTEGER NOT NULL, depth INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS mind_map_nodes_note
                ON mind_map_nodes(noteID, parentID, ordinal);
            CREATE TABLE IF NOT EXISTS mind_map_evidence (
                id TEXT PRIMARY KEY NOT NULL,
                nodeID TEXT NOT NULL REFERENCES mind_map_nodes(id) ON DELETE CASCADE,
                noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                quote TEXT NOT NULL, citation BLOB, offset INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS mind_map_state (
                nodeID TEXT PRIMARY KEY NOT NULL,
                noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                collapsed INTEGER NOT NULL DEFAULT 0
            );
            """)
        }
        migrator.registerMigration("document-library-v1") { db in
            try db.execute(sql: """
            ALTER TABLE notes ADD COLUMN sourceURL TEXT;
            ALTER TABLE notes ADD COLUMN faviconURL TEXT;
            ALTER TABLE notes ADD COLUMN faviconData BLOB;
            ALTER TABLE notes ADD COLUMN faviconCheckedAt REAL;
            CREATE INDEX notes_library_order ON notes(updatedAt DESC, id) WHERE deletedAt IS NULL;
            """)
            // Recover provenance locally; existing icons are acquired only when a page is viewed.
            for row in try Row.fetchAll(
                db,
                sql: "SELECT noteID, document FROM captures ORDER BY createdAt"
            ) {
                let metadata = try JSONDecoder().decode(
                    CapturedDocument.self,
                    from: row["document"]
                )
                if let url = metadata.sourceURL {
                    try db.execute(
                        sql: "UPDATE notes SET sourceURL = ? WHERE id = ?",
                        arguments: [url.absoluteString, row["noteID"] as String]
                    )
                }
            }
        }
        migrator.registerMigration("general-conversation-v1", migrate: ConversationSchema.create)
        migrator.registerMigration("general-task-context-v1") { db in
            try db
                .execute(
                    sql: "ALTER TABLE conversation_tasks ADD COLUMN sourceRefs BLOB NOT NULL DEFAULT X'5B5D'"
                )
        }
        // Never erase a store on migration failure: the notes are the user's knowledge base.
        migrator.registerMigration("reviewable-filing-v1") { db in
            try db.execute(sql: "ALTER TABLE knowledge_proposals ADD COLUMN filing BLOB")
        }
        migrator.registerMigration("page-preview-v1") { db in
            try db.execute(sql: "ALTER TABLE notes ADD COLUMN previewImage BLOB")
        }
        // Which model wrote a capture's summary. Older summaries were all Apple Intelligence.
        migrator.registerMigration("summary-engine-v1") { db in
            try db.execute(sql: "ALTER TABLE notes ADD COLUMN summaryEngine TEXT")
        }
        // Bulk filing suggestions live outside conversation proposals: thousands of them need a
        // review queue of their own, and nothing is filed until someone accepts.
        migrator.registerMigration("filing-suggestions-v1") { db in
            try db.execute(sql: """
            CREATE TABLE filing_suggestions (
                noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                categoryID TEXT REFERENCES decimal_categories(id) ON DELETE CASCADE,
                newCategory TEXT,
                confidence REAL NOT NULL,
                engine TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('pending','accepted','rejected')),
                batch TEXT,
                createdAt REAL NOT NULL,
                CHECK(categoryID IS NOT NULL OR newCategory IS NOT NULL)
            );
            CREATE INDEX filing_suggestions_review ON filing_suggestions(status, categoryID);
            CREATE TABLE classification_cache (
                key TEXT PRIMARY KEY NOT NULL,
                code TEXT NOT NULL,
                newCategory TEXT,
                confident INTEGER NOT NULL,
                createdAt REAL NOT NULL
            );
            """)
        }
        try migrator.migrate(database)
    }
}
