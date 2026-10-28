import AppKit
import SwiftUI

/// A font family menu that shows each family in its own face. SwiftUI's Picker draws every
/// menu item in the system font, so this is AppKit's pop-up button. "" is the system font.
struct FontFamilyPicker: NSViewRepresentable {
    @Binding var family: String
    let families: [String]
    /// Whether the chosen family renders; one that doesn't is marked in the menu.
    let available: Bool
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.family = $family
        button.setAccessibilityLabel(accessibilityLabel)
        // A choice outside the list, such as a font that's been uninstalled, stays listed so
        // the menu can show it.
        let extra = family.isEmpty || families.contains(family) ? nil : family
        let contents = families + [extra ?? "", "\(available)"]
        if contents != context.coordinator.contents {
            context.coordinator.contents = contents
            button.menu = Self.menu(families, extra: extra, available: available)
        }
        if let item = button.itemArray.first(where: { $0.representedObject as? String == family }) {
            button.select(item)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView button: NSPopUpButton,
        context _: Context
    ) -> CGSize? {
        // Sized to the choice rather than the widest family, as Picker is: a button holding
        // only that item measures it in its own face with the bezel and arrows.
        let measure = NSPopUpButton(frame: .zero, pullsDown: false)
        if let item = button.selectedItem?.copy() as? NSMenuItem {
            measure.menu?.addItem(item)
        }
        let width = measure.intrinsicContentSize.width
        return CGSize(
            width: min(width, proposal.width ?? width),
            height: button.intrinsicContentSize.height
        )
    }

    private static func menu(_ families: [String], extra: String?, available: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("System", family: ""))
        menu.addItem(.separator())
        if let extra {
            menu.addItem(item(available ? extra : "\(extra) (unavailable)", family: extra))
        }
        for family in families {
            let item = item(family, family: family)
            if let font = face(family) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
            }
            menu.addItem(item)
        }
        return menu
    }

    private static func item(_ title: String, family: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = family
        return item
    }

    /// The family at menu size, or nil when it can't draw its own name, as with symbol fonts
    /// and scripts it doesn't cover; those stay in the system font so they can be read.
    private static func face(_ family: String) -> NSFont? {
        guard let font = NSFontManager.shared.font(
            withFamily: family, traits: [], weight: 5, size: NSFont.systemFontSize
        ), font.fontDescriptor.symbolicTraits.rawValue
            & NSFontDescriptor.SymbolicTraits.classMask.rawValue
            != NSFontDescriptor.SymbolicTraits.classSymbolic.rawValue,
            CharacterSet(charactersIn: family)
            .subtracting(.whitespaces).isSubset(of: font.coveredCharacterSet)
        else { return nil }
        return font
    }

    @MainActor final class Coordinator: NSObject {
        var family: Binding<String>?
        var contents: [String] = []

        @objc func choose(_ button: NSPopUpButton) {
            if let family = button.selectedItem?.representedObject as? String {
                self.family?.wrappedValue = family
            }
        }
    }
}
