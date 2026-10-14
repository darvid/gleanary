import Foundation
import GRDB

/// A link between two items, from either a chat proposal or an automation's change.
struct LinkedItem: Identifiable, Sendable, Equatable {
    let document: DocumentSummary
    let rationale: String

    var id: UUID {
        document.id
    }
}

extension DocumentStore {
    /// Keeps the item whole but out of the way: hidden from the library, Atlas, search and chat
    /// retrieval until unarchived. Passages stay, so unarchiving needs no reindex.
    func archive(_ noteID: UUID, reason: String) throws {
        try readyDatabase().write { db in
            _ = try Self.liveNote(noteID, in: db)
            try db.execute(
                sql: "UPDATE notes SET archivedAt = ?, archiveReason = ? WHERE id = ? AND archivedAt IS NULL",
                arguments: [Date().timeIntervalSince1970, reason, noteID.uuidString]
            )
        }
    }

    func unarchive(_ noteID: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE notes SET archivedAt = NULL, archiveReason = NULL WHERE id = ?",
                arguments: [noteID.uuidString]
            )
        }
    }

    /// Items linked to this one, through chat's applied links and automation links alike.
    func linkedItems(for noteID: UUID) throws -> [LinkedItem] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            WITH links(other, rationale) AS (
                SELECT CASE WHEN l.leftID = ?1 THEN l.rightID ELSE l.leftID END, l.rationale
                FROM note_links l WHERE ?1 IN (l.leftID, l.rightID)
                UNION ALL
                SELECT CASE WHEN k.leftID = ?1 THEN k.rightID ELSE k.leftID END, p.rationale
                FROM knowledge_links k JOIN knowledge_proposals p ON p.id = k.proposalID
                WHERE ?1 IN (k.leftID, k.rightID)
            )
            SELECT n.id, n.name, n.sourceURL, min(links.rationale) AS rationale
            FROM links JOIN notes n ON n.id = links.other
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL
            GROUP BY n.id ORDER BY n.name LIMIT 30
            """, arguments: [noteID.uuidString]).map { row in
                let source: String? = row["sourceURL"]
                return try LinkedItem(
                    document: DocumentSummary(
                        id: Self.uuid(row["id"]),
                        name: row["name"],
                        sourceURL: source.flatMap(URL.init(string:)),
                        faviconData: nil,
                        faviconChecked: true,
                        kind: "source"
                    ),
                    rationale: row["rationale"]
                )
            }
        }
    }
}
