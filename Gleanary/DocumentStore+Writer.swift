import Foundation
import GRDB

/// One compose or refresh request (SPEC §7.6): what was asked, in which style, the gathered
/// scope and what the person confirmed. A saved document's latest request is what Refresh
/// re-runs.
struct WriterRequest: Sendable, Equatable {
    enum Kind: String, Sendable {
        case compose, refresh
    }

    enum Status: String, Sendable {
        /// Gathered; waiting for the person to confirm the scope.
        case awaiting
        /// Confirmed; extracting and writing.
        case writing
        /// A composed document was saved.
        case saved
        /// A refresh's new text waits for review.
        case proposed
        /// A refresh found nothing to change.
        case unchanged
        case cancelled
    }

    let taskID: UUID
    var noteID: UUID?
    let kind: Kind
    let request: String
    var style: WritingStyle
    var brief: WriterBrief
    var generalKnowledge: Bool
    /// The most items the scope may hold: fewer on this Mac than with ChatGPT.
    var scopeLimit: Int
    var candidates: [ScopeCandidate]
    var selection: [UUID]
    /// Items the person unchecked; a refresh doesn't bring them back.
    var excluded: [UUID]
    /// The sources the saved text cites, at the versions it read.
    var sources: [SourceVersion]
    var status: Status
    /// Written as the person's own notes (the weekly digest); never stored, chat documents
    /// keep the usual wording.
    var personal = false
}

/// A source's text as extraction reads it: the captured document when there is one, else the
/// note itself.
struct WriterSourceText: Sendable {
    let id: UUID
    let title: String
    let text: String

    var version: SourceVersion {
        SourceVersion(id: id, hash: ContentHash.of(text))
    }
}

