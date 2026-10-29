import SwiftUI

/// Suggests a Johnny Decimal scheme from what the person works on. Every category is previewed,
/// can be renamed or left out, and the whole addition can be undone while nothing is filed in it.
struct StarterCategoriesView: View {
    let store: DocumentStore
    /// The scheme when the sheet opened; new codes are planned around it.
    let existing: [DecimalCategory]
    let didChange: () async -> Void
    @Environment(\.dismiss) private var dismiss
    /// Chosen pack IDs in the order picked, which decides their tens blocks.
    @State private var chosen = [StarterPack.essentials.id]
    @State private var excluded: Set<String> = []
    @State private var names: [String: String] = [:]
    @State private var created: [UUID]?
    @State private var working = false
    @State private var error: String?

    private var plan: StarterPlan {
        StarterPlan(
            packs: chosen.compactMap { id in StarterPack.all.first { $0.id == id } },
            existing: existing
        )
    }

    private var additions: [StarterPlan.Category] {
        plan.categories.filter { !excluded.contains($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Starter categories").font(.title2.weight(.semibold))
                Text(
                    "Choose what you work on. Review the suggested categories before adding them; existing categories are never changed."
                )
                .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            if let created {
                summary(created)
            } else {
                packPicker.padding(.horizontal, 24).padding(.bottom, 16)
                Divider()
                preview
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 620, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var packPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], spacing: 8) {
            ForEach(StarterPack.all) { pack in
                Toggle(isOn: Binding(
                    get: { chosen.contains(pack.id) },
                    set: { on in
                        chosen.removeAll { $0 == pack.id }
                        if on {
                            chosen.append(pack.id)
                        }
                    }
                )) {
                    Label(pack.title, systemImage: pack.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.button)
            }
        }.disabled(working)
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if plan.areas.isEmpty {
                    Text(chosen.isEmpty ? "Choose at least one area above."
                        : "Your scheme already covers these suggestions.")
                        .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                }
                ForEach(plan.areas) { area in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(area.title).font(.headline)
                        ForEach(area.categories) { category in
                            row(category)
                        }
                    }
                }
                if !plan.unplaced.isEmpty {
                    Text(
                        "No free area for \(plan.unplaced.map(\.title).formatted()). Johnny Decimal allows areas 10 to 90, and the others are in use."
                    )
                    .font(.caption).foregroundStyle(Color.primary.opacity(0.72))
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(working)
    }

    private func row(_ category: StarterPlan.Category) -> some View {
        let included = !excluded.contains(category.key)
        return HStack(spacing: 10) {
            Toggle("Include \(category.name)", isOn: Binding(
                get: { included },
                set: {
                    if $0 {
                        excluded.remove(category.key)
                    } else {
                        excluded.insert(category.key)
                    }
                }
            )).toggleStyle(.checkbox).labelsHidden()
            Text(category.code).monospacedDigit().frame(width: 28, alignment: .leading)
                .foregroundStyle(Color.primary.opacity(included ? 0.72 : 0.4))
            TextField(category.name, text: Binding(
                get: { names[category.key] ?? category.name },
                set: { names[category.key] = $0 }
            ))
            .textFieldStyle(.plain)
            .accessibilityLabel("Name for category \(category.code)")
            .disabled(!included)
            .opacity(included ? 1 : 0.5)
        }
    }

    private func summary(_ created: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                created.isEmpty ? "No categories were added; they already exist."
                    : "Added \(Self.counted(created.count)).",
                systemImage: "checkmark.circle"
            ).font(.headline)
            Text(
                "Rename, renumber or add categories any time in Settings › Filing. The librarian files new material into this scheme."
            )
            .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 24).frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var footer: some View {
        HStack {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer()
            if let created {
                if !created.isEmpty {
                    Button("Undo") { Task { await undo(created) } }.disabled(working)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(Self.counted(additions.count))") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || additions.isEmpty)
            }
        }
    }

    private static func counted(_ count: Int) -> String {
        count == 1 ? "1 category" : "\(count) categories"
    }

    private func apply() async {
        working = true
        defer { working = false }
        do {
            created = try await store.addCategories(additions.map {
                (code: $0.code, name: names[$0.key] ?? $0.name)
            })
            error = nil
        } catch { self.error = error.localizedDescription }
        await didChange()
    }

    private func undo(_ ids: [UUID]) async {
        working = true
        defer { working = false }
        do {
            let kept = try await store.removeUnusedCategories(ids)
            created = nil
            error = kept == 0 ? nil
                : "Kept \(Self.counted(kept)) with filed material."
        } catch { self.error = error.localizedDescription }
        await didChange()
    }
}
