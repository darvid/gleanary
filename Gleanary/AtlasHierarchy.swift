import Foundation

/// One saved Library item as the Atlas sees it: display metadata plus filing memberships.
struct AtlasItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    /// The Library kind (`source`, `summary`, `comparison` or `note`).
    let kind: String
    let host: String?
    let updatedAt: Date
    /// Filing memberships, primary first, then by code.
    var categoryIDs: [UUID] = []
    /// A page screenshot or video thumbnail exists, loaded only once its tile is large enough.
    var hasPreview = false

    var kindLabel: String {
        DocumentSummary.kindLabel(for: kind)
    }
}

struct AtlasSnapshot: Sendable, Equatable {
    var categories: [DecimalCategory]
    var items: [AtlasItem]
}

enum AtlasNodeID: Hashable, Sendable {
    case library
    case category(UUID)
    /// A code prefix with descendants but no category row of its own (for example "50" when only
    /// "50.01" exists).
    case group(String)
    /// Items filed directly on a category that also has subcategories.
    case direct(UUID)
    case uncategorized
    case item(UUID)
}

struct AtlasNode: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case library, category, group, direct, uncategorized, item
    }

    let id: AtlasNodeID
    let kind: Kind
    let code: String?
    let title: String
    var children: [AtlasNode] = []
    /// Unique items placed in this subtree. Each item is counted once, in its primary home.
    var itemCount = 0
    /// Items whose secondary memberships point here. Informational only; never summed upward.
    var alsoFiledCount = 0
    var lastActivity: Date?
    /// Palette slot inherited from the top-level region; nil for neutral (uncategorized) regions.
    var hue: Int?
    var item: AtlasItem?
    /// 0 (oldest) to 1 (most recently updated), ranked across the whole projection.
    var recency = 0.0

    var label: String {
        [code, title].compactMap(\.self).joined(separator: " ")
    }
}

/// Projects flat Johnny Decimal categories and many-to-many item memberships into a display tree.
///
/// Counting strategy: an item is placed once, in its primary filing home (or, without one, its
/// lowest-coded membership). Aggregates sum placed items only, so totals never double-count an
/// item filed in several places. Secondary memberships are reported as `alsoFiledCount` on the
/// categories they point to.
enum AtlasHierarchy {
    static let paletteSize = 9

