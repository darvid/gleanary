import Foundation
import GRDB

extension DocumentStore {
    static func enqueueGraph(_ document: MarkdownDocument, in db: Database) throws {
        guard let revision = document.revision else { throw GleanaryError.invalidDatabase }
        let id = document.id.uuidString
        try db.execute(sql: "DELETE FROM graph_evidence WHERE noteID = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM graph_links WHERE noteID = ?", arguments: [id])
        try db.execute(sql: """
        INSERT INTO graph_nodes(id, kind, label, noteID) VALUES (?, 'document', ?, ?)
        ON CONFLICT(id) DO UPDATE SET label = excluded.label
        """, arguments: [GraphNode.documentID(document.id), document.name, id])
        try db.execute(sql: """
        INSERT INTO graph_jobs(noteID, revision, version, token, state) VALUES (?, ?, ?, ?, 'queued')
        ON CONFLICT(noteID) DO UPDATE SET revision = excluded.revision, version = excluded.version,
            token = excluded.token, state = 'queued', completed = 0, total = 0, chunks = NULL, error = NULL
        """, arguments: [id, revision.uuidString, GraphExtractor.version, UUID().uuidString])
        try pruneGraph(in: db)
    }

    static func pruneGraph(in db: Database) throws {
        try db.execute(sql: """
        DELETE FROM graph_edges WHERE NOT EXISTS (SELECT 1 FROM graph_evidence WHERE edgeID = graph_edges.id);
        DELETE FROM graph_nodes WHERE kind != 'document'
            AND NOT EXISTS (SELECT 1 FROM graph_edges WHERE source = graph_nodes.id OR target = graph_nodes.id);
        """)
    }

    static func removeGraph(_ noteID: UUID, in db: Database) throws {
        let id = noteID.uuidString
        for table in [
            "mind_map_evidence",
            "mind_map_state",
            "mind_map_nodes",
            "mind_maps",
            "graph_passage_cache",
            "graph_evidence",
            "graph_jobs",
            "graph_decisions",
            "graph_links",
            "graph_nodes",
        ] {
            try db.execute(sql: "DELETE FROM \(table) WHERE noteID = ?", arguments: [id])
        }
        // Removing a document also cascades incoming links and their evidence.
        try pruneGraph(in: db)
    }

