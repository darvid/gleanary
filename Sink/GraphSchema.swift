import GRDB

/// Graph evidence is derived from a specific revision. Dismissals are user data, not cache.
enum GraphSchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE graph_nodes (
            id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, label TEXT NOT NULL,
            noteID TEXT UNIQUE REFERENCES notes(id) ON DELETE CASCADE
        );
        CREATE INDEX graph_nodes_label ON graph_nodes(label COLLATE NOCASE);
        CREATE TABLE graph_edges (
            id TEXT PRIMARY KEY NOT NULL,
            source TEXT NOT NULL REFERENCES graph_nodes(id) ON DELETE CASCADE,
            target TEXT NOT NULL REFERENCES graph_nodes(id) ON DELETE CASCADE,
            predicate TEXT NOT NULL,
            UNIQUE(source, target, predicate)
        );
        CREATE INDEX graph_edges_source ON graph_edges(source);
        CREATE INDEX graph_edges_target ON graph_edges(target);
        CREATE TABLE graph_evidence (
            id TEXT PRIMARY KEY NOT NULL,
            edgeID TEXT NOT NULL REFERENCES graph_edges(id) ON DELETE CASCADE,
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            revision TEXT NOT NULL, quote TEXT NOT NULL, citation BLOB,
            offset INTEGER NOT NULL, origin TEXT NOT NULL, chunk INTEGER NOT NULL
        );
        CREATE INDEX graph_evidence_note ON graph_evidence(noteID);
        CREATE INDEX graph_evidence_edge ON graph_evidence(edgeID);
        CREATE TABLE graph_decisions (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            edgeID TEXT NOT NULL, PRIMARY KEY(noteID, edgeID)
        );
        CREATE TABLE graph_jobs (
            noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            revision TEXT NOT NULL, version TEXT NOT NULL, token TEXT NOT NULL,
            state TEXT NOT NULL, completed INTEGER NOT NULL DEFAULT 0,
            total INTEGER NOT NULL DEFAULT 0, chunks BLOB, error TEXT
        );
        CREATE INDEX graph_jobs_state ON graph_jobs(state);
        CREATE TABLE graph_passage_cache (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            contentHash TEXT NOT NULL, version TEXT NOT NULL, mode TEXT NOT NULL,
            proposal BLOB NOT NULL, createdAt REAL NOT NULL,
            PRIMARY KEY(noteID, contentHash, version, mode)
        );
        CREATE TABLE graph_links (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            identity TEXT NOT NULL, quote TEXT NOT NULL, offset INTEGER NOT NULL,
            PRIMARY KEY(noteID, identity, offset)
        );
        CREATE TABLE mind_maps (
            noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            revision TEXT NOT NULL, version TEXT NOT NULL, rootID TEXT NOT NULL,
            generatedAt REAL NOT NULL
        );
        CREATE TABLE mind_map_nodes (
            id TEXT PRIMARY KEY NOT NULL,
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            parentID TEXT, title TEXT NOT NULL, summary TEXT NOT NULL,
            role TEXT NOT NULL, ordinal INTEGER NOT NULL, depth INTEGER NOT NULL
        );
        CREATE INDEX mind_map_nodes_note ON mind_map_nodes(noteID, parentID, ordinal);
        CREATE TABLE mind_map_evidence (
            id TEXT PRIMARY KEY NOT NULL,
            nodeID TEXT NOT NULL REFERENCES mind_map_nodes(id) ON DELETE CASCADE,
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            quote TEXT NOT NULL, citation BLOB, offset INTEGER NOT NULL
        );
        CREATE TABLE mind_map_state (
            nodeID TEXT PRIMARY KEY NOT NULL,
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            collapsed INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE graph_layout (
            nodeID TEXT PRIMARY KEY NOT NULL REFERENCES graph_nodes(id) ON DELETE CASCADE,
            x REAL NOT NULL, y REAL NOT NULL, pinned INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE graph_node_fts USING fts5(
            id UNINDEXED, label, tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER graph_node_insert AFTER INSERT ON graph_nodes BEGIN
            INSERT INTO graph_node_fts(id, label) VALUES(new.id, new.label);
        END;
        CREATE TRIGGER graph_node_delete AFTER DELETE ON graph_nodes BEGIN
            DELETE FROM graph_node_fts WHERE id = old.id;
        END;
        CREATE TRIGGER graph_node_update AFTER UPDATE OF label ON graph_nodes BEGIN
            DELETE FROM graph_node_fts WHERE id = old.id;
            INSERT INTO graph_node_fts(id, label) VALUES(new.id, new.label);
        END;
        """)
    }
}
