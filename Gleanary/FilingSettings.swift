import SwiftUI

/// Settings › Filing: the Johnny Decimal scheme grouped by area. Categories sort by code, so
/// renumbering one is how it moves.
struct FilingSettings: View {
    @Bindable var model: ConversationModel
    @State private var selection: UUID?
    @State private var editor: CategoryEditorTarget?
    @State private var deleting: DecimalCategory?
    @State private var counts: [UUID: Int] = [:]
    @State private var starterCategories = false
    @State private var error: String?

    private var areas: [CategoryArea] {
        CategoryArea.group(model.categories)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.categories
                    .count == 1 ? "1 category" : "\(model.categories.count) categories")
                    .font(.callout).foregroundStyle(Color.primary.opacity(0.72))
                Spacer(minLength: 16)
                Button("Starter Categories…") { starterCategories = true }
            }
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(areas) { area in
                        Section {
                            ForEach(area.categories) { category in
                                row(category).tag(category.id).listRowSeparator(.hidden)
                            }
                        } header: {
                            areaHeader(area)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let category = category(ids.first) {
                        Button("Edit…") { editor = .edit(category.id) }
                        if !category.code.contains(".") {
                            Button("Add Subcategory") {
                                editor = .add(
                                    suggestedCode: nextSubcode(under: category),
                                    area: nil
                                )
                            }
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = category }
                    }
                } primaryAction: { ids in
                    if let id = ids.first {
                        editor = .edit(id)
                    }
                }
                Divider()
                listControls
            }
            // The list and its +/− bar share one box, as in System Settings.
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onDeleteCommand {
                if let category = category(selection) {
                    deleting = category
                }
            }
            if model.categories.isEmpty {
                emptyPrompt
            } else {
                Text(
                    "Sorted by code: change a code to move a category. Sub-codes like 31.04 sit under 31."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task(id: model.categories) {
            counts = await (try? model.store.categoryItemCounts()) ?? [:]
        }
        .confirmationDialog(
            deleting.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            }),
            titleVisibility: .visible,
            presenting: deleting
        ) { category in
            Button("Delete Category", role: .destructive) { Task { await delete(category) } }
            Button("Cancel", role: .cancel) {}
        } message: { category in
            Text(deleteMessage(category))
        }
        .sheet(isPresented: $starterCategories) {
            StarterCategoriesView(store: model.store, existing: model.categories) { await saved() }
        }
    }

    private func areaHeader(_ area: CategoryArea) -> some View {
        Text(area.range).font(.caption.weight(.medium)).monospacedDigit()
            .foregroundStyle(.secondary)
    }

    /// The standard footer under an editable Mac list, as in System Settings: + adds near the
    /// selection, − deletes it, and … names the other places a category can go. Equal plain
    /// buttons with hairline dividers, so nothing draws its own chrome.
    private var listControls: some View {
        let selected = category(selection)
        let area = areas.first { $0.digit == selected?.area } ?? areas.last
        return HStack(spacing: 0) {
            Button("Add Category", systemImage: "plus") {
                editor = .add(suggestedCode: suggestedCode(near: selection), area: nil)
            }
            .help("Add a category in \(area?.range ?? "the next free area")")
            .modifier(FooterControl())
            footerDivider
            Button("Delete Category", systemImage: "minus") {
                if let selected {
                    deleting = selected
                }
            }
            .disabled(selected == nil)
            .help("Delete the selected category")
            .modifier(FooterControl())
            footerDivider
            Menu {
                if let area, let code = area.nextFreeCode {
                    Button("Add Category in \(area.range)") {
                        editor = .add(suggestedCode: code, area: nil)
                    }
                }
                if let parent = selected, !parent.code.contains(".") {
                    Button("Add Subcategory Under \(parent.label)") {
                        editor = .add(suggestedCode: nextSubcode(under: parent), area: nil)
                    }
                }
                if let code = nextAreaCode {
                    Button("Add Area (\(code))") { editor = .add(suggestedCode: code, area: nil) }
                }
            } label: {
                Label("More ways to add", systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Add a subcategory or a new area")
            .modifier(FooterControl())
            footerDivider
            Spacer()
        }
        .frame(height: 24)
        .popover(isPresented: presenting { $0.addsTo(area: nil) }, arrowEdge: .bottom) {
            editorPopover
        }
    }

    private var footerDivider: some View {
        Divider().frame(height: 14)
    }

    /// The next unused XY.NN under a category, such as 31.05 after 31.04.
    private func nextSubcode(under parent: DecimalCategory) -> String {
        let used = Set(model.categories.map(\.code))
        return (1 ... 99).map { parent.code + String(format: ".%02d", $0) }
            .first { !used.contains($0) } ?? ""
    }

    /// The `X0` code of the first empty area, for a new top-level block.
    private var nextAreaCode: String? {
        let used = Set(areas.map(\.digit))
        return (1 ... 9).first { !used.contains($0) }.map { "\($0)0" }
    }

    private func row(_ category: DecimalCategory) -> some View {
        CategoryRow(category: category, count: counts[category.id] ?? 0)
            .popover(isPresented: presenting { $0 == .edit(category.id) }, arrowEdge: .trailing) {
                editorPopover
            }
    }

    private var emptyPrompt: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No categories yet").font(.callout.weight(.medium))
                Text("Start from a suggested set for the kind of work you do, then adjust it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Starter Categories…") { starterCategories = true }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var editorPopover: some View {
        if let editor {
            CategoryEditor(
                target: editor,
                categories: model.categories,
                save: { id, code, name in
                    try await model.store.saveCategory(id: id, code: code, name: name)
                    selection = id
                    self.editor = nil
                    await saved()
                },
                cancel: { self.editor = nil }
            )
        }
    }

    /// A popover binding for the editor target matching `predicate`.
    private func presenting(_ predicate: @escaping (CategoryEditorTarget) -> Bool)
        -> Binding<Bool>
    {
        Binding(
            get: { editor.map(predicate) ?? false },
            set: {
                if !$0, let editor, predicate(editor) {
                    self.editor = nil
                }
            }
        )
    }

    private func category(_ id: UUID?) -> DecimalCategory? {
        model.categories.first { $0.id == id }
    }

    /// The next free code in the selected category's area, else in the last area.
    private func suggestedCode(near id: UUID?) -> String {
        let area = category(id).map(\.area) ?? areas.last?.digit
        return areas.first { $0.digit == area }?.nextFreeCode ?? ""
    }

    private func deleteMessage(_ category: DecimalCategory) -> String {
        let count = counts[category.id] ?? 0
        let filed = switch count {
        case 0: "Nothing is filed here."
        case 1: "1 item is filed here. It stays in the library and keeps any other categories; with none left it becomes unfiled."
        default: "\(count) items are filed here. They stay in the library and keep any other categories; items with none left become unfiled."
        }
        return filed + " This can't be undone."
    }

    private func delete(_ category: DecimalCategory) async {
        do {
            try await model.store.deleteCategory(category.id)
            if selection == category.id {
                selection = nil
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        await saved()
    }

    private func saved() async {
        await model.refresh()
        await model.didMutate?()
    }
}

enum CategoryEditorTarget: Equatable {
    /// `area` identifies which add control anchors the popover; nil is the list's + button.
    case add(suggestedCode: String, area: Int?)
    case edit(UUID)

    func addsTo(area: Int?) -> Bool {
        if case let .add(_, anchor) = self {
            anchor == area
        } else {
            false
        }
    }
}

/// One tens block of the scheme, such as 20–29.
struct CategoryArea: Identifiable {
    let digit: Int
    let categories: [DecimalCategory]
    var id: Int {
        digit
    }

    var range: String {
        "\(digit)0–\(digit)9"
    }

    /// The area's `X0` category names it, as Johnny Decimal suggests.
    var title: String {
        categories.first { $0.code == "\(digit)0" }?.name ?? "Area \(range)"
    }

    var nextFreeCode: String? {
        let used = Set(categories.map(\.code))
        return (0 ... 9).map { "\(digit)\($0)" }.first { !used.contains($0) }
    }

    func contains(_ code: String) -> Bool {
        code.first?.wholeNumberValue == digit
    }

    static func group(_ categories: [DecimalCategory]) -> [CategoryArea] {
        Dictionary(grouping: categories, by: \.area)
            .map { CategoryArea(digit: $0.key, categories: $0.value.sorted { $0.code < $1.code }) }
            .sorted { $0.digit < $1.digit }
    }
}

private struct CategoryRow: View {
    let category: DecimalCategory
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(category.code).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
                .padding(.leading, category.code.contains(".") ? 14 : 0)
            // An area's X0 category names the area.
            Text(category.name).lineLimit(1)
                .fontWeight(category.code.hasSuffix("0") && category.code
                    .count == 2 ? .semibold : nil)
            Spacer(minLength: 8)
            if count > 0 {
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help(count == 1 ? "1 item filed here" : "\(count) items filed here")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

/// Code and name fields with live feedback, shown in a popover.
private struct CategoryEditor: View {
    let target: CategoryEditorTarget
    let categories: [DecimalCategory]
    let save: (UUID, String, String) async throws -> Void
    let cancel: () -> Void
    @State private var code = ""
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private var editing: DecimalCategory? {
        if case let .edit(id) = target {
            categories.first { $0.id == id }
        } else {
            nil
        }
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the draft can't be saved, or where it will appear.
    private var feedback: (message: String, problem: Bool)? {
        if trimmedCode.isEmpty {
            return nil
        }
        guard (try? DecimalCategory.validate(code: trimmedCode, name: "x")) != nil else {
            return ("Use two digits from 10 to 99, like 31, or a sub-code like 31.04.", true)
        }
        let others = categories.filter { $0.id != editing?.id }
        if let clash = others.first(where: { $0.code == trimmedCode }) {
            return ("\(trimmedCode) is already \u{201C}\(clash.name)\u{201D}.", true)
        }
        if !trimmedName.isEmpty, let clash = others.first(where: {
            DecimalCategory.normalized($0.name) == DecimalCategory.normalized(trimmedName)
        }) {
            return ("\u{201C}\(clash.name)\u{201D} already exists at \(clash.code).", true)
        }
        let area = CategoryArea.group(others).first { $0.contains(trimmedCode) }
        if trimmedCode.contains("."), let parent = others.first(where: {
            $0.code == String(trimmedCode.prefix(2))
        }) {
            return ("Sits under \(parent.code) \(parent.name).", false)
        }
        return area.map { ("Sits in \($0.range) \($0.title).", false) }
            ?? ("Starts a new area, \(trimmedCode.prefix(1))0–\(trimmedCode.prefix(1))9.", false)
    }

    private var canSave: Bool {
        !saving && !trimmedCode.isEmpty && !trimmedName.isEmpty && feedback?.problem != true
            && (editing.map { $0.code != trimmedCode || $0.name != trimmedName } ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "New category" : "Edit category").font(.headline)
            HStack(spacing: 8) {
                TextField("Code", text: $code, prompt: Text("31"))
                    .frame(width: 72).monospacedDigit()
                    .accessibilityLabel("Category code")
                TextField("Name", text: $name, prompt: Text("Category name"))
                    .frame(width: 220).focused($nameFocused)
                    .accessibilityLabel("Category name")
                    .onSubmit { Task { await submit() } }
            }
            Group {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                } else if let feedback {
                    Label(
                        feedback.message,
                        systemImage: feedback.problem
                            ? "exclamationmark.triangle" : "arrow.turn.down.right"
                    )
                } else {
                    Text("Codes run from 10 to 99. Sub-codes like 31.04 sit under 31.")
                }
            }
            .font(.caption)
            .foregroundStyle(failure != nil || feedback?.problem == true ? AnyShapeStyle(.red)
                : AnyShapeStyle(.secondary))
            .frame(width: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(16)
        .onAppear {
            switch target {
            case let .add(suggested, _): code = suggested
            case .edit: code = editing?.code ?? ""; name = editing?.name ?? ""
            }
            nameFocused = true
        }
    }

    private func submit() async {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        do {
            try await save(editing?.id ?? UUID(), trimmedCode, trimmedName)
        } catch { failure = error.localizedDescription }
    }
}

/// One square, plain control in a list footer.
private struct FooterControl: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
    }
}
