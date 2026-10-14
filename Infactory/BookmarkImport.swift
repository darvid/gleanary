import Foundation
import SwiftSoup

/// One saved link from a bookmark export. Imports keep only what the export says about the page;
/// the page itself is fetched later, when someone opens it.
struct ImportedBookmark: Sendable, Equatable {
    var url: URL
    var title: String
    /// Folder names from the root down; empty for unsorted bookmarks.
    var folder: [String] = []
    var tags: [String] = []
    var excerpt: String?
    var note: String?
    var highlights: [String] = []
    var created: Date?

    var folderPath: String {
        folder.joined(separator: " / ")
    }

    /// Readable Markdown made only from export metadata, never from fetched page content.
    var markdown: String {
        var parts = ["[\(Self.escaped(title))](\(url.absoluteString))"]
        if let excerpt = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty
        {
            parts.append(Self.quoted(excerpt))
        }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            parts.append("**Note:** " + note)
        }
        if !highlights.isEmpty {
            parts.append("## Highlights")
            parts.append(contentsOf: highlights.map(Self.quoted))
        }
        var provenance: [String] = []
        if !folder.isEmpty {
            provenance.append("Folder: " + folderPath)
        }
        if !tags.isEmpty {
            provenance.append("Tags: " + tags.joined(separator: ", "))
        }
        if let created {
            provenance.append("Bookmarked " + created.formatted(date: .abbreviated, time: .omitted))
        }
        if !provenance.isEmpty {
            parts.append(provenance.joined(separator: " · "))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
    }
}

enum BookmarkFormat: String, Sendable {
    /// Raindrop's CSV, and any CSV with a `url` column (Pocket, Instapaper, spreadsheets).
    case csv
    /// The Netscape bookmark file every browser and most bookmark managers export.
    case netscapeHTML

    var label: String {
        switch self {
        case .csv: "CSV bookmarks"
        case .netscapeHTML: "Browser bookmarks (HTML)"
        }
    }
}

struct BookmarkFile: Sendable {
    let format: BookmarkFormat
    let bookmarks: [ImportedBookmark]
    /// Rows without a usable web address: extension pages, `javascript:` links, blank URLs.
    let skipped: Int
}

enum BookmarkImportError: LocalizedError {
    case unrecognized, empty, busy

    var errorDescription: String? {
        switch self {
        case .unrecognized:
            "This file isn't a bookmark export Infactory can read. Export bookmarks as HTML from your browser, or as CSV or HTML from Raindrop."
        case .empty:
            "No web bookmarks were found in this file."
        case .busy:
            "The library is finishing another change. Try the import again in a moment."
        }
    }
}

enum BookmarkParser {
    static let maximumBytes = 200_000_000

    static func parse(_ data: Data) throws -> BookmarkFile {
        guard data.count <= maximumBytes else { throw CaptureError.tooLarge }
        let text = String(decoding: data, as: UTF8.self)
        let head = text.prefix(2048).lowercased()
        let file: BookmarkFile = if head.contains("<!doctype netscape-bookmark-file")
            || head.contains("<dl") && head.contains("<dt")
        {
            try netscape(text)
        } else {
            try csv(text)
        }
        guard !file.bookmarks.isEmpty else { throw BookmarkImportError.empty }
        return file
    }

    // MARK: CSV

