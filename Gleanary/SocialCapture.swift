import Foundation

@MainActor enum SocialCapture {
    static func extractHTML(_ html: String, target: MediaTarget) async throws -> SocialSnapshot {
        let analysis = try HTMLExtractor.analyze(html, url: target.url)
        let json = try await LocalCaptureDOM(
            scripts: ["CaptureSocial"],
            arguments: ["sourceURL": target.url.absoluteString, "platform": target.site.rawValue]
        )
        .extract(analysis.sanitizedHTML)
        return try JSONDecoder().decode(SocialSnapshot.self, from: Data(json.utf8))
    }

    /// Screen order does not prove an X reply relationship.
    private nonisolated static func connectedPosts(
        _ posts: [SocialPost],
        root: SocialPost
    ) -> [SocialPost] {
        var ordered = [root]
        var included: Set<String> = [root.id]
        while true {
            let quotes = Set(ordered.compactMap(\.quoteID))
            let next = posts
                .filter {
                    !included
                        .contains($0.id) &&
                        (quotes.contains($0.id) || $0.parentID.map(included.contains) == true)
                }
            guard !next.isEmpty else { return ordered }
            for post in next where included.insert(post.id).inserted {
                ordered.append(post)
            }
        }
    }

    nonisolated static func document(
        _ snapshot: SocialSnapshot,
        target: MediaTarget
    ) throws -> CapturedDocument {
        guard let page = try MediaTarget.parse(snapshot.pageURL),
              page.identity == target.identity else { throw MediaError.wrongPage }
        guard snapshot.posts.count <= 300,
              target.site != .youtube else { throw CaptureError.noContent }
        let rootID = target.site == .reddit ? "t3_" + target.id : target.id
        var unique: [String: SocialPost] = [:]
        for post in snapshot.posts {
            guard let linked = try MediaTarget.parse(post.url), linked.site == target.site,
                  target.site == .reddit ? linked.id == target.id : linked.id == post.id,
                  post.text.utf8.count <= 250_000 else { throw CaptureError.noContent }
            if unique[post.id] == nil {
                unique[post.id] = post
            }
        }
        guard let root = unique[rootID] else { throw MediaError.browserRequired }
        let ordered = connectedPosts(snapshot.posts, root: root)
        let quoted = Set(ordered.compactMap(\.quoteID))
        let blocks = ordered.map { post in
            let section = (quoted.contains(post.id) ? "Quoted post" : post
                .id == rootID ? "Post" : "Reply") + (post.author.map { " · " + $0 } ?? "")
            let text = post.text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
                of: ">",
                with: "&gt;"
            )
            return ContentBlock(
                kind: quoted.contains(post.id) ? .quote : .paragraph,
                markdown: "### \(section.replacingOccurrences(of: "\n", with: " "))\n\n[Source](\(post.url.absoluteString))\(post.published.map { " · " + $0 } ?? "")\n\n\(text)",
                text: post.text,
                section: section,
                method: "social-dom-v1",
                sourceURL: post.url,
                author: post.author,
                externalID: post.id,
                parentID: post.parentID,
                quoteID: post.quoteID
            )
        }
        var warnings =
            [
                "Only loaded posts with identifiable source links were captured. Collapsed, deleted, virtualized, and unloaded content may be missing. Images and video are not interpreted.",
            ]
        if target
            .site ==
            .x
        {
            warnings
                .append(
                    "X replies without explicit parent references are omitted; screen order does not prove a thread relationship."
                )
        }
        if snapshot
            .truncated
        {
            warnings
                .append(
                    "Capture reached the 300-post or 50,000-character-per-post limit. This is a partial snapshot."
                )
        }
        let title = String(root.text.split(whereSeparator: \.isNewline).first?.prefix(160) ?? "")
        return CapturedDocument(
            title: title.isEmpty ? "\(target.site.rawValue) · \(target.id)" : title,
            authors: root.author.map { [$0] } ?? [],
            published: root.published,
            identifier: target.identity,
            sourceURL: target.url,
            coverage: .visibleThread,
            warnings: warnings,
            blocks: blocks
        )
    }
}
