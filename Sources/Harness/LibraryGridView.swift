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
         padding: CGFloat = 10,
         spacing: CGFloat = 10,
         minCardWidth: CGFloat = 200) {
        self.itemCount = max(0, itemCount)
        self.contentWidth = max(300, contentWidth)
        self.viewportHeight = max(0, viewportHeight)
        self.padding = padding
        self.spacing = spacing

        let availableWidth = max(1, self.contentWidth - (padding * 2))
        columns = max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))
        cardWidth = (availableWidth - (CGFloat(columns - 1) * spacing)) / CGFloat(columns)
        cardHeight = cardWidth * 9.0 / 16.0
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

    /// Keep the leading visible wallpaper and fractional row position on resize.
    func scrollOrigin(preserving origin: CGFloat, from old: LibraryGridLayoutPlan) -> CGFloat {
        guard origin > 0, old.itemCount > 0, itemCount > 0 else { return 0 }
        let row = max(0, Int(floor((origin - old.padding) / old.rowStride)))
        let index = min(itemCount - 1, row * old.columns)
        let fraction = (origin - old.padding - CGFloat(row) * old.rowStride) / old.rowStride
        let target = padding + CGFloat(index / columns) * rowStride + fraction * rowStride
        return max(0, min(contentHeight - viewportHeight, target))
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
    var onDragURL: ((LibraryItem) -> URL?)?
    var onDragEnd: (() -> Void)?
    var onSelect: ((LibraryItem) -> Void)?
    var onMenu: ((LibraryItem) -> NSMenu)?
    var onDoubleAction: ((LibraryItem) -> Void)?
    var onPlaybackAction: ((LibraryItem) -> Void)?
    var playingIDs: Set<String> = [] { didSet { updateCardPlayback() } }
    private func updateCardPlayback() {
        for card in activeCards.values { card.showsPause = card.item.map { playingIDs.contains($0.id) } ?? false }
    }
    var onRequestThumbnail: ((LibraryItem, @escaping (NSImage) -> Void) -> Void)?

    private var items: [LibraryItem] = []
    private var selectedID: String?
    private var activeCards: [Int: LibraryCardView] = [:]
    private var reusableCards: [LibraryCardView] = []
    private var layoutPlan: LibraryGridLayoutPlan?
    var onVisibleItemsChange: ((Set<String>) -> Void)?
    var onGeometryChange: (() -> Void)?
    private var windowObservers: [NSObjectProtocol] = []
    private var scrollObserver: NSObjectProtocol?
    private weak var observedClipView: NSClipView?
    private var isRelayouting = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var lastVisibleRange: Range<Int>?
    var thumbnailTrailingEdgeInWindow: CGFloat? {
        guard let plan = layoutPlan, window != nil else { return nil }
        return convert(NSPoint(x: plan.contentWidth - plan.padding, y: 0), to: nil).x
    }


    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
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
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.updatePointerHover()
                })
            }
        }
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
        lastVisibleRange = nil
        guard !isRelayouting else { return }
        attachScrollObserverIfNeeded()
        let viewport = enclosingScrollView?.contentView.bounds ?? bounds
        let width = viewport.width > 0 ? viewport.width : (bounds.width > 0 ? bounds.width : 800)
        let height = viewport.height > 0 ? viewport.height : bounds.height
        let plan = LibraryGridLayoutPlan(itemCount: items.count,
                                         contentWidth: width,
                                         viewportHeight: height)
        let previousPlan = layoutPlan
        layoutPlan = plan

        isRelayouting = true
        super.setFrameSize(NSSize(width: plan.contentWidth, height: plan.contentHeight))
        if let previousPlan, previousPlan.contentWidth != plan.contentWidth,
           let clip = enclosingScrollView?.contentView {
            let origin = plan.scrollOrigin(preserving: viewport.minY, from: previousPlan)
            clip.scroll(to: NSPoint(x: 0, y: origin))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        isRelayouting = false
        updateVisibleCards()
        onGeometryChange?()
    }

    private func updateVisibleCards() {
        defer { updatePointerHover() }
        guard let plan = layoutPlan else { return }
        let visibleRect = enclosingScrollView?.contentView.bounds ?? bounds
        let targetRange = plan.indexes(intersecting: visibleRect, extraRows: 1)
        guard targetRange != lastVisibleRange else { return }
        lastVisibleRange = targetRange
        onVisibleItemsChange?(Set(targetRange.filter { items.indices.contains($0) }.map { items[$0].id }))
        let target = Set(targetRange)

        for index in activeCards.keys.filter({ !target.contains($0) }) {
            guard let card = activeCards.removeValue(forKey: index) else { continue }
            card.prepareForReuse()
            card.isHidden = true
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
                card.onDragURL = { [weak self] item in self?.onDragURL?(item) }
                card.onDragEnd = { [weak self] in self?.onDragEnd?() }
                card.onClick = { [weak self] item in self?.selectFromUser(item) }
                card.onMenu = { [weak self] item in self?.onMenu?(item) }
                card.onPlaybackAction = { [weak self] item in self?.onPlaybackAction?(item) }
                card.onDoubleClick = { [weak self] item in self?.doubleActionFromUser(item) }
                changed = card.configure(item: item)
                activeCards[index] = card
                if card.superview == nil { addSubview(card) }
                card.isHidden = false
            }
            if let frame = plan.frame(for: index), card.frame != frame { card.frame = frame }
            card.showsPause = playingIDs.contains(item.id)
            card.isSelected = item.id == selectedID
            if changed, let onRequestThumbnail {
                card.requestThumbnail(using: onRequestThumbnail)
            }
        }
    }

    private func updatePointerHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        for card in activeCards.values {
            card.setPointerHovered(window.isKeyWindow && visible.contains(point) && card.frame.contains(point))
        }
    }

    static func smokeReuse(template: LibraryItem) {
        let viewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1040, height: 640))
        let gallery = LibraryGridView(frame: viewport.bounds)
        viewport.documentView = gallery
        gallery.update(items: (0..<4000).map {
            LibraryItem(id: "reuse-\($0)", title: "Wallpaper \($0)", builtin: template.builtin, entry: nil)
        }, selectedID: nil)
        func travel(_ pass: Int) {
            for step in 0..<200 {
                let index = (step * 19 + pass * 7) % 3990
                let y = gallery.layoutPlan!.frame(for: index)!.minY
                viewport.contentView.scroll(to: NSPoint(x: 0, y: y))
                gallery.updateVisibleCards()
                precondition(gallery.subviews.count < 40, "The retained view pool must remain bounded by the viewport")
                precondition(gallery.activeCards.values.allSatisfy { !$0.isHidden })
                precondition(gallery.reusableCards.allSatisfy(\.isHidden))
            }
        }
        travel(0)
        let playing = gallery.activeCards.values.first!.item!.id
        gallery.playingIDs = [playing]
        precondition(gallery.activeCards.values.allSatisfy {
            $0.showsPause == ($0.item?.id == playing)
        }, "Pause affordance must follow playback rather than poster selection")
        gallery.playingIDs = []
        precondition(gallery.activeCards.values.allSatisfy { !$0.showsPause },
                     "Pausing playback must restore the play affordance")
        let retained = Set(gallery.subviews.map(ObjectIdentifier.init))
        travel(1)
        precondition(Set(gallery.subviews.map(ObjectIdentifier.init)) == retained,
                     "Steady-state scrolling must reuse the same attached card views")
        print("Gallery reuse passed: 400 scroll positions, 4,000 items, \(retained.count) retained card views")
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

