import Foundation
import GRDB

extension DocumentStore {
    func activityPage(
        query: ActivityQuery = ActivityQuery(), offset: Int = 0, limit: Int = 80
    ) throws -> ActivityPage {
        let (predicate, arguments) = Self.activityPredicate(query)
        let size = max(1, min(limit, 200))
        return try readyDatabase().read { db in
            var values = arguments
            values += [size + 1, max(0, offset)]
            let rows = try Row.fetchAll(db, sql: """
            WITH grouped AS (
                SELECT groupID, date(occurredAt, 'unixepoch', 'localtime') AS day,
                    max(sequence) AS latest, count(*) AS count
                FROM activity_events WHERE \(predicate)
                GROUP BY groupID, day
                ORDER BY max(occurredAt) DESC, latest DESC LIMIT ? OFFSET ?
            )
            SELECT e.*, g.day, g.count FROM grouped g
            JOIN activity_events e ON e.sequence = g.latest
            ORDER BY e.occurredAt DESC, e.sequence DESC
            """, arguments: values)
            let groups = try rows.prefix(size).map { row in
                try ActivityGroup(
                    key: row["groupID"],
                    day: row["day"],
                    latest: Self.activityEvent(row),
                    count: row["count"]
                )
            }
            var days: [ActivityDay] = []
            for group in groups {
                if days.last?.id == group.day {
                    days[days.count - 1].groups.append(group)
                } else {
                    let date = Calendar.current.startOfDay(for: group.latest.date)
                    let summary = try Self.activitySummary(db, query: query, date: date)
                    days.append(ActivityDay(
                        id: group.day,
                        date: date,
                        summary: summary,
                        groups: [group]
                    ))
                }
            }
            let since = try Self.metadata("activityTrackingSince", in: db).flatMap(Double.init) ?? 0
            return ActivityPage(
                days: days,
                hasMore: rows.count > size,
                trackingSince: Date(timeIntervalSince1970: since)
            )
        }
    }

    func activityEvents(
        in group: ActivityGroup, query: ActivityQuery, before: Int64? = nil, limit: Int = 80
    ) throws -> [ActivityEvent] {
        let (predicate, arguments) = Self.activityPredicate(query)
        var values = arguments
        values += [group.key, group.day, before ?? Int64.max, max(1, min(limit, 200))]
        return try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT * FROM activity_events WHERE \(predicate) AND groupID = ?
                AND date(occurredAt, 'unixepoch', 'localtime') = ? AND sequence < ?
            ORDER BY sequence DESC LIMIT ?
            """, arguments: values).map(Self.activityEvent)
        }
    }

    /// Re-read the event so a purge can never reopen an old UI snapshot's title or revision.
    func inspectActivity(_ id: Int64) throws -> ActivityInspection? {
        try readyDatabase().read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM activity_events WHERE sequence = ?",
                arguments: [id]
            ) else { return nil }
            let event = try Self.activityEvent(row)
            guard event.title != nil else {
                return ActivityInspection(
                    event: event,
                    current: nil,
                    before: nil,
                    after: nil,
                    previousTitle: nil
                )
            }
            let current = try event.noteID.flatMap { id in
                try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM notes WHERE id = ? AND deletedAt IS NULL",
                    arguments: [id.uuidString]
                ).map(Self.document)
            }
            let revision = try event.revisionID.flatMap { id in
                try Row.fetchOne(db, sql: """
                SELECT r.markdown, p.markdown AS previous, p.name AS previousTitle
                FROM note_revisions r LEFT JOIN note_revisions p ON p.id = r.parentID WHERE r.id = ?
                """, arguments: [id.uuidString])
            }
            return ActivityInspection(
                event: event,
                current: current,
                before: revision?["previous"],
                after: revision?["markdown"],
                previousTitle: revision?["previousTitle"]
            )
        }
    }

    /// The context lives only inside this transaction; it cannot leak into another worker.
    func activityWrite<T>(
        actor: String, batchID: UUID? = nil, label: String? = nil,
        _ body: (Database) throws -> T
    ) throws -> T {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE activity_context SET actor = ?, batchID = ?, batchLabel = ? WHERE id = 1",
                arguments: [actor, batchID?.uuidString, label]
            )
            let result = try body(db)
            try db
                .execute(
                    sql: "UPDATE activity_context SET actor = 'app', batchID = NULL, batchLabel = NULL WHERE id = 1"
                )
            return result
        }
    }

    private static func activityPredicate(_ query: ActivityQuery) -> (String, StatementArguments) {
        let placeholders = Array(repeating: "?", count: query.filter.kinds.count)
            .joined(separator: ",")
        var sql = "kind IN (\(placeholders))"
        var arguments = StatementArguments(query.filter.kinds.map(\.rawValue))
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            sql += " AND instr(lower(coalesce(title, '') || ' ' || coalesce(detail, '') || ' ' || coalesce(batchLabel, '')), lower(?)) > 0"
            arguments += [search]
        }
        if let day = query.day, let interval = Calendar.current.dateInterval(of: .day, for: day) {
            sql += " AND occurredAt >= ? AND occurredAt < ?"
            arguments += [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
        }
        return (sql, arguments)
    }

    private static func activitySummary(
        _ db: Database,
        query: ActivityQuery,
        date: Date
    ) throws -> String {
        var dayQuery = query
        dayQuery.day = date
        let (predicate, values) = activityPredicate(dayQuery)
        let rows = try Row.fetchAll(db, sql: """
        SELECT kind, count(DISTINCT coalesce(noteID, CAST(sequence AS TEXT))) AS items,
            count(*) AS events FROM activity_events WHERE \(predicate) GROUP BY kind
        """, arguments: values)
        let parts = rows.compactMap { row -> String? in
            guard let kind = ActivityEvent.Kind(rawValue: row["kind"]) else { return nil }
            let itemLabels: [ActivityEvent.Kind: String] = [
                .created: "created", .updated: "updated", .deleted: "deleted",
                .purged: "permanently deleted", .filed: "filed", .unfiled: "unfiled",
                .archived: "archived", .unarchived: "unarchived",
                .primaryHome: "primary homes changed", .sourceUpdated: "source addresses changed",
            ]
            if let label = itemLabels[kind] {
                let count: Int = row["items"]
                return "\(count.formatted()) \(label)"
            }
            let eventLabels: [ActivityEvent.Kind: (String, String)] = [
                .sourceSaved: ("source saved", "sources saved"),
                .sourceLinked: ("source attached", "sources attached"),
                .sourceUnlinked: ("source detached", "sources detached"),
                .linkAdded: ("link added", "links added"),
                .linkRemoved: ("link removed", "links removed"),
            ]
            guard let labels = eventLabels[kind] else { return nil }
            let count: Int = row["events"]
            return "\(count.formatted()) \(count == 1 ? labels.0 : labels.1)"
        }
        return parts.joined(separator: " · ")
    }

    private static func activityEvent(_ row: Row) throws -> ActivityEvent {
        guard let kind = ActivityEvent.Kind(rawValue: row["kind"])
        else { throw GleanaryError.invalidDatabase }
        let note: String? = row["noteID"], related: String? = row["relatedID"],
            revision: String? = row["revisionID"]
        return try ActivityEvent(
            id: row["sequence"],
            date: Date(timeIntervalSince1970: row["occurredAt"]),
            kind: kind,
            noteID: note.map(uuid),
            relatedID: related.map(uuid),
            title: row["title"],
            detail: row["detail"],
            actor: row["actor"],
            revisionID: revision.map(uuid),
            groupID: row["groupID"],
            batchLabel: row["batchLabel"]
        )
    }
}
