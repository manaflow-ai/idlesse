import AppKit

/// Geometry shared by the virtualized gallery and its synthetic large-catalog tests.
/// It intentionally scales with visible rows rather than catalog size.
struct LibraryGridLayoutPlan {
    let itemCount: Int
    let contentWidth: CGFloat
    let viewportHeight: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let columns: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let rowStride: CGFloat
    let rowCount: Int
    let contentHeight: CGFloat

    init(itemCount: Int,
         contentWidth: CGFloat,
         viewportHeight: CGFloat,
         padding: CGFloat = 18,
         spacing: CGFloat = 16,
         minCardWidth: CGFloat = 200) {
        self.itemCount = max(0, itemCount)
        self.contentWidth = max(300, contentWidth)
        self.viewportHeight = max(0, viewportHeight)
        self.padding = padding
        self.spacing = spacing

        let availableWidth = max(1, self.contentWidth - (padding * 2))
        columns = max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))
        cardWidth = (availableWidth - (CGFloat(columns - 1) * spacing)) / CGFloat(columns)
        cardHeight = cardWidth * 9.0 / 16.0 + 44
        rowStride = cardHeight + spacing
        rowCount = self.itemCount == 0 ? 0 : (self.itemCount + columns - 1) / columns
        if rowCount == 0 {
            contentHeight = max(self.viewportHeight, padding * 2)
        } else {
            contentHeight = max(self.viewportHeight,
                                padding * 2 + CGFloat(rowCount) * cardHeight + CGFloat(rowCount - 1) * spacing)
        }
    }

    func frame(for index: Int) -> NSRect? {
        guard index >= 0, index < itemCount else { return nil }
        let row = index / columns
        let column = index % columns
        return NSRect(x: padding + CGFloat(column) * (cardWidth + spacing),
                      y: padding + CGFloat(row) * rowStride,
                      width: cardWidth,
                      height: cardHeight)
    }

    func itemIndex(at point: NSPoint) -> Int? {
        guard itemCount > 0, point.x >= padding, point.y >= padding else { return nil }
        let column = Int((point.x - padding) / (cardWidth + spacing))
        let row = Int((point.y - padding) / rowStride)
        guard column >= 0, column < columns, row >= 0, row < rowCount else { return nil }
        let index = row * columns + column
        guard index < itemCount, let frame = frame(for: index), frame.contains(point) else { return nil }
        return index
    }

    /// Returns whole rows around the viewport. The amount of work is bounded by
    /// viewport height + `extraRows`, regardless of a 40-item or 40,000-item catalog.
    func indexes(intersecting rect: NSRect, extraRows: Int = 1) -> Range<Int> {
        guard itemCount > 0, rowCount > 0 else { return 0..<0 }
        let margin = CGFloat(max(0, extraRows)) * rowStride
        let minY = rect.minY - margin
        let maxY = rect.maxY + margin
        guard maxY >= padding, minY <= contentHeight - padding else { return 0..<0 }

        let firstRow = max(0, min(rowCount - 1, Int(floor((max(padding, minY) - padding) / rowStride))))
        let lastRow = max(firstRow, min(rowCount - 1, Int(floor((max(padding, maxY) - padding) / rowStride))))
        let lower = firstRow * columns
        let upper = min(itemCount, (lastRow + 1) * columns)
        return lower..<upper
    }
}

#if !LIBRARY_GRID_VIRTUALIZATION_TESTS

typealias LibraryItem = SceneLibraryController.Item

final class LibraryGridView: NSView {
    var onSelect: ((LibraryItem) -> Void)?
    var onMenu: ((LibraryItem) -> NSMenu)?
    var onDoubleAction: ((LibraryItem) -> Void)?
    var onRequestThumbnail: ((LibraryItem, @escaping (NSImage) -> Void) -> Void)?

    private var items: [LibraryItem] = []
    private var selectedID: String?
    private var activeCards: [Int: LibraryCardView] = [:]
    private var reusableCards: [LibraryCardView] = []
    private var layoutPlan: LibraryGridLayoutPlan?
    private var scrollObserver: NSObjectProtocol?
    private weak var observedClipView: NSClipView?
    private var isRelayouting = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func update(items: [LibraryItem], selectedID: String?) {
        self.items = items
        self.selectedID = selectedID
        relayout()
    }

