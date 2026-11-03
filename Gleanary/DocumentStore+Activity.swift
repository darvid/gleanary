import Foundation
import GRDB

extension DocumentStore {
    func activityPage(
        query: ActivityQuery = ActivityQuery(), offset: Int = 0, limit: Int = 80
    ) throws -> ActivityPage {
        let (keyed, arguments) = Self.activityWork(query)
        let size = max(1, min(limit, 200))
        return try readyDatabase().read { db in
            var values = arguments
            values += [size + 1, max(0, offset)]
            let rows = try Row.fetchAll(db, sql: """
            WITH \(keyed), grouped AS (
                SELECT workKey, day, max(sequence) AS latest, count(*) AS count,
                    min(origin) AS firstOrigin, max(origin) AS lastOrigin
                FROM keyed GROUP BY workKey, day
                ORDER BY max(occurredAt) DESC, latest DESC LIMIT ? OFFSET ?
            )
            SELECT k.*, g.count, g.firstOrigin, g.lastOrigin,
                r.automationID, r.status AS runStatus, r.examined, r.changed, r.proposed, r.skipped,
                coalesce(saved.provenance, queued.provenance) AS provenance,
                o.name AS foundIn, subject.name AS subjectTitle
            FROM grouped g
            JOIN keyed k ON k.sequence = g.latest
            LEFT JOIN automation_runs r ON r.id = k.groupID
            LEFT JOIN acquisition_candidates saved ON saved.savedNoteID = k.subject
            LEFT JOIN acquisition_candidates queued ON queued.captureJobID = k.groupID
            LEFT JOIN notes o ON o.id = coalesce(saved.foundInNoteID, queued.foundInNoteID)
                AND o.deletedAt IS NULL
            LEFT JOIN notes subject ON subject.id = k.subject AND k.workKey GLOB 'note:*'
            GROUP BY k.sequence
            ORDER BY k.occurredAt DESC, k.sequence DESC
            """, arguments: values)
            var groups = try rows.prefix(size).map(Self.activityGroup)
            let counts = try Self.activityKindCounts(
                db, query: query, keys: Set(groups.map(\.key))
            )
            for index in groups.indices {
                let work = counts[groups[index].id]
                groups[index].kinds = work?.kinds ?? [:]
                groups[index].summaries = work?.summaries ?? 0
                groups[index].filedUnder = work?.filedUnder
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
        let (keyed, arguments) = Self.activityWork(query)
        var values = arguments
        values += [group.key, group.day, before ?? Int64.max, max(1, min(limit, 200))]
        return try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            WITH \(keyed)
            SELECT * FROM keyed WHERE workKey = ? AND day = ? AND sequence < ?
            ORDER BY sequence DESC LIMIT ?
            """, arguments: values).map(Self.activityEvent)
        }
    }

    /// What changed since `date`, for the recap at the top of Activity.
    func activityRecap(since date: Date) throws -> ActivityRecap {
        try readyDatabase().read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT kind, \(Self.activityOrigin("activity_events")) AS origin,
                count(DISTINCT coalesce(noteID, CAST(sequence AS TEXT))) AS items,
                count(*) AS events
            FROM activity_events
            WHERE occurredAt >= ? AND kind IN ('sourceSaved', 'created', 'linkAdded', 'filed')
                -- A saved source creates its own note; count only notes written.
                AND NOT (kind = 'created' AND EXISTS (SELECT 1 FROM activity_events s
                    WHERE s.noteID = activity_events.noteID AND s.kind = 'sourceSaved'))
            GROUP BY kind, origin
            """, arguments: [date.timeIntervalSince1970])
            var recap = ActivityRecap()
            for row in rows {
                let items: Int = row["items"], events: Int = row["events"]
                switch row["kind"] as String {
                case "sourceSaved"
                    where row["origin"] as String == "you": recap.sourcesByYou += items
                case "sourceSaved": recap.sourcesByGleanary += items
                case "created": recap.notesCreated += items
                case "linkAdded": recap.linksAdded += events
                case "filed": recap.notesFiled += items
                default: break
                }
            }
            return recap
        }
    }

