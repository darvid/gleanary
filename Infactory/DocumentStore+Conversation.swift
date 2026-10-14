import Foundation
import GRDB

extension DocumentStore {
    func conversationMessages(
        before sequence: Int64? = nil,
        limit: Int = 200
    ) throws -> [ConversationMessage] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT * FROM (SELECT * FROM conversation_messages
            WHERE (? IS NULL OR sequence < ?) ORDER BY sequence DESC LIMIT ?) ORDER BY sequence
            """, arguments: [sequence, sequence, min(500, max(1, limit))]).map { row in
                let task: String? = row["taskID"]
                return try ConversationMessage(
                    sequence: row["sequence"], id: Self.uuid(row["id"]), author: row["author"],
                    text: row["text"],
                    references: JSONDecoder().decode([UUID].self, from: row["refs"]),
                    taskID: task.map(Self.uuid),
                    createdAt: Date(timeIntervalSince1970: row["createdAt"])
                )
            }
        }
    }

    func conversationTasks() throws -> [ConversationTask] {
        try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_tasks t
                WHERE EXISTS (SELECT 1 FROM conversation_messages m WHERE m.taskID = t.id)
                ORDER BY createdAt DESC LIMIT 100
                """
            ).map { row in
                guard let owner = AgentRole(rawValue: row["owner"])
                else { throw InfactoryError.invalidDatabase }
                let capture: String? = row["captureID"]
                return try ConversationTask(
                    id: Self.uuid(row["id"]),
                    owner: owner,
                    request: row["request"],
                    state: row["state"],
                    progress: row["progress"],
                    captureID: capture.map(Self.uuid),
                    sources: JSONDecoder().decode([UUID].self, from: row["sourceRefs"])
                )
            }
        }
    }

    func recoverConversation() throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            UPDATE conversation_tasks SET state = 'failed', progress = ?, updatedAt = ?
            WHERE state IN ('queued','running')
            """, arguments: [
                ConversationError.interrupted.localizedDescription,
                Date().timeIntervalSince1970,
            ])
        }
    }

    func clearConversation() throws {
        try readyDatabase().write { db in
            // Retained task IDs support artifact/link provenance, not conversational memory.
            try db.execute(sql: """
            UPDATE conversation_tasks SET
                state = CASE WHEN state IN ('queued','running','awaiting_user') THEN 'cancelled' ELSE state END,
                request = '', progress = '', sourceRefs = ?, updatedAt = ?
            """, arguments: [JSONEncoder().encode([UUID]()), Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM conversation_events")
            try db.execute(sql: "DELETE FROM conversation_messages")
            try db
                .execute(
                    sql: "UPDATE knowledge_proposals SET status = 'rejected' WHERE status = 'pending'"
                )
            try db
                .execute(
                    sql: "UPDATE agent_changes SET status = 'rejected' WHERE status = 'pending'"
                )
            try db.execute(sql: """
            DELETE FROM conversation_tasks
            WHERE id NOT IN (SELECT taskID FROM authored_artifacts)
              AND id NOT IN (SELECT taskID FROM knowledge_proposals)
            """)
        }
    }

    func beginConversation(
        _ request: String,
        owner: AgentRole,
        captureID: UUID? = nil,
        sources: [UUID] = []
    ) throws -> UUID {
        _ = try ConversationRoute(request)
        return try readyDatabase().write { db in
            for source in sources {
                _ = try Self.liveNote(source, in: db)
            }
            let id = UUID()
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
            INSERT INTO conversation_tasks(id, owner, request, state, captureID, sourceRefs, createdAt, updatedAt)
            VALUES (?, ?, ?, 'running', ?, ?, ?, ?)
            """, arguments: [
                id.uuidString,
                owner.rawValue,
                request,
                captureID?.uuidString,
                JSONEncoder().encode(sources),
                now,
                now,
            ])
            try Self.insertMessage(
                author: "user",
                text: request,
                references: [],
                taskID: id,
                in: db
            )
            try db.execute(
                sql: "INSERT INTO conversation_events(taskID, kind, detail, createdAt) VALUES (?, 'started', '', ?)",
                arguments: [id.uuidString, now]
            )
            return id
        }
    }

    func updateConversationTask(
        _ id: UUID,
        state: String = "running",
        progress: String,
        captureID: UUID? = nil,
        owner: AgentRole? = nil,
        event: String = "progress"
    ) throws {
        try readyDatabase().write { db in
            // Terminal states are fences against late model/network completions.
            try db.execute(sql: """
            UPDATE conversation_tasks SET state = ?, progress = ?, captureID = coalesce(?, captureID), owner = coalesce(?, owner), updatedAt = ?
            WHERE id = ? AND state IN ('queued','running','awaiting_user')
            """, arguments: [
                state,
                progress,
                captureID?.uuidString,
                owner?.rawValue,
                Date().timeIntervalSince1970,
                id.uuidString,
            ])
            if db.changesCount > 0 {
                try db.execute(
                    sql: "INSERT INTO conversation_events(taskID, kind, detail, createdAt) VALUES (?, ?, ?, ?)",
                    arguments: [id.uuidString, event, progress, Date().timeIntervalSince1970]
                )
            }
        }
    }

    func postConversation(
        author: AgentRole,
        text: String,
        references: [UUID] = [],
        taskID: UUID
    ) throws {
        try readyDatabase().write { db in
            try Self.requireConversationTask(taskID, in: db)
            for id in references {
                _ = try Self.liveNote(id, in: db)
            }
            try Self.insertMessage(
                author: author.rawValue,
                text: text,
                references: references,
                taskID: taskID,
                in: db
            )
        }
    }

    func captureJob(id: UUID) throws -> CaptureJob? {
        try readyDatabase().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM ingestion_jobs WHERE id = ?",
                arguments: [id.uuidString]
            )
            .map(Self.captureJob)
        }
    }

    func researchSource(noteID: UUID) throws -> ResearchSource {
        guard let note = try document(id: noteID) else { throw ConversationError.missingSource }
        let capture = try readyDatabase().read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM captures WHERE noteID = ? ORDER BY createdAt DESC LIMIT 1",
                arguments: [noteID.uuidString]
            )
        }
        let document: CapturedDocument = if let capture {
            try captureDetail(id: Self.uuid(capture)).document
        } else {
            CapturedDocument(
                title: note.name,
                coverage: .note,
                blocks: [ContentBlock(
                    kind: .paragraph,
                    markdown: note.markdown,
                    text: note.markdown
                )]
            )
        }
        let sources = try readyDatabase().read { db in
            try String.fetchAll(
                db,
                sql: "SELECT sourceID FROM note_sources WHERE noteID = ?",
                arguments: [noteID.uuidString]
            ).map(Self.uuid)
        }
        return ResearchSource(note: note, sourceIDs: sources, document: document)
    }

    /// Artifact creation, source associations and its feed reference commit together.
    func saveResearch(
        _ markdown: String,
        name: String,
        sources: [ResearchSource],
        taskID: UUID,
        provider: String,
        kind: String = "summary"
    ) throws -> MarkdownDocument {
        try Task.checkCancellation()
        return try readyDatabase().write { db in
            try Self.requireConversationTask(taskID, in: db)
            if let existing = try String.fetchOne(
                db,
                sql: "SELECT noteID FROM authored_artifacts WHERE taskID = ?",
                arguments: [taskID.uuidString]
            ) {
                return try Self.liveNote(Self.uuid(existing), in: db)
            }
            for source in sources {
                guard try Self.liveNote(source.note.id, in: db).revision == source.note.revision
                else { throw ConversationError.staleProposal }
            }
            let note = MarkdownDocument(name: String(name.prefix(240)), markdown: markdown)
            try Self.validate(note)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationError.invalidOutput
            }
            let saved = try Self.writeNote(note, in: db)
            for id in Set(sources.flatMap(\.sourceIDs)) {
                try db.execute(
                    sql: "INSERT INTO note_sources(noteID, sourceID) VALUES (?, ?)",
                    arguments: [saved.id.uuidString, id.uuidString]
                )
            }
            try db.execute(
                sql: "INSERT INTO authored_artifacts VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    saved.id.uuidString,
                    taskID.uuidString,
                    kind,
                    provider,
                    Date().timeIntervalSince1970,
                ]
            )
            try Self.insertMessage(
                author: kind == "note" ? "librarian" : "researcher",
                text: markdown,
                references: [saved.id] + sources.map(\.note.id),
                taskID: taskID,
                in: db
            )
            return saved
        }
    }

    func categories(for noteID: UUID? = nil) throws -> [DecimalCategory] {
        try readyDatabase().read { db in
            let sql = noteID == nil ? "SELECT * FROM decimal_categories ORDER BY code" : """
            SELECT c.* FROM decimal_categories c JOIN note_categories n ON n.categoryID = c.id
            WHERE n.noteID = ? ORDER BY n.isPrimary DESC, c.code
            """
            return try Row.fetchAll(db, sql: sql, arguments: noteID.map { [$0.uuidString] } ?? [])
                .map {
                    try DecimalCategory(id: Self.uuid($0["id"]), code: $0["code"], name: $0["name"])
                }
        }
    }

    func saveCategory(id: UUID = UUID(), code: String, name: String) throws {
        try DecimalCategory.validate(code: code, name: name)
        try readyDatabase().write { db in
            let current = try String.fetchOne(
                db,
                sql: "SELECT code FROM decimal_categories WHERE id = ?",
                arguments: [id.uuidString]
            )
            if current == DecimalCategory.inboxCode, code != DecimalCategory.inboxCode {
                throw ConversationError.inboxCategory
            }
            let taken = try Row.fetchAll(db, sql: "SELECT id, code, name FROM decimal_categories")
                .contains {
                    let other: String = $0["id"], otherCode: String = $0["code"]
                    let otherName: String = $0["name"]
                    return other != id.uuidString && (otherCode == code
                        || DecimalCategory.normalized(otherName) == DecimalCategory
                        .normalized(name))
                }
            if taken {
                throw ConversationError.categoryTaken
            }
            try db.execute(sql: """
            INSERT INTO decimal_categories(id, code, name) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET code = excluded.code, name = excluded.name
            """, arguments: [
                id.uuidString,
                code,
                name.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
    }

    /// Adds categories in one transaction, skipping any whose code or name is already taken.
    /// Returns the IDs actually created, for `removeUnusedCategories`.
    func addCategories(_ categories: [(code: String, name: String)]) throws -> [UUID] {
        for category in categories {
            try DecimalCategory.validate(code: category.code, name: category.name)
        }
        return try readyDatabase().write { db in
            var created: [UUID] = []
            for category in categories {
                let new = DecimalCategory(
                    id: UUID(),
                    code: category.code,
                    name: category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard try !Self.categoryExists(like: new, in: db) else { continue }
                try db.execute(
                    sql: "INSERT INTO decimal_categories(id, code, name) VALUES (?, ?, ?)",
                    arguments: [new.id.uuidString, new.code, new.name]
                )
                created.append(new.id)
            }
            return created
        }
    }

    /// Deletes the given categories unless something has been filed in them since.
    /// Returns how many were kept because they are in use.
    func removeUnusedCategories(_ ids: [UUID]) throws -> Int {
        try readyDatabase().write { db in
            var kept = 0
            for id in ids {
                try db.execute(sql: """
                DELETE FROM decimal_categories WHERE id = ?1
                AND NOT EXISTS (SELECT 1 FROM note_categories WHERE categoryID = ?1)
                AND NOT EXISTS (SELECT 1 FROM source_categories WHERE categoryID = ?1)
                """, arguments: [id.uuidString])
                if db.changesCount == 0,
                   try Bool.fetchOne(
                       db,
                       sql: "SELECT EXISTS(SELECT 1 FROM decimal_categories WHERE id = ?)",
                       arguments: [id.uuidString]
                   ) == true
                {
                    kept += 1
                }
            }
            return kept
        }
    }

    /// Live items filed in each category, as primary or secondary home.
    func categoryItemCounts() throws -> [UUID: Int] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT nc.categoryID, count(*) AS items FROM note_categories nc
            JOIN notes n ON n.id = nc.noteID AND n.deletedAt IS NULL
            GROUP BY nc.categoryID
            """).reduce(into: [:]) { counts, row in
                try counts[Self.uuid(row["categoryID"])] = row["items"]
            }
        }
    }

    /// Deletes a category and its memberships. An item whose primary home this was keeps its
    /// lowest-coded remaining category as primary; items filed nowhere else become unfiled.
    /// Pending proposals into this category go stale when reviewed.
    func deleteCategory(_ id: UUID) throws {
        try readyDatabase().write { db in
            let code = try String.fetchOne(
                db,
                sql: "SELECT code FROM decimal_categories WHERE id = ?",
                arguments: [id.uuidString]
            )
            if code == DecimalCategory.inboxCode {
                throw ConversationError.inboxCategory
            }
            for (table, column) in [
                ("note_categories", "noteID"),
                ("source_categories", "sourceID"),
            ] {
                let homeless = try String.fetchAll(
                    db,
                    sql: "SELECT \(column) FROM \(table) WHERE categoryID = ? AND isPrimary = 1",
                    arguments: [id.uuidString]
                )
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE categoryID = ?",
                    arguments: [id.uuidString]
                )
                for item in homeless {
                    try db.execute(sql: """
                    UPDATE \(table) SET isPrimary = 1 WHERE \(column) = ?1 AND categoryID = (
                        SELECT m.categoryID FROM \(table) m
                        JOIN decimal_categories c ON c.id = m.categoryID
                        WHERE m.\(column) = ?1 ORDER BY c.code LIMIT 1
                    )
                    """, arguments: [item])
                }
            }
            try db.execute(
                sql: "DELETE FROM decimal_categories WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func fileNote(
        _ noteID: UUID,
        categoryID: UUID,
        primary: Bool = true,
        includeSources: Bool = false
    ) throws {
        try readyDatabase().write { db in
            _ = try Self.liveNote(noteID, in: db)
            if primary {
                try db.execute(
                    sql: "UPDATE note_categories SET isPrimary = 0 WHERE noteID = ?",
                    arguments: [noteID.uuidString]
                )
            }
            try db.execute(sql: """
            INSERT INTO note_categories VALUES (?, ?, ?) ON CONFLICT(noteID, categoryID) DO UPDATE SET isPrimary = excluded.isPrimary
            """, arguments: [noteID.uuidString, categoryID.uuidString, primary])
            if includeSources {
                for source in try String.fetchAll(
                    db,
                    sql: "SELECT sourceID FROM note_sources WHERE noteID = ?",
                    arguments: [noteID.uuidString]
                ) {
                    if primary {
                        try db.execute(
                            sql: "UPDATE source_categories SET isPrimary = 0 WHERE sourceID = ?",
                            arguments: [source]
                        )
                    }
                    try db.execute(sql: """
                    INSERT INTO source_categories VALUES (?, ?, ?) ON CONFLICT(sourceID, categoryID) DO UPDATE SET isPrimary = excluded.isPrimary
                    """, arguments: [source, categoryID.uuidString, primary])
                }
            }
        }
    }

    func proposeLink(
        _ left: MarkdownDocument,
        _ right: MarkdownDocument,
        rationale: String,
        taskID: UUID
    ) throws -> UUID {
        try readyDatabase().write { db in
            try Self.requireConversationTask(taskID, in: db)
            guard left.id != right.id, let leftRevision = left.revision,
                  let rightRevision = right.revision,
                  try Self.liveNote(left.id, in: db).revision == leftRevision,
                  try Self.liveNote(right.id, in: db).revision == rightRevision
            else { throw ConversationError.staleProposal }
            let id = UUID()
            try db.execute(
                sql: "INSERT INTO knowledge_proposals(id, taskID, leftID, rightID, leftRevision, rightRevision, rationale, status, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
                arguments: [
                    id.uuidString,
                    taskID.uuidString,
                    left.id.uuidString,
                    right.id.uuidString,
                    leftRevision.uuidString,
                    rightRevision.uuidString,
                    rationale,
                    Date().timeIntervalSince1970,
                ]
            )
            return id
        }
    }

    func proposals() throws -> [KnowledgeProposal] {
        try readyDatabase().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM knowledge_proposals ORDER BY createdAt DESC LIMIT 100"
            ).map { row in
                try KnowledgeProposal(
                    id: Self.uuid(row["id"]),
                    taskID: Self.uuid(row["taskID"]),
                    left: Self.uuid(row["leftID"]),
                    right: Self.uuid(row["rightID"]),
                    leftRevision: Self.uuid(row["leftRevision"]),
                    rightRevision: Self.uuid(row["rightRevision"]),
                    rationale: row["rationale"],
                    status: row["status"],
                    filing: (row["filing"] as Data?).map { try JSONDecoder().decode(
                        FilingChange.self,
                        from: $0
                    ) }
                )
            }
        }
    }

    /// Only the UI's explicit approval calls this method. A stale preview commits no link.
    func reviewProposal(_ id: UUID, action: String) throws {
        guard ["apply", "reject", "undo"].contains(action)
        else { throw ConversationError.staleProposal }
        let stale = try readyDatabase().write { db -> Bool in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM knowledge_proposals WHERE id = ?",
                arguments: [id.uuidString]
            )
            else { throw ConversationError.staleProposal }
            let status: String = row["status"]
            if let data: Data = row["filing"] {
                return try Self.reviewFiling(
                    row: row,
                    change: JSONDecoder().decode(FilingChange.self, from: data),
                    action: action,
                    in: db
                )
            }
            if action == "undo", status == "applied" {
                try db.execute(
                    sql: "DELETE FROM knowledge_links WHERE proposalID = ?",
                    arguments: [id.uuidString]
                )
                try db.execute(
                    sql: "UPDATE knowledge_proposals SET status = 'undone' WHERE id = ?",
                    arguments: [id.uuidString]
                )
                return false
            }
            guard status == "pending" else { return status == "stale" }
            if action == "reject" {
                try db.execute(
                    sql: "UPDATE knowledge_proposals SET status = 'rejected' WHERE id = ?",
                    arguments: [id.uuidString]
                )
                return false
            }
            guard action == "apply" else { return false }
            let left: String = row["leftID"], right: String = row["rightID"]
            let leftRevision: String = row["leftRevision"],
                rightRevision: String = row["rightRevision"]
            let valid = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM notes WHERE deletedAt IS NULL AND ((id = ? AND revision = ?) OR (id = ? AND revision = ?))
            """, arguments: [left, leftRevision, right, rightRevision]) == 2
            if !valid {
                try db.execute(
                    sql: "UPDATE knowledge_proposals SET status = 'stale' WHERE id = ?",
                    arguments: [id.uuidString]
                )
                return true
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO knowledge_links VALUES (?, ?, ?)",
                arguments: [min(left, right), max(left, right), id.uuidString]
            )
            try db.execute(
                sql: "UPDATE knowledge_proposals SET status = 'applied' WHERE id = ?",
                arguments: [id.uuidString]
            )
            return false
        }
        if stale {
            throw ConversationError.staleProposal
        }
    }

    /// With `creating`, `category` is a new home that applying the proposal will create.
    func proposeFiling(
        noteID: UUID,
        category: DecimalCategory,
        rationale: String,
        taskID: UUID,
        creating: Bool = false
    ) throws -> UUID {
        try readyDatabase().write { db in
            try Self.requireConversationTask(taskID, in: db)
            let note = try Self.liveNote(noteID, in: db)
            guard let revision = note.revision else { throw ConversationError.staleProposal }
            if creating {
                try DecimalCategory.validate(code: category.code, name: category.name)
                guard try !Self.categoryExists(like: category, in: db)
                else { throw ConversationError.invalidCategory }
            } else {
                guard try String.fetchOne(
                    db,
                    sql: "SELECT code || ' ' || name FROM decimal_categories WHERE id = ?",
                    arguments: [category.id.uuidString]
                ) == category.label
                else { throw ConversationError.invalidCategory }
            }
            let before = try Self.filingMemberships(
                table: "note_categories",
                column: "noteID",
                id: noteID,
                in: db
            )
            let labels = try String.fetchAll(
                db,
                sql: "SELECT c.code || ' ' || c.name FROM note_categories nc JOIN decimal_categories c ON c.id = nc.categoryID WHERE nc.noteID = ? ORDER BY nc.isPrimary DESC, c.code",
                arguments: [noteID.uuidString]
            )
            var sources: [UUID: [FilingMembership]] = [:]
            // Filing an artifact does not relocate its cited sources. Captured representations do.
            for value in try String.fetchAll(
                db,
                sql: "SELECT DISTINCT sourceID FROM captures WHERE noteID = ?",
                arguments: [noteID.uuidString]
            ) {
                let id = try Self.uuid(value)
                sources[id] = try Self.filingMemberships(
                    table: "source_categories",
                    column: "sourceID",
                    id: id,
                    in: db
                )
            }
            let change = FilingChange(
                destination: category.id,
                destinationLabel: category.label,
                previousLabel: labels.isEmpty ? "Unfiled" : labels
                    .joined(separator: "; "),
                before: before,
                sources: sources,
                newCategory: creating ? .init(code: category.code, name: category.name) : nil
            )
            let id = UUID()
            try db.execute(sql: """
            INSERT INTO knowledge_proposals(id, taskID, leftID, rightID, leftRevision, rightRevision, rationale, status, createdAt, filing)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
            """, arguments: [
                id.uuidString,
                taskID.uuidString,
                noteID.uuidString,
                category.id.uuidString,
                revision.uuidString,
                revision.uuidString,
                String(rationale.prefix(1500)),
                Date().timeIntervalSince1970,
                JSONEncoder().encode(change),
            ])
            return id
        }
    }

    private static func filingMemberships(
        table: String,
        column: String,
        id: UUID,
        in db: Database
    ) throws -> [FilingMembership] {
        // table/column are application constants, never values from a plan.
        try Row.fetchAll(
            db,
            sql: "SELECT categoryID, isPrimary FROM \(table) WHERE \(column) = ? ORDER BY categoryID",
            arguments: [id.uuidString]
        ).map {
            try FilingMembership(categoryID: uuid($0["categoryID"]), primary: $0["isPrimary"])
        }
    }

    private static func filedMemberships(
        _ before: [FilingMembership],
        destination: UUID
    ) -> [FilingMembership] {
        let result = before.filter { $0.categoryID != destination }.map { FilingMembership(
            categoryID: $0.categoryID,
            primary: false
        ) }
            + [FilingMembership(categoryID: destination, primary: true)]
        return result.sorted { $0.categoryID.uuidString < $1.categoryID.uuidString }
    }

    private static func replaceMemberships(
        _ memberships: [FilingMembership],
        table: String,
        column: String,
        id: UUID,
        in db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ?", arguments: [id.uuidString])
        for membership in memberships {
            try db.execute(
                sql: "INSERT INTO \(table)(\(column), categoryID, isPrimary) VALUES (?, ?, ?)",
                arguments: [id.uuidString, membership.categoryID.uuidString, membership.primary]
            )
        }
    }

    private static func reviewFiling(
        row: Row,
        change: FilingChange,
        action: String,
        in db: Database
    ) throws -> Bool {
        let proposal: String = row["id"], status: String = row["status"]
        if action == "reject", status == "pending" {
            try db.execute(
                sql: "UPDATE knowledge_proposals SET status = 'rejected' WHERE id = ?",
                arguments: [proposal]
            )
            return false
        }
        let undo = action == "undo" && status == "applied"
        guard undo || (action == "apply" && status == "pending") else { return status == "stale" }
        let id = try uuid(row["leftID"])
        let revision: String = row["leftRevision"]
        let expected = undo ? filedMemberships(change.before, destination: change.destination) :
            change.before
        var valid = try String.fetchOne(
            db,
            sql: "SELECT revision FROM notes WHERE id = ? AND deletedAt IS NULL",
            arguments: [id.uuidString]
        ) == revision
        valid = try valid && filingMemberships(
            table: "note_categories",
            column: "noteID",
            id: id,
            in: db
        ) == expected
        let destinationExists = try String.fetchOne(
            db,
            sql: "SELECT code || ' ' || name FROM decimal_categories WHERE id = ?",
            arguments: [change.destination.uuidString]
        ) == change.destinationLabel
        // A sibling proposal from the same request may already have created this home.
        let creating = destinationExists ? nil : change.newCategory.map {
            DecimalCategory(id: change.destination, code: $0.code, name: $0.name)
        }
        if let creating, !undo {
            // A manual edit may have created an equivalent home meanwhile.
            valid = try valid && !categoryExists(like: creating, in: db)
        } else {
            valid = valid && destinationExists
        }
        for (source, before) in change.sources {
            let expected = undo ? filedMemberships(before, destination: change.destination) : before
            valid = try valid && filingMemberships(
                table: "source_categories",
                column: "sourceID",
                id: source,
                in: db
            ) == expected
        }
        if !valid {
            if !undo {
                try db.execute(
                    sql: "UPDATE knowledge_proposals SET status = 'stale' WHERE id = ?",
                    arguments: [proposal]
                )
            }
            if undo {
                throw ConversationError.staleProposal
            }
            return true
        }
        if let creating, !undo {
            try db.execute(
                sql: "INSERT INTO decimal_categories(id, code, name) VALUES (?, ?, ?)",
                arguments: [creating.id.uuidString, creating.code, creating.name]
            )
        }
        try replaceMemberships(
            undo ? change.before : filedMemberships(change.before, destination: change.destination),
            table: "note_categories",
            column: "noteID",
            id: id,
            in: db
        )
        for (source, before) in change.sources {
            try replaceMemberships(
                undo ? before : filedMemberships(before, destination: change.destination),
                table: "source_categories",
                column: "sourceID",
                id: source,
                in: db
            )
        }
        if change.newCategory != nil, undo {
            // Undo removes a category this proposal created, unless something else now uses it.
            try db.execute(sql: """
            DELETE FROM decimal_categories WHERE id = ?1
            AND NOT EXISTS (SELECT 1 FROM note_categories WHERE categoryID = ?1)
            AND NOT EXISTS (SELECT 1 FROM source_categories WHERE categoryID = ?1)
            """, arguments: [change.destination.uuidString])
        }
        try db.execute(
            sql: "UPDATE knowledge_proposals SET status = ? WHERE id = ?",
            arguments: [undo ? "undone" : "applied", proposal]
        )
        return false
    }

    /// True when the code, id or normalized name is already taken.
    private static func categoryExists(
        like category: DecimalCategory,
        in db: Database
    ) throws -> Bool {
        try Row.fetchAll(db, sql: "SELECT id, code, name FROM decimal_categories").contains {
            let code: String = $0["code"], name: String = $0["name"], id: String = $0["id"]
            return id == category.id.uuidString || code == category.code
                || DecimalCategory.normalized(name) == DecimalCategory.normalized(category.name)
        }
    }

    static func liveNote(_ id: UUID, in db: Database) throws -> MarkdownDocument {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM notes WHERE id = ? AND deletedAt IS NULL",
            arguments: [id.uuidString]
        )
        else { throw ConversationError.missingSource }
        return try document(row)
    }

    private static func requireConversationTask(_ id: UUID, in db: Database) throws {
        guard try String.fetchOne(
            db,
            sql: "SELECT state FROM conversation_tasks WHERE id = ?",
            arguments: [id.uuidString]
        ) == "running"
        else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func insertMessage(
        author: String,
        text: String,
        references: [UUID],
        taskID: UUID,
        in db: Database
    ) throws {
        try db.execute(
            sql: "INSERT INTO conversation_messages(id, author, text, refs, taskID, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [
                UUID().uuidString,
                author,
                text,
                JSONEncoder().encode(references),
                taskID.uuidString,
                Date().timeIntervalSince1970,
            ]
        )
    }
}
