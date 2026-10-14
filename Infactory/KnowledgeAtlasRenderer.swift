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
    let selectedID: AtlasNodeID?
    let hoveredID: AtlasNodeID?
    let matchCounts: [Int]
    let dark: Bool
    let highContrast: Bool
    let keyboardFocused: Bool
    /// Device pixels per point, used to keep edges on the pixel grid.
    var displayScale: CGFloat = 2

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
            let screen = snapped(camera.screen(tile.rect))
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
                // Items fade in over a short size range while a count stands in for them.
                let shown = Self.itemReveal(cell)
                if shown < 1 {
                    drawHiddenItems(tile, at: position, opacity: 1 - shown, in: &context)
                }
                if shown == 0 {
                    position = tile.end
                    continue
                }
                if cell.width < Self.batchedItemWidth {
                    var faded = context
                    faded.opacity = shown
                    drawBatchedItems(of: position, viewport: viewport, in: &faded)
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
        // A category's own items sit beside its subcategories without a box of their own.
        guard tile.node.kind != .direct else { return }
        let shape = Path(
            roundedRect: screen,
            cornerRadius: Self.cornerRadius(tile, screen: screen),
            style: .continuous
        )
        let ink = AtlasPalette.ink(tile.node.hue, dark: dark)
        let dimmed = searching && matchCounts[position] == 0
        if tile.node.itemCount == 0, tile.childCount == 0 {
            context.stroke(
                border(tile, screen, width: 1, inside: true),
                with: .color(ink.opacity(dimmed ? 0.15 : 0.4)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        } else {
            let base = tile.depth == 1 ? (dark ? 0.2 : 0.3) : (dark ? 0.16 : 0.22)
            context.fill(
                shape,
                with: .color(AtlasPalette.fill(tile.node.hue, dark: dark)
                    .opacity(dimmed ? base * 0.3 : base))
            )
            let hairline = highContrast ? 1 : 1 / displayScale
            context.stroke(
                border(tile, screen, width: hairline, inside: true),
                with: .color(ink.opacity(highContrast ? 0.45 : 0.12)),
                lineWidth: hairline
            )
        }
        // Drawn even when the header names the region: the band is reserved for it either way.
        drawRegionLabel(tile, at: position, screen: screen, dimmed: dimmed, in: &context)
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
        let visible = Self.ramp(band, 13, 19) * Self.ramp(width, 28, 40)
        guard visible > 0 else { return }
        var label = context
        label.clip(to: Path(screen))
        label.opacity = (dimmed ? 0.45 : 1) * visible
        let origin = CGPoint(
            x: screen.minX + inset,
            y: screen.minY + min(inset, max(2, band * 0.12))
        )

        // Layouts switch at fixed sizes because overlapping text cannot crossfade cleanly;
        // only detail that appears in empty space fades in.
        // Each style needs its height plus clear space above the contents; switching later keeps
        // the title from crowding the first row.
        let style: RegionLabelStyle = if band >= 104, width >= 90, tile.node.code != nil {
            .hero
        } else if band >= 66, width >= 110 {
            .stacked
        } else {
            band >= 30 ? .compactWithCount : .compact
        }
        drawRegionLabel(
            style, tile: tile, at: position, origin: origin, width: width,
            countOpacity: Self.ramp(band, 30, 36), in: &label
        )
    }

    private enum RegionLabelStyle {
        /// The code set large above the name, for regions with room to spare.
        case hero
        case compact, compactWithCount, stacked
    }

    private func drawRegionLabel(
        _ style: RegionLabelStyle,
        tile: AtlasTile,
        at position: Int,
        origin: CGPoint,
        width: CGFloat,
        countOpacity: Double,
        in context: inout GraphicsContext
    ) {
        let ink = AtlasPalette.ink(tile.node.hue, dark: dark)
        let count = countText(tile, at: position)
        var y = origin.y
        switch style {
        case .hero:
            if let code = tile.node.code {
                y += line(
                    code,
                    style: {
                        $0.font(.system(size: 30, weight: .medium)).monospacedDigit()
                            .foregroundStyle(ink)
                    },
                    x: origin.x, y: y, width: width, in: &context
                )
            }
            y += line(
                tile.node.title,
                style: { $0.font(.system(size: 16, weight: .medium)).foregroundStyle(ink) },
                x: origin.x, y: y, width: width, in: &context
            )
            _ = line(
                count, style: { $0.font(.callout).foregroundStyle(.secondary) },
                x: origin.x, y: y + 3, width: width, in: &context
            )
        case .stacked:
            if let code = tile.node.code {
                y += line(
                    code,
                    style: {
                        $0.font(.system(size: 21, weight: .medium)).monospacedDigit()
                            .foregroundStyle(ink)
                    },
                    x: origin.x, y: y, width: width, in: &context
                )
            }
            y += line(
                tile.node.title, style: { $0.font(.headline).foregroundStyle(ink) },
                x: origin.x, y: y, width: width, in: &context
            )
            _ = line(
                count, style: { $0.font(.caption).foregroundStyle(.secondary) },
                x: origin.x, y: y + 1, width: width, in: &context
            )
        case .compact, .compactWithCount:
            let title = [tile.node.code, tile.node.title].compactMap(\.self).joined(separator: " ")
            let font: Font = style == .compact
                ? .caption.weight(.semibold) : .callout.weight(.semibold)
            y += line(
                title, style: { $0.font(font).foregroundStyle(ink) },
                x: origin.x, y: y, width: width, in: &context
            )
            if style == .compactWithCount {
                var layer = context
                layer.opacity *= countOpacity
                _ = line(
                    count, style: { $0.font(.caption2).foregroundStyle(.secondary) },
                    x: origin.x, y: y, width: width, in: &layer
                )
            }
        }
    }

    /// Stands in for item tiles too small to draw: a denser fill and, where it fits, the count.
    private func drawHiddenItems(
        _ tile: AtlasTile,
        at position: Int,
        opacity: Double,
        in context: inout GraphicsContext
    ) {
        let content = camera.screen(tile.contentRect)
        guard content.width >= 2, content.height >= 2 else { return }
        var layer = context
        layer.opacity = opacity * (searching && matchCounts[position] == 0 ? 0.3 : 1)
        let radius = min(6, min(content.width, content.height) * 0.12)
        layer.fill(
            Path(roundedRect: content, cornerRadius: radius, style: .continuous),
            with: .color(AtlasPalette.fill(tile.node.hue, dark: dark).opacity(dark ? 0.3 : 0.4))
        )
        let total = searching ? matchCounts[position] : tile.node.itemCount
        let text = layer.resolve(
            Text(total.formatted()).font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(AtlasPalette.ink(tile.node.hue, dark: dark))
        )
        let size = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        guard size.width + 8 <= content.width, size.height + 2 <= content.height else { return }
        layer.opacity *= Self.ramp(content.width - size.width, 8, 16)
        layer.draw(text, at: CGPoint(x: content.midX, y: content.midY), anchor: .center)
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
        let shape = Path(
            roundedRect: screen,
            cornerRadius: Self.cornerRadius(tile, screen: screen),
            style: .continuous
        )
        let fill = AtlasPalette.fill(node.hue, dark: dark)
        let ink = AtlasPalette.ink(node.hue, dark: dark)
        let opacity = itemOpacity(node, at: position)
        let source = node.item?.kind == "source"
        var tileLayer = context
        tileLayer.opacity = Self.itemReveal(screen)
        // Sources are solid; notes and generated artifacts are lighter with an outline, so type
        // reads without relying on colour.
        tileLayer.fill(shape, with: .color(fill.opacity(source ? opacity : opacity * 0.5)))
        if !source || highContrast {
            tileLayer.stroke(
                border(tile, screen, width: 1, inside: true),
                with: .color(ink.opacity(0.35 * opacity + 0.1)),
                lineWidth: 1
            )
        }
        let titled = Self.ramp(screen.width, 60, 72) * Self.ramp(screen.height, 24, 30)
        guard titled > 0, let item = node.item else { return }
        var label = context
        label.clip(to: Path(screen))
        label.opacity = titled * (searching && matchCounts[position] == 0 ? 0.4 : 1)
        drawItemLabel(
            item, title: node.title, ink: ink, screen: screen,
            large: screen.width >= 200 && screen.height >= 80, in: &label
        )
    }

    private func drawItemLabel(
        _ item: AtlasItem,
        title: String,
        ink: Color,
        screen: CGRect,
        large: Bool,
        in context: inout GraphicsContext
    ) {
        let inset = min(10, max(5, screen.width * 0.06))
        let width = screen.width - inset * 2
        let top = screen.minY + min(inset, screen.height * 0.18)
        // Symbols are drawn as text so they keep their own proportions and baseline.
        let glyphShown = Self.ramp(screen.width, 96, 108) * Self.ramp(screen.height, 34, 40)
        let glyph = glyphShown > 0
            ? context.resolve(Text(Image(systemName: Self.symbol(for: item.kind)))
                .font(large ? .callout : .caption).foregroundStyle(ink.opacity(0.8)))
            : nil
        let glyphWidth = glyph.map {
            $0.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width + 4
        } ?? 0
        var y = top
        y += line(
            title,
            style: {
                $0.font(large ? .callout.weight(.medium) : .caption.weight(.medium))
                    .foregroundStyle(.primary)
            },
            x: screen.minX + inset, y: y, width: width - glyphWidth, in: &context
        )
        let detailShown = Self.ramp(screen.height, 42, 50)
        if detailShown > 0 {
            var layer = context
            layer.opacity *= detailShown
            let detail = [item.kindLabel, item.host].compactMap(\.self).joined(separator: " · ")
            y += line(
                detail, style: { $0.font(.caption2).foregroundStyle(.secondary) },
                x: screen.minX + inset, y: y + 1, width: width, in: &layer
            )
        }
        if large {
            var layer = context
            layer.opacity *= Self.ramp(screen.height, 80, 92)
            _ = line(
                item.updatedAt.formatted(.dateTime.month(.abbreviated).day().year()),
                style: { $0.font(.caption2).foregroundStyle(.secondary) },
                x: screen.minX + inset, y: y + 1, width: width, in: &layer
            )
        }
        if let glyph {
            var layer = context
            layer.opacity *= glyphShown
            layer.draw(glyph, at: CGPoint(x: screen.maxX - inset, y: top), anchor: .topTrailing)
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

    // MARK: Level of detail

    /// 0 below `start`, 1 above `end`, eased in between, so detail fades rather than pops.
    static func ramp(_ value: CGFloat, _ start: CGFloat, _ end: CGFloat) -> Double {
        let t = Double(min(1, max(0, (value - start) / (end - start))))
        return t * t * (3 - 2 * t)
    }

    /// How visible item tiles of this on-screen size are; hit testing uses the same lower bound.
    static func itemReveal(_ screen: CGRect) -> Double {
        let side = min(screen.width, screen.height)
        return ramp(
            side,
            KnowledgeAtlasModel.minimumItemSize,
            KnowledgeAtlasModel.minimumItemSize * 2
        )
    }

    // MARK: Hover, selection and focus

    /// Rounds a view-space rectangle to whole device pixels so straight edges render as crisply
    /// as the curved corners instead of smearing across two pixel rows.
    private func snapped(_ rect: CGRect) -> CGRect {
        let scale = max(1, displayScale)
        func round(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        let minX = round(rect.minX)
        let minY = round(rect.minY)
        return CGRect(
            x: minX,
            y: minY,
            width: round(rect.maxX) - minX,
            height: round(rect.maxY) - minY
        )
    }

    /// A border drawn entirely inside or outside a tile. Centred strokes straddle the edge and
    /// leave a seam against the fill at the corners; offsetting the path by half the line width,
    /// and the radius by the same amount, keeps the border concentric with the tile.
    private func border(
        _ tile: AtlasTile,
        _ screen: CGRect,
        width: CGFloat,
        inside: Bool
    ) -> Path {
        let offset = inside ? width / 2 : -width / 2
        let radius = max(0, Self.cornerRadius(tile, screen: screen) - offset)
        return Path(
            roundedRect: screen.insetBy(dx: offset, dy: offset),
            cornerRadius: radius,
            style: .continuous
        )
    }

    /// One radius per tile, shared by its fill and every outline drawn around it.
    private static func cornerRadius(_ tile: AtlasTile, screen: CGRect) -> CGFloat {
        let side = min(screen.width, screen.height)
        return tile.node.kind == .item ? min(6, side * 0.16) : min(10, side * 0.06)
    }

    private func drawEmphasis(in context: inout GraphicsContext, viewport: CGRect) {
        if let hoveredID, hoveredID != selectedID, let tile = layout.tile(hoveredID) {
            let screen = snapped(camera.screen(tile.rect))
            context.stroke(
                border(tile, screen, width: 1, inside: true),
                with: .color(AtlasPalette.ink(tile.node.hue, dark: dark).opacity(0.55)),
                lineWidth: 1
            )
        }
        if let selectedID, let tile = layout.tile(selectedID) {
            // The tile's own ink, like hover, so the ring belongs to the region instead of
            // clashing with its hue. A small gap outside keeps it from reading as a border.
            let gap: CGFloat = 2
            let width: CGFloat = keyboardFocused ? 2.5 : 2
            let screen = snapped(camera.screen(tile.rect)).insetBy(dx: -gap, dy: -gap)
            context.stroke(
                border(tile, screen, width: width, inside: false),
                with: .color(AtlasPalette.ink(tile.node.hue, dark: dark)),
                lineWidth: width
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