    /// Files a capture an automation started under that automation's run, so the save reads
    /// as the run's work rather than as a capture of yours.
    func attributeCaptureActivity(_ jobID: UUID, toRun runID: UUID) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE activity_events SET actor = 'automation', groupID = ?,
                batchLabel = 'Automation changes'
            WHERE groupID = ?
            """, arguments: [runID.uuidString, jobID.uuidString])
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
        if query.scope != .everyone {
            sql += " AND \(activityOrigin("activity_events")) = ?"
            arguments += [query.scope == .you ? "you" : "gleanary"]
        }
        if let day = query.day, let interval = Calendar.current.dateInterval(of: .day, for: day) {
            sql += " AND occurredAt >= ? AND occurredAt < ?"
            arguments += [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
        }
        return (sql, arguments)
    }

    /// "you" for your own work, "gleanary" for agents and automations. Captures are written
    /// by the app for everyone, so a save counts as Gleanary's only when it followed a link
    /// on its own, or an automation claimed it for its run.
    private static func activityOrigin(_ table: String) -> String {
        """
        (CASE WHEN \(table).actor IN ('manual', 'import', 'legacy') THEN 'you'
            WHEN \(table).actor = 'app' AND \(table).batchLabel IN ('Saved source', 'Queued capture')
                AND NOT EXISTS (SELECT 1 FROM acquisition_candidates c
                    WHERE c.captureJobID = \(table).groupID AND c.automatic = 1) THEN 'you'
            ELSE 'gleanary' END)
        """
    }

    private static func activityGroup(_ row: Row) throws -> ActivityGroup {
        let automation = (row["automationID"] as String?).flatMap(AutomationKind.init)
        var context: String?
        if automation != nil, (row["runStatus"] as String?) == "running" {
            context = "Still running"
        } else if automation != nil {
            let examined: Int = row["examined"], changed: Int = row["changed"],
                proposed: Int = row["proposed"], skipped: Int = row["skipped"]
            context = ["\(examined.formatted()) checked", "\(changed.formatted()) changed",
                       proposed > 0 ? "\(proposed.formatted()) waiting for review" : nil,
                       skipped > 0 ? "\(skipped.formatted()) skipped" : nil]
                .compactMap(\.self).joined(separator: " · ")
        } else if let provenance = (row["provenance"] as String?)
            .flatMap(AcquisitionProvenance.init), let origin: String = row["foundIn"]
        {
            context = "\(provenance.label) in “\(origin)”"
        }
        // Origins sort as "gleanary" < "you".
        let first: String? = row["firstOrigin"], last: String? = row["lastOrigin"]
        return try ActivityGroup(
            key: row["workKey"],
            day: row["day"],
            latest: activityEvent(row),
            count: row["count"],
            byYou: last == "you",
            byGleanary: first == "gleanary",
            automation: automation,
            context: context,
            subjectTitle: row["subjectTitle"]
        )
    }

    /// One unit of work per row. Writes that share a batch across several items (a run, a
    /// chat task, an import, a review) stay together; everything else is grouped by the item
    /// it was about, counting a summary note toward its source, so saving, summarizing and
    /// filing one source is one row however many transactions it took.
    private static func activityWork(_ query: ActivityQuery) -> (String, StatementArguments) {
        let (predicate, arguments) = activityPredicate(query)
        return ("""
        base AS (
            SELECT activity_events.*, date(occurredAt, 'unixepoch', 'localtime') AS day,
                \(activityOrigin("activity_events")) AS origin,
                coalesce((SELECT c.noteID FROM note_sources ns
                    JOIN captures c ON c.sourceID = ns.sourceID
                    WHERE ns.noteID = activity_events.noteID AND ns.summaryRole = 'summary'
                        AND c.noteID != activity_events.noteID
                    ORDER BY c.createdAt DESC LIMIT 1), noteID) AS subject,
                min(noteID) OVER batch AS firstNote, max(noteID) OVER batch AS lastNote
            FROM activity_events WHERE \(predicate)
            WINDOW batch AS (PARTITION BY groupID)
        ),
        keyed AS (
            SELECT *, CASE WHEN subject IS NULL OR firstNote IS NOT lastNote
                    OR EXISTS (SELECT 1 FROM automation_runs r WHERE r.id = base.groupID)
                THEN groupID ELSE 'note:' || subject END AS workKey
            FROM base
        )
        """, arguments)
    }

    struct WorkCounts {
        var kinds: [ActivityEvent.Kind: Int] = [:]
        var summaries = 0
        var filedUnder: String?
    }

    /// Per-kind counts for each group on a page, keyed by group id, in one query.
    private static func activityKindCounts(
        _ db: Database, query: ActivityQuery, keys: Set<String>
    ) throws -> [String: WorkCounts] {
        guard !keys.isEmpty else { return [:] }
        let (keyed, values) = activityWork(query)
        var arguments = values
        arguments += StatementArguments(keys.sorted())
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        // A saved source's own note isn't a second piece of work, and a summary attaching
        // its source is part of writing the summary.
        let rows = try Row.fetchAll(db, sql: """
        WITH \(keyed)
        SELECT workKey, day,
            CASE WHEN kind = 'created' AND noteID IS NOT subject THEN 'summary' ELSE kind END
                AS work,
            count(DISTINCT coalesce(noteID, CAST(sequence AS TEXT))) AS items, count(*) AS events,
            max(CASE WHEN kind = 'filed' THEN detail END) AS filedUnder
        FROM keyed k WHERE workKey IN (\(placeholders))
            AND NOT (kind IN ('created', 'updated') AND EXISTS (SELECT 1 FROM keyed s
                WHERE s.workKey = k.workKey AND s.noteID = k.noteID AND s.kind = 'sourceSaved'))
            AND NOT (kind = 'sourceLinked' AND noteID IS NOT subject)
        GROUP BY workKey, day, work
        """, arguments: arguments)
        var counts: [String: WorkCounts] = [:]
        for row in rows {
            let id = (row["day"] as String) + "/" + (row["workKey"] as String)
            let work: String = row["work"]
            if work == "summary" {
                counts[id, default: WorkCounts()].summaries = row["items"]
                continue
            }
            guard let kind = ActivityEvent.Kind(rawValue: work) else { continue }
            counts[id, default: WorkCounts()].kinds[kind] =
                kind.countsItems ? row["items"] : row["events"]
            if kind == .filed {
                counts[id, default: WorkCounts()].filedUnder = row["filedUnder"]
            }
        }
        return counts
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
            batchLabel: row["batchLabel"],
            byYou: (row["origin"] as String?).map { $0 == "you" }
        )
    }
}
