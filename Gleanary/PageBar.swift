import AppKit
import SwiftUI

/// The content panel's surface. Near-black in dark mode, a step above the window around it.
enum PanelSurface {
    static let color = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
            : NSColor.windowBackgroundColor
    })
}

/// What the sidebar sits on: flat near-black in dark mode, so the panel lifts off it; the
/// system's translucent sidebar in light mode.
struct WindowSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            Color(red: 0.055, green: 0.055, blue: 0.063)
        } else {
            SidebarMaterial()
        }
    }
}

/// The material a `.sidebar` list draws, across the whole window so sidebar and titlebar are one.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

extension EnvironmentValues {
    /// The window's More menu, which every page's bar ends with.
    @Entry var pageMenu: AnyView?
    /// Where Search goes on a page with nothing of its own to search.
    @Entry var openCommandPalette: (() -> Void)?
}

/// What a page's Search button narrows.
struct PageSearch {
    let prompt: String
    let label: String
    @Binding var query: String
    var focus: FocusState<Bool>.Binding
}

/// The row at the top of every page: its filters on the left and its own controls after them, then
/// Search and More. Those two end every page's bar, so they never change places.
struct PageBar<Leading: View, Accessory: View>: View {
    static var height: CGFloat {
        46
    }

    var search: PageSearch?
    @ViewBuilder var leading: Leading
    @ViewBuilder var accessory: Accessory
    @Environment(\.pageMenu) private var pageMenu

    var body: some View {
        HStack(spacing: 4) {
            leading
            Spacer(minLength: 12)
            accessory
            PageSearchControl(search: search)
            pageMenu
        }
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(height: Self.height)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension PageBar where Accessory == EmptyView {
    init(search: PageSearch? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(search: search, leading: leading, accessory: { EmptyView() })
    }
}

/// The field grows to the left, leaving the button where it was. It stays in the view while
/// collapsed because SwiftUI can't focus a field that isn't there, and ⌘F has to.
private struct PageSearchControl: View {
    let search: PageSearch?
    @Environment(\.openCommandPalette) private var openCommandPalette

    var body: some View {
        HStack(spacing: 2) {
            if let search {
                field(search)
            }
            Button("Search", systemImage: "magnifyingglass") {
                if let search {
                    search.focus.wrappedValue = true
                } else {
                    openCommandPalette?()
                }
            }
            .buttonStyle(PageIconButtonStyle())
            .help(search?.label ?? "Search everything")
        }
    }

    private func field(_ search: PageSearch) -> some View {
        let expanded = search.focus.wrappedValue || !search.query.isEmpty
        return HStack(spacing: 4) {
            TextField(search.prompt, text: search.$query)
                .textFieldStyle(.plain).focused(search.focus)
                .accessibilityLabel(search.label)
                .onExitCommand {
                    search.query = ""
                    search.focus.wrappedValue = false
                }
            if !search.query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { search.query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, expanded ? 8 : 0)
        .frame(width: expanded ? 200 : 0, height: 26)
        .background(
            Color(nsColor: .quaternarySystemFill).opacity(expanded ? 1 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .clipped()
        .animation(.snappy(duration: 0.18), value: expanded)
    }
}

/// A row of plain text filters: quieter than a segmented control, and the same on every page.
struct PageTabs<Value: Hashable>: View {
    let label: String
    let items: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button(item.title) { selection = item.value }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .background(
                        Color.primary.opacity(selected ? 0.09 : 0),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The square icon button used along the page bar.
struct PageIconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(selected ? .primary : .secondary)
            .frame(width: 28, height: 28)
            .background(
                Color.primary.opacity(selected ? 0.09 : configuration.isPressed ? 0.06 : 0),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}
