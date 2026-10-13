import SwiftUI

/// Soft, desaturated category hues. Slots come from `AtlasHierarchy.hue(for:)`.
enum AtlasPalette {
    private static let hues: [Double] = [232, 350, 24, 44, 140, 210, 174, 262, 312]

    static func fill(_ slot: Int?, dark: Bool) -> Color {
        guard let slot else { return Color(white: dark ? 0.55 : 0.62) }
        let hue = hues[slot % hues.count] / 360
        return dark
            ? Color(hue: hue, saturation: 0.42, brightness: 0.78)
            : Color(hue: hue, saturation: 0.4, brightness: 0.95)
    }

    static func ink(_ slot: Int?, dark: Bool) -> Color {
        guard let slot else { return Color(white: dark ? 0.82 : 0.32) }
        let hue = hues[slot % hues.count] / 360
        return dark
            ? Color(hue: hue, saturation: 0.32, brightness: 0.96)
            : Color(hue: hue, saturation: 0.72, brightness: 0.42)
    }
}

/// Draws an `AtlasLayout` through a camera with semantic level of detail: regions gain labels,
/// counts and contents as their on-screen size grows, and items appear only once legible.
struct AtlasRenderer {
    let layout: AtlasLayout
    let camera: AtlasCamera
    /// The focused region and its ancestors; the header already names them.
    let focusPath: Set<Int>
    let selectedID: AtlasNodeID?
    let hoveredID: AtlasNodeID?
    let matchCounts: [Int]
    let dark: Bool
    let highContrast: Bool
    let keyboardFocused: Bool

    /// Item grids below this cell width are filled in batches without labels or strokes.
    private static let batchedItemWidth: CGFloat = 26

    private var searching: Bool {
        !matchCounts.isEmpty
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let viewport = CGRect(origin: .zero, size: size)
        var position = 1
        while position < layout.tiles.count {
            let tile = layout.tiles[position]
            let screen = camera.screen(tile.rect)
            guard screen.intersects(viewport), min(screen.width, screen.height) >= 1.5 else {
                position = tile.end
                continue
            }
            if tile.node.kind == .item {
                drawItem(tile, at: position, screen: screen, in: &context)
                position += 1
                continue
            }
            drawRegion(tile, at: position, screen: screen, in: &context)
            if tile.hasItemChildren {
                let cell = camera.screen(layout.tiles[position + 1].rect)
                if min(cell.width, cell.height) < KnowledgeAtlasModel.minimumItemSize {
                    position = tile.end
                    continue
                }
                if cell.width < Self.batchedItemWidth {
                    drawBatchedItems(of: position, viewport: viewport, in: &context)
                    position = tile.end
                    continue
                }
            }
            position += 1
        }
        drawEmphasis(in: &context, viewport: viewport)
    }

    // MARK: Regions

