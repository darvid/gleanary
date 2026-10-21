import SwiftUI

/// Shape and fill distinguish sources from notes even without color or a visible title.
struct GraphDocumentMark {
    let isSource: Bool

    var label: String {
        isSource ? "Source" : "Note"
    }

    func path(in rect: CGRect) -> Path {
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
        guard isSource else { return Path() }
        let page = rect.insetBy(dx: rect.width * 0.1, dy: 0)
        let fold = page.width * 0.32
        return Path { path in
            path.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
            path.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
            path.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        }
    }

    func textLines(in rect: CGRect) -> Path {
        guard !isSource else { return Path() }
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
        background: Color = Color(nsColor: .windowBackgroundColor)
    ) {
        let shape = path(in: rect)
        if isSource {
            context.fill(shape, with: .color(background))
            context.fill(shape, with: .color(Color.primary.opacity(0.08)))
            context.stroke(shape, with: .color(.primary), lineWidth: increasedContrast ? 2 : 1.5)
            context.stroke(fold(in: rect), with: .color(.primary), lineWidth: 1)
        } else {
            context.fill(shape, with: .color(.primary))
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            GraphDocumentMark(isSource: isSource).draw(
                in: &context, rect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                increasedContrast: contrast == .increased
            )
        }
        .frame(width: 18, height: 18)
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 16) {
            entry(isSource: false, title: "Notes")
            entry(isSource: true, title: "Sources")
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Notes are filled pages with text lines. Sources are outlined pages with a folded corner."
        )
    }

    private func entry(isSource: Bool, title: String) -> some View {
        HStack(spacing: 6) {
            Canvas { context, size in
                GraphDocumentMark(isSource: isSource).draw(
                    in: &context, rect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                    increasedContrast: contrast == .increased
                )
            }.frame(width: 16, height: 16).accessibilityHidden(true)
            Text(title)
        }
    }
}
