import SwiftUI

/// The browsing column Library and Entities share beside their detail pane.
enum ListColumn {
    static let minWidth: CGFloat = 260
    static let idealWidth: CGFloat = 330
    static let maxWidth: CGFloat = 440
    /// Aligns the header, status lines and footers with each other.
    static let inset: CGFloat = 14
}

/// A resizable edge between columns, dragged like the sidebar's. `HSplitView` can't take its place:
/// its AppKit columns draw offset inside the content panel's rounded clip.
struct ColumnDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let ideal: CGFloat
    /// Which side of this divider the sized column is on.
    var column: HorizontalEdge = .leading
    @State private var dragStart: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear.frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? width
                                dragStart = start
                                let delta = value.translation.width
                                let next = start + (column == .leading ? delta : -delta)
                                width = min(max(next, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .onTapGesture(count: 2) { width = ideal }
                    .accessibilityHidden(true)
            }
            // Above the columns, so the handle's far half isn't covered.
            .zIndex(1)
    }
}

/// A resizable list beside its detail. The list gives way before the detail's minimum in a
/// narrow window.
struct ListDetailColumns<List: View, Detail: View>: View {
    var range: ClosedRange<CGFloat> = ListColumn.minWidth ... ListColumn.maxWidth
    var ideal: CGFloat = ListColumn.idealWidth
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail
    @State private var width: CGFloat?

    var body: some View {
        let current = width ?? ideal
        HStack(spacing: 0) {
            list.frame(
                minWidth: range.lowerBound,
                idealWidth: current,
                maxWidth: current,
                maxHeight: .infinity,
                alignment: .top
            )
            ColumnDivider(
                width: Binding(get: { current }, set: { width = $0 }),
                range: range,
                ideal: ideal
            )
            detail.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