final class LibraryCardView: NSView, NSDraggingSource, NSMenuDelegate {
    var onDragURL: ((LibraryItem) -> URL?)?
    var onDragEnd: (() -> Void)?
    private var mouseOrigin: NSPoint?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var trackingInteraction = false
    private let quickMenu = LibraryHoverButton(frame: .zero)
    private let playbackButton = LibraryHoverButton(frame: .zero)
    var onPlaybackAction: ((LibraryItem) -> Void)?
    var showsPause = false { didSet {
        guard oldValue != showsPause else { return }
        updatePlaybackButton()
    } }
    private func updatePlaybackButton() {
        let title = showsPause ? "Pause wallpaper" : "Play wallpaper"
        playbackButton.image = NSImage(systemSymbolName: showsPause ? "pause.fill" : "play.fill", accessibilityDescription: title)
        playbackButton.setAccessibilityLabel(title)
    }
    @objc private func playWallpaper() {
        guard let item else { return }
        onPlaybackAction?(item)
    }
    private let hoverName = LibraryHoverName()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { setPointerHovered(true) }
    override func mouseExited(with event: NSEvent) { setPointerHovered(false) }
    func setPointerHovered(_ value: Bool) {
        let value = value && !trackingInteraction && window?.isKeyWindow == true
        guard hovered != value else { return }
        hovered = value
        updateHover()
    }
    private func updateHover() {
        quickMenu.isHidden = !hovered
        playbackButton.isHidden = !hovered
        hoverName.setHovered(hovered)
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovered ? 0.07 : 0).cgColor
        thumbnailView.layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        thumbnailView.layer?.borderWidth = 0
        needsLayout = true
    }
    @objc private func showQuickMenu() {
        guard let item, let menu = onMenu?(item) else { return }
        onClick?(item)
        menu.delegate = self
        menu.popUp(positioning: nil, at: NSPoint(x: quickMenu.frame.minX, y: quickMenu.frame.maxY), in: self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === playbackButton || hit.isDescendant(of: playbackButton) { return hit }
        if hit === quickMenu || hit.isDescendant(of: quickMenu) { return hit }
        return self
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseOrigin, let item else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x-origin.x, point.y-origin.y) > 5, let url = onDragURL?(item) else { return }
        mouseOrigin = nil
        trackingInteraction = true
        setPointerHovered(false)
        let dragging = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragging.setDraggingFrame(thumbnailView.frame, contents: thumbnailView.image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { trackingInteraction = false; onDragEnd?() }

    override var isFlipped: Bool { true }
    var onMenu: ((LibraryItem) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        onClick?(item)
        let menu = onMenu?(item)
        menu?.delegate = self
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        trackingInteraction = true
        setPointerHovered(false)
    }
    func menuDidClose(_ menu: NSMenu) {
        trackingInteraction = false
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setPointerHovered(visibleRect.contains(point))
    }
    private(set) var item: LibraryItem?
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            if isSelected, artworkTint == nil, let image = thumbnailView.image,
               image !== Self.placeholderImage { updateArtworkTint(image) }
            updateBorder()
        }
    }
    var onClick: ((LibraryItem) -> Void)?
    var onDoubleClick: ((LibraryItem) -> Void)?

    private let selectionEdge = LibrarySelectionEdge()
    private(set) var artworkTint: NSColor?
    private(set) var artworkLights: [NSColor] = []
    let thumbnailView = NSImageView()
    private func updateArtworkTint(_ image: NSImage) {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 48, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 12, height: 6))
        NSGraphicsContext.restoreGraphicsState()
        artworkLights = (0..<3).compactMap { region in
            var best: NSColor?
            var score: CGFloat = -1
            for x in (region * 4)..<(region * 4 + 4) {
                for y in 0..<6 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let candidate = color.saturationComponent * color.brightnessComponent
                    if candidate > score { score = candidate; best = color }
                }
            }
            guard let best else { return nil }
            return NSColor(calibratedHue: best.hueComponent,
                           saturation: min(1, best.saturationComponent * 1.12),
                           brightness: min(0.9, max(0.4, best.brightnessComponent)), alpha: 1)
        }
        artworkTint = artworkLights.first
        selectionEdge.tint = artworkTint

    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var thumbnailWork: DispatchWorkItem?
    private var thumbnailGeneration: UInt = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnailView.image = Self.placeholderImage
        addSubview(thumbnailView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = true
        quickMenu.image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.white.setFill()
            for x in [CGFloat(5), 12, 19] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.5, y: 10.5, width: 3, height: 3)).fill()
            }
            return true
        }
        quickMenu.imagePosition = .imageOnly
        addSubview(hoverName)
        quickMenu.isBordered = false
        quickMenu.contentTintColor = .white
        quickMenu.wantsLayer = true
        quickMenu.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        quickMenu.layer?.cornerRadius = 8
        quickMenu.target = self
        quickMenu.action = #selector(showQuickMenu)
        quickMenu.toolTip = "Wallpaper actions"
        quickMenu.isHidden = true
        addSubview(quickMenu)
        playbackButton.imagePosition = .imageOnly
        playbackButton.isBordered = false
        playbackButton.contentTintColor = .white
        playbackButton.wantsLayer = true
        playbackButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        playbackButton.layer?.cornerRadius = 8
        playbackButton.target = self
        playbackButton.action = #selector(playWallpaper)
        playbackButton.isHidden = true
        updatePlaybackButton()
        addSubview(playbackButton)
        addSubview(selectionEdge)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.isHidden = true
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        selectionEdge.frame = bounds
        let thumbHeight = bounds.width * 9.0 / 16.0
        thumbnailView.frame = bounds
        playbackButton.frame = NSRect(x: 6, y: 6, width: 34, height: 34)
        quickMenu.frame = NSRect(x: bounds.width - 40, y: 6, width: 34, height: 34)
        hoverName.frame = NSRect(x: 0, y: bounds.height - 26, width: bounds.width, height: 26)
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
            artworkTint = nil
            artworkLights = []
            selectionEdge.tint = nil

            thumbnailView.image = Self.placeholderImage
        } else {
            self.item = item
        }
        let title = SceneLibraryController.displayTitle(item.title)
        if titleLabel.stringValue != title { titleLabel.stringValue = title }
        toolTip = nil
        if hoverName.text != title { hoverName.text = title }
        thumbnailView.setAccessibilityLabel(titleLabel.stringValue)
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
        trackingInteraction = false
        hovered = false
        updateHover()
        isSelected = false
        thumbnailView.image = Self.placeholderImage
        titleLabel.stringValue = ""
        badgeLabel.stringValue = ""
    }

    /// Cached thumbnails are applied immediately when a card reappears.
    /// A background decode may finish after reuse, but generation
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
                    if self.isSelected { self.updateArtworkTint(image) }
                }
                if Thread.isMainThread { apply() }
                else { DispatchQueue.main.async(execute: apply) }
            }
        }
        thumbnailWork = work
        work.perform()
    }

    private func cancelThumbnailRequest() {
        thumbnailGeneration &+= 1
        thumbnailWork?.cancel()
        thumbnailWork = nil
    }

    private func updateBorder() {
        layer?.borderWidth = 0
        selectionEdge.isHidden = !isSelected
    }

    override func mouseDown(with event: NSEvent) {
        mouseOrigin = convert(event.locationInWindow, from: nil)
        guard let item else { return }
        if event.clickCount == 2 { onDoubleClick?(item) }
        else { onClick?(item) }
    }

    private static var placeholderImage: NSImage? {
        NSImage(systemSymbolName: "photo", accessibilityDescription: "Thumbnail")
    }
}

