import Foundation
import GRDB

/// Why an entity couldn't be recorded against a note, worded for the assistant to act on.
enum EntityEditError: LocalizedError {
    case noteUnavailable, notMentioned(String)

    var errorDescription: String? {
        switch self {
        case .noteUnavailable: "That item is deleted or archived."
        case let .notMentioned(name):
            "The item doesn't contain that quote or the name \"\(name)\". Quote its exact words."
        }
    }
}

extension EntitySchema {
    /// Entities recorded by hand or by the assistant, kept apart from extraction so saving the
    /// note, which clears its evidence, can put them back while the quote is still there.
    static func addAssertions(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE entity_assertions (
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            entityID TEXT NOT NULL,
            label TEXT NOT NULL,
            kind TEXT NOT NULL,
            quote TEXT NOT NULL,
            createdAt REAL NOT NULL,
            PRIMARY KEY(noteID, entityID)
        );
        CREATE INDEX entity_assertions_entity ON entity_assertions(entityID);
        """)
    }
}

extension DocumentStore {
    /// Records that a note mentions an entity, creating the entity if it's new or adding the
    /// note to one with the same name and kind. The quote must be in the note; empty uses the
    /// name's first mention. Returns the entity's ID.
    @discardableResult
    func recordEntity(
        _ name: String,
        kind: GraphNode.Kind,
        in noteID: UUID,
        quote: String
    ) throws -> String {
        let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !label.isEmpty, kind != .document else { throw GleanaryError.invalidNote }
        return try readyDatabase().write { db in
            guard let note = try Row.fetchOne(db, sql: """
            SELECT name, markdown, revision FROM notes
            WHERE id = ? AND deletedAt IS NULL AND archivedAt IS NULL
            """, arguments: [noteID.uuidString]),
            let revision = UUID(uuidString: note["revision"])
            else { throw EntityEditError.noteUnavailable }
            let markdown: String = note["markdown"]
            let wanted = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let found = Self.passage(wanted, or: label, in: markdown) else {
                throw EntityEditError.notMentioned(label)
            }
            let entity = GraphNode.entity(label, kind: kind, noteID: noteID)
            try db.execute(sql: """
            INSERT INTO entity_assertions(noteID, entityID, label, kind, quote, createdAt)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(noteID, entityID) DO UPDATE SET quote = excluded.quote
            """, arguments: [
                noteID.uuidString, entity.id, label, kind.rawValue, found.quote,
                Date().timeIntervalSince1970,
            ])
            try Self.insertAssertion(
                entity, quote: found.quote, offset: found.offset,
                note: (noteID, revision, note["name"]), in: db
            )
            // Recording it again brings back an entity you'd hidden.
            try db.execute(
                sql: "UPDATE entity_overrides SET hidden = 0 WHERE entityID = ?",
                arguments: [entity.id]
            )
            // Names come from quotes; when this one doesn't spell the name out, keep the name
            // as given rather than a recapitalized label, unless you've already named it.
            if found.quote
                .range(of: label, options: [.caseInsensitive, .diacriticInsensitive]) == nil
            {
                try db.execute(sql: """
                INSERT INTO entity_overrides(entityID, name, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(entityID) DO UPDATE SET name = coalesce(name, excluded.name)
                """, arguments: [entity.id, label, Date().timeIntervalSince1970])
            }
            return entity.id
        }
    }

    /// Hides an entity and anything merged into it, and drops the mentions recorded by hand,
    /// so it leaves the list and later reading doesn't bring it back.
    func removeEntity(_ id: String) throws {
        try readyDatabase().write { db in
            let ids = try String.fetchAll(db, sql: """
            SELECT ? UNION SELECT entityID FROM entity_overrides WHERE mergedInto = ?
            """, arguments: [id, id])
            for entity in ids {
                try db.execute(sql: """
                DELETE FROM entity_assertions WHERE entityID = ?;
                DELETE FROM graph_evidence WHERE origin = 'recorded' AND edgeID IN (
                    SELECT id FROM graph_edges WHERE source = ? OR target = ?
                );
                """, arguments: [entity, entity, entity])
            }
            try db.execute(sql: """
            INSERT INTO entity_overrides(entityID, hidden, updatedAt) VALUES (?, 1, ?)
            ON CONFLICT(entityID) DO UPDATE SET hidden = 1, updatedAt = excluded.updatedAt
            """, arguments: [id, Date().timeIntervalSince1970])
            try Self.pruneGraph(in: db)
        }
    }

    /// Puts recorded entities back after a save cleared the note's evidence, for those whose
    /// quote the new text still has.
    static func reapplyEntityAssertions(_ document: MarkdownDocument, in db: Database) throws {
        guard let revision = document.revision else { return }
        let rows = try Row.fetchAll(
            db, sql: "SELECT label, kind, quote FROM entity_assertions WHERE noteID = ?",
            arguments: [document.id.uuidString]
        )
        for row in rows {
            guard let kind = GraphNode.Kind(rawValue: row["kind"]) else { continue }
            let label: String = row["label"]
            guard let found = passage(row["quote"], or: label, in: document.markdown) else {
                continue
            }
            try insertAssertion(
                GraphNode.entity(label, kind: kind, noteID: document.id),
                quote: found.quote, offset: found.offset,
                note: (document.id, revision, document.name), in: db
            )
        }
    }

    private static func insertAssertion(
        _ entity: GraphNode,
        quote: String,
        offset: Int,
        note: (id: UUID, revision: UUID, name: String),
        in db: Database
    ) throws {
        let document = GraphNode(
            id: GraphNode.documentID(note.id), kind: .document, label: note.name, noteID: note.id
        )
        let job = GraphJob(
            noteID: note.id, revision: note.revision, token: UUID(), name: note.name,
            state: "ready", completed: 0, total: 0, error: nil
        )
        try insertGraphClaim(GraphClaim(
            source: document, target: entity, predicate: .mentions, quote: quote,
            citation: nil, offset: offset, origin: "recorded"
        ), job: job, chunk: -3, in: db)
    }

    /// The quote as the note has it, else the name's first mention, with its UTF-16 offset.
    private static func passage(
        _ quote: String,
        or name: String,
        in markdown: String
    ) -> (quote: String, offset: Int)? {
        for wanted in [quote, name] where !wanted.isEmpty {
            if let range = markdown.range(
                of: wanted, options: [.caseInsensitive, .diacriticInsensitive]
            ) {
                return (
                    String(markdown[range].prefix(500)),
                    range.lowerBound.utf16Offset(in: markdown)
                )
            }
        }
        return nil
    }
}