    static func csv(_ text: String) throws -> BookmarkFile {
        var rows = CSVReader.rows(text)
        guard !rows.isEmpty else { throw BookmarkImportError.unrecognized }
        let header = rows.removeFirst().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func column(_ names: String...) -> Int? {
            names.lazy.compactMap { header.firstIndex(of: $0) }.first
        }
        guard let urlColumn = column("url", "href", "link", "address") else {
            throw BookmarkImportError.unrecognized
        }
        let titleColumn = column("title", "name")
        let folderColumn = column("folder", "collection", "folders")
        let tagsColumn = column("tags", "tag", "labels")
        let excerptColumn = column("excerpt", "description", "summary")
        let noteColumn = column("note", "notes", "comment")
        let highlightsColumn = column("highlights")
        let createdColumn = column("created", "time_added", "created_at", "date_added", "date")
        var bookmarks: [ImportedBookmark] = []
        var skipped = 0
        for row in rows where !(row.count == 1 && row[0].isEmpty) {
            func value(_ index: Int?) -> String? {
                guard let index, row.indices.contains(index) else { return nil }
                let text = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            guard let url = value(urlColumn).flatMap(webURL) else { skipped += 1; continue }
            let folder = value(folderColumn).map(folderPath) ?? []
            bookmarks.append(ImportedBookmark(
                url: url,
                title: value(titleColumn) ?? url.host() ?? url.absoluteString,
                folder: folder,
                tags: value(tagsColumn).map { tags($0, separators: ",|") } ?? [],
                excerpt: value(excerptColumn),
                note: value(noteColumn),
                highlights: value(highlightsColumn).map(highlights) ?? [],
                created: value(createdColumn).flatMap(date)
            ))
        }
        return BookmarkFile(format: .csv, bookmarks: bookmarks, skipped: skipped)
    }

    /// Raindrop writes nested folders as `Parent / Child`; "Unsorted" means no folder.
    private static func folderPath(_ text: String) -> [String] {
        let parts = text.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts == ["Unsorted"] ? [] : parts
    }

    private static func tags(_ text: String, separators: String) -> [String] {
        var seen = Set<String>()
        return text.split { separators.contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Raindrop prefixes each highlight with `Highlight:` and attaches `Note:` lines to it.
    private static func highlights(_ text: String) -> [String] {
        text.components(separatedBy: "Highlight:")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Netscape HTML

    static func netscape(_ html: String) throws -> BookmarkFile {
        let document = try SwiftSoup.parse(html)
        var bookmarks: [ImportedBookmark] = []
        var skipped = 0
        // Folders are an H3 followed by a DL; walk anchors and climb to collect folder names.
        for anchor in try document.select("a[href]") {
            guard let url = try webURL(anchor.attr("href")) else { skipped += 1; continue }
            var folder: [String] = []
            var node = anchor.parent()
            while let current = node {
                if current.tagName() == "dl",
                   let heading = try current.previousElementSibling(),
                   heading.tagName() == "h3"
                {
                    try folder.insert(heading.text(), at: 0)
                }
                node = current.parent()
            }
            // Browsers wrap everything in a "Bookmarks bar"/"Bookmarks Menu" style root.
            if let root = folder.first, root.lowercased().contains("bookmark") {
                folder.removeFirst()
            }
            let description = try anchor.parent()?.nextElementSibling()
            let excerpt = try description?.tagName() == "dd" ? description?.text() : nil
            let title = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
            try bookmarks.append(ImportedBookmark(
                url: url,
                title: title.isEmpty ? url.host() ?? url.absoluteString : title,
                folder: folder == ["Unsorted"] ? [] : folder,
                tags: tags(anchor.attr("tags"), separators: ","),
                excerpt: excerpt.flatMap { $0.isEmpty ? nil : $0 },
                created: TimeInterval(anchor.attr("add_date"))
                    .map { Date(timeIntervalSince1970: $0) }
            ))
        }
        return BookmarkFile(format: .netscapeHTML, bookmarks: bookmarks, skipped: skipped)
    }

    // MARK: Values

    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil else { return nil }
        return url
    }

    private static func date(_ text: String) -> Date? {
        if let seconds = TimeInterval(text) {
            // Some exporters write milliseconds.
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// RFC 4180 CSV: quoted fields may hold commas, doubled quotes, and line breaks.
enum CSVReader {
    static func rows(_ text: String) -> [[String]] {
        var parser = Parser()
        var scalars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        while let scalar = pending ?? scalars.next() {
            pending = nil
            if parser.quoted {
                pending = parser.quotedScalar(scalar) { scalars.next() }
            } else {
                parser.plainScalar(scalar)
            }
        }
        return parser.finish()
    }

    private struct Parser {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false

        /// Returns a scalar read ahead that the caller must handle next.
        mutating func quotedScalar(
            _ scalar: Unicode.Scalar,
            next: () -> Unicode.Scalar?
        ) -> Unicode.Scalar? {
            guard scalar == "\"" else {
                field.unicodeScalars.append(scalar)
                return nil
            }
            let following = next()
            if following == "\"" {
                field.unicodeScalars.append("\"")
                return nil
            }
            quoted = false
            return following
        }

        mutating func plainScalar(_ scalar: Unicode.Scalar) {
            switch scalar {
            case "\"" where field.isEmpty:
                quoted = true
            case ",":
                row.append(field); field = ""
            case "\r":
                break
            case "\n":
                row.append(field); field = ""
                rows.append(row); row = []
            default:
                field.unicodeScalars.append(scalar)
            }
        }

        mutating func finish() -> [[String]] {
            if !field.isEmpty || !row.isEmpty {
                row.append(field)
                rows.append(row)
            }
            return rows
        }
    }
}

/// Where each export folder lands. Nothing here touches the database; the sheet edits it and the
/// store applies it in the same transaction as the import.
struct BookmarkFolderPlan: Sendable, Equatable {
    enum Destination: Hashable, Sendable {
        /// Left for auto-categorization.
        case unfiled
        case existing(UUID)
        /// A category the import creates, keyed by its proposed code.
        case new(code: String, name: String)
    }

    struct Folder: Identifiable, Sendable, Equatable {
        let path: [String]
        let count: Int
        var destination: Destination
        var id: String {
            path.joined(separator: " / ")
        }

        var depth: Int {
            path.count - 1
        }
    }

    var folders: [Folder]
    let unsorted: Int

    /// Folders get matching existing categories first. Remaining top-level folders take free tens
    /// blocks by size, as an area (`X0`) with their subfolders as `X1`–`X9`; deeper folders join
    /// their nearest placed parent. What doesn't fit stays unfiled for auto-categorization.
    init(bookmarks: [ImportedBookmark], existing: [DecimalCategory]) {
        let counts = Self.subtreeCounts(bookmarks)
        unsorted = bookmarks.count { $0.folder.isEmpty }
        var destinations = Self.placements(counts: counts, existing: existing)
        Self.joinPlannedNames(&destinations, paths: Array(counts.keys))
        folders = counts.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { path in
            var destination = destinations[path]
            var ancestor = path
            while destination == nil, ancestor.count > 1 {
                ancestor.removeLast()
                destination = destinations[ancestor]
            }
            return Folder(
                path: path,
                count: counts[path] ?? 0,
                destination: destination ?? .unfiled
            )
        }
    }

    /// Bookmarks per folder, where a parent's total includes its subfolders.
    private static func subtreeCounts(_ bookmarks: [ImportedBookmark]) -> [[String]: Int] {
        var counts: [[String]: Int] = [:]
        for bookmark in bookmarks where !bookmark.folder.isEmpty {
            for depth in 1 ... bookmark.folder.count {
                counts[Array(bookmark.folder.prefix(depth)), default: 0] += 1
            }
        }
        return counts
    }

    /// Homes for top-level folders and their direct children, largest folders first.
    private static func placements(
        counts: [[String]: Int],
        existing: [DecimalCategory]
    ) -> [[String]: Destination] {
        let names = Dictionary(
            existing.map { (DecimalCategory.normalized($0.name), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        func match(_ name: String) -> Destination? {
            names[DecimalCategory.normalized(name)].map(Destination.existing)
        }
        var freeBlocks = (2 ... 9).filter { block in
            !existing.contains { $0.code.hasPrefix(String(block)) }
        }[...]
        var destinations: [[String]: Destination] = [:]
        let roots = counts.keys.filter { $0.count == 1 }
            .sorted { (counts[$0] ?? 0, $1[0]) > (counts[$1] ?? 0, $0[0]) }
        for root in roots {
            let children = counts.keys.filter { $0.count == 2 && $0[0] == root[0] }
                .sorted { (counts[$0] ?? 0, $1[1]) > (counts[$1] ?? 0, $0[1]) }
            var codes: ArraySlice<String> = []
            if let existing = match(root[0]) {
                destinations[root] = existing
            } else if let block = freeBlocks.popFirst() {
                destinations[root] = .new(code: "\(block)0", name: root[0])
                codes = (1 ... 9).map { "\(block)\($0)" }[...]
            }
            for child in children {
                if let existing = match(child[1]) {
                    destinations[child] = existing
                } else if let code = codes.popFirst() {
                    destinations[child] = .new(code: code, name: child[1])
                } else {
                    destinations[child] = destinations[root]
                }
            }
        }
        return destinations
    }

    /// A folder left without a home joins a category this plan creates under the same name,
    /// such as a top-level "Real Estate" and "Services / Real Estate".
    private static func joinPlannedNames(
        _ destinations: inout [[String]: Destination],
        paths: [[String]]
    ) {
        var planned: [String: Destination] = [:]
        for case let .new(code, name) in destinations.values {
            planned[DecimalCategory.normalized(name)] = .new(code: code, name: name)
        }
        for path in paths where destinations[path] == nil {
            if let match = path.last.flatMap({ planned[DecimalCategory.normalized($0)] }) {
                destinations[path] = match
            }
        }
    }

    /// The destination for one bookmark: its own folder's choice.
    func destination(for folder: [String]) -> Destination {
        guard !folder.isEmpty else { return .unfiled }
        return folders.first { $0.path == folder }?.destination ?? .unfiled
    }

    /// Distinct new categories the plan would create, in code order.
    var newCategories: [(code: String, name: String)] {
        var seen = Set<String>()
        return folders.compactMap {
            guard case let .new(code, name) = $0.destination, seen.insert(code).inserted
            else { return nil }
            return (code, name)
        }.sorted { $0.code < $1.code }
    }
}
