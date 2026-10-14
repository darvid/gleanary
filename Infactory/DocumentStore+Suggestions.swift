import Foundation
import GRDB

/// A proposed home for an unfiled note, awaiting review.
struct FilingSuggestion: Identifiable, Sendable, Equatable {
    let noteID: UUID
    let title: String
    let host: String?
    let categoryID: UUID?
    /// A home the model suggested that doesn't exist yet.
    let newCategory: String?
    let confidence: Double
    /// The inference identifier that made the suggestion.
    let engine: String
    var id: UUID {
        noteID
    }

    /// Suggestions confident enough to accept in bulk without reading each one.
    var confident: Bool {
        categoryID != nil && confidence >= 0.75
    }
}

struct FilingSuggestionDraft: Sendable, Equatable {
    let noteID: UUID
    var categoryID: UUID?
    var newCategory: String?
    let confidence: Double
    let engine: String
}

/// A model answer kept so a rerun over the same text and taxonomy costs nothing.
struct CachedClassification: Sendable, Equatable {
    let code: String
    let newCategory: String?
    let confident: Bool
}

extension DocumentStore {
    /// Live notes with no category and no suggestion yet. A rejected suggestion is not retried.
    func filingCandidates() throws -> [FilingCandidate] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT n.id, n.revision, n.name, n.sourceURL, n.markdown FROM notes n
            WHERE n.deletedAt IS NULL
                AND NOT EXISTS (SELECT 1 FROM note_categories WHERE noteID = n.id)
                AND NOT EXISTS (SELECT 1 FROM filing_suggestions WHERE noteID = n.id)
            ORDER BY n.updatedAt DESC
            """).map { row in
                let source = (row["sourceURL"] as String?).flatMap(URL.init(string:))
                let name: String = row["name"]
                return try FilingCandidate(
                    id: Self.uuid(row["id"]),
                    revision: Self.uuid(row["revision"]),
                    title: name,
                    host: source?.host(),
                    text: FilingText.classification(
                        name: name,
                        sourceURL: source,
                        markdown: row["markdown"]
                    )
                )
            }
        }
    }

    /// Every live note's primary home, the examples the neighbour vote learns from.
    func filingExamples() throws -> [FilingExample] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT n.id, n.name, n.sourceURL, n.markdown, nc.categoryID FROM notes n
            JOIN note_categories nc ON nc.noteID = n.id AND nc.isPrimary = 1
            WHERE n.deletedAt IS NULL
            """).map { row in
                try FilingExample(
                    id: Self.uuid(row["id"]),
                    categoryID: Self.uuid(row["categoryID"]),
                    text: FilingText.classification(
                        name: row["name"],
                        sourceURL: (row["sourceURL"] as String?).flatMap(URL.init(string:)),
                        markdown: row["markdown"]
                    )
                )
            }
        }
    }

    func saveFilingSuggestions(_ drafts: [FilingSuggestionDraft]) throws {
        guard !drafts.isEmpty else { return }
        try readyDatabase().write { db in
            let now = Date().timeIntervalSince1970
            for draft in drafts where draft.categoryID != nil || draft.newCategory != nil {
                try db.execute(sql: """
                INSERT OR IGNORE INTO filing_suggestions(
                    noteID, categoryID, newCategory, confidence, engine, status, createdAt
                )
                SELECT ?, ?, ?, ?, ?, 'pending', ? WHERE EXISTS (
                    SELECT 1 FROM notes WHERE id = ? AND deletedAt IS NULL
                )
                """, arguments: [
                    draft.noteID.uuidString, draft.categoryID?.uuidString,
                    draft.newCategory.map { String($0.prefix(100)) },
                    min(1, max(0, draft.confidence)), draft.engine, now,
                    draft.noteID.uuidString,
                ])
            }
        }
    }

    func pendingFilingSuggestions() throws -> [FilingSuggestion] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT s.*, n.name, n.sourceURL FROM filing_suggestions s
            JOIN notes n ON n.id = s.noteID AND n.deletedAt IS NULL
            WHERE s.status = 'pending'
            ORDER BY s.confidence DESC, n.name
            """).map { row in
                try FilingSuggestion(
                    noteID: Self.uuid(row["noteID"]),
                    title: row["name"],
                    host: (row["sourceURL"] as String?).flatMap(URL.init(string:))?.host(),
                    categoryID: (row["categoryID"] as String?).map(Self.uuid),
                    newCategory: row["newCategory"],
                    confidence: row["confidence"],
                    engine: row["engine"]
                )
            }
        }
    }

    /// Files each still-unfiled note in its suggested home, as one undoable batch. A note
    /// someone filed in the meantime keeps its home and the suggestion is dropped.
    func acceptFilingSuggestions(_ noteIDs: [UUID]) throws -> (accepted: Int, batch: UUID) {
        let batch = UUID()
        let accepted = try readyDatabase().write { db in
            var accepted = 0
            for id in noteIDs {
                guard let categoryID = try String.fetchOne(db, sql: """
                SELECT s.categoryID FROM filing_suggestions s
                JOIN notes n ON n.id = s.noteID AND n.deletedAt IS NULL
                WHERE s.noteID = ? AND s.status = 'pending' AND s.categoryID IS NOT NULL
                """, arguments: [id.uuidString]) else { continue }
                let filed = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM note_categories WHERE noteID = ?)",
                    arguments: [id.uuidString]
                ) ?? false
                if filed {
                    try db.execute(
                        sql: "UPDATE filing_suggestions SET status = 'rejected' WHERE noteID = ?",
                        arguments: [id.uuidString]
                    )
                    continue
                }
                try Self.fileImported(id, categoryID: Self.uuid(categoryID), in: db)
                try db.execute(
                    sql: "UPDATE filing_suggestions SET status = 'accepted', batch = ? WHERE noteID = ?",
                    arguments: [batch.uuidString, id.uuidString]
                )
                accepted += 1
            }
            return accepted
        }
        return (accepted, batch)
    }

    func rejectFilingSuggestions(_ noteIDs: [UUID]) throws {
        try readyDatabase().write { db in
            for id in noteIDs {
                try db.execute(
                    sql: "UPDATE filing_suggestions SET status = 'rejected' WHERE noteID = ? AND status = 'pending'",
                    arguments: [id.uuidString]
                )
            }
        }
    }

    /// Returns a batch's notes to unfiled and their suggestions to review. Notes moved since
    /// keep their newer home.
    func undoFilingSuggestions(batch: UUID) throws -> Int {
        try readyDatabase().write { db in
            var restored = 0
            for row in try Row.fetchAll(
                db,
                sql: "SELECT noteID, categoryID FROM filing_suggestions WHERE batch = ? AND status = 'accepted'",
                arguments: [batch.uuidString]
            ) {
                let noteID: String = row["noteID"], categoryID: String = row["categoryID"]
                try db.execute(
                    sql: "DELETE FROM note_categories WHERE noteID = ? AND categoryID = ? AND isPrimary = 1",
                    arguments: [noteID, categoryID]
                )
                guard db.changesCount > 0 else { continue }
                try db.execute(sql: """
                DELETE FROM source_categories WHERE categoryID = ?1 AND sourceID IN (
                    SELECT sourceID FROM note_sources WHERE noteID = ?2
                ) AND NOT EXISTS (
                    SELECT 1 FROM note_sources other JOIN note_categories nc ON nc.noteID = other.noteID
                    WHERE other.sourceID = source_categories.sourceID AND nc.categoryID = ?1
                )
                """, arguments: [categoryID, noteID])
                try db.execute(
                    sql: "UPDATE filing_suggestions SET status = 'pending', batch = NULL WHERE noteID = ?",
                    arguments: [noteID]
                )
                restored += 1
            }
            return restored
        }
    }

    /// Creates a category a model proposed and points its pending suggestions at it.
    func createSuggestedCategory(_ name: String, code: String) throws -> UUID {
        try DecimalCategory.validate(code: code, name: name)
        let id = UUID()
        try saveCategory(id: id, code: code, name: name)
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE filing_suggestions SET categoryID = ?, newCategory = NULL
            WHERE status = 'pending' AND categoryID IS NULL AND newCategory = ?
            """, arguments: [id.uuidString, name])
        }
        return id
    }

    func cachedClassifications(_ keys: [String]) throws -> [String: CachedClassification] {
        try readyDatabase().read { db in
            var found: [String: CachedClassification] = [:]
            for key in keys {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM classification_cache WHERE key = ?",
                    arguments: [key]
                ) {
                    found[key] = CachedClassification(
                        code: row["code"],
                        newCategory: row["newCategory"],
                        confident: row["confident"]
                    )
                }
            }
            return found
        }
    }

    func cacheClassifications(_ answers: [String: CachedClassification]) throws {
        try readyDatabase().write { db in
            let now = Date().timeIntervalSince1970
            for (key, answer) in answers {
                try db.execute(sql: """
                INSERT OR REPLACE INTO classification_cache(key, code, newCategory, confident, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [key, answer.code, answer.newCategory, answer.confident, now])
            }
        }
    }
}
