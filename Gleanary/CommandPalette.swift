import SwiftUI

extension EnvironmentValues {
    /// True while the command palette is open, so other Escape handlers stand aside.
    @Entry var commandPaletteOpen = false
}

/// One row in the command palette.
struct PaletteItem: Identifiable {
    enum Section: Int, CaseIterable, Comparable {
        case recent, documents, categories, places, commands, ask

        var title: String {
            switch self {
            case .recent: "Recent"
            case .documents: "Documents"
            case .categories: "Categories"
            case .places: "Go to"
            case .commands: "Commands"
            case .ask: "Chat"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: String
    let section: Section
    let title: String
    var subtitle: String?
    var symbol: String
    var shortcut: KeyShortcut?
    /// A category label shown as a tinted chip, such as "20.03 AI agents & automation".
    var filing: String?
    var keywords = ""
    let run: () -> Void
    /// ⌘Return: open a document beside Chat.
    var runBeside: (() -> Void)?
}

/// Fuzzy matching for the palette: a run of letters beats scattered ones, and a match at the
/// start of a word beats one inside it.
enum PaletteMatcher {
    struct Match: Equatable {
        let score: Int
        /// Character offsets in the text that matched, for bolding.
        let indices: [Int]
    }

    static func match(_ text: String, query: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, indices: []) }
        let haystack = Array(text.lowercased())
        func wordStart(_ index: Int) -> Bool {
            index == 0 || !haystack[index - 1].isLetter && !haystack[index - 1].isNumber
        }
        // A contiguous run, preferring one at a word start.
        let squeezed = String(needle)
        let lowered = String(haystack)
        var best: Match?
        var search = lowered.startIndex
        while let range = lowered.range(of: squeezed, range: search ..< lowered.endIndex) {
            let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            let score = 1000 - start + (wordStart(start) ? 300 : 0)
                - (haystack.count - needle.count) / 4
            if best.map({ score > $0.score }) ?? true {
                best = Match(score: score, indices: Array(start ..< start + needle.count))
            }
            search = lowered.index(after: range.lowerBound)
        }
        if let best {
            return best
        }
        // Otherwise the letters in order, rewarding word starts and penalizing gaps.
        var indices: [Int] = []
        var score = 400
        var position = 0
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            if let last = indices.last {
                score -= (found - last - 1) * 4
            }
            if wordStart(found) {
                score += 25
            }
            indices.append(found)
            position = found + 1
        }
        return Match(score: score - (indices.first ?? 0), indices: indices)
    }

    /// The text with matched characters in bold.
    static func highlighted(_ text: String, indices: [Int]) -> AttributedString {
        var result = AttributedString()
        let hits = Set(indices)
        for (offset, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if hits.contains(offset) {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
        }
        return result
    }
}

/// ⇧⌘P by default: find a document, go anywhere, or run a command, from the keyboard.
struct CommandPaletteView: View {
    /// Commands, places and categories, filtered as you type.
    let items: [PaletteItem]
    let suggested: [String]
    let recent: () async -> [PaletteItem]
    let documents: (String) async -> [PaletteItem]
    /// Sends the query to Chat, or saves it when it's links; nil when there's no Chat.
    let ask: (String) -> PaletteItem?
    let close: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @State private var found: [PaletteItem] = []
    @State private var recentItems: [PaletteItem] = []
    /// The results' natural height, so a short list doesn't leave the panel half empty.
    @State private var listHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private struct Row: Identifiable {
        let item: PaletteItem
        let match: PaletteMatcher.Match
        var id: String {
            item.id
        }
    }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var groups: [(section: PaletteItem.Section, rows: [Row])] {
        let text = trimmed
        var rows: [Row] = []
        func matching(_ pool: [PaletteItem], _ term: String, limit: Int) -> [Row] {
            pool.compactMap { item -> Row? in
                if let title = PaletteMatcher.match(item.title, query: term) {
                    return Row(item: item, match: title)
                }
                // Keywords can find a row, but only its title is bolded.
                guard !item.keywords.isEmpty,
                      let other = PaletteMatcher.match(item.keywords, query: term)
                else { return nil }
                return Row(item: item, match: .init(score: other.score - 200, indices: []))
            }
            .sorted { $0.match.score > $1.match.score }
            .prefix(limit).map(\.self)
        }
        if text.isEmpty {
            rows = recentItems.map { Row(item: $0, match: .init(score: 0, indices: [])) }
            rows += suggested.compactMap { id in items.first { $0.id == id } }
                .map { Row(item: $0, match: .init(score: 0, indices: [])) }
        } else if text.hasPrefix(">") {
            let term = String(text.dropFirst())
            rows = matching(
                items.filter { [.commands, .places].contains($0.section) },
                term,
                limit: 40
            )
        } else if text.hasPrefix("#") {
            rows = matching(
                items.filter { $0.section == .categories },
                String(text.dropFirst()),
                limit: 40
            )
        } else if !PastedLinks.isOnlyLinks(text) {
            rows = found.map { item in
                Row(
                    item: item,
                    match: PaletteMatcher.match(item.title, query: text)
                        ?? .init(score: -1, indices: [])
                )
            }
            .sorted { $0.match.score > $1.match.score }
            for section in [PaletteItem.Section.categories, .places, .commands] {
                rows += matching(
                    items.filter { $0.section == section },
                    text,
                    limit: section == .commands ? 4 : 3
                )
            }
        }
        if !text.isEmpty, !text.hasPrefix(">"), !text.hasPrefix("#"), let ask = ask(text) {
            rows.append(Row(item: ask, match: .init(score: 0, indices: [])))
        }
        let ordered = Dictionary(grouping: rows) {
            text.isEmpty && $0.item.section != .recent ? .commands : $0.item.section
        }
        return ordered.keys.sorted().map { section in
            (section, ordered[section] ?? [])
        }
    }

