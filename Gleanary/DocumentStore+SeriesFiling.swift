import Foundation
import GRDB

extension DocumentStore {
    /// Only newly authored members participate. Reused notes and cited sources stay untouched.
    func publishedSeriesFiling() throws -> [UUID: SeriesFiling.Status] {
        try readyDatabase().read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT r.taskID, n.id, c.code || ' ' || c.name AS home, s.batch
            FROM note_series_runs r JOIN note_series_members m ON m.runID = r.id
            JOIN notes n ON n.id = m.noteID
            LEFT JOIN note_categories nc ON nc.noteID = n.id
            LEFT JOIN decimal_categories c ON c.id = nc.categoryID
            LEFT JOIN filing_suggestions s ON s.noteID = n.id AND s.status = 'accepted'
                AND s.categoryID = nc.categoryID AND nc.isPrimary = 1
            WHERE r.published = 1 AND m.reused = 0 AND n.deletedAt IS NULL AND n.archivedAt IS NULL
              AND EXISTS (SELECT 1 FROM conversation_messages WHERE taskID = r.taskID)
            ORDER BY m.ordinal
            """)
            var result: [UUID: SeriesFiling.Status] = [:]
            for (task, members) in Dictionary(grouping: rows, by: { $0["taskID"] as String }) {
                var seen = Set<UUID>()
                let ids = try members.compactMap { row -> UUID? in
                    let id = try Self.uuid(row["id"])
                    return seen.insert(id).inserted ? id : nil
                }
                let unfiled = Set(members.filter { ($0["home"] as String?) == nil }
                    .map { $0["id"] as String }).count
                let homes = Set(members.compactMap { $0["home"] as String? }).sorted()
                let batches = try Set(members.compactMap { $0["batch"] as String? }).map(Self.uuid)
                let id = try Self.uuid(task)
                result[id] = .init(
                    taskID: id,
                    noteIDs: ids,
                    unfiled: unfiled,
                    homes: homes,
                    batches: batches
                )
            }
            return result
        }
    }

    /// Claim once before inference. The original publication remains terminal and successful.
    func beginSeriesFiling(_ run: NoteSeries.Run) throws -> [FilingCandidate]? {
        try readyDatabase().write { db -> [FilingCandidate]? in
            try Self.requirePublishedSeries(run, in: db)
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM note_series_artifacts WHERE runID = ? AND kind = 'filing')",
                arguments: [run.id.uuidString]
            ) == false,
                try Int.fetchOne(
                    db,
                    sql: "SELECT calls FROM note_series_runs WHERE id = ?",
                    arguments: [run.id.uuidString]
                ) ?? NoteSeries.maximumCalls < NoteSeries.maximumCalls
            else { return nil }
            let rows = try Row.fetchAll(db, sql: """
            SELECT n.id, n.revision, n.name, n.markdown FROM note_series_members m
            JOIN notes n ON n.id = m.noteID WHERE m.runID = ? AND m.reused = 0
              AND n.deletedAt IS NULL AND n.archivedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM note_categories WHERE noteID = n.id)
              AND NOT EXISTS (SELECT 1 FROM filing_suggestions WHERE noteID = n.id)
            ORDER BY m.ordinal
            """, arguments: [run.id.uuidString])
            let candidates = try rows.map { row in
                try FilingCandidate(
                    id: Self.uuid(row["id"]),
                    revision: Self.uuid(row["revision"]),
                    title: row["name"],
                    host: nil,
                    text: FilingText.classification(
                        name: row["name"],
                        sourceURL: nil,
                        markdown: row["markdown"]
                    )
                )
            }
            let payload = try JSONEncoder().encode(candidates.map(\.id))
            try db.execute(sql: """
            INSERT INTO note_series_artifacts(id,runID,kind,slot,version,payload,contentHash,parents,createdAt)
            VALUES (?,?,'filing','',1,?,?,?,?)
            """, arguments: [
                UUID().uuidString,
                run.id.uuidString,
                payload,
                ContentHash.of(String(decoding: payload, as: UTF8.self)),
                JSONEncoder().encode([UUID]()),
                Date().timeIntervalSince1970,
            ])
            if !candidates.isEmpty {
                try db.execute(
                    sql: "UPDATE note_series_runs SET calls = calls + 1 WHERE id = ?",
                    arguments: [run.id.uuidString]
                )
            }
            return candidates
        }
    }

    func finishSeriesFiling(
        _ run: NoteSeries.Run,
        candidates: [FilingCandidate],
        suggestions: [FilingSuggestionDraft],
        categories: [DecimalCategory]
    ) throws {
        try activityWrite(actor: "agent", batchID: UUID(), label: "Filed research series") { db in
            try Self.requirePublishedSeries(run, in: db)
            let batch = UUID()
            for suggestion in suggestions {
                guard let candidate = candidates.first(where: { $0.id == suggestion.noteID }),
                      try Self.seriesFilingIsCurrent(candidate, runID: run.id, in: db)
                else { continue }
                if let categoryID = suggestion.categoryID {
                    guard let expected = categories.first(where: { $0.id == categoryID }),
                          try String.fetchOne(
                              db,
                              sql: "SELECT code || ' ' || name FROM decimal_categories WHERE id = ?",
                              arguments: [categoryID.uuidString]
                          ) == expected.label else { continue }
                }
                try db.execute(sql: """
                INSERT OR IGNORE INTO filing_suggestions(noteID,categoryID,newCategory,confidence,engine,status,createdAt)
                VALUES (?,?,?,?,?,'pending',?)
                """, arguments: [
                    candidate.id.uuidString,
                    suggestion.categoryID?.uuidString,
                    suggestion.newCategory,
                    suggestion.confidence,
                    suggestion.engine,
                    Date().timeIntervalSince1970,
                ])
                try Self.autoFileSeriesSuggestion(suggestion, batch: batch, in: db)
            }
        }
    }

    private static func autoFileSeriesSuggestion(
        _ suggestion: FilingSuggestionDraft,
        batch: UUID,
        in db: Database
    ) throws {
        guard let categoryID = suggestion.categoryID, suggestion.confidence >= 0.75,
              try Bool.fetchOne(
                  db,
                  sql: """
                  SELECT EXISTS(SELECT 1 FROM filing_suggestions
                  WHERE noteID = ? AND categoryID = ? AND confidence >= 0.75 AND engine = ? AND status = 'pending')
                  """,
                  arguments: [
                      suggestion.noteID.uuidString,
                      categoryID.uuidString,
                      suggestion.engine,
                  ]
              ) == true else { return }
        try fileImported(suggestion.noteID, categoryID: categoryID, includeSources: false, in: db)
        try db.execute(
            sql: "UPDATE filing_suggestions SET status = 'accepted', batch = ? WHERE noteID = ? AND status = 'pending'",
            arguments: [batch.uuidString, suggestion.noteID.uuidString]
        )
    }

    private static func seriesFilingIsCurrent(
        _ candidate: FilingCandidate,
        runID: UUID,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM notes n JOIN note_series_members m ON m.noteID = n.id
          WHERE n.id = ? AND n.revision = ? AND n.deletedAt IS NULL AND n.archivedAt IS NULL AND m.runID = ? AND m.reused = 0
          AND NOT EXISTS(SELECT 1 FROM note_categories WHERE noteID = n.id))
        """, arguments: [candidate.id.uuidString, candidate.revision.uuidString, runID.uuidString]) ?? false
    }

    private static func requirePublishedSeries(_ run: NoteSeries.Run, in db: Database) throws {
        try Task.checkCancellation()
        guard try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM note_series_runs r JOIN conversation_tasks t ON t.id = r.taskID
        WHERE r.id = ? AND r.lease = ? AND r.published = 1 AND t.state = 'succeeded'
          AND EXISTS(SELECT 1 FROM conversation_messages WHERE taskID = r.taskID AND author = 'writer'))
        """, arguments: [run.id.uuidString, run.lease.uuidString]) == true else { throw CancellationError(
        ) }
    }
}
