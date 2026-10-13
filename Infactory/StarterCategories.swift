import Foundation

/// A starter set of Johnny Decimal categories for one kind of work. Packs overlap through shared
/// keys, so choosing Product and Design creates a single "User research" category.
struct StarterPack: Identifiable, Sendable, Hashable {
    struct Entry: Sendable, Hashable {
        let key: String
        let name: String
    }

    let id: String
    let title: String
    let symbol: String
    /// The area name, written as its `X0` category. Nil packs extend the built-in 10–19 Inbox area.
    let area: String?
    let entries: [Entry]

    private init(
        _ id: String,
        _ title: String,
        _ symbol: String,
        area: String?,
        _ entries: [(String, String)]
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.area = area
        self.entries = entries.map { Entry(key: $0.0, name: $0.1) }
    }

    static let essentials = StarterPack("essentials", "Essentials", "tray", area: nil, [
        ("ideas", "Ideas"),
        ("reading-queue", "Reading queue"),
        ("books", "Books"),
        ("courses", "Courses & talks"),
        ("tools", "Tools & software"),
    ])

    static let all: [StarterPack] = [
        essentials,
        StarterPack(
            "engineering",
            "Software engineering",
            "chevron.left.forwardslash.chevron.right",
            area: "Engineering",
            [
                ("languages", "Languages & frameworks"),
                ("architecture", "Architecture"),
                ("infrastructure", "Infrastructure & ops"),
                ("incidents", "Debugging & incidents"),
                ("snippets", "Snippets & recipes"),
            ]
        ),
        StarterPack("writing", "Writing", "pencil.line", area: "Writing", [
            ("drafts", "Drafts"),
            ("published", "Published work"),
            ("craft", "Craft & technique"),
            ("research-notes", "Research notes"),
            ("pitches", "Pitches & markets"),
        ]),
        StarterPack("product", "Product management", "map", area: "Product", [
            ("strategy", "Strategy & roadmaps"),
            ("user-research", "User research"),
            ("specs", "Specs & PRDs"),
            ("metrics", "Metrics & analytics"),
            ("competitors", "Competitors"),
        ]),
        StarterPack("design", "Design", "paintpalette", area: "Design", [
            ("inspiration", "Inspiration"),
            ("user-research", "User research"),
            ("design-systems", "Design systems"),
            ("visual", "Typography & visual"),
        ]),
        StarterPack("research", "Research & academia", "graduationcap", area: "Research", [
            ("papers", "Papers"),
            ("methods", "Methods"),
            ("datasets", "Datasets"),
            ("grants", "Grants & funding"),
        ]),
        StarterPack("business", "Founder & business", "briefcase", area: "Business", [
            ("fundraising", "Fundraising"),
            ("hiring", "Hiring & team"),
            ("marketing", "Marketing & sales"),
            ("competitors", "Competitors"),
            ("legal", "Legal & compliance"),
        ]),
        StarterPack("personal", "Personal life", "house", area: "Personal", [
            ("health", "Health"),
            ("money", "Money"),
            ("home", "Home"),
            ("travel", "Travel"),
        ]),
    ]
}

/// The categories a set of packs would add to an existing scheme. Nothing existing is changed:
/// each new area takes the next empty tens block, and names already in use are skipped.
struct StarterPlan: Sendable, Equatable {
    struct Area: Sendable, Equatable, Identifiable {
        let packID: String
        let title: String
        var categories: [Category]
        var id: String {
            packID
        }
    }

    struct Category: Sendable, Equatable, Identifiable {
        /// The shared entry key, or `area:<pack>` for an area's `X0` category.
        let key: String
        let code: String
        let name: String
        var id: String {
            key
        }
    }

    var areas: [Area] = []
    /// Packs that did not fit because every tens block from 20 to 90 is in use.
    var unplaced: [StarterPack] = []

    var categories: [Category] {
        areas.flatMap(\.categories)
    }

    init(packs: [StarterPack], existing: [DecimalCategory]) {
        var usedCodes = Set(existing.map { String($0.code.prefix(2)) })
        var usedNames = Set(existing.map { DecimalCategory.normalized($0.name) })
        var usedKeys = Set<String>()
        var freeBlocks = (2 ... 9).filter { block in
            !existing.contains { $0.code.hasPrefix(String(block)) }
        }

        func take(_ entries: [StarterPack.Entry], codes: [String]) -> [Category] {
            var codes = codes.filter { !usedCodes.contains($0) }[...]
            var placed: [Category] = []
            for entry in entries {
                let name = DecimalCategory.normalized(entry.name)
                guard !usedKeys.contains(entry.key), !usedNames.contains(name),
                      let code = codes.popFirst() else { continue }
                usedKeys.insert(entry.key); usedNames.insert(name); usedCodes.insert(code)
                placed.append(Category(key: entry.key, code: code, name: entry.name))
            }
            return placed
        }

        // Essentials fill the Inbox area; other packs take tens blocks in the order they were
        // chosen.
        for pack in packs.filter({ $0.area == nil }) + packs.filter({ $0.area != nil }) {
            let placed: [Category]
            if let area = pack.area {
                guard let block = freeBlocks.first else { unplaced.append(pack); continue }
                freeBlocks.removeFirst()
                // X0 names the area even when the area name is skipped as a duplicate.
                let header = StarterPack.Entry(key: "area:\(pack.id)", name: area)
                placed = take([header], codes: ["\(block)0"])
                    + take(pack.entries, codes: (1 ... 9).map { "\(block)\($0)" })
            } else {
                placed = take(pack.entries, codes: (11 ... 19).map(String.init))
            }
            if !placed.isEmpty {
                areas.append(Area(
                    packID: pack.id,
                    title: pack.area ?? "Inbox & essentials",
                    categories: placed
                ))
            }
        }
    }
}
