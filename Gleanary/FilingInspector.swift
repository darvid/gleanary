import SwiftUI

/// Changes an item's filing in the window's inspector, beside the item rather than over it.
/// It follows the selection, and a choice applies at once.
struct FilingInspector: View {
    let document: MarkdownDocument?
    let categories: [DecimalCategory]
    let store: DocumentStore
    /// Makes `categoryID` the item's primary home; the inspector stays open.
    let file: (MarkdownDocument, UUID) async -> Void
    let close: () -> Void
    @State private var query = ""
    /// The item's memberships, primary first.
    @State private var assigned: [DecimalCategory] = []
    @State private var filingID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    private var areas: [CategoryArea] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let shown = text.isEmpty ? categories : categories.filter {
            $0.label.localizedCaseInsensitiveContains(text)
        }
        return CategoryArea.group(shown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let document {
                TextField("Find a category", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 14).padding(.bottom, 8)
                List {
                    ForEach(areas) { area in
                        Section(area.title) {
                            ForEach(area.categories) { row($0, document: document) }
                        }
                    }
                }
                // Not `.sidebar`: its vibrant text looks soft away from the window's edge.
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if areas.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                Text(
                    "Choosing a category moves the item's primary home. Other places it's filed stay."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "folder",
                    description: Text("Select an item to file it.")
                )
            }
        }
        .task(id: document?.id) { await loadAssigned() }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Filing").font(.headline)
                if let document {
                    Text(document.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Done", action: close).keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    private func row(_ category: DecimalCategory, document: MarkdownDocument) -> some View {
        let slot = AtlasHierarchy.hue(for: category.code)
        let primary = assigned.first?.id == category.id
        let secondary = !primary && assigned.contains { $0.id == category.id }
        return Button {
            guard !primary else { return }
            filingID = category.id
            Task {
                await file(document, category.id)
                await loadAssigned()
                filingID = nil
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(AtlasPalette.ink(slot, dark: colorScheme == .dark))
                    .frame(width: 8, height: 8)
                Text(category.code).monospacedDigit().foregroundStyle(.secondary)
                Text(category.name).lineLimit(1)
                Spacer(minLength: 4)
                if filingID == category.id {
                    ProgressView().controlSize(.mini)
                } else if primary {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                } else if secondary {
                    Text("Also here").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, category.code.contains(".") ? 12 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(filingID != nil)
        .accessibilityLabel(category.label)
        .accessibilityValue(primary ? "Primary home" : secondary ? "Also filed here" : "")
    }

    private func loadAssigned() async {
        guard let id = document?.id else { assigned = []; return }
        assigned = await (try? store.categories(for: id)) ?? []
    }
}
