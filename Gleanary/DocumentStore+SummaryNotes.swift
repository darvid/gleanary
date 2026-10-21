import Foundation
import GRDB

extension DocumentStore {
    func explicitSummaryIDs(for sourceNoteID: UUID) throws -> Set<UUID> {
        try readyDatabase().read { db in
            try Set(String.fetchAll(db, sql: """
            SELECT DISTINCT ns.noteID FROM note_sources ns JOIN captures c ON c.sourceID = ns.sourceID
            WHERE c.noteID = ? AND ns.summaryRole = 'summary'
            """, arguments: [sourceNoteID.uuidString]).map(Self.uuid))
        }
    }

    /// User-confirmed role, not an inference from an ordinary link or the note's title.
    func associateSummary(_ noteID: UUID, with sourceNoteID: UUID, enabled: Bool = true) throws {
        try activityWrite(
            actor: "manual",
            label: enabled ? "Associated summary" : "Removed summary role"
        ) { db in
            _ = try Self.liveNote(noteID, in: db)
            _ = try Self.liveNote(sourceNoteID, in: db)
            guard noteID != sourceNoteID,
                  let sourceID = try String.fetchOne(db, sql: """
                  SELECT sourceID FROM captures WHERE noteID = ? ORDER BY createdAt DESC LIMIT 1
                  """, arguments: [sourceNoteID.uuidString]),
                  let kind = try String.fetchOne(db, sql: """
                  SELECT \(Self.libraryKindSQL) FROM notes n WHERE n.id = ?
                  """, arguments: [noteID.uuidString]), kind != "source"
            else { throw LinkSummaryError.editedCapture }
            if enabled {
                try db.execute(sql: """
                INSERT INTO note_sources(noteID, sourceID, summaryRole) VALUES (?, ?, 'summary')
                ON CONFLICT(noteID, sourceID) DO UPDATE SET summaryRole = 'summary'
                """, arguments: [noteID.uuidString, sourceID])
            } else {
                // Keep provenance: removing a role must not discard an existing citation.
                try db.execute(
                    sql: "UPDATE note_sources SET summaryRole = 'reference' WHERE noteID = ? AND sourceID = ?",
                    arguments: [noteID.uuidString, sourceID]
                )
            }
        }
    }

    func summaryNoteInput(
        for document: MarkdownDocument,
        createAnother: Bool = false
    ) throws -> CaptureDetail {
        let captureID = try readyDatabase().read { db -> UUID in
            let current = try Self.liveNote(document.id, in: db)
            guard current.revision == document.revision else { throw GleanaryError.editConflict }
            if !createAnother, try !Self.librarySummaries(for: document.id, in: db).isEmpty {
                throw LinkSummaryError.alreadySummarized
            }
            guard let capture = try String.fetchOne(db, sql: """
            SELECT id FROM captures WHERE noteID = ? ORDER BY createdAt DESC LIMIT 1
            """, arguments: [document.id.uuidString]) else { throw LinkSummaryError.editedCapture }
            return try Self.uuid(capture)
        }
        let detail = try captureDetail(id: captureID)
        let legacySummary = detail.artifacts.contains {
            $0.name == "Summary.md" && $0.hash == ContentHash.of(document.markdown)
        }
        let summaryFirst = try librarySummaries(for: document.id).contains { $0.id == document.id }
        guard document.markdown == detail.document
            .markdown || legacySummary || (createAnother && summaryFirst)
        else { throw LinkSummaryError.editedCapture }
        return detail
    }

    /// Publish a separate editable note; never replace the source or an existing summary.
    func publishSummaryNote(
        _ markdown: String, for document: MarkdownDocument, captureID: UUID,
        engine: String, createAnother: Bool = false
    ) throws -> MarkdownDocument {
        try Task.checkCancellation()
        return try activityWrite(actor: "app", label: "Created summary note") { db in
            let current = try Self.liveNote(document.id, in: db)
            guard current.revision == document.revision else { throw GleanaryError.editConflict }
            let existingSummaries = try Self.librarySummaries(for: document.id, in: db)
            if !createAnother,
               !existingSummaries.isEmpty
            {
                throw LinkSummaryError.alreadySummarized
            }
            guard let sourceID = try String.fetchOne(db, sql: """
            SELECT sourceID FROM captures WHERE id = ? AND noteID = ?
            """, arguments: [captureID.uuidString, document.id.uuidString])
            else { throw LinkSummaryError.editedCapture }
            let existingNames = Set(existingSummaries.map(\.name))
            var name = String("Summary: \(document.name)".prefix(240))
            var ordinal = 2
            while existingNames.contains(name) {
                name = String("Summary \(ordinal): \(document.name)".prefix(240))
                ordinal += 1
            }
            let note = MarkdownDocument(name: name, markdown: markdown)
            try Self.validate(note)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw LinkSummaryError.invalidOutput }
            let saved = try Self.writeNote(note, in: db)
            try db.execute(
                sql: "INSERT INTO note_sources(noteID, sourceID, summaryRole) VALUES (?, ?, 'summary')",
                arguments: [saved.id.uuidString, sourceID]
            )
            try db.execute(
                sql: "UPDATE notes SET summaryEngine = ? WHERE id = ?",
                arguments: [engine.isEmpty ? nil : engine, saved.id.uuidString]
            )
            try db.execute(sql: """
            INSERT INTO note_categories(noteID, categoryID, isPrimary)
                SELECT ?, categoryID, isPrimary FROM note_categories WHERE noteID = ?
            """, arguments: [saved.id.uuidString, document.id.uuidString])
            return saved
        }
    }
}