    private func drawRegion(
        _ tile: AtlasTile,
        at position: Int,
        screen: CGRect,
        in context: inout GraphicsContext
    ) {
        let radius = min(10, min(screen.width, screen.height) * 0.06)
        let shape = Path(roundedRect: screen, cornerRadius: radius, style: .continuous)
        let ink = AtlasPalette.ink(tile.node.hue, dark: dark)
        let dimmed = searching && matchCounts[position] == 0
        if tile.node.itemCount == 0, tile.childCount == 0 {
            context.stroke(
                shape, with: .color(ink.opacity(dimmed ? 0.15 : 0.4)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        } else {
            let base = tile.depth == 1 ? (dark ? 0.2 : 0.3) : (dark ? 0.16 : 0.22)
            context.fill(
                shape,
                with: .color(AtlasPalette.fill(tile.node.hue, dark: dark)
                    .opacity(dimmed ? base * 0.3 : base))
            )
            context.stroke(
                shape,
                with: .color(ink.opacity(highContrast ? 0.45 : 0.12)),
                lineWidth: highContrast ? 1 : 0.5
            )
        }
        if !focusPath.contains(position) {
            drawRegionLabel(tile, at: position, screen: screen, dimmed: dimmed, in: &context)
        }
    }

    private func drawRegionLabel(
        _ tile: AtlasTile,
        at position: Int,
        screen: CGRect,
        dimmed: Bool,
        in context: inout GraphicsContext
    ) {
        let content = camera.screen(tile.contentRect)
        let band = tile.childCount == 0 ? screen.height : content.minY - screen.minY
        let inset = min(14, max(4, screen.width * 0.045))
        let width = screen.width - inset * 2
        guard width >= 28, band >= 13 else { return }
        let ink = AtlasPalette.ink(tile.node.hue, dark: dark)
        var label = context
        label.clip(to: Path(screen))
        label.opacity = dimmed ? 0.45 : 1
        var y = screen.minY + min(inset, max(2, band * 0.12))
        let count = countText(tile, at: position)
        let name = tile.node.title

        if band >= 54, width >= 110 {
            if let code = tile.node.code {
                y += line(
                    code,
                    style: { $0.font(.title3.weight(.semibold)).foregroundStyle(ink) },
                    x: screen.minX + inset,
                    y: y,
                    width: width,
                    in: &label
                )
            }
            y += line(
                name,
                style: { $0.font(.headline).foregroundStyle(ink) },
                x: screen.minX + inset,
                y: y,
                width: width,
                in: &label
            )
            _ = line(
                count,
                style: { $0.font(.caption).foregroundStyle(.secondary) },
                x: screen.minX + inset,
                y: y + 1,
                width: width,
                in: &label
            )
        } else {
            let title = [tile.node.code, name].compactMap(\.self).joined(separator: " ")
            let font: Font = band >= 30 ? .callout.weight(.semibold) : .caption.weight(.semibold)
            y += line(
                title,
                style: { $0.font(font).foregroundStyle(ink) },
                x: screen.minX + inset,
                y: y,
                width: width,
                in: &label
            )
            if band >= 30 {
                _ = line(
                    count,
                    style: { $0.font(.caption2).foregroundStyle(.secondary) },
                    x: screen.minX + inset,
                    y: y,
                    width: width,
                    in: &label
                )
            }
        }
    }

    private func countText(_ tile: AtlasTile, at position: Int) -> String {
        let total = tile.node.itemCount
        guard total > 0 else { return "Empty" }
        let items = total == 1 ? "1 item" : "\(total.formatted()) items"
        guard searching else { return items }
        return "\(matchCounts[position].formatted()) of \(items) match"
    }

    /// Draws one line of styled text, truncated with an ellipsis, and returns its height.
    private func line(
        _ string: String,
        style: (Text) -> Text,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        in context: inout GraphicsContext
    ) -> CGFloat {
        let unbounded = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        var resolved = context.resolve(style(Text(string)))
        let size = resolved.measure(in: unbounded)
        if size.width > width {
            // Binary search for the longest prefix that fits with an ellipsis.
            let characters = Array(string)
            var low = 0
            var high = characters.count
            while low < high {
                let middle = (low + high + 1) / 2
                let candidate = context.resolve(style(Text(String(characters[..<middle]) + "…")))
                if candidate.measure(in: unbounded).width <= width {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            guard low > 0 else { return size.height }
            let prefix = String(characters[..<low]).trimmingCharacters(in: .whitespaces)
            resolved = context.resolve(style(Text(prefix + "…")))
        }
        context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
        return size.height
    }

    // MARK: Items

    private func itemOpacity(_ node: AtlasNode, at position: Int) -> Double {
        let base = dark ? 0.32 + node.recency * 0.4 : 0.42 + node.recency * 0.45
        let matched = !searching || matchCounts[position] > 0
        return matched ? base : base * 0.18
    }

    private func drawItem(
        _ tile: AtlasTile,
        at position: Int,
        screen: CGRect,
        in context: inout GraphicsContext
    ) {
        let node = tile.node
        let radius = min(6, min(screen.width, screen.height) * 0.16)
        let shape = Path(roundedRect: screen, cornerRadius: radius, style: .continuous)
        let fill = AtlasPalette.fill(node.hue, dark: dark)
        let ink = AtlasPalette.ink(node.hue, dark: dark)
        let opacity = itemOpacity(node, at: position)
        let source = node.item?.kind == "source"
        // Sources are solid; notes and generated artifacts are lighter with an outline, so type
        // reads without relying on colour.
        context.fill(shape, with: .color(fill.opacity(source ? opacity : opacity * 0.5)))
        if !source || highContrast {
            context.stroke(shape, with: .color(ink.opacity(0.35 * opacity + 0.1)), lineWidth: 1)
        }
        guard screen.width >= 60, screen.height >= 24, let item = node.item else { return }
        var label = context
        label.clip(to: Path(screen))
        if searching, matchCounts[position] == 0 {
            label.opacity = 0.4
        }
        let inset = min(10, max(5, screen.width * 0.06))
        let large = screen.width >= 200 && screen.height >= 80
        let width = screen.width - inset * 2
        // Symbols are drawn as text so they keep their own proportions and baseline.
        let glyph = screen.width >= 96 && screen.height >= 34
            ? label.resolve(Text(Image(systemName: Self.symbol(for: item.kind)))
                .font(large ? .callout : .caption).foregroundStyle(ink.opacity(0.8)))
            : nil
        let glyphWidth = glyph.map {
            $0.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width + 4
        } ?? 0
        var y = screen.minY + min(inset, screen.height * 0.18)
        y += line(
            node.title,
            style: {
                $0.font(large ? .callout.weight(.medium) : .caption.weight(.medium))
                    .foregroundStyle(.primary)
            },
            x: screen.minX + inset, y: y,
            width: width - glyphWidth, in: &label
        )
        if screen.height >= 42 {
            let detail = [item.kindLabel, item.host].compactMap(\.self).joined(separator: " · ")
            y += line(
                detail,
                style: { $0.font(.caption2).foregroundStyle(.secondary) },
                x: screen.minX + inset,
                y: y + 1,
                width: width,
                in: &label
            )
        }
        if large {
            _ = line(
                item.updatedAt.formatted(.dateTime.month(.abbreviated).day().year()),
                style: { $0.font(.caption2).foregroundStyle(.secondary) },
                x: screen.minX + inset, y: y + 1, width: width, in: &label
            )
        }
        if let glyph {
            label.draw(
                glyph,
                at: CGPoint(
                    x: screen.maxX - inset,
                    y: screen.minY + min(inset, screen.height * 0.18)
                ),
                anchor: .topTrailing
            )
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "source": "doc.text"
        case "summary", "comparison": "sparkles.rectangle.stack"
        default: "note.text"
        }
    }

    /// Fills small item tiles in a few opacity buckets instead of one path per item.
    private func drawBatchedItems(
        of parent: Int,
        viewport: CGRect,
        in context: inout GraphicsContext
    ) {
        let parentTile = layout.tiles[parent]
        let fill = AtlasPalette.fill(parentTile.node.hue, dark: dark)
        var buckets = Array(repeating: Path(), count: 5)
        var outlines = Path()
        for position in parent + 1 ..< parentTile.end {
            let tile = layout.tiles[position]
            let screen = camera.screen(tile.rect)
            guard screen.intersects(viewport) else { continue }
            let opacity = itemOpacity(tile.node, at: position)
            let source = tile.node.item?.kind == "source"
            let effective = source ? opacity : opacity * 0.5
            buckets[min(4, Int(effective * 5))].addRect(screen)
            if !source {
                outlines.addRect(screen.insetBy(dx: 0.5, dy: 0.5))
            }
        }
        for (level, path) in buckets.enumerated() where !path.isEmpty {
            context.fill(path, with: .color(fill.opacity((Double(level) + 0.5) / 5)))
        }
        if !outlines.isEmpty {
            context.stroke(
                outlines,
                with: .color(AtlasPalette.ink(parentTile.node.hue, dark: dark).opacity(0.2)),
                lineWidth: 0.5
            )
        }
    }

    // MARK: Hover, selection and focus

    private func drawEmphasis(in context: inout GraphicsContext, viewport: CGRect) {
        if let hoveredID, hoveredID != selectedID, let tile = layout.tile(hoveredID) {
            let screen = camera.screen(tile.rect)
            let radius = min(10, min(screen.width, screen.height) * 0.08)
            context.stroke(
                Path(roundedRect: screen, cornerRadius: radius, style: .continuous),
                with: .color(AtlasPalette.ink(tile.node.hue, dark: dark).opacity(0.55)),
                lineWidth: 1
            )
        }
        if let selectedID, let tile = layout.tile(selectedID) {
            let screen = camera.screen(tile.rect).insetBy(dx: -1, dy: -1)
            let radius = min(10, min(screen.width, screen.height) * 0.08)
            context.stroke(
                Path(roundedRect: screen, cornerRadius: radius, style: .continuous),
                with: .color(.accentColor),
                lineWidth: keyboardFocused ? 2.5 : 2
            )
        } else if keyboardFocused {
            context.stroke(
                Path(roundedRect: viewport.insetBy(dx: 1, dy: 1), cornerRadius: 8),
                with: .color(.accentColor.opacity(0.6)),
                lineWidth: 2
            )
        }
    }
}
