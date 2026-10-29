import AppKit
import QuartzCore
import SwiftUI

struct DocumentGridView: View {
    let model: DocumentGridModel
    let openNote: (UUID) -> Void
    var deleteNote: (UUID) -> Void = { _ in }
    var canDeleteNotes = false
    var selectsOnOpen = false

    var body: some View {
        DocumentCollection(
            model: model,
            openNote: openNote,
            deleteNote: deleteNote,
            canDeleteNotes: canDeleteNotes,
            selectsOnOpen: selectsOnOpen
        )
        .onDisappear { model.pause() }
        .overlay {
            if model.loading {
                WorkingProgress("Loading documents…")
            } else if model.total == 0, model.error == nil {
                ContentUnavailableView(
                    model.query.isEmpty ? "Your library starts here" : "No matching documents",
                    systemImage: model.query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(model.query.isEmpty
                        ? "Save a link, write a note, or attach a document below."
                        : "Try another title or a word from the document.")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.error {
                HStack {
                    Text(error).font(.callout).textSelection(.enabled)
                    Button("Retry") { Task { await model.reload() } }
                }
                .padding(12).background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .padding(16)
            }
        }
    }
}

private struct DocumentCollection: NSViewRepresentable {
    let model: DocumentGridModel
    let openNote: (UUID) -> Void
    let deleteNote: (UUID) -> Void
    let canDeleteNotes: Bool
    let selectsOnOpen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            openNote: openNote,
            deleteNote: deleteNote,
            canDeleteNotes: canDeleteNotes
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let collection = ResponsiveDocumentCollection()
        collection.selectsOnOpen = selectsOnOpen
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 24, bottom: 24, right: 24)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.register(DocumentTile.self, forItemWithIdentifier: DocumentTile.identifier)
        collection.setAccessibilityLabel("Stored documents")
        collection
            .activate = { [weak coordinator = context.coordinator] index in
                coordinator?.open(index)
            }
        collection.deleteSelected = { [weak coordinator = context.coordinator] index in
            coordinator?.delete(index)
        }
        collection
            .viewportChanged = { [weak coordinator = context.coordinator] in
                coordinator?.showViewport()
            }
        scroll.documentView = collection
        context.coordinator.collection = collection
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.collection?.selectsOnOpen = selectsOnOpen
        coordinator.openNote = openNote
        coordinator.deleteNote = deleteNote
        let deletionChanged = coordinator.canDeleteNotes != canDeleteNotes
        coordinator.canDeleteNotes = canDeleteNotes
        // Reading these counters connects the bounded native cache to SwiftUI observation.
        let version = model.cacheVersion
        if coordinator.generation != model.generation || coordinator.total != model.total {
            let reset = coordinator.generation != model.generation
            coordinator.generation = model.generation
            coordinator.total = model.total
            coordinator.collection?.reloadData()
            if reset {
                scroll.contentView.scroll(to: .zero)
            }
        }
        if coordinator.cacheVersion != version || deletionChanged {
            coordinator.cacheVersion = version
            if let collection = coordinator.collection {
                for path in collection.indexPathsForVisibleItems() {
                    if let tile = collection.item(at: path) as? DocumentTile {
                        coordinator.configure(tile, at: path.item)
                    }
                }
            }
            coordinator.showViewport()
        }
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource,
        NSCollectionViewDelegate
    {
        let model: DocumentGridModel
        var openNote: (UUID) -> Void
        var deleteNote: (UUID) -> Void
        var canDeleteNotes: Bool
        weak var collection: ResponsiveDocumentCollection?
        var generation = -1
        var cacheVersion = -1
        var total = 0

        init(
            model: DocumentGridModel,
            openNote: @escaping (UUID) -> Void,
            deleteNote: @escaping (UUID) -> Void,
            canDeleteNotes: Bool
        ) {
            self.model = model
            self.openNote = openNote
            self.deleteNote = deleteNote
            self.canDeleteNotes = canDeleteNotes
        }

        func collectionView(
            _: NSCollectionView,
            numberOfItemsInSection _: Int
        ) -> Int {
            model.total
        }

        func collectionView(
            _ collection: NSCollectionView,
            itemForRepresentedObjectAt path: IndexPath
        ) -> NSCollectionViewItem {
            let item = collection.makeItem(withIdentifier: DocumentTile.identifier, for: path)
            if let tile = item as? DocumentTile {
                configure(tile, at: path.item)
            }
            // Data-source callbacks run during layout; defer observable writes to the next turn.
            Task { [weak self] in self?.model.requestPage(path.item / DocumentGridModel.pageSize) }
            return item
        }

        func collectionView(
            _: NSCollectionView,
            willDisplay _: NSCollectionViewItem,
            forRepresentedObjectAt _: IndexPath
        ) {
            showViewport()
        }

        func collectionView(
            _: NSCollectionView,
            didEndDisplaying _: NSCollectionViewItem,
            forRepresentedObjectAt _: IndexPath
        ) {
            showViewport()
        }

        func configure(_ tile: DocumentTile, at index: Int) {
            let document = model.document(at: index)
            tile.configure(document, canDelete: canDeleteNotes, action: { [weak self] in
                guard let document else { return }
                if self?.collection?.selectsOnOpen == true {
                    self?.collection?.selectionIndexPaths = [IndexPath(item: index, section: 0)]
                }
                self?.openNote(document.id)
            }, delete: { [weak self] in
                guard let self, canDeleteNotes, let document else { return }
                deleteNote(document.id)
            })
        }

        func collectionView(
            _: NSCollectionView,
            didSelectItemsAt paths: Set<IndexPath>
        ) {
            if let path = paths.first {
                open(path.item)
            }
        }

        func open(_ index: Int) {
            guard let document = model.document(at: index) else { return }
            openNote(document.id)
        }

        func delete(_ index: Int) {
            guard canDeleteNotes, let document = model.document(at: index) else { return }
            deleteNote(document.id)
        }

        func showViewport() {
            guard let collection else { return }
            let indices = collection.indexPathsForVisibleItems().map(\.item)
            Task { [weak self] in self?.model.show(indices: indices) }
        }
    }
}

private final class ResponsiveDocumentCollection: NSCollectionView {
    var activate: ((Int) -> Void)?
    var deleteSelected: ((Int) -> Void)?
    var viewportChanged: (() -> Void)?
    var selectsOnOpen = false

