import SwiftUI

/// Resolved text is reused while panning; cache keys include layout and appearance inputs.
@MainActor final class GraphLabelCache {
    struct Entry {
        let text: GraphicsContext.ResolvedText
        let size: CGSize
    }

    private struct Key: Hashable {
        let label: String
        let selected: Bool
        let emphasized: Bool
        let width: Double
        let dark: Bool
        let increasedContrast: Bool
    }

    private var entries: [Key: Entry] = [:]

    func resolve(
        _ label: String, selected: Bool, emphasized: Bool, width: Double,
        dark: Bool, increasedContrast: Bool, context: GraphicsContext
    ) -> Entry {
        let key = Key(
            label: label,
            selected: selected,
            emphasized: emphasized,
            width: width,
            dark: dark,
            increasedContrast: increasedContrast
        )
        if let cached = entries[key] {
            return cached
        }
        let title = String(label.prefix(38)) + (label.count > 38 ? "…" : "")
        let text = context.resolve(Text(title).font(.system(
            size: selected ? 13 : 12, weight: emphasized ? .semibold : .regular
        )).foregroundStyle(.primary))
        let entry = Entry(text: text, size: text.measure(in: CGSize(width: width, height: 40)))
        if entries.count >= 512 {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = entry
        return entry
    }
}