    private var flat: [Row] {
        groups.flatMap(\.rows)
    }

    var body: some View {
        let rows = flat
        let selected = rows.indices.contains(selection) ? rows[selection].item : nil
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search documents, go anywhere, or run a command…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .accessibilityLabel("Search or run a command")
                    .accessibilityValue(rows.count == 1 ? "1 result" : "\(rows.count) results")
                    .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
                        handle(press, rows: rows)
                    }
                if let mode {
                    Text(mode).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: results are capped, and the list's real height sizes the panel.
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(groups, id: \.section) { group in
                            Text(group.section == .commands && trimmed.isEmpty ? "Suggested"
                                : group.section.title)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.rows) { row in
                                let index = rows.firstIndex { $0.id == row.id } ?? 0
                                rowView(row, selected: index == selection)
                                    .id(row.id)
                                    .onHover {
                                        if $0 {
                                            selection = index
                                        }
                                    }
                            }
                        }
                        if rows.isEmpty {
                            Text(trimmed.isEmpty ? "Loading…" : "No matches")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(24)
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        listHeight = $0
                    }
                }
                .frame(height: min(max(listHeight, 44), 400))
                .onChange(of: selection) {
                    if rows.indices.contains(selection) {
                        proxy.scrollTo(rows[selection].id)
                    }
                }
            }
            Divider()
            footer(selected)
        }
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(
                Color.primary.opacity(0.12),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.2), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .accessibilityAddTraits(.isModal)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .task { recentItems = await recent() }
        .task(id: trimmed) {
            let text = trimmed
            guard !text.isEmpty, !text.hasPrefix(">"), !text.hasPrefix("#"),
                  !PastedLinks.isOnlyLinks(text) else { found = []; return }
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            found = await documents(text)
        }
    }

    private var mode: String? {
        if trimmed.hasPrefix(">") {
            return "Commands"
        }
        if trimmed.hasPrefix("#") {
            return "Categories"
        }
        if !trimmed.isEmpty, PastedLinks.isOnlyLinks(trimmed) {
            return "Links"
        }
        return nil
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        let item = row.item
        return Button {
            run(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PaletteMatcher.highlighted(item.title, indices: row.match.indices))
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let filing = item.filing {
                    PaletteFilingChip(label: filing)
                }
                if let shortcut = item.shortcut {
                    Text(shortcut.display).font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(
                            Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .foregroundStyle(.secondary)
                }
                if selected {
                    Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.22) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([item.title, item.subtitle, item.filing].compactMap(\.self)
            .joined(separator: ", "))
        .accessibilityValue(item.shortcut?.spoken ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func footer(_ selected: PaletteItem?) -> some View {
        HStack(spacing: 14) {
            Text("↑↓ Move")
            Text(
                "↩ \(selected?.section == .documents || selected?.section == .recent ? "Open" : "Run")"
            )
            if selected?.runBeside != nil {
                Text("⌘↩ Open beside Chat")
            }
            Spacer()
            Text("esc Close")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    private func handle(_ press: KeyPress, rows: [Row]) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            if !rows.isEmpty {
                selection = (selection + 1) % rows.count
            }
        case .upArrow:
            if !rows.isEmpty {
                selection = (selection - 1 + rows.count) % rows.count
            }
        case .escape:
            close()
        case .return:
            guard rows.indices.contains(selection) else { return .handled }
            let item = rows[selection].item
            if press.modifiers.contains(.command), let beside = item.runBeside {
                close()
                beside()
            } else {
                run(item)
            }
        default:
            return .ignored
        }
        return .handled
    }

    private func run(_ item: PaletteItem) {
        close()
        item.run()
    }
}

/// A category label in its filing ink, as in Chat's saved-items card.
private struct PaletteFilingChip: View {
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let code = String(label.prefix { !$0.isWhitespace })
        let ink = AtlasPalette.ink(AtlasHierarchy.hue(for: code), dark: colorScheme == .dark)
        Text(label).font(.caption).lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(ink.opacity(0.14), in: Capsule())
    }
}
