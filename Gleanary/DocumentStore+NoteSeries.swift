import Foundation
import GRDB

enum NoteSeriesSchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE authored_artifacts_series (
            noteID TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            taskID TEXT NOT NULL REFERENCES conversation_tasks(id), kind TEXT NOT NULL,
            provider TEXT NOT NULL, createdAt REAL NOT NULL
        );
        INSERT INTO authored_artifacts_series SELECT * FROM authored_artifacts;
        DROP TABLE authored_artifacts;
        ALTER TABLE authored_artifacts_series RENAME TO authored_artifacts;
        CREATE UNIQUE INDEX single_artifact_task ON authored_artifacts(taskID)
            WHERE kind NOT IN ('series-note','series-index');
        CREATE TABLE note_series_runs (
            id TEXT PRIMARY KEY NOT NULL, taskID TEXT UNIQUE NOT NULL
                REFERENCES conversation_tasks(id) ON DELETE CASCADE,
            indexID TEXT UNIQUE NOT NULL, lease TEXT NOT NULL, request TEXT NOT NULL,
            provider TEXT NOT NULL, style BLOB NOT NULL, selected BLOB NOT NULL,
            published INTEGER NOT NULL DEFAULT 0, calls INTEGER NOT NULL DEFAULT 0,
            createdAt REAL NOT NULL
        );
        CREATE TABLE note_series_artifacts (
            id TEXT PRIMARY KEY NOT NULL, runID TEXT NOT NULL
                REFERENCES note_series_runs(id) ON DELETE CASCADE,
            kind TEXT NOT NULL, slot TEXT NOT NULL, version INTEGER NOT NULL,
            payload BLOB NOT NULL, contentHash TEXT NOT NULL, parents BLOB NOT NULL,
            createdAt REAL NOT NULL, UNIQUE(runID, kind, slot)
        );
        CREATE TABLE note_series_members (
            runID TEXT NOT NULL REFERENCES note_series_runs(id) ON DELETE CASCADE,
            noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL, reused INTEGER NOT NULL,
            PRIMARY KEY(runID, noteID), UNIQUE(runID, ordinal)
        );
        """)
    }
}

extension DocumentStore {
    func noteSeriesRun(taskID: UUID) throws -> NoteSeries.Run? {
        try readyDatabase().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM note_series_runs WHERE taskID = ?",
                arguments: [taskID.uuidString]
            ).map(Self.seriesRun)
        }
    }

    func beginNoteSeries(
        taskID: UUID,
        request: String,
        provider: String,
        style: WritingStyle,
        selected: [UUID]
    ) throws -> NoteSeries.Run {
        if let existing = try noteSeriesRun(taskID: taskID) {
            return existing
        }
        return try readyDatabase().write { db in
            guard try String.fetchOne(
                db,
                sql: "SELECT state FROM conversation_tasks WHERE id = ?",
                arguments: [taskID.uuidString]
            ) == "running"
            else { throw CancellationError() }
            let id = UUID(), index = UUID(), lease = UUID()
            try db.execute(
                sql: "INSERT INTO note_series_runs(id,taskID,indexID,lease,request,provider,style,selected,createdAt) VALUES (?,?,?,?,?,?,?,?,?)",
                arguments: [
                    id.uuidString, taskID.uuidString, index.uuidString, lease.uuidString, request,
                    provider, JSONEncoder().encode(style), JSONEncoder().encode(selected),
                    Date().timeIntervalSince1970,
                ]
            )
            return NoteSeries.Run(
                id: id,
                taskID: taskID,
                indexID: index,
                lease: lease,
                request: request,
                provider: provider,
                style: style,
                selected: selected,
                published: false
            )
        }
    }

    /// Explicit Retry reuses the job, but replaces its lease so old workers cannot commit.
    func retryNoteSeries(taskID: UUID) throws {
        try readyDatabase().write { db in
            guard let run = try Row.fetchOne(
                db,
                sql: "SELECT * FROM note_series_runs WHERE taskID = ?",
                arguments: [taskID.uuidString]
            ),
                (run["published"] as Bool) == false,
                try String.fetchOne(
                    db,
                    sql: "SELECT state FROM conversation_tasks WHERE id = ?",
                    arguments: [taskID.uuidString]
                ).map({ ["failed", "cancelled"].contains($0) }) == true
            else { throw NoteSeries.Failure.invalidArtifact }
            try db.execute(
                sql: "UPDATE note_series_runs SET lease = ? WHERE taskID = ?",
                arguments: [UUID().uuidString, taskID.uuidString]
            )
            try db.execute(
                sql: "UPDATE conversation_tasks SET state = 'running', progress = 'Resuming note series', updatedAt = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, taskID.uuidString]
            )
        }
    }

    func reserveSeriesCall(_ run: NoteSeries.Run) throws {
        try readyDatabase().write { db in
            try Self.requireSeriesLease(run, in: db)
            guard try Int.fetchOne(
                db,
                sql: "SELECT calls FROM note_series_runs WHERE id = ?",
                arguments: [run.id.uuidString]
            ) ?? NoteSeries.maximumCalls < NoteSeries.maximumCalls
            else { throw NoteSeries.Failure.budget }
            try db.execute(
                sql: "UPDATE note_series_runs SET calls = calls + 1 WHERE id = ?",
                arguments: [run.id.uuidString]
            )
        }
    }

    func seriesArtifact<Value: Codable & Sendable>(
        _ run: NoteSeries.Run,
        kind: NoteSeries.ArtifactKind,
        slot: String = "",
        as _: Value.Type
    ) throws -> NoteSeries.Artifact<Value>? {
        try readyDatabase().read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM note_series_artifacts WHERE runID = ? AND kind = ? AND slot = ?",
                arguments: [run.id.uuidString, kind.rawValue, slot]
            ) else { return nil }
            let data: Data = row["payload"]
            guard (row["version"] as Int) == 1, data.count <= 4_000_000,
                  ContentHash
                  .of(String(decoding: data, as: UTF8.self)) == row["contentHash"] as String
            else { throw NoteSeries.Failure.invalidArtifact }
            do {
                return try NoteSeries.Artifact(
                    id: Self.uuid(row["id"]),
                    value: JSONDecoder().decode(Value.self, from: data)
                )
            } catch { throw NoteSeries.Failure.invalidArtifact }
        }
    }

    /// Revisions and failed reviews remain immutable. Retry resumes the newest checkpoint.
    func latestSeriesArtifact<Value: Codable & Sendable>(
        _ run: NoteSeries.Run,
        kind: NoteSeries.ArtifactKind,
        slotPrefix: String = "",
        as type: Value.Type
    ) throws -> NoteSeries.Artifact<Value>? {
        let slot = try readyDatabase().read { db in
            try String.fetchOne(db, sql: """
            SELECT slot FROM note_series_artifacts
            WHERE runID = ? AND kind = ? AND substr(slot, 1, length(?)) = ?
            ORDER BY createdAt DESC, rowid DESC LIMIT 1
            """, arguments: [run.id.uuidString, kind.rawValue, slotPrefix, slotPrefix])
        }
        guard let slot else { return nil }
        return try seriesArtifact(run, kind: kind, slot: slot, as: type)
    }

    /// Workflow snapshots are an append-only sequence, independent of wall-clock changes.
    func researchSeriesState(_ run: NoteSeries.Run) throws -> NoteSeries
        .Artifact<ResearchSeries.State>?
    {
        let slot = try readyDatabase().read { db in
            try String.fetchOne(
                db,
                sql: "SELECT slot FROM note_series_artifacts WHERE runID = ? AND kind = 'workflow' ORDER BY rowid DESC LIMIT 1",
                arguments: [run.id.uuidString]
            )
        }
        guard let slot else { return nil }
        return try seriesArtifact(run, kind: .workflow, slot: slot, as: ResearchSeries.State.self)
    }

    func seriesArtifactIncludesParents(
        _ run: NoteSeries.Run,
        artifactID: UUID,
        parents: [UUID]
    ) throws -> Bool {
        try readyDatabase().read { db in
            guard let data = try Data
                .fetchOne(
                    db,
                    sql: "SELECT parents FROM note_series_artifacts WHERE runID = ? AND id = ?",
                    arguments: [run.id.uuidString,
                                artifactID.uuidString]
                )
            else {
                throw NoteSeries.Failure.invalidArtifact
            }
            let recorded = try JSONDecoder().decode([UUID].self, from: data)
            return Set(parents).isSubset(of: Set(recorded))
        }
    }

    @discardableResult
    func checkpointSeries<Value: Codable & Sendable>(
        _ run: NoteSeries.Run,
        kind: NoteSeries.ArtifactKind,
        slot: String = "",
        value: Value,
        parents: [UUID]
    ) throws -> NoteSeries.Artifact<Value> {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        guard data.count <= 4_000_000 else { throw NoteSeries.Failure.invalidArtifact }
        return try readyDatabase().write { db in
            try Self.requireSeriesLease(run, in: db)
            for parent in parents {
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM note_series_artifacts WHERE id = ? AND runID = ?)",
                    arguments: [parent.uuidString, run.id.uuidString]
                ) == true
                else { throw NoteSeries.Failure.invalidArtifact }
            }
            let hash = ContentHash.of(String(decoding: data, as: UTF8.self))
            if let previous = try Row.fetchOne(
                db,
                sql: "SELECT id, contentHash FROM note_series_artifacts WHERE runID = ? AND kind = ? AND slot = ?",
                arguments: [run.id.uuidString, kind.rawValue, slot]
            ) {
                guard (previous["contentHash"] as String) == hash
                else { throw NoteSeries.Failure.invalidArtifact }
                return try NoteSeries.Artifact(id: Self.uuid(previous["id"]), value: value)
            }
            let id = UUID()
            try db.execute(
                sql: "INSERT INTO note_series_artifacts VALUES (?,?,?,?,1,?,?,?,?)",
                arguments: [
                    id.uuidString,
                    run.id.uuidString,
                    kind.rawValue,
                    slot,
                    data,
                    hash,
                    JSONEncoder().encode(parents),
                    Date().timeIntervalSince1970,
                ]
            )
            return NoteSeries.Artifact(id: id, value: value)
        }
    }

    func validateSeriesLibrary(_ sources: [NoteSeries.Source]) throws {
        try readyDatabase().read { try Self.validateSeriesLibrary(sources, in: $0) }
    }

    /// All member notes, their index, links, provenance and the success message commit together.
    /// Re-entering after a completed commit returns the same IDs; it never rewrites the notes.
    func publishNoteSeries(_ run: NoteSeries.Run) throws -> NoteSeries.Publication {
        let originalOutline = try requiredSeriesArtifact(
            run,
            kind: .outline,
            as: NoteSeries.Outline.self
        )
        let original = try requiredSeriesArtifact(run, kind: .dossier, as: NoteSeries.Dossier.self)
        let reviewed = try publicationSeries(run, outline: originalOutline)
        let outline = reviewed.scope?.outline ?? originalOutline
        let dossier = reviewed.evidence ?? original
        let curation = reviewed.curation, drafts = reviewed.drafts
        let web = try seriesArtifact(run, kind: .webSearch, as: WebResearchResult.self)?.value
        try dossier.validate()
        if let workflow = reviewed.workflow,
           workflow.request != run.request
        {
            throw NoteSeries.Failure.invalidArtifact
        }
        try reviewed.validate(outline: originalOutline, dossier: original)
        let rendered = try SeriesRenderer.render(
            run: run,
            outline: outline,
            dossier: dossier,
            drafts: drafts,
            curation: curation,
            minimumParagraphs: reviewed.workflow == nil ? 2 : 1
        )
        var evidence: [UUID: WebResearchResult] = [:]
        for note in [rendered.index] + rendered.notes {
            let paragraphs = note.id == run.indexID ? drafts.values
                .flatMap(\.paragraphs) : drafts[note.id]?.paragraphs ?? []
            evidence[note.id] = try SeriesRenderer.externalEvidence(
                records: Set(paragraphs.flatMap(\.records)),
                dossier: dossier,
                searchCount: (web?.searchCount ?? 0) + (dossier.recoverySearchCount ?? 0)
            )
        }
        try Task.checkCancellation()
        return try activityWrite(
            actor: "agent",
            batchID: run.id,
            label: "Published research series"
        ) { db in
            if try Bool.fetchOne(
                db,
                sql: "SELECT published FROM note_series_runs WHERE id = ?",
                arguments: [run.id.uuidString]
            ) == true {
                return try NoteSeries.Publication(
                    index: Self.liveNote(run.indexID, in: db),
                    created: rendered.notes.map { try Self.liveNote($0.id, in: db) },
                    reused: outline.entries.compactMap(\.existingNoteID)
                )
            }
            try Self.requireSeriesLease(run, in: db)
            try Self.validateSeriesLibrary(dossier.sources, in: db)
            let all = [rendered.index] + rendered.notes
            for note in all {
                // A concurrent capture/edit must not be overwritten or duplicated by a stale plan.
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ? OR (lower(name) = lower(?) AND deletedAt IS NULL AND archivedAt IS NULL))",
                    arguments: [note.id.uuidString, note.name]
                ) == false
                else { throw NoteSeries.Failure.staleLibrary }
                try Self.validate(note)
                _ = try Self.writeNote(note, in: db)
                try db.execute(
                    sql: "INSERT INTO authored_artifacts VALUES (?,?,?,?,?)",
                    arguments: [
                        note.id.uuidString,
                        run.taskID.uuidString,
                        note.id == run.indexID ? "series-index" : "series-note",
                        run.provider,
                        Date().timeIntervalSince1970,
                    ]
                )
                if let external = evidence[note.id] {
                    try db.execute(
                        sql: "INSERT INTO web_research_evidence VALUES (?,?,?)",
                        arguments: [
                            note.id.uuidString,
                            JSONEncoder().encode(external),
                            Date().timeIntervalSince1970,
                        ]
                    )
                }
            }
            let members = [run.indexID] + outline.entries.map { $0.existingNoteID ?? $0.id }
            for (ordinal, id) in members.enumerated() {
                try db.execute(
                    sql: "INSERT INTO note_series_members VALUES (?,?,?,?)",
                    arguments: [
                        run.id.uuidString,
                        id.uuidString,
                        ordinal,
                        outline.entries.contains { $0.existingNoteID == id },
                    ]
                )
            }
            for edge in rendered.edges {
                let ids = [edge.from.uuidString, edge.to.uuidString].sorted()
                guard ids[0] != ids[1] else { continue }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO note_links VALUES (?,?,?,?,?)",
                    arguments: [
                        ids[0],
                        ids[1],
                        run.taskID.uuidString,
                        edge.reason,
                        Date().timeIntervalSince1970,
                    ]
                )
            }
            let created = try rendered.notes.map { try Self.liveNote($0.id, in: db) }
            let reused = outline.entries.compactMap(\.existingNoteID)
            try db.execute(
                sql: "UPDATE note_series_runs SET published = 1 WHERE id = ?",
                arguments: [run.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE conversation_tasks SET state = 'succeeded', progress = 'Published note series', updatedAt = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, run.taskID.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO conversation_messages(id,author,text,refs,taskID,createdAt) VALUES (?,'writer',?,?,?,?)",
                arguments: [
                    UUID().uuidString,
                    "Published an index and \(created.count) new notes, reusing \(reused.count) existing notes. Existing notes were not changed.",
                    JSONEncoder().encode(members),
                    run.taskID.uuidString,
                    Date().timeIntervalSince1970,
                ]
            )
            return try NoteSeries.Publication(
                index: Self.liveNote(run.indexID, in: db),
                created: created,
                reused: reused
            )
        }
    }

    private func publicationSeries(
        _ run: NoteSeries.Run,
        outline: NoteSeries.Outline
    ) throws -> NoteSeries.ReviewedSeries {
        if let reviewed = try seriesArtifact(
            run,
            kind: .reviewedSeries,
            as: NoteSeries.ReviewedSeries.self
        ) {
            return reviewed.value
        }
        // Runs reviewed by older versions still use their original checkpoint format.
        let curation = try requiredSeriesArtifact(
            run,
            kind: .curation,
            as: NoteSeries.Curation.self
        )
        var drafts: [UUID: NoteSeries.Draft] = [:]
        for entry in outline.entries where entry.existingNoteID == nil {
            drafts[entry.id] = try requiredSeriesArtifact(
                run,
                kind: .draft,
                slot: entry.id.uuidString,
                as: NoteSeries.Draft.self
            )
        }
        return .init(drafts: drafts, curation: curation, requirements: curation)
    }

    private func requiredSeriesArtifact<Value: Codable & Sendable>(
        _ run: NoteSeries.Run,
        kind: NoteSeries.ArtifactKind,
        slot: String = "",
        as type: Value.Type
    ) throws -> Value {
        guard let artifact = try seriesArtifact(run, kind: kind, slot: slot, as: type)
        else { throw NoteSeries.Failure.invalidArtifact }
        return artifact.value
    }

    private static func requireSeriesLease(_ run: NoteSeries.Run, in db: Database) throws {
        try Task.checkCancellation()
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM note_series_runs r JOIN conversation_tasks t ON t.id = r.taskID WHERE r.id = ? AND r.lease = ? AND r.published = 0 AND t.state = 'running')",
            arguments: [run.id.uuidString, run.lease.uuidString]
        ) == true
        else { throw CancellationError() }
    }

    private static func validateSeriesLibrary(
        _ sources: [NoteSeries.Source],
        in db: Database
    ) throws {
        for source in sources {
            guard let noteID = source.noteID else { continue }
            guard let note = try Row.fetchOne(
                db,
                sql: "SELECT revision FROM notes WHERE id = ? AND deletedAt IS NULL AND archivedAt IS NULL",
                arguments: [noteID.uuidString]
            ),
                (note["revision"] as String) == source.revision?.uuidString
            else { throw NoteSeries.Failure.staleLibrary }
        }
    }

    private static func seriesRun(_ row: Row) throws -> NoteSeries.Run {
        try NoteSeries.Run(
            id: uuid(row["id"]),
            taskID: uuid(row["taskID"]),
            indexID: uuid(row["indexID"]),
            lease: uuid(row["lease"]),
            request: row["request"],
            provider: row["provider"],
            style: JSONDecoder().decode(WritingStyle.self, from: row["style"]),
            selected: JSONDecoder().decode([UUID].self, from: row["selected"]),
            published: row["published"]
        )
    }
}