extension DocumentStore {
    func beginWriterRequest(_ request: WriterRequest) throws {
        try readyDatabase().write { db in
            try Self.requireLiveTask(request.taskID, in: db)
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            INSERT INTO writer_requests(taskID, noteID, kind, request, style, brief,
                generalKnowledge, scopeLimit, candidates, selection, excluded, sources, status,
                createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                request.taskID.uuidString, request.noteID?.uuidString, request.kind.rawValue,
                request.request, Self.json(request.style), Self.json(request.brief),
                request.generalKnowledge, request.scopeLimit, Self.json(request.candidates),
                Self.json(request.selection), Self.json(request.excluded),
                Self.json(request.sources), request.status.rawValue, now, now,
            ])
        }
    }

    func writerRequest(taskID: UUID) throws -> WriterRequest? {
        try readyDatabase().read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM writer_requests WHERE taskID = ?",
                arguments: [taskID.uuidString]
            ).map(Self.writerRequest)
        }
    }

    /// Scopes waiting for confirmation, for the scope cards in chat.
    func awaitingWriterRequests() throws -> [WriterRequest] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT w.* FROM writer_requests w JOIN conversation_tasks t ON t.id = w.taskID
            WHERE w.status = 'awaiting' AND t.state = 'awaiting_user'
            ORDER BY w.createdAt DESC LIMIT 20
            """).map(Self.writerRequest)
        }
    }

    /// The request behind a document's current text: the compose that saved it, or the latest
    /// refresh whose new text was applied.
    func latestWriterRequest(noteID: UUID) throws -> WriterRequest? {
        try readyDatabase().read { db in
            try Row.fetchOne(db, sql: """
            SELECT w.* FROM writer_requests w WHERE w.noteID = ?1 AND (w.status = 'saved'
                OR (w.status = 'proposed' AND EXISTS (SELECT 1 FROM agent_changes c
                    WHERE c.taskID = w.taskID AND c.kind = 'revision' AND c.status = 'applied')))
            ORDER BY w.createdAt DESC LIMIT 1
            """, arguments: [noteID.uuidString]).map(Self.writerRequest)
        }
    }

    func isComposedDocument(_ noteID: UUID) throws -> Bool {
        try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM writer_requests WHERE noteID = ? AND status = 'saved')
            """, arguments: [noteID.uuidString]) ?? false
        }
    }

    /// The person's confirmation. Only an awaiting scope can be confirmed, once, with items it
    /// actually gathered and no more than its limit; the task then runs again.
    func confirmWriterScope(
        taskID: UUID,
        selection: [UUID],
        style: WritingStyle,
        generalKnowledge: Bool
    ) throws {
        try readyDatabase().write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM writer_requests WHERE taskID = ?",
                arguments: [taskID.uuidString]
            ) else { throw WriterError.scopeChanged }
            let request = try Self.writerRequest(row)
            let gathered = Set(request.candidates.map(\.id))
            guard request.status == .awaiting, !selection.isEmpty,
                  Set(selection).count == selection.count,
                  Set(selection).isSubset(of: gathered)
            else { throw WriterError.scopeChanged }
            guard selection.count <= request.scopeLimit else { throw WriterError.needsChatGPT }
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            UPDATE conversation_tasks SET state = 'running', progress = 'Starting', updatedAt = ?
            WHERE id = ? AND state = 'awaiting_user'
            """, arguments: [now, taskID.uuidString])
            guard db.changesCount > 0 else { throw WriterError.scopeChanged }
            let excluded = request.candidates.map(\.id).filter { !selection.contains($0) }
            try db.execute(sql: """
            UPDATE writer_requests SET status = 'writing', selection = ?, excluded = ?, style = ?,
                generalKnowledge = ?, updatedAt = ? WHERE taskID = ?
            """, arguments: [
                Self.json(selection), Self.json(excluded), Self.json(style), generalKnowledge,
                now, taskID.uuidString,
            ])
        }
    }

    func setWriterRequestStatus(_ taskID: UUID, _ status: WriterRequest.Status) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE writer_requests SET status = ?, updatedAt = ? WHERE taskID = ?",
                arguments: [status.rawValue, Date().timeIntervalSince1970, taskID.uuidString]
            )
        }
    }

    // MARK: Gathering

    /// Live items filed in these categories or beneath them, newest first.
    func categoryMembers(codes: [String], limit: Int) throws -> [UUID] {
        guard !codes.isEmpty else { return [] }
        return try readyDatabase().read { db in
            let matches = codes.map { _ in "(c.code = ? OR c.code LIKE ? || '.%')" }
                .joined(separator: " OR ")
            return try String.fetchAll(db, sql: """
            SELECT DISTINCT n.id FROM notes n
            JOIN note_categories nc ON nc.noteID = n.id
            JOIN decimal_categories c ON c.id = nc.categoryID
            WHERE n.deletedAt IS NULL AND n.archivedAt IS NULL AND (\(matches))
            ORDER BY n.updatedAt DESC LIMIT ?
            """, arguments: StatementArguments(codes.flatMap { [$0, $0] } + [limit])).map(Self.uuid)
        }
    }

    /// Titles and primary filing for many items in a few queries; deleted, archived and
    /// Writer-composed items are left out, so a document never gathers its own kind.
    func scopeDetails(_ ids: [UUID]) throws -> [UUID: (title: String, filing: String?)] {
        try readyDatabase().read { db in
            var details: [UUID: (title: String, filing: String?)] = [:]
            for batch in stride(from: 0, to: ids.count, by: 400).map({
                Array(ids[$0 ..< min($0 + 400, ids.count)])
            }) {
                let marks = batch.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: """
                SELECT n.id, n.name, (SELECT c.code || ' ' || c.name FROM note_categories nc
                    JOIN decimal_categories c ON c.id = nc.categoryID
                    WHERE nc.noteID = n.id AND nc.isPrimary = 1) AS filing
                FROM notes n
                WHERE n.id IN (\(marks)) AND n.deletedAt IS NULL AND n.archivedAt IS NULL
                AND NOT EXISTS (SELECT 1 FROM authored_artifacts a
                    WHERE a.noteID = n.id AND a.kind = 'document')
                """, arguments: StatementArguments(batch.map(\.uuidString))) {
                    try details[Self.uuid(row["id"])] = (row["name"], row["filing"])
                }
            }
            return details
        }
    }

    // MARK: Extraction

    func writerSource(_ id: UUID) throws -> WriterSourceText? {
        guard try document(id: id) != nil else { return nil }
        let source = try researchSource(noteID: id)
        let text = source.document.blocks.map(\.text).joined(separator: "\n\n")
        return WriterSourceText(
            id: id, title: source.note.name,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? source.note.markdown : text
        )
    }

    func cachedExtraction(_ version: SourceVersion, fieldsKey: String) throws -> [FactRecord]? {
        try readyDatabase().read { db in
            try String.fetchOne(db, sql: """
            SELECT records FROM extraction_records
            WHERE noteID = ? AND contentHash = ? AND fieldsKey = ?
            """, arguments: [version.id.uuidString, version.hash, fieldsKey]).map {
                try JSONDecoder().decode([FactRecord].self, from: Data($0.utf8))
            }
        }
    }

    func saveExtraction(
        _ records: [FactRecord],
        version: SourceVersion,
        fieldsKey: String,
        engine: String
    ) throws {
        try readyDatabase().write { db in
            // Older text's records are never read again once a source changes.
            try db.execute(
                sql: "DELETE FROM extraction_records WHERE noteID = ? AND fieldsKey = ?",
                arguments: [version.id.uuidString, fieldsKey]
            )
            try db.execute(sql: """
            INSERT INTO extraction_records(noteID, contentHash, fieldsKey, records, engine, createdAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                version.id.uuidString, version.hash, fieldsKey, Self.json(records), engine,
                Date().timeIntervalSince1970,
            ])
        }
    }

    // MARK: Saving

    /// Saves a composed document in one transaction: the note, its provenance, a link to every
    /// source it cites and the request it answers. A task cancelled meanwhile saves nothing.
    func saveComposedDocument(
        _ rendered: WriterDocument.Rendered,
        taskID: UUID,
        provider: String,
        sources: [SourceVersion]
    ) throws -> MarkdownDocument {
        try Task.checkCancellation()
        return try activityWrite(actor: "agent", batchID: taskID, label: "Wrote document") { db in
            try Self.requireRunningTask(taskID, in: db)
            let note = MarkdownDocument(name: rendered.title, markdown: rendered.markdown)
            try Self.validate(note)
            let saved = try Self.writeNote(note, in: db)
            try db.execute(
                sql: "INSERT INTO authored_artifacts VALUES (?, ?, 'document', ?, ?)",
                arguments: [
                    saved.id.uuidString, taskID.uuidString, provider, Date().timeIntervalSince1970,
                ]
            )
            for source in rendered.used {
                try Self.linkSource(source, to: saved.id, changeID: taskID, in: db)
            }
            try db.execute(sql: """
            UPDATE writer_requests SET noteID = ?, sources = ?, status = 'saved', updatedAt = ?
            WHERE taskID = ?
            """, arguments: [
                saved.id.uuidString, Self.json(sources), Date().timeIntervalSince1970,
                taskID.uuidString,
            ])
            return saved
        }
    }

    /// A refresh's new text and new source links, saved for review together with what it read.
    func proposeWriterRefresh(
        _ drafts: [AgentChangeDraft],
        taskID: UUID,
        sources: [SourceVersion]
    ) throws {
        try Task.checkCancellation()
        try readyDatabase().write { db in
            try Self.requireRunningTask(taskID, in: db)
            try Self.insertAgentChanges(drafts, taskID: taskID, in: db)
            try db.execute(sql: """
            UPDATE writer_requests SET sources = ?, status = 'proposed', updatedAt = ?
            WHERE taskID = ?
            """, arguments: [Self.json(sources), Date().timeIntervalSince1970, taskID.uuidString])
        }
    }

    /// Whether two items are already linked, either way round.
    func linked(_ left: UUID, _ right: UUID) throws -> Bool {
        let ids = [left.uuidString, right.uuidString].sorted()
        return try readyDatabase().read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM note_links WHERE leftID = ?1 AND rightID = ?2)
                OR EXISTS(SELECT 1 FROM knowledge_links WHERE leftID = ?1 AND rightID = ?2)
            """, arguments: [ids[0], ids[1]]) ?? false
        }
    }

    private static func linkSource(
        _ source: UUID,
        to document: UUID,
        changeID: UUID,
        in db: Database
    ) throws {
        guard source != document, (try? liveNote(source, in: db)) != nil else { return }
        let ids = [source.uuidString, document.uuidString].sorted()
        try db.execute(sql: """
        INSERT OR IGNORE INTO note_links(leftID, rightID, changeID, rationale, createdAt)
        VALUES (?, ?, ?, 'A source the Writer cited.', ?)
        """, arguments: [ids[0], ids[1], changeID.uuidString, Date().timeIntervalSince1970])
    }

    private static func requireLiveTask(_ id: UUID, in db: Database) throws {
        guard try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM conversation_tasks
            WHERE id = ? AND state IN ('queued','running','awaiting_user'))
        """, arguments: [id.uuidString]) == true else { throw CancellationError() }
    }

    /// Cancelling marks the task first, so a late save after Stop finds it and writes nothing.
    private static func requireRunningTask(_ id: UUID, in db: Database) throws {
        guard try String.fetchOne(
            db, sql: "SELECT state FROM conversation_tasks WHERE id = ?", arguments: [id.uuidString]
        ) == "running" else { throw CancellationError() }
    }

    private static func json(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        _ text: String
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    private static func writerRequest(_ row: Row) throws -> WriterRequest {
        guard let kind = WriterRequest.Kind(rawValue: row["kind"]),
              let status = WriterRequest.Status(rawValue: row["status"])
        else { throw GleanaryError.invalidDatabase }
        let note: String? = row["noteID"]
        return try WriterRequest(
            taskID: uuid(row["taskID"]),
            noteID: note.flatMap(UUID.init(uuidString:)),
            kind: kind,
            request: row["request"],
            style: decode(WritingStyle.self, row["style"]),
            brief: decode(WriterBrief.self, row["brief"]),
            generalKnowledge: row["generalKnowledge"],
            scopeLimit: row["scopeLimit"],
            candidates: decode([ScopeCandidate].self, row["candidates"]),
            selection: decode([UUID].self, row["selection"]),
            excluded: decode([UUID].self, row["excluded"]),
            sources: decode([SourceVersion].self, row["sources"]),
            status: status
        )
    }
}
