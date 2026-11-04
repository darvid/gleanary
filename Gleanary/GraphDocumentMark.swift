import SwiftUI

/// Shape and fill distinguish sources from notes even without color or a visible title.
/// How the graph marks notes and sources. Every style fills notes and outlines sources.
enum GraphMarkStyle: String, CaseIterable, Identifiable {
    case pages, dots, shapes

    static let key = "appearance.graphMarks"
    /// Used until someone picks a style in Settings.
    static let standard = GraphMarkStyle.shapes

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .pages: "Pages"
        case .dots: "Dots"
        case .shapes: "Shapes"
        }
    }

    var detail: String {
        switch self {
        case .pages: "Notes are filled pages with text lines; sources are outlined pages with a folded corner."
        case .dots: "Notes are filled dots and sources are rings. People, organizations, tools and concepts are triangles."
        case .shapes: "Notes are filled circles and sources are outlined squares. People, organizations, tools and concepts are triangles."
        }
    }

    /// Beside dots and squares, entities draw as triangles so they don't read like the circles
    /// and rounded squares of concepts and people.
    static func triangle(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.08))
            path.closeSubpath()
        }
    }
}

struct GraphDocumentMark {
    let isSource: Bool
    var style = GraphMarkStyle.pages

    var label: String {
        isSource ? "Source" : "Note"
    }

    func path(in rect: CGRect) -> Path {
        switch style {
        case .pages: break
        case .dots: return Path(ellipseIn: rect.insetBy(
                dx: rect.width * 0.12,
                dy: rect.height * 0.12
            ))
        case .shapes:
            let inset = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
            return isSource ? Path(roundedRect: inset, cornerRadius: inset.width * 0.12)
                : Path(ellipseIn: inset)
        }
        let page = rect.insetBy(dx: rect.width * 0.1, dy: 0)
        guard isSource else {
            return Path(roundedRect: page, cornerRadius: rect.width * 0.08)
        }
        let fold = page.width * 0.32
        return Path { path in
            path.move(to: CGPoint(x: page.minX, y: page.minY))
            path.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
            path.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
            path.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
            path.addLine(to: CGPoint(x: page.minX, y: page.maxY))
            path.closeSubpath()
        }
    }

    func fold(in rect: CGRect) -> Path {
        guard isSource, style == .pages else { return Path() }
        let page = rect.insetBy(dx: rect.width * 0.1, dy: 0)
        let fold = page.width * 0.32
        return Path { path in
            path.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
            path.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
            path.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        }
    }

    func textLines(in rect: CGRect) -> Path {
        guard !isSource, style == .pages else { return Path() }
        return Path { path in
            for index in 0 ..< 3 {
                let y = rect.minY + rect.height * (0.34 + Double(index) * 0.18)
                path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: y))
                path.addLine(to: CGPoint(
                    x: rect.minX + rect.width * (index == 2 ? 0.58 : 0.72), y: y
                ))
            }
        }
    }

    func draw(
        in context: inout GraphicsContext, rect: CGRect, increasedContrast: Bool,
        background: Color = PanelSurface.color, ink: Color = .primary
    ) {
        let shape = path(in: rect)
        if isSource {
            context.fill(shape, with: .color(background))
            context.fill(shape, with: .color(ink.opacity(0.08)))
            context.stroke(shape, with: .color(ink), lineWidth: increasedContrast ? 2 : 1.5)
            context.stroke(fold(in: rect), with: .color(ink), lineWidth: 1)
        } else {
            context.fill(shape, with: .color(ink))
            context.stroke(
                textLines(in: rect),
                with: .color(background),
                style: StrokeStyle(lineWidth: max(1, rect.width * 0.065), lineCap: .round)
            )
        }
    }
}

/// The visible reading role, independent of a URL, thumbnail, or AI provider.
struct DocumentIdentity: Equatable {
    let isSource: Bool
    let subtype: String?

    init(kind: String, showsCapturedSource: Bool = false) {
        isSource = showsCapturedSource || kind == "source"
        if isSource {
            subtype = nil
        } else {
            let label = DocumentSummary.kindLabel(for: kind)
            switch kind {
            case "series-note": subtype = "Research"
            case "series-index": subtype = "Series"
            default: subtype = label == "Note" ? nil : label
            }
        }
    }

    var label: String {
        isSource ? "Source" : "Note"
    }

    var text: String {
        [label, subtype].compactMap(\.self).joined(separator: " ")
    }
}

struct DocumentIdentityMark: View {
    let isSource: Bool
    var ink: Color = .primary
    var size: CGFloat = 18
    /// For rows beside the graph, which match its canvas. Elsewhere marks stay pages: a Source's
    /// outlined square would read as a checkbox beside a title.
    var followsGraphStyle = false
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(GraphMarkStyle.key) private var style = GraphMarkStyle.standard

    var body: some View {
        Canvas { context, size in
            GraphDocumentMark(isSource: isSource, style: followsGraphStyle ? style : .pages).draw(
                in: &context, rect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                increasedContrast: contrast == .increased, ink: ink
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DocumentIdentityLabel: View {
    let identity: DocumentIdentity
    var showsMark = true

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if showsMark {
                    DocumentIdentityMark(isSource: identity.isSource)
                }
                Text(identity.label).fontWeight(.medium).foregroundStyle(.primary)
            }
            if let subtype = identity.subtype {
                Text(subtype).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.text)
    }
}

struct GraphDocumentLegend: View {
    var usesFilingColors = false
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(GraphMarkStyle.key) private var style = GraphMarkStyle.standard

    var body: some View {
        HStack(spacing: 16) {
            entry(isSource: false, title: "Notes")
            entry(isSource: true, title: "Sources")
            if style != .pages {
                HStack(spacing: 6) {
                    Canvas { context, size in
                        context.fill(
                            GraphMarkStyle.triangle(
                                in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                            ),
                            with: .color(.secondary)
                        )
                    }.frame(width: 16, height: 16).accessibilityHidden(true)
                    Text("Entities")
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            style.detail
                +
                (
                    usesFilingColors ? " Colors follow primary filing. Unfiled items are neutral." :
                        ""
                )
        )
    }

    private func entry(isSource: Bool, title: String) -> some View {
        HStack(spacing: 6) {
            Canvas { context, size in
                GraphDocumentMark(isSource: isSource, style: style).draw(
                    in: &context, rect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                    increasedContrast: contrast == .increased
                )
            }.frame(width: 16, height: 16).accessibilityHidden(true)
            Text(title)
        }
    }
}