final class LibrarySelectionEdge: NSView {
    var tint: NSColor? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        ring.append(NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6.5, yRadius: 6.5))
        ring.windingRule = .evenOdd
        ring.addClip()
        NSGradient(colors: [.white.withAlphaComponent(0.15),
            (tint ?? .white).withAlphaComponent(0.32), .white.withAlphaComponent(0.60)])?.draw(in: bounds, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

#endif


/// Full-card-width hover caption. Overflow travels once after a reading pause.
private final class LibraryHoverName: NSView {
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private var hovered = false
    private var measuredWidth: CGFloat = -1
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            label.stringValue = text
            measuredWidth = -1
            needsLayout = true
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            surface = glass
        } else {
            let glass = NSVisualEffectView()
            glass.material = .hudWindow
            glass.blendingMode = .withinWindow
            glass.state = .active
            surface = glass
        }
        surface.autoresizingMask = [.width, .height]
        surface.frame = bounds
        addSubview(surface)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.wantsLayer = true
        addSubview(label)
        layer?.opacity = 0
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: 4,
            width: max(bounds.width - 24, label.intrinsicContentSize.width), height: 18)
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            restartMotion()
        }
    }
    func setHovered(_ hovered: Bool) {
        self.hovered = hovered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = hovered ? 1 : 0
        CATransaction.commit()
        layoutSubtreeIfNeeded()
        restartMotion()
    }
    private func restartMotion() {
        pending?.cancel()
        pending = nil
        label.layer?.removeAllAnimations()
        guard hovered else { return }
        let overflow = label.intrinsicContentSize.width - max(0, bounds.width - 24)
        guard overflow > 2, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.layer?.opacity == 1 else { return }
            let motion = CABasicAnimation(keyPath: "transform.translation.x")
            motion.fromValue = 0
            motion.toValue = -overflow
            motion.duration = Double(overflow / 28)
            motion.timingFunction = CAMediaTimingFunction(name: .linear)
            motion.fillMode = .forwards
            motion.isRemovedOnCompletion = false
            self.label.layer?.add(motion, forKey: "readName")
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
