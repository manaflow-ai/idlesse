import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

/// Native reference library with one on-demand poster, never a grid of live renderers.
final class SceneLibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    struct Item {
        let id: String
        let title: String
        let builtin: URL?
        let entry: SceneLibraryStore.Entry?
    }
    private struct OpenedItem {
        let url: URL
        let access: SceneLibraryStore.Access?
    }
    private let store: SceneLibraryStore
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSPopUpButton()
    private let sort = NSPopUpButton()
    private let viewModeControl = NSSegmentedControl(labels: ["List", "Grid"], trackingMode: .selectOne, target: nil, action: nil)
    private let collectionActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sourceActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let thumbnailQueue = DispatchQueue(label: "Idlesse.library.thumbnails", qos: .utility)
    private let thumbnails = NSCache<NSString, NSImage>()
    private let scroll = NSScrollView()
    private let right = NSStackView()
    private let gridScroll = NSScrollView()
    private let gridView = LibraryGridView()
    private let poster = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Choose a wallpaper")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let favorite = NSButton(title: "Favorite", target: nil, action: nil)
    private let apply = NSButton(title: "Set Wallpaper", target: nil, action: nil)
    private let edit = NSButton(title: "Edit in Studio", target: nil, action: nil)
    private let clearSearchButton = NSButton(title: "Clear search", target: nil, action: nil)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let remove = NSButton(title: "Remove from Library", target: nil, action: nil)
    private enum PosterRevision: Equatable, Sendable {
        case package(ScenePackageWriter.Revision)
        case file(Date?, Int?)
        static func read(_ source: URL) throws -> PosterRevision {
            var url = source
            url.removeAllCachedResourceValues()
            if url.pathExtension.lowercased() == "idlesse" { return .package(try ScenePackageWriter.revision(of: url)) }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return .file(values.contentModificationDate, values.fileSize)
        }
    }
    private var cache: [String: (image: NSImage, note: String, revision: PosterRevision)] = [:]
    private var cacheOrder: [String] = []
    private var items: [Item] = []
    private var selected: Item? {
        didSet { UserDefaults.standard.set(selected?.id, forKey: "Idlesse.library.selectedID") }
    }
    /// Launch-restore for the filter popup, matched by title and consumed by
    /// the first reload (a deleted collection falls back to All Wallpapers).
    private var pendingFilterTitle: String?
    private var task: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private var importFailureHandler: (([String]) -> Void)?
    private var activeUseAccess: [String: SceneLibraryStore.Access] = [:]
    private var activeEditAccess: [String: SceneLibraryStore.Access] = [:]
    private var generation = 0
    private var rotationTimer: Timer?
    private var rotationCollectionID: String?
    private var rotationQueue = SceneRotationQueue()
    private var rotationShuffle = false
    private var rotationMinutes = 30
    private var scheduleTimer: Timer?
    private var scheduleToken: String?

    func startSchedules() {
        guard scheduleTimer == nil else { return }
        checkSchedule()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkSchedule() }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }
    private func checkSchedule(now: Date = Date()) {
        let collection = store.scheduledCollection(at: now)
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: now)
        if let settings = collection?.playback, let start = settings.startMinute, let end = settings.endMinute,
           start > end, calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now) < end {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        let token = collection.map { "\($0.id):\(day.timeIntervalSince1970)" } ?? "outside"
        guard token != scheduleToken else { return }
        scheduleToken = token
        stopRotation(manual: false)
        if let collection { beginRotation(collection, shuffle: collection.playback?.shuffle ?? false) }
    }
    private func beginRotation(_ collection: SceneLibraryStore.Collection, shuffle: Bool) {
        rotationCollectionID = collection.id
        rotationShuffle = shuffle
        rotationMinutes = collection.playback?.minutes ?? 30
        rotationQueue = SceneRotationQueue()
        advanceRotation()
        if rotationCollectionID != nil { armRotationTimer() }
    }
    func stopRotation(manual: Bool = true) {
        if manual {
            // Record the current boundary before stopping, including before the first timer tick.
            if scheduleTimer != nil { checkSchedule() }
        }
        rotationTimer?.invalidate()
        rotationTimer = nil
        rotationCollectionID = nil
        collectionActions.item(at: 0)?.title = "Collections…"
    }
    func releaseActiveUseAccess() { activeUseAccess.removeAll() }
    func releaseActiveEditAccess() { activeEditAccess.removeAll() }
    private func retainUseAccess(_ access: SceneLibraryStore.Access?) {
        guard let access, let sourceID = access.sourceID else { return }
        activeUseAccess[sourceID] = access
    }
    private func retainEditAccess(_ access: SceneLibraryStore.Access?) {
        guard let access, let sourceID = access.sourceID else { return }
        activeEditAccess[sourceID] = access
    }
    private func advanceRotation() {
        guard let id = rotationCollectionID,
              let collection = store.catalog.collections.first(where: { $0.id == id }) else {
            stopRotation(manual: false); return
        }
        let available = allItems()
        let ids = collection.sceneIDs.filter { id in available.contains { $0.id == id } }
        guard let next = rotationQueue.next(ids, shuffle: rotationShuffle),
              let item = available.first(where: { $0.id == next }) else { stopRotation(manual: false); return }
        do {
            let opened = try open(item)
            try store.used(item.id)
            retainUseAccess(opened.access)
            onUse(opened.url)
        } catch { detail.stringValue = "Rotation: " + error.localizedDescription }
    }
    private var onUse: (URL) -> Void
    private var onEdit: (URL, Bool) -> Void
    /// Hover-peek: transient desktop preview while hovering, revert on exit.
    var onPeek: ((URL) -> Void)?
    var onEndPeek: ((Bool) -> Void)?
    private var hoverMonitor: Any?
    private var lastPeekID: String?

    init(indexURL: URL? = nil, onUse: @escaping (URL) -> Void, onEdit: @escaping (URL, Bool) -> Void) throws {
        self.onUse = onUse
        self.onEdit = onEdit
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        store = try SceneLibraryStore(file: indexURL ?? support.appendingPathComponent("Idlesse/Library/index.json"))
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false))
        window?.title = "Idlesse Library"
        window?.minSize = NSSize(width: 900, height: 520)
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        window?.center()
        window?.restoreManagedFrame(name: "IdlesseLibrary", defaultSize: NSSize(width: 1040, height: 640))
        setup()
        reload(selecting: UserDefaults.standard.string(forKey: "Idlesse.library.selectedID"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumbnails.totalCostLimit = 64 * 1024 * 1024
        search.placeholderString = "Search wallpapers"
        search.delegate = self
        filter.addItems(withTitles: ["All Wallpapers", "Included", "Imported", "Favorites", "Videos", "Interactive Scenes", "Static Images"])
        filter.target = self; filter.action = #selector(filterChanged)
        sort.addItems(withTitles: ["Name", "Recently Opened"])
        sort.target = self; sort.action = #selector(filterChanged)
        sort.selectItem(at: min(max(0, UserDefaults.standard.integer(forKey: "Idlesse.library.sortMode")), sort.numberOfItems - 1))
        pendingFilterTitle = UserDefaults.standard.string(forKey: "Idlesse.library.filterTitle")
        let add = NSButton(title: "Import…", target: self, action: #selector(addScenes))
        collectionActions.addItem(withTitle: "Collections…")
        collectionActions.target = self
        collectionActions.action = #selector(collectionAction)
        sourceActions.addItem(withTitle: "Sources…")
        sourceActions.target = self
        sourceActions.action = #selector(sourceAction)
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = UserDefaults.standard.integer(forKey: "Idlesse.library.viewMode")
        let toolbar = NSStackView(views: [search, filter, sort, viewModeControl, collectionActions, sourceActions, add])
        toolbar.spacing = 10
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Scene"))
        column.width = 280
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.style = .sourceList
        table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(doubleClickScene)
        table.setAccessibilityLabel("Scenes")
        table.registerForDraggedTypes([.fileURL])
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        gridScroll.documentView = gridView
        gridScroll.hasVerticalScroller = true
        gridScroll.hasHorizontalScroller = false
        gridScroll.autohidesScrollers = true
        gridScroll.drawsBackground = false
        gridView.autoresizingMask = [.width]
        gridView.onSelect = { [weak self] item in
            self?.selected = item
            if let index = self?.items.firstIndex(where: { $0.id == item.id }) {
                self?.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                self?.table.scrollRowToVisible(index)
            }
            self?.preview()
        }
        gridView.onDoubleAction = { [weak self] item in
            self?.selected = item
            self?.useScene()
        }
        gridView.onRequestThumbnail = { [weak self] item, callback in
            self?.requestThumbnail(for: item, completion: callback)
        }
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.black.cgColor
        poster.layer?.cornerRadius = 10
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        favorite.target = self; favorite.action = #selector(toggleFavorite)
        apply.target = self; apply.action = #selector(useScene)
        edit.target = self; edit.action = #selector(editScene)
        clearSearchButton.target = self; clearSearchButton.action = #selector(clearSearch)
        clearSearchButton.bezelStyle = .rounded
        clearSearchButton.isHidden = true
        remove.target = self; remove.action = #selector(removeScene)
        more.addItems(withTitles: ["More…", "Refresh Preview", "Make a Copy in Studio", "Remove from Library"])
        more.menu?.autoenablesItems = false
        more.target = self; more.action = #selector(moreAction)
        favorite.isBordered = false; favorite.setAccessibilityLabel("Favorite wallpaper")
        let heading = NSStackView(views: [titleLabel, NSView(), favorite])
        heading.orientation = .horizontal
        let primary = NSStackView(views: [apply, edit, more, clearSearchButton])
        primary.spacing = 10
        for button in [add, apply, edit] { button.bezelStyle = .rounded }
        apply.bezelColor = .controlAccentColor
        apply.contentTintColor = .white
        detail.font = .systemFont(ofSize: 12)
        right.setViews([poster, heading, detail, primary], in: .leading)
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        for view in [toolbar, scroll, right, gridScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        poster.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalToConstant: 300),
            right.topAnchor.constraint(equalTo: scroll.topAnchor),
            right.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 22),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            right.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            poster.widthAnchor.constraint(equalTo: right.widthAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 9.0 / 16.0),
            heading.widthAnchor.constraint(equalTo: right.widthAnchor),
            detail.widthAnchor.constraint(equalTo: right.widthAnchor),
            gridScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 18),
            gridScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            gridScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            gridScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        viewModeChanged()
    }

    @objc private func viewModeChanged() {
        let isGrid = viewModeControl.selectedSegment == 1
        UserDefaults.standard.set(viewModeControl.selectedSegment, forKey: "Idlesse.library.viewMode")
        scroll.isHidden = isGrid
        right.isHidden = isGrid
        gridScroll.isHidden = !isGrid
        if isGrid {
            gridView.update(items: items, selectedID: selected?.id)
        }
    }

    weak var hostWindow: NSWindow?
    private var presentationWindow: NSWindow? { hostWindow ?? window }
    var embedded = false
    func refreshEmbedded() {
        if selected != nil { preview() }
    }
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.restoreManagedFrame(name: "IdlesseLibrary", defaultSize: NSSize(width: 1040, height: 640))
        NSApp.activate(ignoringOtherApps: true)
        startHoverMonitor()
        if selected != nil { preview() }
    }
    private func startHoverMonitor() {
        guard hoverMonitor == nil else { return }
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleHover(event)
            return event
        }
    }
    private func stopHoverMonitor() {
        if let monitor = hoverMonitor { NSEvent.removeMonitor(monitor) }
        hoverMonitor = nil
        lastPeekID = nil
    }
    private func handleHover(_ event: NSEvent) {
        guard let window, window.isKeyWindow, onPeek != nil else {
            if lastPeekID != nil { lastPeekID = nil; onEndPeek?(true) }
            return
        }
        var hovered: Item?
        if !gridScroll.isHidden {
            let point = gridView.convert(event.locationInWindow, from: nil)
            if gridView.bounds.contains(point) {
                hovered = gridView.item(at: point).flatMap { card in items.first { $0.id == card.id } }
            }
        } else if !scroll.isHidden {
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            if row >= 0, items.indices.contains(row) { hovered = items[row] }
        }
        guard hovered?.id != lastPeekID else { return }
        lastPeekID = hovered?.id
        if let hovered {
            guard let opened = try? open(hovered) else { return }
            onPeek?(opened.url)
        } else {
            onEndPeek?(true)
        }
    }
    /// Presentation only: preserve catalog titles and filenames for round trips.
    static func displayTitle(_ title: String) -> String {
        let suffixes = ["-Restored-4K60", "-Restored-4K-HEVC", "-4K-HEVC", "-4K60"]
        guard let suffix = suffixes.first(where: { title.hasSuffix($0) }) else { return title }
        let name = String(title.dropLast(suffix.count))
        let variants = ["Kayoko-Dress": "Kayoko (Dress)", "Hina-Dress": "Hina (Dress)",
            "Hare-Camping": "Hare (Camping)", "Shiroko-Terror": "Shiroko (Terror)", "Vivian-Trust": "Vivian (Trust)"]
        return variants[name] ?? name.replacingOccurrences(of: "-", with: " ")
    }
    private func allItems() -> [Item] {
        Self.builtinScenes().map { Item(id: "builtin.\($0.name)", title: $0.title, builtin: $0.url, entry: nil) }
            + store.catalog.entries.map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
    }
    /// Shared with first-run onboarding so both list the same starters.
    static func builtinScenes() -> [(name: String, title: String, url: URL)] {
        let names = ["DeskClock", "AfterHours", "Undertow", "Fireflies", "Ripple", "AudioAurora", "Gradient", "BreathingAurora"]
        let titles = ["Desk Clock", "After Hours", "Undertow", "Fireflies", "Ripple", "Audio Aurora", "Aurora", "Breathing Aurora"]
        return zip(names, titles).compactMap { name, title in
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Scenes/\(name).idlesse"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (name, title, url)
        }
    }
    @objc private func filterChanged() {
        UserDefaults.standard.set(sort.indexOfSelectedItem, forKey: "Idlesse.library.sortMode")
        UserDefaults.standard.set(filter.selectedItem?.title ?? "All Wallpapers", forKey: "Idlesse.library.filterTitle")
        reload()
    }
    /// Forgiving subsequence match: every query character must appear in order,
    /// with bonuses for prefixes, word starts, and contiguity. Lower is better;
    /// nil means no match. Empty queries match everything at zero cost.
    static func fuzzyScore(query: String, in title: String) -> Double? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let t = Array(title.lowercased())
        if title.localizedCaseInsensitiveContains(query) {
            let contiguous = title.lowercased().contains(query.lowercased())
            let prefix = t.starts(with: q) ? 0.0 : 0.5
            return prefix + (contiguous ? 1.0 : 2.0) + Double(t.count) / 1000
        }
        var ti = 0
        var score = 4.0
        var lastMatch = -2
        for qc in q {
            var found = false
            while ti < t.count {
                let c = t[ti]
                ti += 1
                if c == qc {
                    if ti - 1 == 0 || t[ti - 2] == " " || t[ti - 2] == "-" { score -= 0.3 }
                    if ti - 1 == lastMatch + 1 { score -= 0.2 }
                    lastMatch = ti - 1
                    found = true
                    break
                }
                score += 0.05
            }
            if !found { return nil }
        }
        return score + Double(t.count) / 1000
    }
    @objc private func clearSearch() {
        search.stringValue = ""
        reload()
    }
    /// Designed empty states instead of a blank panel. Builtins mean the full
    /// list is never empty; these cover search misses and empty collections.
    private func updateEmptyState(activeCollection: SceneLibraryStore.Collection?) {
        guard items.isEmpty else {
            clearSearchButton.isHidden = true
            if selected == nil {
                titleLabel.stringValue = "Choose a wallpaper"
                detail.stringValue = "Select a scene to preview it here."
            }
            return
        }
        poster.image = nil
        apply.isEnabled = false
        edit.isEnabled = false
        if !search.stringValue.isEmpty {
            titleLabel.stringValue = "No matches"
            detail.stringValue = "Nothing matches “\(search.stringValue)”. Clear the search to browse everything, or Import… to add more."
            clearSearchButton.isHidden = false
        } else if let collection = activeCollection {
            titleLabel.stringValue = collection.name
            detail.stringValue = "This collection is empty. Use Collections… to add scenes, or play order and shuffle once it has some."
            clearSearchButton.isHidden = true
        } else {
            titleLabel.stringValue = "No scenes"
            detail.stringValue = "Import… to add your first wallpaper."
            clearSearchButton.isHidden = true
        }
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload(selecting id: String? = nil) {
        reloadSourceActions()
        let previous = id ?? selected?.id
        let collectionID = filter.selectedItem?.representedObject as? String
        let previousFilter = min(filter.indexOfSelectedItem, 6)
        filter.removeAllItems()
        filter.addItems(withTitles: ["All Wallpapers", "Included", "Imported", "Favorites", "Videos", "Interactive Scenes", "Static Images"])
        for collection in store.catalog.collections {
            filter.addItem(withTitle: "Collection: \(collection.name)")
            filter.lastItem?.representedObject = collection.id
        }
        if let collectionID, let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == collectionID }) {
            filter.selectItem(at: index)
        } else { filter.selectItem(at: max(0, previousFilter)) }
        if let pending = pendingFilterTitle {
            pendingFilterTitle = nil
            if let index = filter.itemArray.firstIndex(where: { $0.title == pending }) {
                filter.selectItem(at: index)
            }
        }
        let activeCollection = store.catalog.collections.first { $0.id == (filter.selectedItem?.representedObject as? String) }
        items = allItems().filter { item in
            let matches = Self.fuzzyScore(query: search.stringValue, in: item.title) != nil
            if let activeCollection { return matches && activeCollection.sceneIDs.contains(item.id) }
            switch filter.indexOfSelectedItem {
            case 1: return matches && item.builtin != nil
            case 2: return matches && item.entry != nil
            case 3: return matches && store.catalog.favorites.contains(item.id)
            case 4:
                let path = item.entry?.relativeMediaPath?.lowercased() ?? ""
                return matches && (path.hasSuffix(".mp4") || path.hasSuffix(".mov") || item.entry?.mediaType == "video")
            case 5:
                let path = item.entry?.relativeMediaPath?.lowercased() ?? ""
                return matches && (item.builtin != nil || path.hasSuffix(".idlesse") || item.entry?.mediaType == "scene")
            case 6:
                let path = item.entry?.relativeMediaPath?.lowercased() ?? ""
                return matches && (path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") || path.hasSuffix(".png") || path.hasSuffix(".heic") || item.entry?.mediaType == "image")
            default: return matches
            }
        }.sorted {
            if let activeCollection {
                return activeCollection.sceneIDs.firstIndex(of: $0.id)! < activeCollection.sceneIDs.firstIndex(of: $1.id)!
            }
            if !search.stringValue.isEmpty {
                let a = Self.fuzzyScore(query: search.stringValue, in: $0.title) ?? .infinity
                let b = Self.fuzzyScore(query: search.stringValue, in: $1.title) ?? .infinity
                if a != b { return a < b }
            }
            if sort.indexOfSelectedItem == 1 {
                let a = store.catalog.recent[$0.id] ?? .distantPast, b = store.catalog.recent[$1.id] ?? .distantPast
                if a != b { return a > b }
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        table.reloadData()
        gridView.update(items: items, selectedID: selected?.id)
        updateEmptyState(activeCollection: activeCollection)
        if let index = items.firstIndex(where: { $0.id == previous }) ?? (items.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            // Reloading can keep the same row number while changing its identity.
            // AppKit need not send a selection notification in that case.
            selected = items[index]
            gridView.select(id: selected?.id)
            preview()
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
            selected = nil
            gridView.select(id: nil)
            preview()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let text = NSTextField(labelWithString: (store.catalog.favorites.contains(item.id) ? "★  " : "") + item.title)
        text.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        cell.textField = text
        let thumbnail = NSImageView()
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 5
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        thumbnail.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Wallpaper preview")
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(thumbnail)
        cell.imageView = thumbnail
        requestThumbnail(for: item) { [weak thumbnail] image in
            thumbnail?.image = image
        }
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 80),
            thumbnail.heightAnchor.constraint(equalToConstant: 45),
            text.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func requestThumbnail(for item: Item, completion: @escaping (NSImage) -> Void) {
        thumbnails.countLimit = 64
        guard let opened = try? open(item) else { return }
        let posterAccess: SceneLibraryStore.Access?
        if let entry = item.entry { posterAccess = try? store.accessPoster(entry) }
        else { posterAccess = nil }
        thumbnailQueue.async { [weak self, opened, posterAccess] in
            guard let self else { return }
            let source = opened.url
            let stamp = try? source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let key = "\(source.path)|\(stamp?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(stamp?.fileSize ?? 0)" as NSString
            if let image = self.thumbnails.object(forKey: key) {
                DispatchQueue.main.async { completion(image) }
                return
            }
            let image: CGImage?
            if let explicit = posterAccess?.url, let poster = Self.listThumbnail(explicit) {
                image = poster
            } else if source.pathExtension.lowercased() == "idlesse" {
                image = Self.listThumbnail(source.appendingPathComponent("preview.jpg"))
                    ?? Self.listThumbnail(source.appendingPathComponent("preview.png"))
                    ?? Self.packageAssetThumbnail(source)
            } else if let still = Self.listThumbnail(source) ?? Self.decodedStill(source) {
                image = still
            } else if let sidecar = Self.listThumbnail(source.deletingPathExtension().appendingPathExtension("jpg"))
                ?? Self.listThumbnail(source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-Restored-4K60", with: "") + ".jpg")) {
                image = sidecar
            } else if ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 180)
                image = try? generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil)
            } else {
                image = nil
            }
            guard let image else {
                Self.appendThumbLine("THUMB-MISS \(source.path)")
                return
            }
            let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            self.thumbnails.setObject(result, forKey: key, cost: Int(image.width * image.height * 4))
            DispatchQueue.main.async { completion(result) }
        }
    }
    private static func listThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ] as CFDictionary)
    }
    /// Fallback for scene packages without a baked preview. Prefer the package's
    /// own decodable asset, then use the same bounded compositor session as
    /// Finder/Quick Look for an assetless procedural still.
    private static func packageAssetThumbnail(_ package: URL) -> CGImage? {
        guard let scene = try? LocalSceneSource.read(package) else { return nil }
        let candidates: [URL] = ([scene.assetURL] + scene.allNodes.map(\.assetURL)).compactMap { $0 }
        for url in candidates {
            if let thumb = listThumbnail(url) ?? decodedStill(url) { return thumb }
            if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 180)
                if let frame = try? generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil) {
                    return frame
                }
            }
        }
        return try? ScenePreviewRuntime.renderImmediate(
            scene: scene,
            pixelSize: CGSize(width: 320, height: 180)
        ).image
    }
    private static func appendThumbLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let path = "/tmp/idlesse-thumb.log"
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    private static func decodedStill(_ url: URL) -> CGImage? {
        guard ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let maxSide = max(full.width, full.height)
        guard maxSide > 320 else { return full }
        let scale = 320.0 / Double(maxSide)
        let w = max(1, Int((Double(full.width) * scale).rounded()))
        let h = max(1, Int((Double(full.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return full }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? full
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        selected = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        gridView.select(id: selected?.id)
        preview()
    }
    private func open(_ item: Item) throws -> OpenedItem {
        if let builtin = item.builtin { return OpenedItem(url: builtin, access: nil) }
        guard let entry = item.entry else { throw CocoaError(.fileNoSuchFile) }
        let access = try store.access(entry)
        return OpenedItem(url: access.url, access: access)
    }
    @objc private func refreshPreview() {
        if let selected { cache.removeValue(forKey: selected.id); cacheOrder.removeAll { $0 == selected.id } }
        preview()
    }
    private func preview() {
        task?.cancel(); task = nil; generation += 1
        let token = generation
        poster.image = nil
        favorite.isEnabled = selected != nil
        apply.isEnabled = selected != nil
        edit.isEnabled = selected != nil
        remove.isEnabled = selected?.entry != nil
        more.isEnabled = selected != nil
        more.item(at: 3)?.isEnabled = selected?.entry != nil
        collectionActions.removeAllItems()
        collectionActions.addItems(withTitles: [rotationTimer == nil ? "Collections…" : "Collections · Rotating every \(rotationMinutes)m", "New Collection…"])
        if filter.selectedItem?.representedObject is String {
            collectionActions.addItems(withTitles: ["Rename Collection…", "Delete Collection…",
                "Move Collection Up", "Move Collection Down", "Move Scene Earlier", "Move Scene Later", "Play Collection in Order", "Shuffle Collection", "Playback & Schedule…"])
        }
        collectionActions.addItems(withTitles: ["Change Every 5 Minutes", "Change Every 15 Minutes", "Change Every 30 Minutes", "Change Every 60 Minutes"])
        if rotationTimer != nil {
            collectionActions.addItem(withTitle: "Stop Collection Rotation")
        }
        if let selected {
            for collection in store.catalog.collections {
                collectionActions.addItem(withTitle: "\(collection.sceneIDs.contains(selected.id) ? "Remove from" : "Add to") \(collection.name)")
                collectionActions.lastItem?.representedObject = collection.id
            }
        }
        guard let selected else {
            let activeCollection = store.catalog.collections.first { $0.id == (filter.selectedItem?.representedObject as? String) }
            updateEmptyState(activeCollection: activeCollection)
            return
        }
        titleLabel.stringValue = selected.title
        favorite.title = store.catalog.favorites.contains(selected.id) ? "★" : "☆"
        detail.stringValue = "Preparing still preview…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.task = nil } }
            do {
                let opened = try self.open(selected)
                let url = opened.url
                defer { withExtendedLifetime(opened.access) {} }
                let revision = try await Task.detached(priority: .utility) { try PosterRevision.read(url) }.value
                try Task.checkCancellation()
                guard token == self.generation else { return }
                if let cached = self.cache[selected.id], cached.revision == revision {
                    self.poster.image = cached.image
                    self.detail.stringValue = cached.note
                    return
                }
                self.cache.removeValue(forKey: selected.id)
                let scene = try await LocalSceneSource().resolve(url)
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let sourceDetails = try await Self.sourceDetails(url)
                let note = sourceDetails.isEmpty ? (scene.animated ? "Animated scene" : "Scene") : String(sourceDetails.dropFirst(3))
                let frame = try await ScenePreviewRuntime.render(
                    scene: scene,
                    pixelSize: CGSize(width: 1024, height: 576)
                )
                try Task.checkCancellation()
                let image = NSImage(cgImage: frame.image, size: frame.pixelSize)
                guard token == self.generation else { return }
                let after = try await Task.detached(priority: .utility) { try PosterRevision.read(url) }.value
                try Task.checkCancellation()
                guard token == self.generation else { return }
                guard after == revision else { throw SceneError.invalid("Scene changed while preparing its preview. Select it again to retry.") }
                self.cacheOrder.removeAll { $0 == selected.id }
                while self.cacheOrder.count >= 4 { self.cache.removeValue(forKey: self.cacheOrder.removeFirst()) }
                self.cacheOrder.append(selected.id)
                self.cache[selected.id] = (image, note, revision)
                self.poster.image = image
                self.detail.stringValue = note
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.detail.stringValue = "Preview unavailable: \(error.localizedDescription). Use Relink Source… for a moved Source, or re-add a moved individual file."
            }
        }
    }

    private static func sourceDetails(_ url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov"].contains(ext) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return "" }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displayed = size.applying(transform)
            let fps = try await track.load(.nominalFrameRate)
            return " · \(Int(abs(displayed.width))) × \(Int(abs(displayed.height))) · \(String(format: "%g", fps)) fps"
        }
        guard ext != "idlesse" else { return "" }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return "" }
            return " · \(width) × \(height)"
        }.value
    }

    private func reloadSourceActions() {
        sourceActions.removeAllItems()
        sourceActions.addItem(withTitle: "Sources…")
        sourceActions.addItem(withTitle: "Add Source…")
        for source in store.catalog.sources {
            sourceActions.addItem(withTitle: "Relink \(source.name)…")
            sourceActions.lastItem?.representedObject = ["action": "relink", "id": source.id]
            sourceActions.addItem(withTitle: "Remove \(source.name)…")
            sourceActions.lastItem?.representedObject = ["action": "remove", "id": source.id]
        }
    }

    @objc private func sourceAction() {
        guard let item = sourceActions.selectedItem else { return }
        if item.title == "Add Source…" { chooseSourceFolder(relinking: nil); return }
        guard let command = item.representedObject as? [String: String],
              let action = command["action"], let id = command["id"] else { return }
        if action == "relink" { chooseSourceFolder(relinking: id); return }
        guard action == "remove", let source = store.catalog.sources.first(where: { $0.id == id }),
              let window = presentationWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(source.name) from Library?"
        alert.informativeText = "Its Library entries, favorites, recent records, and collection references are removed. Files in the Source folder stay untouched."
        alert.addButton(withTitle: "Remove Source")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let removed = Set(self.store.catalog.entries.filter { $0.sourceID == id }.map(\.id))
                try self.store.removeSource(id)
                for entryID in removed { self.cache.removeValue(forKey: entryID) }
                self.cacheOrder.removeAll { removed.contains($0) }
                self.thumbnails.removeAllObjects()
                self.reload()
                self.detail.stringValue = "Removed \(source.name) from the Library. Source files were preserved."
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }

    private func chooseSourceFolder(relinking id: String?) {
        guard let window = presentationWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = id == nil ? "Add Source" : "Relink Source"
        panel.message = id == nil
            ? "Choose a wallpaper folder. Idlesse scans it once and stores one folder access reference plus safe relative paths."
            : "Choose the folder that now contains this Source. Saved entry IDs and relative paths stay unchanged."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let root = panel.url else { return }
            if let id {
                do {
                    try self.store.relinkSource(id, to: root)
                    self.cache.removeAll(); self.cacheOrder.removeAll(); self.thumbnails.removeAllObjects()
                    self.reload()
                    self.detail.stringValue = "Source relinked."
                } catch { self.detail.stringValue = error.localizedDescription }
            } else { self.importSource(root) }
        }
    }

    private func importSource(_ root: URL) {
        guard conversionTask == nil else {
            detail.stringValue = "An import is already running. Try again when it finishes."
            return
        }
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.conversionTask = nil }
            self.detail.stringValue = "Scanning Source…"
            do {
                let drafts = try await Task.detached(priority: .utility) { try Self.scanSource(root) }.value
                try Task.checkCancellation()
                let oldIDs = Set(self.store.catalog.entries.map(\.id))
                let source = try self.store.addSource(root, entries: drafts)
                let firstNew = self.store.catalog.entries.first { $0.sourceID == source.id && !oldIDs.contains($0.id) }?.id
                    ?? self.store.catalog.entries.first { $0.sourceID == source.id }?.id
                self.search.stringValue = ""
                self.filter.selectItem(at: 2)
                self.reload(selecting: firstNew)
                self.detail.stringValue = "\(source.name): \(self.store.catalog.entries.filter { $0.sourceID == source.id }.count) wallpapers in Library."
            } catch {
                guard !Task.isCancelled else { return }
                self.detail.stringValue = "Source import failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func scanSource(_ root: URL) throws -> [SceneLibraryStore.SourceEntry] {
        let maxSourceScanItems = 20_000
        let sourceNativeExtensions: Set<String> = ["idlesse", "jpg", "jpeg", "png", "heic", "mp4", "mov"]
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw NSError(domain: "IdlesseLibrary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The Source folder could not be scanned."])
        }
        var visited = 0
        var entries: [SceneLibraryStore.SourceEntry] = []
        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            guard visited <= maxSourceScanItems else {
                throw NSError(domain: "IdlesseLibrary", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The Source contains more than 20,000 items. Choose a narrower folder."])
            }
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
            let ext = candidate.pathExtension.lowercased()
            if values.isDirectory == true {
                if ext == "idlesse" {
                    let relative = try SceneLibraryStore.relativePath(from: root, to: candidate)
                    entries.append(.init(relativeMediaPath: relative,
                        title: candidate.deletingPathExtension().lastPathComponent, mediaType: "scene"))
                    enumerator.skipDescendants()
                }
            } else if sourceNativeExtensions.contains(ext) {
                let relative = try SceneLibraryStore.relativePath(from: root, to: candidate)
                let type = ext == "idlesse" ? "scene" : (["mp4", "mov"].contains(ext) ? "video" : "image")
                entries.append(.init(relativeMediaPath: relative,
                    title: candidate.deletingPathExtension().lastPathComponent, mediaType: type))
            }
            guard entries.count <= SceneLibraryStore.maxSourceEntries else {
                throw NSError(domain: "IdlesseLibrary", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The Library supports up to 4096 source-backed entries."])
            }
        }
        if let enumerationError { throw enumerationError }
        return entries.sorted { $0.relativeMediaPath.localizedStandardCompare($1.relativeMediaPath) == .orderedAscending }
    }

    @objc private func addScenes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Add references to scenes or media. Originals stay in their current folder."
        panel.beginSheetModal(for: presentationWindow!) { [weak self] response in
            guard let self, response == .OK else { return }
            self.importScenes(panel.urls)
        }
    }
    private static func supportedImport(_ url: URL) -> Bool {
        url.isFileURL && MediaImport.supports(url)
    }
    private func droppedURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(Self.supportedImport)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !droppedURLs(info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        let urls = droppedURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        importScenes(urls)
        return true
    }
    private func importScenes(_ urls: [URL]) {
        guard conversionTask == nil else {
            detail.stringValue = "An import is already running. Try again when it finishes."
            return
        }
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.conversionTask = nil }
            var firstID: String?
            var failures: [String] = []
            for (index, source) in urls.enumerated() {
                if Task.isCancelled { return }
                self.detail.stringValue = "Importing \(index + 1) of \(urls.count)…"
                do {
                    guard Self.supportedImport(source) else {
                        throw SceneError.invalid("This file type is not supported.")
                    }
                    let convert = try await MediaImport.needsConversion(source)
                    try Task.checkCancellation()
                    let imported: URL
                    if convert {
                        self.detail.stringValue = "Converting \(index + 1) of \(urls.count)…"
                        imported = try await MediaImport.convert(source)
                    } else { imported = source }
                    try Task.checkCancellation()
                    let entry = try self.store.add(imported,
                        title: convert ? source.deletingPathExtension().lastPathComponent : nil)
                    if firstID == nil { firstID = entry.id }
                } catch {
                    if Task.isCancelled { return }
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if firstID != nil {
                self.search.stringValue = ""
                self.filter.selectItem(at: 2)
            }
            self.reload(selecting: firstID)
            if !failures.isEmpty {
                if let handler = self.importFailureHandler { handler(failures); return }
                let alert = NSAlert()
                alert.messageText = "Some scenes could not be added"
                alert.informativeText = failures.joined(separator: "\n")
                if let window = self.presentationWindow { await alert.beginSheetModal(for: window) }
            }
        }
    }
    @objc private func moreAction() {
        switch more.indexOfSelectedItem {
        case 1: refreshPreview()
        case 2: duplicateScene()
        case 3: removeScene()
        default: break
        }
    }
    @objc private func toggleFavorite() {
        guard let selected else { return }
        do { try store.favorite(selected.id); reload() } catch { detail.stringValue = error.localizedDescription }
    }
    @objc private func removeScene() {
        guard let selected, selected.entry != nil else { return }
        do { try store.remove(selected.id); cache.removeValue(forKey: selected.id); cacheOrder.removeAll { $0 == selected.id }; reload() }
        catch { detail.stringValue = error.localizedDescription }
    }
    @objc private func useScene() { act(editing: false) }
    /// Steps through the visible list for hotkeys and the menu extra.
    /// Anchors on the current selection, wrapping around.
    func cycle(delta: Int) {
        guard !items.isEmpty else { return }
        let current = selected.flatMap { item in items.firstIndex(where: { $0.id == item.id }) } ?? (delta >= 0 ? -1 : 0)
        let next = (current + delta + items.count * 2) % items.count
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        selected = items[next]
        gridView.select(id: selected?.id)
        preview()
        act(editing: false)
    }
    @objc private func collectionAction() {
        guard let item = collectionActions.selectedItem else { return }
        if ["Move Collection Up", "Move Collection Down"].contains(item.title),
           let id = filter.selectedItem?.representedObject as? String {
            do {
                try store.moveCollection(id, by: item.title == "Move Collection Up" ? -1 : 1)
                reload()
            } catch { detail.stringValue = error.localizedDescription }
            return
        }
        if ["Move Scene Earlier", "Move Scene Later"].contains(item.title),
           let id = filter.selectedItem?.representedObject as? String, let selected {
            do {
                try store.moveScene(selected.id, in: id, by: item.title == "Move Scene Earlier" ? -1 : 1)
                reload(selecting: selected.id)
            } catch { detail.stringValue = error.localizedDescription }
            return
        }
        if item.title == "Playback & Schedule…" { editPlayback(); return }
        if item.title == "Stop Collection Rotation" { stopRotation(); preview(); return }
        if item.title.hasPrefix("Change Every "), let minutes = Int(item.title.split(separator: " ")[2]) {
            if let id = filter.selectedItem?.representedObject as? String,
               let collection = store.catalog.collections.first(where: { $0.id == id }) {
                var settings = collection.playback ?? SceneLibraryStore.Playback()
                settings.minutes = minutes
                do { try store.setPlayback(id, settings) }
                catch { detail.stringValue = error.localizedDescription; return }
            }
            let editedID = filter.selectedItem?.representedObject as? String
            if rotationCollectionID == nil || editedID == rotationCollectionID {
                rotationMinutes = minutes
                if rotationTimer != nil { armRotationTimer(); preview() }
            }
            detail.stringValue = "Collections change every \(minutes) minutes."
            return
        }
        if item.title == "Play Collection in Order" || item.title == "Shuffle Collection" {
            guard let id = filter.selectedItem?.representedObject as? String,
                  let collection = store.catalog.collections.first(where: { $0.id == id }),
                  !collection.sceneIDs.isEmpty else { detail.stringValue = "Add scenes to this collection first."; return }
            stopRotation()
            var settings = collection.playback ?? SceneLibraryStore.Playback()
            settings.shuffle = item.title == "Shuffle Collection"
            do { try store.setPlayback(id, settings) }
            catch { detail.stringValue = error.localizedDescription; return }
            beginRotation(store.catalog.collections.first { $0.id == id }!, shuffle: settings.shuffle)
            preview()
            return
        }
        if let id = item.representedObject as? String, let selected {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
            catch { detail.stringValue = error.localizedDescription }
            return
        }
        let activeID = filter.selectedItem?.representedObject as? String
        let deleting = item.title == "Delete Collection…"
        let renaming = item.title == "Rename Collection…"
        guard item.title == "New Collection…" || deleting || renaming else { return }
        let alert = NSAlert()
        alert.messageText = deleting ? "Delete this collection?" : (renaming ? "Rename Collection" : "New Collection")
        alert.informativeText = deleting ? "Scenes and original files stay in your Library." : "Give this group of scenes a name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = renaming ? (store.catalog.collections.first { $0.id == activeID }?.name ?? "") : ""
        if !deleting { alert.accessoryView = field }
        alert.addButton(withTitle: deleting ? "Delete Collection" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: presentationWindow!) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            do {
                if deleting, let activeID { try self.store.removeCollection(activeID); self.filter.selectItem(at: 0) }
                else if renaming, let activeID { try self.store.renameCollection(activeID, name: field.stringValue) }
                else {
                    let collection = try self.store.createCollection(name: field.stringValue)
                    self.reload()
                    self.filter.selectItem(at: self.filter.itemArray.firstIndex { ($0.representedObject as? String) == collection.id }!)
                    self.search.stringValue = ""
                }
                self.reload()
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }
    private func editPlayback() {
        guard let id = filter.selectedItem?.representedObject as? String,
              let collection = store.catalog.collections.first(where: { $0.id == id }), let window = presentationWindow else { return }
        let settings = collection.playback ?? SceneLibraryStore.Playback()
        let enabled = NSButton(checkboxWithTitle: "Play on a schedule", target: nil, action: nil)
        enabled.state = settings.startMinute == nil ? .off : .on
        let shuffle = NSButton(checkboxWithTitle: "Shuffle without repeats", target: nil, action: nil)
        shuffle.state = settings.shuffle ? .on : .off
        let interval = NSPopUpButton()
        interval.addItems(withTitles: ["5 minutes", "15 minutes", "30 minutes", "60 minutes"])
        interval.selectItem(at: [5, 15, 30, 60].firstIndex(of: settings.minutes) ?? 2)
        func picker(_ minute: Int) -> NSDatePicker {
            let view = NSDatePicker()
            view.datePickerElements = .hourMinute
            view.datePickerStyle = .textFieldAndStepper
            view.dateValue = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date())!
            return view
        }
        let start = picker(settings.startMinute ?? 420)
        let end = picker(settings.endMinute ?? 1320)
        let dayButtons = (1...7).map { day -> NSButton in
            let button = NSButton(checkboxWithTitle: Calendar.current.shortWeekdaySymbols[day - 1], target: nil, action: nil)
            button.state = (settings.weekdays?.contains(day) ?? true) ? .on : .off
            return button
        }
        let days = NSStackView(views: dayButtons)
        days.orientation = .horizontal
        days.spacing = 8
        let stack = NSStackView(views: [enabled, days, NSTextField(labelWithString: "From"), start,
            NSTextField(labelWithString: "Until"), end, NSTextField(labelWithString: "Change scene every"), interval, shuffle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 305)
        let alert = NSAlert()
        alert.messageText = collection.name + " Playback"
        alert.informativeText = "Local time. Checked days are when a range starts; an overnight range continues into the following morning. Manual wallpaper choices last until the next boundary. Bedtime dimming stays independent."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            func minute(_ picker: NSDatePicker) -> Int {
                let c = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
                return c.hour! * 60 + c.minute!
            }
            let updated = SceneLibraryStore.Playback(minutes: [5, 15, 30, 60][interval.indexOfSelectedItem],
                shuffle: shuffle.state == .on, startMinute: enabled.state == .on ? minute(start) : nil,
                endMinute: enabled.state == .on ? minute(end) : nil,
                weekdays: enabled.state == .off ? nil : Set(dayButtons.enumerated().compactMap { $0.element.state == .on ? $0.offset + 1 : nil }))
            do {
                try self.store.setPlayback(id, updated)
                self.scheduleToken = nil
                self.checkSchedule()
                self.preview()
            } catch { self.detail.stringValue = error.localizedDescription }
        }
    }
    private func armRotationTimer() {
        rotationTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(rotationMinutes * 60), repeats: true) { [weak self] _ in
            guard let self else { return }
            let previous = self.scheduleToken
            if self.scheduleTimer != nil { self.checkSchedule() }
            if previous == self.scheduleToken { self.advanceRotation() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }
    @objc private func doubleClickScene() {
        guard items.indices.contains(table.clickedRow) else { return }
        selected = items[table.clickedRow]
        act(editing: false)
    }
    @objc private func editScene() { act(editing: true) }
    @objc private func duplicateScene() { act(editing: true, asCopy: true) }
    private func act(editing: Bool, asCopy: Bool = false) {
        guard let selected else { return }
        // A real choice replaces any hover-peek instead of reverting through it.
        lastPeekID = nil
        onEndPeek?(false)
        do {
            let opened = try open(selected)
            try store.used(selected.id)
            if editing {
                retainEditAccess(opened.access)
                onEdit(opened.url, asCopy || selected.builtin != nil)
            } else {
                stopRotation()
                retainUseAccess(opened.access)
                onUse(opened.url)
                if !embedded { window?.orderOut(nil) }
            }
        } catch { detail.stringValue = error.localizedDescription }
    }
    func windowWillClose(_ notification: Notification) {
        conversionTask?.cancel()
        task?.cancel(); generation += 1
        cache.removeAll(); cacheOrder.removeAll(); poster.image = nil
        stopHoverMonitor()
        onEndPeek?(true)
    }
    func windowDidMove(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlesseLibrary")
    }
    func windowDidResize(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlesseLibrary")
    }
    deinit {
        if let monitor = hoverMonitor { NSEvent.removeMonitor(monitor) }
        conversionTask?.cancel(); task?.cancel(); rotationTimer?.invalidate(); scheduleTimer?.invalidate()
    }

    static func smokeTest(outputURL: URL, videoURL: URL? = nil) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("revision.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: raw)
        let oldRevision = try PosterRevision.read(raw)
        try Data([1, 2]).write(to: raw)
        let newRevision = try PosterRevision.read(raw)
        precondition(oldRevision != newRevision)
        var copied = false
        var applied = false
        let controller = try SceneLibraryController(indexURL: folder.appendingPathComponent("index.json"),
            onUse: { _ in applied = true }, onEdit: { _, asCopy in copied = asCopy })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([raw as NSURL, folder.appendingPathComponent("ignored.txt") as NSURL])
        precondition(controller.droppedURLs(pasteboard) == [raw])
        precondition(controller.items.count == 8 && controller.items.contains { $0.title == "Desk Clock" })
        precondition(controller.sourceActions.itemArray.contains { $0.title == "Add Source…" })
        let index = controller.items.firstIndex { $0.title == "Undertow" }!
        controller.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        controller.selected = controller.items[index]
        controller.preview()
        let deadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let colors = NSBitmapImageRep(data: controller.poster.image!.tiffRepresentation!)!
        var hasWarmColor = false
        for y in stride(from: 0, to: colors.pixelsHigh, by: 32) {
            for x in stride(from: 0, to: colors.pixelsWide, by: 32) {
                if let color = colors.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent - color.blueComponent > 0.2 {
                    hasWarmColor = true
                }
            }
        }
        precondition(hasWarmColor, "Undertow's copper poster must preserve BGRA channel order")
        controller.editScene()
        precondition(copied, "Built-in edits must become drafts")
        controller.doubleClickScene()
        precondition(!applied, "An empty-space double-click must not apply the selection")
        controller.toggleFavorite()
        controller.filter.selectItem(at: 3)
        controller.reload()
        precondition(controller.items.count == 1 && controller.items[0].title == "Undertow")
        precondition(controller.selected?.id == controller.items[0].id)
        let collection = try controller.store.createCollection(name: "Psychedelic")
        try controller.store.toggleMembership(sceneID: controller.selected!.id, collectionID: collection.id)
        controller.reload()
        controller.filter.selectItem(at: controller.filter.itemArray.firstIndex { ($0.representedObject as? String) == collection.id }!)
        controller.reload()
        precondition(controller.items.count == 1 && controller.selected?.title == "Undertow")
        precondition(controller.collectionActions.itemArray.contains { $0.title == "Rename Collection…" })
        controller.collectionActions.selectItem(withTitle: "Shuffle Collection")
        controller.collectionAction()
        precondition(applied && controller.rotationTimer != nil)
        applied = false
        controller.rotationTimer?.fire()
        precondition(applied, "Rotation timer must apply the next scene")
        controller.stopRotation()
        precondition(controller.rotationTimer == nil && controller.rotationCollectionID == nil)
        try controller.store.setPlayback(collection.id, .init(startMinute: 0, endMinute: 720))
        let today = Calendar.current.startOfDay(for: Date())
        let morning = Calendar.current.date(byAdding: .hour, value: 1, to: today)!
        applied = false
        controller.checkSchedule(now: morning)
        precondition(applied && controller.rotationTimer != nil)
        controller.stopRotation()
        applied = false
        controller.checkSchedule(now: morning.addingTimeInterval(60))
        precondition(!applied && controller.rotationTimer == nil, "Manual stop must last through this schedule window")
        controller.checkSchedule(now: Calendar.current.date(byAdding: .day, value: 1, to: morning)!)
        precondition(applied && controller.rotationTimer != nil, "A new daily boundary must resume scheduling even after a missed day")
        controller.stopRotation()
        try controller.store.setPlayback(collection.id, .init())
        controller.preview()
        let posterDeadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < posterDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let root = controller.window!.contentView!
        root.layoutSubtreeIfNeeded()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL, options: .withoutOverwriting)
        controller.search.stringValue = "No matching scene"
        controller.reload()
        precondition(controller.items.isEmpty && !controller.apply.isEnabled)
        precondition(controller.titleLabel.stringValue == "No matches" && !controller.clearSearchButton.isHidden,
            "Search misses need an explicit empty state with a way out")
        controller.filter.selectItem(at: 0)
        controller.clearSearch()
        precondition(controller.search.stringValue.isEmpty && controller.items.count == 8 && controller.clearSearchButton.isHidden,
            "Clearing the search must restore browsing")
        precondition(Self.fuzzyScore(query: "", in: "Anything") == 0)
        precondition(Self.fuzzyScore(query: "undertow", in: "Undertow") != nil)
        precondition(Self.fuzzyScore(query: "xqz", in: "Undertow") == nil)
        precondition(Self.fuzzyScore(query: "aur", in: "Aurora")! < Self.fuzzyScore(query: "aur", in: "Breathing Aurora")!,
            "Prefix matches must outrank scattered ones")
        try OnboardingController.smokeTest(builtins: controller.items.compactMap {
            guard let url = $0.builtin else { return nil }
            return (title: $0.title, url: url)
        })

        func waitForThumbnail(_ item: Item, label: String) -> NSImage {
            var result: NSImage?
            controller.requestThumbnail(for: item) { result = $0 }
            let thumbnailDeadline = Date().addingTimeInterval(10)
            while result == nil && Date() < thumbnailDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(result != nil, "\(label) procedural thumbnail timed out")
            return result!
        }
        let fireflies = controller.items.first { $0.title == "Fireflies" }!
        let fireflyThumbnail = waitForThumbnail(fireflies, label: "Fireflies")
        precondition(Int(fireflyThumbnail.size.width) == 320 && Int(fireflyThumbnail.size.height) == 180,
                     "Particle thumbnails must use the bounded 320×180 probe")
        let shaderPackage = folder.appendingPathComponent("Shader Probe.idlesse")
        try ScenePackageWriter.write(SceneDescriptor(title: "Shader Probe",
            nodes: [SceneNode(content: .shader(.init()))]), to: shaderPackage)
        let shaderItem = Item(id: "smoke.shader", title: "Shader Probe", builtin: shaderPackage, entry: nil)
        let shaderThumbnail = waitForThumbnail(shaderItem, label: "Shader")
        precondition(Int(shaderThumbnail.size.width) == 320 && Int(shaderThumbnail.size.height) == 180,
                     "Shader thumbnails must use the bounded 320×180 probe")

        if let videoURL {
            let invalidMedia = folder.appendingPathComponent("invalid.webm")
            try Data("not a video".utf8).write(to: invalidMedia)
            var importFailures: [String] = []
            controller.importFailureHandler = { importFailures = $0 }
            controller.importScenes([invalidMedia, videoURL])
            let importDeadline = Date().addingTimeInterval(10)
            while controller.conversionTask != nil && Date() < importDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(controller.conversionTask == nil, "Async import timed out")
            precondition(importFailures.count == 1 && importFailures[0].contains("invalid.webm"),
                         "Failed conversion must be reported while later native media imports")
            precondition(controller.search.stringValue.isEmpty && controller.filter.indexOfSelectedItem == 2)
            precondition(controller.items.count == 1 && controller.selected?.id == controller.items[0].id,
                         "Import must reveal and select its scene despite previous search/filter")
            let videoDeadline = Date().addingTimeInterval(10)
            while controller.task != nil && Date() < videoDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(controller.poster.image != nil && controller.detail.stringValue.contains("fps") && controller.detail.stringValue.contains("×"), controller.detail.stringValue)
            // A transparent video must produce black, not a thumbnail of the raw asset.
            var video = SceneNode(content: .video(videoURL))
            video.opacity = 0
            let package = folder.appendingPathComponent("Transparent Video.idlesse")
            try ScenePackageWriter.write(SceneDescriptor(title: "Transparent Video", nodes: [video]), to: package)
            controller.importScenes([package])
            let compositionDeadline = Date().addingTimeInterval(10)
            while (controller.conversionTask != nil || controller.task != nil) && Date() < compositionDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(controller.poster.image != nil, controller.detail.stringValue)
            let pixels = NSBitmapImageRep(data: controller.poster.image!.tiffRepresentation!)!
            for y in stride(from: 0, to: pixels.pixelsHigh, by: 32) {
                for x in stride(from: 0, to: pixels.pixelsWide, by: 32) {
                    let color = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    precondition(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.01,
                                 "Video posters must respect scene opacity instead of exposing the raw frame")
                }
            }
        }
        controller.window?.close()
        print("Library UI checks passed: built-in poster/color, favorites, search, source controls, draft routing, procedural thumbnails\(videoURL == nil ? "" : ", composed video poster"); offscreen snapshot saved")
    }
}