    override func layout() {
        if let flow = collectionViewLayout as? NSCollectionViewFlowLayout {
            let available = max(1, (enclosingScrollView?.contentSize.width ?? bounds.width) - 48)
            let columns = max(1, Int((available + 8) / 184))
            let size = NSSize(
                width: floor((available - CGFloat(columns - 1) * 8) / CGFloat(columns)),
                height: 40
            )
            if flow.itemSize != size {
                flow.itemSize = size
            }
        }
        super.layout()
        viewportChanged?()
    }

    override func keyDown(with event: NSEvent) {
        if [51, 117].contains(event.keyCode), event.modifierFlags.contains(.command),
           let path = selectionIndexPaths.first
        {
            deleteSelected?(path.item)
        } else if event.keyCode == 36 || event.keyCode == 76, let path = selectionIndexPaths.first {
            activate?(path.item)
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class DocumentTile: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("DocumentTile")
    private let surface = DocumentTileSurface()
    private let button = DocumentTileButton()
    private let trash = DocumentTileButton()
    private var action: (() -> Void)?
    private var deleteAction: (() -> Void)?
    private var documentID: UUID?
    private var iconData: Data?
    private var canDelete = false
    private let titleLabel = DocumentTileTitle(labelWithString: "")
    private let icon = DocumentTileIcon()
    private var trashVisible = false
    private var visibilityVersion = 0

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            updateTrashVisibility()
        }
    }

