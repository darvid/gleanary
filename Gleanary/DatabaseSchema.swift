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
        // Changes the library agent proposes. Nothing here touches a note until someone applies
        // it; each row keeps what it replaced so it can be undone.
        migrator.registerMigration("agent-changes-v1") { db in
            try db.execute(sql: """
            CREATE TABLE agent_changes (
                id TEXT PRIMARY KEY NOT NULL,
                taskID TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('title','summary','filing','category')),
                noteID TEXT,
                code TEXT,
                before TEXT NOT NULL,
                after TEXT NOT NULL,
                reason TEXT NOT NULL,
                baseRevision TEXT,
                appliedRevision TEXT,
                snapshot TEXT,
                status TEXT NOT NULL
                    CHECK(status IN ('pending','applied','rejected','stale','undone')),
                createdAt REAL NOT NULL
            );
            CREATE INDEX agent_changes_task ON agent_changes(taskID, ordinal);
            """)
        }
        // Scheduled library maintenance (SPEC §7.4) and archiving (§7.5). Changes gain archive
        // and link kinds; SQLite can't alter a CHECK, so that table is rebuilt in place.
        migrator.registerMigration("automations-v1") { db in
            try db.execute(sql: """
            ALTER TABLE notes ADD COLUMN archivedAt REAL;
            ALTER TABLE notes ADD COLUMN archiveReason TEXT;
            CREATE TABLE agent_changes_v2 (
                id TEXT PRIMARY KEY NOT NULL,
                taskID TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                kind TEXT NOT NULL
                    CHECK(kind IN ('title','summary','filing','category','archive','link')),
                noteID TEXT,
                targetID TEXT,
                code TEXT,
                before TEXT NOT NULL,
                after TEXT NOT NULL,
                reason TEXT NOT NULL,
                baseRevision TEXT,
                appliedRevision TEXT,
                snapshot TEXT,
                status TEXT NOT NULL
                    CHECK(status IN ('pending','applied','rejected','stale','undone')),
                createdAt REAL NOT NULL
            );
            INSERT INTO agent_changes_v2(id, taskID, ordinal, kind, noteID, code, before, after,
                reason, baseRevision, appliedRevision, snapshot, status, createdAt)
            SELECT id, taskID, ordinal, kind, noteID, code, before, after, reason, baseRevision,
                appliedRevision, snapshot, status, createdAt FROM agent_changes;
            DROP TABLE agent_changes;
            ALTER TABLE agent_changes_v2 RENAME TO agent_changes;
            CREATE INDEX agent_changes_task ON agent_changes(taskID, ordinal);
            CREATE TABLE note_links (
                leftID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                rightID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                changeID TEXT NOT NULL,
                rationale TEXT NOT NULL,
                createdAt REAL NOT NULL,
                PRIMARY KEY(leftID, rightID), CHECK(leftID < rightID)
            );
            CREATE TABLE automations (
                id TEXT PRIMARY KEY NOT NULL,
                enabled INTEGER NOT NULL,
                interval REAL NOT NULL,
                batchLimit INTEGER NOT NULL,
                cloudAllowed INTEGER NOT NULL,
                dailyCalls INTEGER NOT NULL,
                lastRunAt REAL
            );
            CREATE TABLE automation_runs (
                id TEXT PRIMARY KEY NOT NULL,
                automationID TEXT NOT NULL,
                startedAt REAL NOT NULL,
                endedAt REAL,
                status TEXT NOT NULL
                    CHECK(status IN ('running','succeeded','partial','failed','cancelled')),
                examined INTEGER NOT NULL DEFAULT 0,
                changed INTEGER NOT NULL DEFAULT 0,
                proposed INTEGER NOT NULL DEFAULT 0,
                skipped INTEGER NOT NULL DEFAULT 0,
                calls INTEGER NOT NULL DEFAULT 0,
                report TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX automation_runs_recent ON automation_runs(automationID, startedAt);
            CREATE TABLE item_checks (
                noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                checkedAt REAL NOT NULL,
                state TEXT NOT NULL,
                failures INTEGER NOT NULL DEFAULT 0,
                firstFailureAt REAL,
                detail TEXT,
                PRIMARY KEY(noteID, kind)
            );
            """)
        }
        migrator.registerMigration("automation-entries-v1") { db in
            // Per-item outcomes for run history, and proposals to update a moved link.
            try db.execute(sql: """
            ALTER TABLE automation_runs ADD COLUMN entries TEXT NOT NULL DEFAULT '[]';
            ALTER TABLE automation_runs ADD COLUMN fine INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE agent_changes_v3 (
                id TEXT PRIMARY KEY NOT NULL,
                taskID TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN
                    ('title','summary','filing','category','archive','link','relink')),
                noteID TEXT,
                targetID TEXT,
                code TEXT,
                before TEXT NOT NULL,
                after TEXT NOT NULL,
                reason TEXT NOT NULL,
                baseRevision TEXT,
                appliedRevision TEXT,
                snapshot TEXT,
                status TEXT NOT NULL
                    CHECK(status IN ('pending','applied','rejected','stale','undone')),
                createdAt REAL NOT NULL
            );
            INSERT INTO agent_changes_v3 SELECT id, taskID, ordinal, kind, noteID, targetID, code,
                before, after, reason, baseRevision, appliedRevision, snapshot, status, createdAt
                FROM agent_changes;
            DROP TABLE agent_changes;
            ALTER TABLE agent_changes_v3 RENAME TO agent_changes;
            CREATE INDEX agent_changes_task ON agent_changes(taskID, ordinal);
            """)
        }
        migrator.registerMigration("automation-scale-v1") { db in
            // Separate from automation-entries-v1, which earlier builds already applied.
            try db.execute(sql: """
            ALTER TABLE automations ADD COLUMN recheck REAL NOT NULL DEFAULT 2592000;
            -- Finding items with no links looks both ways; the primary keys cover leftID.
            CREATE INDEX IF NOT EXISTS note_links_right ON note_links(rightID);
            CREATE INDEX IF NOT EXISTS knowledge_links_right ON knowledge_links(rightID);
            -- Proposals already made for an item, checked before proposing again.
            CREATE INDEX IF NOT EXISTS agent_changes_note ON agent_changes(noteID, kind);
            """)
        }
        migrator.registerMigration("automation-upkeep-v1", migrate: automationUpkeep)
        migrator.registerMigration("automation-archive-v1") { db in
            // Whether the link checker archives dead links itself rather than asking first.
            try db.execute(
                sql: "ALTER TABLE automations ADD COLUMN archivesDeadLinks INTEGER NOT NULL DEFAULT 0"
            )
        }
        migrator.registerMigration("writer-v1", migrate: writer)
        // The weekly digest can be written up by the Writer. Its model-call budget was never
        // shown before, so the 0 saved for it becomes the usual 200.
        migrator.registerMigration("writer-digest-v1") { db in
            try db.execute(sql: """
            ALTER TABLE automations ADD COLUMN usesWriter INTEGER NOT NULL DEFAULT 0;
            UPDATE automations SET dailyCalls = 200 WHERE id = 'weekly-digest' AND dailyCalls = 0;
            """)
        }
        migrator.registerMigration("web-research-v1") { db in
            try db.execute(sql: """
            CREATE TABLE web_research_evidence (
                noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                evidence BLOB NOT NULL, createdAt REAL NOT NULL
            );
            """)
        }
        migrator.registerMigration("note-series-v1", migrate: NoteSeriesSchema.create)
        migrator.registerMigration("library-activity-v1", migrate: ActivitySchema.create)
        migrator.registerMigration("linked-source-capture-index-v1") { db in
            try db.execute(sql: """
            CREATE INDEX ingestion_jobs_identity ON ingestion_jobs(
                json_extract(CAST(request AS TEXT), '$.identity')
            );
            """)
        }
        migrator.registerMigration("explicit-summary-role-v1") { db in
            try db.execute(sql: """
            ALTER TABLE note_sources ADD COLUMN summaryRole TEXT CHECK(summaryRole IN ('summary','reference'));
            CREATE INDEX note_sources_summaries ON note_sources(sourceID, noteID) WHERE summaryRole = 'summary';
            UPDATE note_sources AS ns SET summaryRole = 'summary' WHERE EXISTS (
                SELECT 1 FROM captures c JOIN notes n ON n.id = c.noteID,
                    json_each(CAST(c.artifacts AS TEXT)) artifact
                WHERE c.noteID = ns.noteID AND c.sourceID = ns.sourceID
                    AND json_extract(artifact.value, '$.name') = 'Summary.md'
                    AND json_extract(artifact.value, '$.kind') = 'markdown'
                    AND json_extract(artifact.value, '$.hash') = n.contentHash
            );
            UPDATE notes SET summaryEngine = coalesce(summaryEngine, 'Apple Intelligence')
                WHERE EXISTS (SELECT 1 FROM note_sources
                    WHERE noteID = notes.id AND summaryRole = 'summary');
            """)
        }
        migrator.registerMigration("typed-notes-and-tasks-v1", migrate: NoteWorkspaceSchema.create)
        try migrator.migrate(database)
    }

    /// The Writer (SPEC §7.6): each compose or refresh request with its style and source
    /// selection, extraction records cached by source content, and a revision change kind so a
    /// refresh is reviewed before it saves. The changes table is rebuilt for its CHECK again.
    private static func writer(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE writer_requests (
            taskID TEXT PRIMARY KEY NOT NULL,
            noteID TEXT,
            kind TEXT NOT NULL CHECK(kind IN ('compose','refresh')),
            request TEXT NOT NULL,
            style TEXT NOT NULL,
            brief TEXT NOT NULL,
            generalKnowledge INTEGER NOT NULL,
            scopeLimit INTEGER NOT NULL,
            candidates TEXT NOT NULL DEFAULT '[]',
            selection TEXT NOT NULL DEFAULT '[]',
            excluded TEXT NOT NULL DEFAULT '[]',
            sources TEXT NOT NULL DEFAULT '[]',
            status TEXT NOT NULL CHECK(status IN
                ('awaiting','writing','saved','proposed','unchanged','cancelled')),
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE INDEX writer_requests_note ON writer_requests(noteID, createdAt);
        CREATE TABLE extraction_records (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            contentHash TEXT NOT NULL,
            fieldsKey TEXT NOT NULL,
            records TEXT NOT NULL,
            engine TEXT NOT NULL,
            createdAt REAL NOT NULL,
            PRIMARY KEY(noteID, contentHash, fieldsKey)
        );
        CREATE TABLE agent_changes_v5 (
            id TEXT PRIMARY KEY NOT NULL,
            taskID TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('title','summary','filing','category','archive',
                'link','relink','note','revision')),
            noteID TEXT,
            targetID TEXT,
            code TEXT,
            before TEXT NOT NULL,
            after TEXT NOT NULL,
            reason TEXT NOT NULL,
            baseRevision TEXT,
            appliedRevision TEXT,
            snapshot TEXT,
            status TEXT NOT NULL
                CHECK(status IN ('pending','applied','rejected','stale','undone')),
            createdAt REAL NOT NULL
        );
        INSERT INTO agent_changes_v5 SELECT id, taskID, ordinal, kind, noteID, targetID, code,
            before, after, reason, baseRevision, appliedRevision, snapshot, status, createdAt
            FROM agent_changes;
        DROP TABLE agent_changes;
        ALTER TABLE agent_changes_v5 RENAME TO agent_changes;
        CREATE INDEX agent_changes_task ON agent_changes(taskID, ordinal);
        CREATE INDEX agent_changes_note ON agent_changes(noteID, kind);
        """)
    }

    /// The bookmark fetcher, failed-capture retry, unfiled filer and weekly digest. Failed
    /// captures keep whether they may pass on their own and the retry's progress; changes gain
    /// the digest's new note, so that table is rebuilt again.
    private static func automationUpkeep(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE ingestion_jobs ADD COLUMN retryable INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE ingestion_jobs ADD COLUMN autoRetries INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE ingestion_jobs ADD COLUMN retryAt REAL;
        -- A bookmark's page fetches, looked up for every bookmark the fetcher considers.
        CREATE INDEX IF NOT EXISTS ingestion_jobs_replacing
            ON ingestion_jobs(json_extract(CAST(request AS TEXT), '$.replacingNoteID'));
        -- What was saved in a week, for the digest.
        CREATE INDEX IF NOT EXISTS notes_created ON notes(createdAt) WHERE deletedAt IS NULL;
        CREATE TABLE agent_changes_v4 (
            id TEXT PRIMARY KEY NOT NULL,
            taskID TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN
                ('title','summary','filing','category','archive','link','relink','note')),
            noteID TEXT,
            targetID TEXT,
            code TEXT,
            before TEXT NOT NULL,
            after TEXT NOT NULL,
            reason TEXT NOT NULL,
            baseRevision TEXT,
            appliedRevision TEXT,
            snapshot TEXT,
            status TEXT NOT NULL
                CHECK(status IN ('pending','applied','rejected','stale','undone')),
            createdAt REAL NOT NULL
        );
        INSERT INTO agent_changes_v4 SELECT id, taskID, ordinal, kind, noteID, targetID, code,
            before, after, reason, baseRevision, appliedRevision, snapshot, status, createdAt
            FROM agent_changes;
        DROP TABLE agent_changes;
        ALTER TABLE agent_changes_v4 RENAME TO agent_changes;
        CREATE INDEX agent_changes_task ON agent_changes(taskID, ordinal);
        CREATE INDEX agent_changes_note ON agent_changes(noteID, kind);
        """)
        // Failures from before this kept no reason code; judge them by their message.
        for row in try Row.fetchAll(db, sql: """
        SELECT id, error FROM ingestion_jobs WHERE state = 'failed' AND recovery IS NULL
        """) {
            guard let message: String = row["error"], CaptureFailure.retryable(message: message)
            else { continue }
            try db.execute(
                sql: "UPDATE ingestion_jobs SET retryable = 1 WHERE id = ?",
                arguments: [row["id"] as String]
            )
        }
    }
}