    static func project(_ snapshot: AtlasSnapshot) -> AtlasNode {
        let categories = Dictionary(
            snapshot.categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let byCode = Dictionary(
            snapshot.categories.map { ($0.code, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranks = recencyRanks(snapshot.items)
        var placed: [UUID: [AtlasItem]] = [:]
        var alsoFiled: [UUID: Int] = [:]
        var uncategorized: [AtlasItem] = []
        for item in snapshot.items {
            let homes = item.categoryIDs.filter { categories[$0] != nil }
            guard let home = homes.first else { uncategorized.append(item); continue }
            placed[home, default: []].append(item)
            for secondary in Set(homes.dropFirst()) {
                alsoFiled[secondary, default: 0] += 1
            }
        }

        // Every code's parent is its nearest existing (or synthesized) dotted prefix.
        var childCodes: [String: Set<String>] = [:]
        var topCodes = Set<String>()
        for code in byCode.keys {
            var current = code
            while let parent = parentCode(of: current) {
                childCodes[parent, default: []].insert(current)
                current = parent
            }
            topCodes.insert(current)
        }

        func itemNode(_ item: AtlasItem, hue: Int?) -> AtlasNode {
            AtlasNode(
                id: .item(item.id), kind: .item, code: nil,
                title: item.title.isEmpty ? "Untitled" : item.title,
                itemCount: 1, lastActivity: item.updatedAt, hue: hue, item: item,
                recency: ranks[item.id] ?? 0
            )
        }

        func itemNodes(_ items: [AtlasItem], hue: Int?) -> [AtlasNode] {
            items.sorted(by: newestFirst).map { itemNode($0, hue: hue) }
        }

        func node(for code: String, hue: Int) -> AtlasNode {
            let subcodes = (childCodes[code] ?? []).sorted(by: codeOrder)
            var children = subcodes.map { node(for: $0, hue: hue) }
            var result: AtlasNode
            if let category = byCode[code] {
                let items = placed[category.id] ?? []
                if !children.isEmpty, !items.isEmpty {
                    let direct = AtlasNode(
                        id: .direct(category.id), kind: .direct, code: nil,
                        // Not drawn as a box; the title is for VoiceOver and the header.
                        title: "\(category.name), not in a subcategory",
                        children: itemNodes(items, hue: hue), hue: hue
                    )
                    children.insert(aggregate(direct), at: 0)
                } else if children.isEmpty {
                    children = itemNodes(items, hue: hue)
                }
                result = AtlasNode(
                    id: .category(category.id), kind: .category, code: code,
                    title: category.name, children: children, hue: hue
                )
                result.alsoFiledCount = alsoFiled[category.id] ?? 0
            } else {
                result = AtlasNode(
                    id: .group(code), kind: .group, code: code, title: "Unnamed group",
                    children: children, hue: hue
                )
            }
            return aggregate(result)
        }

        var regions = topCodes.sorted(by: codeOrder).map { node(for: $0, hue: hue(for: $0)) }
        if !uncategorized.isEmpty {
            regions.append(aggregate(AtlasNode(
                id: .uncategorized, kind: .uncategorized, code: nil, title: "Uncategorized",
                children: itemNodes(uncategorized, hue: nil)
            )))
        }
        return aggregate(AtlasNode(
            id: .library, kind: .library, code: nil, title: "Library", children: regions
        ))
    }

    /// The tree without categories that hold no items in their subtree. Hues and counts are
    /// unchanged, so the remaining regions keep their colors.
    static func withoutEmptyCategories(_ node: AtlasNode) -> AtlasNode {
        var node = node
        node.children = node.children
            .filter { $0.kind == .item || $0.itemCount > 0 }
            .map(withoutEmptyCategories)
        return node
    }

    /// Categories and unnamed groups with nothing placed in their subtree.
    static func emptyCategoryCount(_ node: AtlasNode) -> Int {
        node.children.reduce(0) { total, child in
            total + emptyCategoryCount(child)
                + ([.category, .group].contains(child.kind) && child.itemCount == 0 ? 1 : 0)
        }
    }

    /// Categories with nothing placed in their subtree, so other views can mark what the map
    /// hides.
    static func emptyCategoryIDs(_ node: AtlasNode) -> Set<UUID> {
        node.children.reduce(into: Set<UUID>()) { ids, child in
            ids.formUnion(emptyCategoryIDs(child))
            if case let .category(id) = child.id, child.itemCount == 0 {
                ids.insert(id)
            }
        }
    }

    /// Stable per-code palette slot. Consecutive codes (11, 12, 13) and decades (10, 20, 30)
    /// both land on distinct slots because the palette size is coprime with ten.
    static func hue(for code: String) -> Int {
        (Int(code.prefix(2)) ?? 0) % paletteSize
    }

    static func parentCode(of code: String) -> String? {
        guard let dot = code.lastIndex(of: ".") else { return nil }
        return String(code[..<dot])
    }

    private static func aggregate(_ node: AtlasNode) -> AtlasNode {
        var node = node
        guard node.kind != .item else { return node }
        node.itemCount = node.children.reduce(0) { $0 + $1.itemCount }
        node.lastActivity = node.children.compactMap(\.lastActivity).max()
        return node
    }

    private static func codeOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedAscending
    }

    private static func newestFirst(_ lhs: AtlasItem, _ rhs: AtlasItem) -> Bool {
        lhs.updatedAt == rhs.updatedAt
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.updatedAt > rhs.updatedAt
    }

    private static func recencyRanks(_ items: [AtlasItem]) -> [UUID: Double] {
        let ordered = items.sorted(by: newestFirst).reversed()
        let denominator = Double(max(1, items.count - 1))
        return Dictionary(
            ordered.enumerated().map { ($1.id, Double($0) / denominator) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