    override func loadView() {
        view = surface
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        surface.hoverChanged = { [weak self] in self?.updateTrashVisibility(animated: true) }
        button.focusChanged = { [weak self] in
            Task { @MainActor in self?.updateTrashVisibility() }
        }
        trash.focusChanged = button.focusChanged
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(openDocument)
        button.focusRingType = .exterior
        trash.isBordered = false
        trash.title = ""
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        trash.imagePosition = .imageOnly
        trash.contentTintColor = .white
        trash.target = self
        trash.action = #selector(deleteDocument)
        trash.setAccessibilityIdentifier("delete-document")
        trash.isHidden = true
        trash.alphaValue = 0
        trash.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        icon.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        for child in [button, trash] {
            child.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(child)
        }
        for child in [icon, titleLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(child)
        }
        let trailing = titleLabel.trailingAnchor.constraint(
            equalTo: button.trailingAnchor,
            // Reserve the action slot so hover never shifts or retruncates the title.
            constant: -40
        )
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            button.topAnchor.constraint(equalTo: surface.topAnchor),
            button.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            trash.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
            trash.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            trash.widthAnchor.constraint(equalToConstant: 28),
            trash.heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            trailing,
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    func configure(
        _ document: DocumentSummary?,
        canDelete: Bool,
        action: @escaping () -> Void,
        delete: @escaping () -> Void
    ) {
        _ = view
        self.action = action
        deleteAction = delete
        self.canDelete = canDelete && document != nil
        button.isEnabled = document != nil
        trash.isEnabled = self.canDelete
        titleLabel.stringValue = document?.name ?? "Loading…"
        button.setAccessibilityLabel(document?.name ?? "Loading document")
        button.setAccessibilityIdentifier("open-document")
        button
            .setAccessibilityHelp(
                "Open document. Select a document and press Command Delete to delete it."
            )
        trash.setAccessibilityLabel("Delete “\(document?.name ?? "document")”")
        trash.toolTip = self.canDelete ? "Permanently delete document" : "Wait for captures to finish before deleting"
        button.toolTip = document
            .map { $0.name + ($0.sourceURL.map { "\n" + $0.absoluteString } ?? "") }
        // Decode the tiny local PNG once per reuse, never on every observation update.
        if documentID != document?.id || iconData != document?.faviconData {
            documentID = document?.id
            iconData = document?.faviconData
            icon.image = document?.faviconData.flatMap(NSImage.init(data:))
                ?? NSImage(
                    systemSymbolName: document?.sourceURL == nil ? "doc.text" : "globe",
                    accessibilityDescription: nil
                )
            icon.contentTintColor = document?.faviconData == nil ? .white : nil
        }
        let seed = document?.id.uuid.0 ?? 0
        let hues: [CGFloat] = [0.04, 0.11, 0.30, 0.45, 0.57, 0.65, 0.76, 0.88]
        surface.layer?.backgroundColor = NSColor(
            calibratedHue: hues[Int(seed) % hues.count],
            saturation: 0.42,
            brightness: 0.27,
            alpha: 1
        )
        .cgColor
        surface.refreshHover()
        updateTrashVisibility()
    }

    private func updateTrashVisibility(animated: Bool = false) {
        let show = documentID != nil && (surface.hovered || isSelected ||
            button.hasKeyboardFocus || trash.hasKeyboardFocus)
        trash.isEnabled = show && canDelete
        trash.setAccessibilityElement(show)
        guard show != trashVisible else { return }
        trashVisible = show
        visibilityVersion += 1
        let version = visibilityVersion
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            trash.layer?.removeAllAnimations()
            trash.alphaValue = show ? 1 : 0
            trash.isHidden = !show
            return
        }
        trash.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            trash.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, visibilityVersion == version else { return }
                trash.isHidden = !trashVisible
            }
        }
    }

    @objc private func openDocument() {
        action?()
    }

    @objc private func deleteDocument() {
        guard canDelete else { return }
        deleteAction?()
    }
}

private final class DocumentTileTitle: NSTextField {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

private final class DocumentTileIcon: NSImageView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

private final class DocumentTileSurface: NSView {
    var hoverChanged: (() -> Void)?
    private(set) var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
            ],
            owner: self
        ))
    }

    func refreshHover() {
        guard let window else { hovered = false; return }
        hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with _: NSEvent) {
        hovered = true
        hoverChanged?()
    }

    override func mouseExited(with _: NSEvent) {
        hovered = false
        hoverChanged?()
    }
}

private final class DocumentTileButton: NSButton {
    var focusChanged: (() -> Void)?
    private(set) var hasKeyboardFocus = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        hasKeyboardFocus = accepted
        focusChanged?()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            hasKeyboardFocus = false; focusChanged?()
        }
        return accepted
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        alphaValue = flag ? 0.65 : 1
    }
}
