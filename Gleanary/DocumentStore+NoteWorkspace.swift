import Foundation
import GRDB

extension DocumentStore {
    func noteTemplates() throws -> [NoteTemplate] {
        try readyDatabase().read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT definition FROM note_templates ORDER BY stock DESC, rowid"
            )
            .map { try JSONDecoder().decode(NoteTemplate.self, from: $0) }
        }
    }

    func saveNoteTemplate(_ template: NoteTemplate) throws -> NoteTemplate {
        try Self.workspaceTitle(template.name)
        try Self.workspaceTitle(template.title)
        guard template.body.utf8.count <= 1_000_000 else { throw WorkspaceError.invalidProperties }
        guard !template.body.localizedCaseInsensitiveContains("gleanary://task/")
        else { throw WorkspaceError.trackedTemplate }
        return try readyDatabase().write { db in
            try Self.validateProfile(template.defaults, template: true, in: db)
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM note_templates WHERE id = ?",
                arguments: [template.id.uuidString]
            )
            guard row?["stock"] as Bool? != true,
                  !template.stock else { throw WorkspaceError.stockTemplate }
            let version: Int = row?["version"] ?? 0
            guard version == template.version else { throw WorkspaceError.stale }
            var saved = template
            saved.version += 1
            try db.execute(sql: """
            INSERT INTO note_templates(id, definition, version, stock) VALUES (?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET definition = excluded.definition, version = excluded.version
            """, arguments: [saved.id.uuidString, JSONEncoder().encode(saved), saved.version])
            return saved
        }
    }

    func deleteNoteTemplate(_ template: NoteTemplate) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "DELETE FROM note_templates WHERE id = ? AND version = ? AND stock = 0",
                arguments: [template.id.uuidString, template.version]
            )
            guard db.changesCount == 1 else { throw WorkspaceError.stale }
        }
    }

    func noteProfile(_ id: UUID) throws -> NoteProfile {
        try readyDatabase().read { try Self.noteProfile(id, in: $0) }
    }

    func noteProfileRevision(_ revision: UUID) throws -> NoteProfile? {
        try readyDatabase().read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT profile FROM note_profile_revisions WHERE revision = ?",
                arguments: [revision.uuidString]
            )
            .map { try JSONDecoder().decode(NoteProfile.self, from: $0) }
        }
    }

    func workspaceNoteLinks(
        to id: UUID? = nil,
        query: String = "",
        type: NoteRecordType? = nil,
        offset: Int = 0,
        limit: Int = 80
    ) throws -> [WorkspaceNoteLink] {
        try readyDatabase().read { db in
            var predicate = "n.deletedAt IS NULL"
            var arguments = StatementArguments()
            if let id {
                predicate += " AND EXISTS(SELECT 1 FROM note_property_links l WHERE l.noteID = n.id AND l.targetID = ?)"
                arguments += [id.uuidString]
            }
            if !query.isEmpty {
                predicate += " AND instr(lower(n.name), lower(?)) > 0"
                arguments += [query]
            }
            if let type {
                predicate += " AND json_extract(CAST(p.profile AS TEXT), '$.type') = ?"
                arguments += [type.rawValue]
            }
            arguments += [max(1, min(limit, 200)), max(0, offset)]
            return try Row.fetchAll(db, sql: """
            SELECT n.id, n.name FROM notes n LEFT JOIN note_profiles p ON p.noteID = n.id
            WHERE \(predicate) ORDER BY n.name COLLATE NOCASE, n.id LIMIT ? OFFSET ?
            """, arguments: arguments).map { try WorkspaceNoteLink(
                id: Self.uuid($0["id"]),
                name: $0["name"]
            ) }
        }
    }

    func workspaceLinkNames(_ ids: [UUID]) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        return try readyDatabase().read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, name FROM notes WHERE deletedAt IS NULL AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments(ids.map(\.uuidString)))
            return try Dictionary(uniqueKeysWithValues: rows.map { try (
                Self.uuid($0["id"]),
                $0["name"] as String
            ) })
        }
    }

    static func noteProfile(_ id: UUID, in db: Database) throws -> NoteProfile {
        let data = try Data.fetchOne(
            db,
            sql: "SELECT profile FROM note_profiles WHERE noteID = ?",
            arguments: [id.uuidString]
        )
        var profile = try data
            .map { try JSONDecoder().decode(NoteProfile.self, from: $0) } ?? NoteProfile()
        profile.links = [:]
        for row in try Row.fetchAll(db, sql: """
        SELECT l.propertyID, l.targetID FROM note_property_links l JOIN notes n ON n.id = l.targetID
        WHERE l.noteID = ? AND n.deletedAt IS NULL ORDER BY l.propertyID, l.ordinal
        """, arguments: [id.uuidString]) {
            let key: String = row["propertyID"]
            try profile.links[key, default: []].append(Self.uuid(row["targetID"]))
        }
        return profile
    }

    static func writeProfile(
        _ profile: NoteProfile,
        for document: MarkdownDocument,
        in db: Database
    ) throws {
        try validateProfile(profile, in: db)
        var scalar = profile
        scalar.links = [:]
        try db.execute(sql: """
        INSERT INTO note_profiles(noteID, profile) VALUES (?, ?)
        ON CONFLICT(noteID) DO UPDATE SET profile = excluded.profile
        """, arguments: [document.id.uuidString, JSONEncoder().encode(scalar)])
        try db.execute(
            sql: "DELETE FROM note_property_links WHERE noteID = ?",
            arguments: [document.id.uuidString]
        )
        for (key, ids) in profile.links {
            for (ordinal, id) in ids.enumerated() {
                try db.execute(
                    sql: "INSERT INTO note_property_links VALUES (?, ?, ?, ?)",
                    arguments: [document.id.uuidString, key, id.uuidString, ordinal]
                )
            }
        }
        if let revision = document.revision {
            try db.execute(
                sql: "INSERT INTO note_profile_revisions VALUES (?, ?)",
                arguments: [revision.uuidString, JSONEncoder().encode(profile)]
            )
        }
    }

    static func validateProfile(
        _ profile: NoteProfile,
        template: Bool = false,
        in db: Database
    ) throws {
        for (key, value) in profile.values {
            guard let field = profile.type.fields.first(where: { $0.id == key }),
                  field.kind == .text || field.kind == .date,
                  value.utf8.count <= 10000 else { throw WorkspaceError.invalidProperties }
            if field.kind == .date, !value.isEmpty,
               WorkspaceDay(rawValue: value) == nil, !(template && value == "{{date}}")
            {
                throw WorkspaceError.invalidDate
            }
        }
        for (key, ids) in profile.links {
            guard let field = profile.type.fields.first(where: { $0.id == key }),
                  field.kind == .link || field.kind == .links,
                  ids.count <= (field.kind == .link ? 1 : 100), Set(ids).count == ids.count
            else {
                throw WorkspaceError.invalidProperties
            }
            for id in ids {
                try requireWorkspaceNote(id, in: db)
                if let target = field.target,
                   try noteProfile(id, in: db)
                   .type != target
                {
                    throw WorkspaceError.invalidProperties
                }
            }
        }
    }

    static func requireWorkspaceNote(_ id: UUID, in db: Database) throws {
        guard try Bool
            .fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ? AND deletedAt IS NULL)",
                arguments: [id.uuidString]
            ) == true
        else { throw WorkspaceError.missingNote }
    }

    static func workspaceTitle(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500,
              !text.contains(where: \.isNewline) else { throw WorkspaceError.invalidTitle }
    }
}