    func recoverGraph() throws {
        try readyDatabase().write { db in
            let previouslyDismissed = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT noteID FROM graph_decisions"
            )
            try db.execute(sql: "DELETE FROM graph_decisions")
            for id in previouslyDismissed {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM notes WHERE id = ? AND deletedAt IS NULL",
                    arguments: [id]
                ) {
                    try Self.enqueueGraph(Self.document(row), in: db)
                }
            }
            let rows = try Row.fetchAll(db, sql: """
            SELECT notes.* FROM notes LEFT JOIN graph_jobs ON notes.id = graph_jobs.noteID
            WHERE notes.deletedAt IS NULL AND (graph_jobs.noteID IS NULL OR graph_jobs.version != ?)
            """, arguments: [GraphExtractor.version])
            for row in rows {
                try Self.enqueueGraph(Self.document(row), in: db)
            }
            try db.execute(
                sql: "UPDATE graph_jobs SET state = CASE WHEN completed >= total AND total > 0 THEN 'curating' ELSE 'queued' END, token = ? WHERE state IN ('running', 'curating')",
                arguments: [UUID().uuidString]
            )
        }
    }

    func graphJobs() throws -> [GraphJob] {
        try readyDatabase().read { db in
            try Row.fetchAll(db, sql: """
            SELECT graph_jobs.*, notes.name FROM graph_jobs JOIN notes ON notes.id = graph_jobs.noteID
            ORDER BY (state = 'running') DESC, (state = 'curating') DESC,
                (state = 'queued') DESC, notes.createdAt
            """).map(Self.graphJob)
        }
    }

    func cachedGraphProposal(
        for work: GraphWork,
        overview: Bool
    ) throws -> GraphProposal? {
        try readyDatabase().read { db in
            guard let data = try Data.fetchOne(db, sql: """
            SELECT proposal FROM graph_passage_cache
            WHERE noteID = ? AND contentHash = ? AND version = ? AND mode = ?
            """, arguments: [
                work.job.noteID.uuidString,
                ContentHash.of(work.chunk.extractionText),
                GraphExtractor.candidateVersion,
                overview ? "overview" : "passage",
            ]) else { return nil }
            return try JSONDecoder().decode(GraphProposal.self, from: data)
        }
    }

    func cacheGraphProposal(
        _ proposal: GraphProposal,
        for work: GraphWork,
        overview: Bool
    ) throws {
        try readyDatabase().write { db in
            try db.execute(sql: """
            INSERT OR REPLACE INTO graph_passage_cache(
                noteID, contentHash, version, mode, proposal, createdAt
            ) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                work.job.noteID.uuidString,
                ContentHash.of(work.chunk.extractionText),
                GraphExtractor.candidateVersion,
                overview ? "overview" : "passage",
                JSONEncoder().encode(proposal),
                Date().timeIntervalSince1970,
            ])
        }
    }

    static func graphJob(_ row: Row) throws -> GraphJob {
        try GraphJob(
            noteID: uuid(row["noteID"]),
            revision: uuid(row["revision"]),
            token: uuid(row["token"]),
            name: row["name"],
            state: row["state"],
            completed: row["completed"],
            total: row["total"],
            error: row["error"]
        )
    }

    func pauseGraph(_ noteID: UUID, token: UUID? = nil) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE graph_jobs SET state = 'paused', token = ? WHERE noteID = ? AND state IN ('queued','running','curating') AND (? IS NULL OR token = ?)",
                arguments: [
                    UUID().uuidString,
                    noteID.uuidString,
                    token?.uuidString,
                    token?.uuidString,
                ]
            )
        }
    }

    func retryGraph(_ noteID: UUID, rebuild: Bool = false) throws {
        try readyDatabase().write { db in
            if rebuild, let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM notes WHERE id = ? AND deletedAt IS NULL",
                arguments: [noteID.uuidString]
            ) {
                try Self.enqueueGraph(Self.document(row), in: db)
            } else {
                try db.execute(
                    sql: "UPDATE graph_jobs SET state = CASE WHEN completed >= total AND total > 0 THEN 'curating' ELSE 'queued' END, token = ?, error = NULL WHERE noteID = ? AND state IN ('paused','failed','unavailable')",
                    arguments: [UUID().uuidString, noteID.uuidString]
                )
            }
        }
    }

    func failGraph(_ job: GraphJob, message: String, unavailable: Bool = false) throws {
        try readyDatabase().write { db in
            try db.execute(
                sql: "UPDATE graph_jobs SET state = ?, error = ? WHERE noteID = ? AND token = ? AND state IN ('running','curating')",
                arguments: [
                    unavailable ? "unavailable" : "failed",
                    message,
                    job.noteID.uuidString,
                    job.token.uuidString,
                ]
            )
        }
    }

    func nextGraphWork() throws -> GraphWork? {
        try readyDatabase().write { db in
            while let row = try Row.fetchOne(db, sql: """
            SELECT graph_jobs.*, notes.name FROM graph_jobs JOIN notes ON notes.id = graph_jobs.noteID
            WHERE graph_jobs.state = 'queued' AND notes.deletedAt IS NULL ORDER BY notes.createdAt LIMIT 1
            """) {
                let job = try Self.graphJob(row)
                var data: Data? = row["chunks"]
                if data == nil {
                    let plan = try Self.prepareGraph(job, in: db)
                    data = try JSONEncoder().encode(plan)
                    try db.execute(
                        sql: "UPDATE graph_jobs SET chunks = ?, total = ?, state = ? WHERE noteID = ?",
                        arguments: [
                            data,
                            plan.extractionChunks.count,
                            plan.extractionChunks.isEmpty ? "ready" : "queued",
                            job.noteID.uuidString,
                        ]
                    )
                    if plan.extractionChunks.isEmpty {
                        continue
                    }
                }
                guard let data else { throw GleanaryError.invalidDatabase }
                let plan = try JSONDecoder().decode(GraphPlan.self, from: data)
                let chunks = plan.extractionChunks
                guard chunks.indices.contains(job.completed)
                else { throw GleanaryError.invalidDatabase }
                try db.execute(
                    sql: "UPDATE graph_jobs SET state = 'running' WHERE noteID = ?",
                    arguments: [job.noteID.uuidString]
                )
                let claimed = GraphJob(
                    noteID: job.noteID,
                    revision: job.revision,
                    token: job.token,
                    name: job.name,
                    state: "running",
                    completed: job.completed,
                    total: chunks.count,
                    error: nil
                )
                return GraphWork(job: claimed, chunk: chunks[job.completed])
            }
            return nil
        }
    }

    func publishGraph(_ work: GraphWork, claims: [GraphClaim]) throws {
        try publishGraph(work, claims: claims, curateWhenComplete: false)
    }

    func publishGraphCandidates(_ work: GraphWork, claims: [GraphClaim]) throws {
        try publishGraph(work, claims: claims, curateWhenComplete: true)
    }

    private func publishGraph(
        _ work: GraphWork,
        claims: [GraphClaim],
        curateWhenComplete: Bool
    ) throws {
        try readyDatabase().write { db in
            let job = work.job
            guard try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(SELECT 1 FROM graph_jobs JOIN notes ON notes.id = graph_jobs.noteID
                WHERE graph_jobs.noteID = ? AND graph_jobs.token = ? AND graph_jobs.state = 'running'
                    AND graph_jobs.completed = ? AND notes.revision = ? AND notes.deletedAt IS NULL)
                """,
                arguments: [
                    job.noteID.uuidString,
                    job.token.uuidString,
                    job.completed,
                    job.revision.uuidString,
                ]
            ) == true
            else { throw GraphError.stale }
            for claim in claims {
                try Self.insertGraphClaim(claim, job: job, chunk: job.completed, in: db)
            }
            var total = job.total
            var chunksData: Data? = try Data.fetchOne(
                db,
                sql: "SELECT chunks FROM graph_jobs WHERE noteID = ?",
                arguments: [job.noteID.uuidString]
            )
            if curateWhenComplete, job.completed == 0, let encodedPlan = chunksData,
               var plan = try? JSONDecoder().decode(GraphPlan.self, from: encodedPlan),
               !plan.selectionComplete
            {
                plan = Self.selectGraphPassages(
                    plan,
                    candidateNames: claims.filter { $0.predicate == .mentions }.map(\.target.label),
                    title: job.name
                )
                total = plan.extractionChunks.count
                chunksData = try JSONEncoder().encode(plan)
            }
            let done = job.completed + 1 == total
            let finalState = curateWhenComplete ? "curating" : "ready"
            try db.execute(sql: """
            UPDATE graph_jobs SET completed = completed + 1, total = ?, state = ?, error = NULL,
                chunks = CASE WHEN ? THEN NULL ELSE ? END WHERE noteID = ?
            """, arguments: [
                total,
                done ? finalState : "queued",
                done && !curateWhenComplete,
                chunksData,
                job.noteID.uuidString,
            ])
        }
    }

    func nextGraphCurationWork() throws -> GraphCurationWork? {
        try readyDatabase().read { db in
            guard let row = try Row.fetchOne(db, sql: """
            SELECT graph_jobs.*, notes.name FROM graph_jobs JOIN notes ON notes.id = graph_jobs.noteID
            WHERE graph_jobs.state = 'curating' AND notes.deletedAt IS NULL
            ORDER BY notes.createdAt LIMIT 1
            """) else { return nil }
            let job = try Self.graphJob(row)
            let candidateRows = try Row.fetchAll(db, sql: """
            SELECT target.id, target.kind, target.label,
                COUNT(DISTINCT graph_evidence.id) AS mentions,
                COUNT(DISTINCT graph_evidence.chunk) AS sections,
                MIN(graph_evidence.chunk) AS firstChunk
            FROM graph_evidence
            JOIN graph_edges ON graph_edges.id = graph_evidence.edgeID
            JOIN graph_nodes target ON target.id = graph_edges.target
            WHERE graph_evidence.noteID = ? AND graph_evidence.origin = 'model'
                AND graph_edges.predicate = 'mentions' AND target.kind != 'document'
            GROUP BY target.id
            ORDER BY CASE WHEN firstChunk <= 1 THEN 0 ELSE 1 END,
                sections DESC, mentions DESC, firstChunk, LENGTH(target.label) DESC
            LIMIT 30
            """, arguments: [job.noteID.uuidString])
            var candidates: [GraphCandidate] = []
            var candidateIDs = Set<String>()
            var segments: [GraphSegment] = []
            for candidate in candidateRows {
                guard let kind = GraphNode.Kind(rawValue: candidate["kind"]),
                      let extractedKind = ExtractedEntityKind(graphKind: kind),
                      let evidence = try Row.fetchOne(db, sql: """
                      SELECT quote, citation, offset FROM graph_evidence
                      JOIN graph_edges ON graph_edges.id = graph_evidence.edgeID
                      WHERE graph_evidence.noteID = ? AND graph_edges.target = ?
                          AND graph_evidence.origin = 'model'
                      ORDER BY graph_evidence.chunk, graph_evidence.offset LIMIT 1
                      """, arguments: [job.noteID.uuidString, candidate["id"] as String])
                else { continue }
                let citationData: Data? = evidence["citation"]
                let segment = try GraphSegment(
                    text: evidence["quote"],
                    citation: citationData.map {
                        try JSONDecoder().decode(SourceCitation.self, from: $0)
                    },
                    offset: evidence["offset"]
                )
                candidateIDs.insert(candidate["id"])
                candidates.append(GraphCandidate(
                    name: candidate["label"],
                    kind: extractedKind,
                    mentions: candidate["mentions"],
                    sections: candidate["sections"],
                    firstChunk: candidate["firstChunk"],
                    quote: segment.text
                ))
                segments.append(segment)
            }
            let relationRows: [Row] = if candidateIDs.isEmpty {
                []
            } else {
                try Row.fetchAll(db, sql: """
                SELECT source.id AS sourceID, source.label AS sourceLabel,
                    target.id AS targetID, target.label AS targetLabel,
                    graph_edges.predicate, graph_evidence.quote, graph_evidence.citation,
                    graph_evidence.offset
                FROM graph_evidence
                JOIN graph_edges ON graph_edges.id = graph_evidence.edgeID
                JOIN graph_nodes source ON source.id = graph_edges.source
                JOIN graph_nodes target ON target.id = graph_edges.target
                WHERE graph_evidence.noteID = ? AND graph_evidence.origin = 'model'
                    AND graph_edges.predicate != 'mentions'
                ORDER BY graph_evidence.chunk, graph_evidence.offset LIMIT 24
                """, arguments: [job.noteID.uuidString])
            }
            var relations: [GraphRelationCandidate] = []
            for relation in relationRows {
                let source: String = relation["sourceLabel"]
                let target: String = relation["targetLabel"]
                let edgePredicate: String = relation["predicate"]
                guard candidateIDs.contains(relation["sourceID"] as String),
                      candidateIDs.contains(relation["targetID"] as String),
                      let graphPredicate = GraphPredicate(rawValue: edgePredicate),
                      let predicate = ExtractedPredicate(graphPredicate: graphPredicate)
                else { continue }
                let citationData: Data? = relation["citation"]
                let segment = try GraphSegment(
                    text: relation["quote"],
                    citation: citationData.map {
                        try JSONDecoder().decode(SourceCitation.self, from: $0)
                    },
                    offset: relation["offset"]
                )
                relations.append(GraphRelationCandidate(
                    source: source,
                    target: target,
                    predicate: predicate,
                    quote: segment.text
                ))
                if !segments.contains(where: { $0.text == segment.text }) {
                    segments.append(segment)
                }
            }
            let chunkData: Data? = row["chunks"]
            let plan = try chunkData.map {
                try JSONDecoder().decode(GraphPlan.self, from: $0)
            }
            let sourceChunks = plan?.sourceChunks ?? []
            let mapEvidence = Self.mindMapEvidence(in: plan?.extractionChunks ?? [])
            let relationSegments = Self.relationEvidence(
                in: sourceChunks,
                candidateNames: candidates.map(\.name),
                excluding: []
            )
            let existingEvidence = Set(segments.map { GraphNode.normalize($0.text) })
            segments += relationSegments.filter {
                !existingEvidence.contains(GraphNode.normalize($0.text))
            }
            return GraphCurationWork(
                job: job,
                candidates: candidates,
                relations: relations,
                relationExcerpts: relationSegments.map(\.text),
                evidence: GraphChunk(segments: segments),
                sourceChunks: sourceChunks,
                mapEvidence: mapEvidence
            )
        }
    }

    static func relationEvidence(
        in chunks: [GraphChunk],
        candidateNames: [String],
        excluding excluded: Set<String>
    ) -> [GraphSegment] {
        var seen = excluded
        var result: [GraphSegment] = []
        for segment in chunks.flatMap(\.segments) {
            let ranges = candidateNames.compactMap { name in
                graphNameRange(name, in: segment.text)
            }.sorted { $0.lowerBound < $1.lowerBound }
            guard ranges.count >= 2 else { continue }
            for index in ranges.indices.dropLast() {
                for neighbor in ranges.index(after: index) ... min(
                    index + 3,
                    ranges.index(before: ranges.endIndex)
                ) {
                    let first = ranges[index]
                    let last = ranges[neighbor]
                    guard segment.text.distance(
                        from: first.lowerBound,
                        to: last.upperBound
                    ) <= 450 else { break }
                    let lower = segment.text.index(
                        first.lowerBound,
                        offsetBy: -100,
                        limitedBy: segment.text.startIndex
                    ) ?? segment.text.startIndex
                    var upper = segment.text.index(
                        last.upperBound,
                        offsetBy: 100,
                        limitedBy: segment.text.endIndex
                    ) ?? segment.text.endIndex
                    if segment.text.distance(from: lower, to: upper) > 600 {
                        upper = segment.text.index(lower, offsetBy: 600)
                    }
                    let text = String(segment.text[lower ..< upper])
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          seen.insert(GraphNode.normalize(text)).inserted else { continue }
                    result.append(GraphSegment(
                        text: text,
                        citation: segment.citation,
                        offset: segment.offset + lower.utf16Offset(in: segment.text)
                    ))
                    if result.count == 10 {
                        return result
                    }
                }
            }
        }
        return result
    }

    private static func graphNameRange(
        _ name: String,
        in text: String
    ) -> Range<String.Index>? {
        let words = GraphNode.normalize(name).split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?<![\\p{L}\\p{N}_])" +
            words.joined(separator: #"(?:\s|\p{Pd})+"#) + "(?![\\p{L}\\p{N}_])"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            )
        else { return nil }
        return Range(match.range, in: text)
    }

    func publishCuratedGraph(
        _ work: GraphCurationWork,
        claims: [GraphClaim],
        mindMap: [MindMapClaim] = []
    ) throws {
        try readyDatabase().write { db in
            let job = work.job
            guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM graph_jobs JOIN notes ON notes.id = graph_jobs.noteID
            WHERE graph_jobs.noteID = ? AND graph_jobs.token = ? AND graph_jobs.state = 'curating'
                AND notes.revision = ? AND notes.deletedAt IS NULL)
            """, arguments: [job.noteID.uuidString, job.token.uuidString,
                             job.revision.uuidString]) == true
            else { throw GraphError.stale }
            try db.execute(
                sql: "DELETE FROM graph_evidence WHERE noteID = ? AND origin = 'model'",
                arguments: [job.noteID.uuidString]
            )
            try Self.pruneGraph(in: db)
            for claim in claims {
                try Self.insertGraphClaim(claim, job: job, chunk: -2, in: db)
            }
            try db.execute(
                sql: "DELETE FROM mind_map_evidence WHERE noteID = ?; DELETE FROM mind_map_nodes WHERE noteID = ?; DELETE FROM mind_maps WHERE noteID = ?",
                arguments: [
                    job.noteID.uuidString,
                    job.noteID.uuidString,
                    job.noteID.uuidString,
                ]
            )
            var nodeIDs: [String: String] = [:]
            var depths: [String: Int] = [:]
            for (ordinal, node) in mindMap.enumerated() {
                let id = "map:" + ContentHash.of([
                    job.noteID.uuidString,
                    node.key,
                ].joined(separator: "\u{0}"))
                let parentID = node.parentKey.flatMap { nodeIDs[$0] }
                let depth = node.parentKey.flatMap { depths[$0] }.map { $0 + 1 } ?? 0
                guard node.parentKey == nil || parentID != nil else { continue }
                nodeIDs[node.key] = id
                depths[node.key] = depth
                try db.execute(sql: """
                INSERT INTO mind_map_nodes(
                    id, noteID, parentID, title, summary, role, ordinal, depth
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id,
                    job.noteID.uuidString,
                    parentID,
                    node.title,
                    node.summary,
                    node.role.rawValue,
                    ordinal,
                    depth,
                ])
                let evidenceID = ContentHash.of([
                    id,
                    node.evidence.text,
                    String(node.evidence.offset),
                ].joined(separator: "\u{0}"))
                try db.execute(sql: """
                INSERT INTO mind_map_evidence(id, nodeID, noteID, quote, citation, offset)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    evidenceID,
                    id,
                    job.noteID.uuidString,
                    node.evidence.text,
                    node.evidence.citation.map { try JSONEncoder().encode($0) },
                    node.evidence.offset,
                ])
            }
            if let root = mindMap.first, let rootID = nodeIDs[root.key] {
                try db.execute(sql: """
                INSERT INTO mind_maps(noteID, revision, version, rootID, generatedAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    job.noteID.uuidString,
                    job.revision.uuidString,
                    GraphExtractor.curationVersion,
                    rootID,
                    Date().timeIntervalSince1970,
                ])
            }
            try db.execute(sql: """
            DELETE FROM mind_map_state WHERE noteID = ? AND nodeID NOT IN (
                SELECT id FROM mind_map_nodes WHERE noteID = ?
            );
            UPDATE graph_jobs SET state = 'ready', chunks = NULL, error = NULL WHERE noteID = ?
            """, arguments: [
                job.noteID.uuidString,
                job.noteID.uuidString,
                job.noteID.uuidString,
            ])
        }
    }

    static func insertGraphClaim(
        _ claim: GraphClaim,
        job: GraphJob,
        chunk: Int,
        in db: Database
    ) throws {
        let edge = claim.edge
        for node in [claim.source, claim.target] {
            try db.execute(
                sql: "INSERT OR IGNORE INTO graph_nodes(id, kind, label, noteID) VALUES (?, ?, ?, ?)",
                arguments: [node.id, node.kind.rawValue, node.label, node.noteID?.uuidString]
            )
        }
        try db.execute(
            sql: "INSERT OR IGNORE INTO graph_edges(id, source, target, predicate) VALUES (?, ?, ?, ?)",
            arguments: [edge.id, edge.source, edge.target, edge.predicate.rawValue]
        )
        let evidenceID = ContentHash
            .of([edge.id, job.noteID.uuidString, job.revision.uuidString, String(chunk),
                 String(claim.offset), claim.quote]
                    .joined(separator: "\u{0}"))
        try db.execute(sql: """
        INSERT OR IGNORE INTO graph_evidence(id, edgeID, noteID, revision, quote, citation, offset, origin, chunk)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            evidenceID,
            edge.id,
            job.noteID.uuidString,
            job.revision.uuidString,
            claim.quote,
            claim.citation.map { try JSONEncoder().encode($0) },
            claim.offset,
            claim.origin,
            chunk,
        ])
    }
}