    func refreshThumbnail(id: String) {
        guard let request = onRequestThumbnail else { return }
        for card in activeCards.values where card.item?.id == id {
            card.requestThumbnail(using: request)
        }
    }

    func select(id: String?) {
        selectedID = id
        for card in activeCards.values {
            card.isSelected = card.item?.id == id
        }
    }

    /// Reveal the same item when switching layouts or restoring a scope.
    /// This changes only scroll position; it never selects or applies a wallpaper.
    func revealSelection() {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return }
        relayout()
        if let frame = layoutPlan?.frame(for: index) {
            scrollToVisible(frame.insetBy(dx: 0, dy: -8))
        }
    }

    /// Hit-tests directly from layout geometry, so it works even though only a
    /// small window of cards exists at any moment.
    func item(at point: NSPoint) -> LibraryItem? {
        guard let index = layoutPlan?.itemIndex(at: point), items.indices.contains(index) else { return nil }
        return items[index]
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachScrollObserverIfNeeded()
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachScrollObserverIfNeeded()
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(newSize.width - oldWidth) > 1, !isRelayouting {
            relayout()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !items.isEmpty else { return super.keyDown(with: event) }
        let columns = layoutPlan?.columns ?? 1
        switch event.keyCode {
        case 123: moveSelection(by: -1)                 // left
        case 124: moveSelection(by: 1)                  // right
        case 125: moveSelection(by: columns)            // down
        case 126: moveSelection(by: -columns)           // up
        case 115: selectIndex(0, notify: true)           // home
        case 119: selectIndex(items.count - 1, notify: true) // end
        case 36, 76:                                    // return / keypad enter
            if let selectedID, let item = items.first(where: { $0.id == selectedID }) {
                onDoubleAction?(item)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func attachScrollObserverIfNeeded() {
        guard let clipView = enclosingScrollView?.contentView, observedClipView !== clipView else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                 object: clipView,
                                                                 queue: .main) { [weak self] _ in
            self?.updateVisibleCards()
        }
    }

    private func relayout() {
        guard !isRelayouting else { return }
        attachScrollObserverIfNeeded()
        let viewport = enclosingScrollView?.contentView.bounds ?? bounds
        let width = viewport.width > 0 ? viewport.width : (bounds.width > 0 ? bounds.width : 800)
        let height = viewport.height > 0 ? viewport.height : bounds.height
        let plan = LibraryGridLayoutPlan(itemCount: items.count,
                                         contentWidth: width,
                                         viewportHeight: height)
        layoutPlan = plan

        isRelayouting = true
        super.setFrameSize(NSSize(width: plan.contentWidth, height: plan.contentHeight))
        isRelayouting = false
        updateVisibleCards()
    }

    private func updateVisibleCards() {
        guard let plan = layoutPlan else { return }
        let visibleRect = enclosingScrollView?.contentView.bounds ?? bounds
        let targetRange = plan.indexes(intersecting: visibleRect, extraRows: 1)
        let target = Set(targetRange)

        for index in activeCards.keys.filter({ !target.contains($0) }) {
            guard let card = activeCards.removeValue(forKey: index) else { continue }
            card.prepareForReuse()
            card.removeFromSuperview()
            reusableCards.append(card)
        }

        for index in targetRange where items.indices.contains(index) {
            let item = items[index]
            let card: LibraryCardView
            let changed: Bool
            if let existing = activeCards[index] {
                card = existing
                changed = card.configure(item: item)
            } else {
                card = reusableCards.popLast() ?? LibraryCardView(frame: .zero)
                card.onClick = { [weak self] item in self?.selectFromUser(item) }
                card.onMenu = { [weak self] item in self?.onMenu?(item) }
                card.onDoubleClick = { [weak self] item in self?.doubleActionFromUser(item) }
                changed = card.configure(item: item)
                activeCards[index] = card
                addSubview(card)
            }
            if let frame = plan.frame(for: index) { card.frame = frame }
            card.isSelected = item.id == selectedID
            if changed, let onRequestThumbnail {
                card.requestThumbnail(using: onRequestThumbnail)
            }
        }
    }

    private func selectFromUser(_ item: LibraryItem) {
        selectedID = item.id
        select(id: item.id)
        window?.makeFirstResponder(self)
        onSelect?(item)
    }

    private func doubleActionFromUser(_ item: LibraryItem) {
        selectedID = item.id
        select(id: item.id)
        window?.makeFirstResponder(self)
        onDoubleAction?(item)
    }

    private func moveSelection(by delta: Int) {
        let current = selectedID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        let start: Int
        if let current { start = current }
        else { start = delta < 0 ? items.count - 1 : 0 }
        selectIndex(max(0, min(items.count - 1, start + (current == nil ? 0 : delta))), notify: true)
    }

    private func selectIndex(_ index: Int, notify: Bool) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        selectedID = item.id
        select(id: item.id)
        if let frame = layoutPlan?.frame(for: index) {
            scrollToVisible(frame.insetBy(dx: 0, dy: -8))
        }
        if notify { onSelect?(item) }
    }

#if DEBUG
    /// Exposed only to debug/test builds for quick manual scaling diagnostics.
    var debugActiveCardCount: Int { activeCards.count }
#endif
}

final class LibraryCardView: NSView {
    override var isFlipped: Bool { true }
    var onMenu: ((LibraryItem) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        onClick?(item)
        return onMenu?(item)
    }
    private(set) var item: LibraryItem?
    var isSelected = false {
        didSet { updateBorder() }
    }
    var onClick: ((LibraryItem) -> Void)?
    var onDoubleClick: ((LibraryItem) -> Void)?

    let thumbnailView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var thumbnailWork: DispatchWorkItem?
    private var thumbnailGeneration: UInt = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailView.image = Self.placeholderImage
        addSubview(thumbnailView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor
        addSubview(badgeLabel)
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        let thumbHeight = bounds.width * 9.0 / 16.0
        thumbnailView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thumbHeight)
        let labelY = thumbHeight + 5
        titleLabel.frame = NSRect(x: 8, y: labelY, width: max(0, bounds.width - 16), height: 18)
        badgeLabel.frame = NSRect(x: 8, y: labelY + 18, width: max(0, bounds.width - 16), height: 14)
    }

    /// Returns true when the represented item changed and needs a fresh thumbnail.
    @discardableResult
    func configure(item: LibraryItem) -> Bool {
        let changed = self.item?.id != item.id
        if changed {
            cancelThumbnailRequest()
            self.item = item
            thumbnailView.image = Self.placeholderImage
        } else {
            self.item = item
        }
        titleLabel.stringValue = SceneLibraryController.displayTitle(item.title)
        let mediaType = item.builtin != nil ? "scene" : item.entry?.inferredMediaType
        switch mediaType {
        case "video": badgeLabel.stringValue = "Video"
        case "scene": badgeLabel.stringValue = "Scene"
        case "image": badgeLabel.stringValue = "Image"
        default: badgeLabel.stringValue = "Media"
        }
        return changed
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailRequest()
        item = nil
        isSelected = false
        thumbnailView.image = Self.placeholderImage
        titleLabel.stringValue = ""
        badgeLabel.stringValue = ""
    }

    /// A short delay makes scroll churn cancellable before it reaches disk/cloud.
    /// Once a legacy thumbnail decode has begun it may finish, but generation
    /// checks keep reused cards from receiving stale images.
    func requestThumbnail(using request: @escaping (LibraryItem, @escaping (NSImage) -> Void) -> Void) {
        cancelThumbnailRequest()
        guard let item else { return }
        let itemID = item.id
        let generation = thumbnailGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.thumbnailGeneration == generation,
                  self.item?.id == itemID else { return }
            self.thumbnailWork = nil
            request(item) { [weak self] image in
                let apply = {
                    guard let self,
                          self.thumbnailGeneration == generation,
                          self.item?.id == itemID else { return }
                    self.thumbnailView.image = image
                }
                if Thread.isMainThread { apply() }
                else { DispatchQueue.main.async(execute: apply) }
            }
        }
        thumbnailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func cancelThumbnailRequest() {
        thumbnailGeneration &+= 1
        thumbnailWork?.cancel()
        thumbnailWork = nil
    }

    private func updateBorder() {
        if isSelected {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 2
        } else {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            layer?.borderWidth = 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        if event.clickCount == 2 { onDoubleClick?(item) }
        else { onClick?(item) }
    }

    private static var placeholderImage: NSImage? {
        NSImage(systemSymbolName: "photo", accessibilityDescription: "Thumbnail")
    }
}

#endif
