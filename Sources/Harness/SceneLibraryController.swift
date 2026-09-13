import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import CoreImage

/// Native reference library with one on-demand poster, never a grid of live renderers.
final class SceneLibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
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
    enum Scope: Hashable {
        case library, favorites, recent, collection(String)
    }
    private(set) var scope: Scope = .library
    private var selectionByScope: [Scope: String] = [:]
    private var homeNavigation = false
    var onScopeChange: ((Scope) -> Void)?
    private let mediaFilter = LibraryFilterButton()
    private let importButton = LibraryHoverButton(title: "Add Wallpapers…", target: nil, action: nil)

    /// Home owns the toolbar, while Library retains the search query and import actions.
    func makeSearchToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        if let stack = search.superview as? NSStackView { stack.removeArrangedSubview(search); stack.isHidden = true }
        search.removeFromSuperview()
        let item = NSToolbarItem(itemIdentifier: identifier)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        search.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(search)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 300),
            host.heightAnchor.constraint(equalToConstant: 28),
            search.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            search.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: 28),
        ])
        item.view = host
        item.label = "Search Wallpapers"
        item.toolTip = "Search the current Library selection"
        return item
    }

    func makeImportToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        if let stack = importButton.superview as? NSStackView { stack.removeArrangedSubview(importButton) }
        importButton.removeFromSuperview()
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Import Wallpapers"
        let button = LibraryHoverButton(title: "Add Wallpapers…", target: self, action: #selector(addScenes))
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .texturedRounded
        item.view = button
        item.toolTip = "Import wallpapers…"
        item.target = self
        item.action = #selector(addScenes)
        return item
    }

    func importWallpapers() { addScenes() }

    func setSearchEnabled(_ enabled: Bool) { search.isEnabled = enabled }

    private func revealImportedScope() {
        guard homeNavigation else { return }
        scope = .library
        mediaFilter.selectItem(at: 0)
        onScopeChange?(.library)
    }
    var rotationSummary: String? {
        rotationTimer == nil ? nil : "Rotating every \(rotationMinutes)m"
    }
    func useHomeNavigation() {
        homeNavigation = true
        filter.isHidden = true
        mediaFilter.isHidden = false
        pendingFilterTitle = nil
        setScope(.library)
    }
    func setScope(_ scope: Scope) {
        let changed = self.scope != scope
        if changed, let selected { selectionByScope[self.scope] = selected.id }
        self.scope = scope
        pendingFilterTitle = nil
        filter.selectItem(at: 0)
        if case .collection(let id) = scope,
           let index = filter.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
            filter.selectItem(at: index)
        }
        reload(selecting: changed ? selectionByScope[scope] : nil)
    }
    private let inspectorButton = LibraryHoverButton(frame: .zero)
    private let libraryActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let browserSplit = NSSplitViewController()
    private var inspectorItem: NSSplitViewItem?
    private let store: SceneLibraryStore
    private let table = NSTableView()
    private let search: NSSearchField = {
        let field = NSSearchField()
        field.cell = CenteredLibrarySearchCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.font = .systemFont(ofSize: 13)
        return field
    }()
    private var pendingSearch: DispatchWorkItem?
    private let filter = NSPopUpButton()
    private let sort = LibraryFilterButton()
    private let refinementButton = LibraryHoverButton(title: "Filters", target: nil, action: nil)
    private var favoriteOnly = false
    private var unopenedOnly = false
    private var sourceFilterID: String?
    private let viewModeControl = NSSegmentedControl(labels: ["List", "Grid"], trackingMode: .selectOne, target: nil, action: nil)
    private let collectionActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sourceActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Idlesse.library.thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var pendingThumbnails: [String: [(NSImage) -> Void]] = [:]
    private var resolvedMediaURLs: [String: URL] = [:]
    private var thumbnailRevisions: [String: UInt] = [:]
    private var thumbnailJobsStarted = 0
    private let scroll = NSScrollView()
    private let right = NSStackView()
    private let gridScroll = NSScrollView()
    private let gridView = LibraryGridView()
    private let poster = LibraryDraggablePreview()
    private let previewStage = NSView()
    private var displayCanvas: DisplayAssignmentViewController?
    private var dragAccess: OpenedItem?
    func installDisplayCanvas(wallpaper: WallpaperController) {
        guard displayCanvas == nil else { return }
        let canvas = DisplayAssignmentViewController(wallpaper: wallpaper, compact: true)
        canvas.requestArtwork = { [weak self] url, done in self?.requestPlaybackArtwork(url, completion: done) }
        displayCanvas = canvas
        right.addArrangedSubview(canvas.view)
        canvas.view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        canvas.activate()
    }
    private var posterItemID: String?
    private var knownDetails: [String: String] = [:]
    private func setDetail(_ value: String) {
        if detail.stringValue != value { detail.stringValue = value }
    }
    private let livePreviewButton = LibraryHoverButton(title: "Play Preview", target: nil, action: nil)
    private let previewHost = ScenePreviewHost()
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = 0
    private var liveAccess: SceneLibraryStore.Access?
    private let taskStatus = NSTextField(labelWithString: "")
    private let dismissStatus = LibraryHoverButton(title: "Dismiss", target: nil, action: nil)
    private let taskStatusRow = NSStackView()
    private var browserBottom: NSLayoutConstraint?
    private let desktopStatus = NSTextField(labelWithString: "✓ On Desktop")
    private var playingURL: URL?
    func updatePlayingURL(_ url: URL?) {
        let next = url?.standardizedFileURL
        guard next != playingURL else { return }
        playingURL = next
        updateApplyState()
    }
    private func updateApplyState() {
        let isPlaying: Bool
        if let selected, let playingURL {
            isPlaying = (try? open(selected).url.standardizedFileURL) == playingURL
        } else { isPlaying = false }
        apply.title = isPlaying ? "✓ On Desktop" : "Set Wallpaper"
        apply.isEnabled = selected != nil && !isPlaying
        apply.isHidden = false
        desktopStatus.isHidden = true
    }
    private var previewObservers: [NSObjectProtocol] = []
    private let titleLabel = NSTextField(labelWithString: "Choose a wallpaper")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let favorite = LibraryHoverButton(title: "Favorite", target: nil, action: nil)
    private let apply = LibraryHoverButton(title: "Set Wallpaper", target: nil, action: nil)
    private let edit = LibraryHoverButton(title: "Edit in Studio", target: nil, action: nil)
    private let adjust = LibraryHoverButton(title: "Adjust…", target: nil, action: nil)
    private let clearSearchButton = LibraryHoverButton(title: "Clear search", target: nil, action: nil)
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let remove = LibraryHoverButton(title: "Remove from Library", target: nil, action: nil)
    private enum PosterRevision: Equatable, Sendable {
        case package(ScenePackageWriter.Revision)
        case file(Date?, Int?, Data?)
        static func read(_ source: URL) throws -> PosterRevision {
            var url = source
            url.removeAllCachedResourceValues()
            if url.pathExtension.lowercased() == "idlesse" { return .package(try ScenePackageWriter.revision(of: url)) }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // A crop/color save changes the sidecar, not the movie. Keep the
            // bounded sidecar bytes in the revision so even same-size edits
            // invalidate a previously rendered preview.
            let handle = try? FileHandle(forReadingFrom: SceneFraming.url(for: url))
            defer { try? handle?.close() }
            let framing = try handle?.read(upToCount: 4097)
            return .file(values.contentModificationDate, values.fileSize, framing)
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
        } catch { reportTask("Rotation: " + error.localizedDescription) }
    }
    private var onUse: (URL) -> Void
    /// Opens the framing editor for an imported picture or video, handing over
    /// the access that keeps its folder readable and writable while it is open.
    var onFrame: ((URL, AnyObject?) -> Void)?
    private var onEdit: (URL, Bool) -> Void

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
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            previewObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name != NSWindow.didChangeOcclusionStateNotification || self.window?.occlusionState.contains(.visible) != true {
                    self.stopLivePreview()
                }
            })
        }
        previewObservers.append(NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
            object: browserSplit.splitView, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.inspectorItem?.isCollapsed == true { self.stopLivePreview() }
        })
        reload(selecting: UserDefaults.standard.string(forKey: "Idlesse.library.selectedID"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = LibrarySurfaceColors.content.cgColor
        // Keep a typical personal library resident while retaining a byte ceiling.
        // 130 decoded 320×180 posters occupy about 29 MiB.
        thumbnails.countLimit = 256
        thumbnails.totalCostLimit = 96 * 1024 * 1024
        search.placeholderString = ""
        search.setAccessibilityLabel("Search wallpapers")
        search.delegate = self
        search.target = self
        search.action = #selector(commitSearch)
        search.sendsWholeSearchString = true
        filter.addItems(withTitles: ["All Wallpapers", "Included", "Imported", "Favorites", "Videos", "Interactive Scenes", "Static Images"])
        filter.target = self; filter.action = #selector(filterChanged)
        sort.addItems(withTitles: ["Name A–Z", "Recently Opened", "Name Z–A", "Oldest Opened"])
        sort.target = self; sort.action = #selector(filterChanged)
        sort.selectItem(at: min(max(0, UserDefaults.standard.integer(forKey: "Idlesse.library.sortMode")), sort.numberOfItems - 1))
        pendingFilterTitle = UserDefaults.standard.string(forKey: "Idlesse.library.filterTitle")
        importButton.target = self
        importButton.action = #selector(addScenes)
        collectionActions.addItem(withTitle: "Collections…")
        collectionActions.target = self
        collectionActions.action = #selector(collectionAction)
        sourceActions.addItem(withTitle: "Sources…")
        sourceActions.target = self
        sourceActions.action = #selector(sourceAction)
        viewModeControl.selectedSegmentBezelColor = NSColor.controlColor
        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged)
        viewModeControl.selectedSegment = (UserDefaults.standard.object(forKey: "Idlesse.library.viewMode") as? Int) ?? 1
        mediaFilter.addItems(withTitles: ["All Media", "Videos", "Scenes", "Images"])
        mediaFilter.isHidden = true
        mediaFilter.target = self
        mediaFilter.action = #selector(mediaFilterChanged)
        for popup in [mediaFilter, sort] {
            popup.bezelStyle = .rounded
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 13, weight: .regular)
            (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            popup.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            popup.imagePosition = .imageTrailing
        }
        libraryActions.isBordered = false
        libraryActions.font = .systemFont(ofSize: 13, weight: .regular)
        viewModeControl.setLabel("", forSegment: 0)
        viewModeControl.setLabel("", forSegment: 1)
        viewModeControl.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 0)
        viewModeControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid"), forSegment: 1)
        viewModeControl.setToolTip("List view", forSegment: 0)
        viewModeControl.setToolTip("Gallery view", forSegment: 1)
        inspectorButton.setButtonType(.pushOnPushOff)
        inspectorButton.bezelStyle = .texturedRounded
        inspectorButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
        inspectorButton.imagePosition = .imageOnly
        inspectorButton.setAccessibilityLabel("Inspector")
        libraryActions.addItem(withTitle: "Organize")
        libraryActions.toolTip = "Collections and sources"
        libraryActions.setAccessibilityLabel("Organize library")
        libraryActions.menu?.delegate = self
        inspectorButton.target = self
        inspectorButton.action = #selector(toggleInspector)
        inspectorButton.state = UserDefaults.standard.object(forKey: "Idlesse.library.inspectorVisible") as? Bool == false ? .off : .on
        inspectorButton.toolTip = inspectorButton.state == .on ? "Hide Inspector" : "Show Inspector"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        importButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add wallpapers")
        importButton.imagePosition = .imageOnly
        importButton.isBordered = false
        importButton.toolTip = "Add wallpapers…"
        importButton.setAccessibilityLabel("Add wallpapers")
        importButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let searchRow = NSStackView(views: [search])
        searchRow.spacing = 12
        refinementButton.isBordered = false
        refinementButton.font = .systemFont(ofSize: 13)
        refinementButton.target = self
        refinementButton.action = #selector(showRefinements)
        let browsingRow = NSStackView(views: [filter, mediaFilter, refinementButton, sort, viewModeControl, inspectorButton, libraryActions, spacer, importButton])
        browsingRow.spacing = 10
        let toolbar = NSStackView(views: homeNavigation ? [browsingRow] : [searchRow, browsingRow])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 6
        if !homeNavigation { searchRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true }
        browsingRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
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
            guard let self, self.selected?.id != item.id else { return }
            self.selected = item
            if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                self.table.scrollRowToVisible(index)
            }
            self.preview()
        }
        gridView.onMenu = { [weak self] item in
            let menu = NSMenu()
            guard let self else { return menu }
            self.selected = item
            menu.autoenablesItems = false
            for (title, action) in [(self.apply.isEnabled ? "Set Wallpaper" : "On Desktop", #selector(useScene)),
                                    ("Adjust…", #selector(frameScene)),
                                    ("Edit in Studio", #selector(editScene)),
                                    ("Make a Copy in Studio", #selector(duplicateScene)),
                                    (self.store.catalog.favorites.contains(item.id) ? "Remove Favorite" : "Add Favorite", #selector(toggleFavorite))] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self
                if action == #selector(useScene) { entry.isEnabled = self.apply.isEnabled }
                if action == #selector(frameScene) { entry.isEnabled = self.canAdjustSelection }
            }
            return menu
        }
        gridView.onDoubleAction = { [weak self] item in
            self?.selected = item
            self?.useScene()
        }
        gridView.onDragURL = { [weak self] item in
            guard let self, let opened = try? self.open(item) else { return nil }
            self.dragAccess = opened
            return opened.url
        }
        gridView.onDragEnd = { [weak self] in self?.dragAccess = nil }
        poster.onDragURL = { [weak self] in
            guard let self, let selected = self.selected, let opened = try? self.open(selected) else { return nil }
            self.dragAccess = opened
            return opened.url
        }
        poster.onDragEnd = { [weak self] in self?.dragAccess = nil }
        gridView.onRequestThumbnail = { [weak self] item, callback in
            self?.requestThumbnail(for: item, completion: callback)
        }
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true
        poster.layer?.backgroundColor = NSColor.black.cgColor
        poster.layer?.cornerRadius = 0
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        favorite.target = self; favorite.action = #selector(toggleFavorite)
        apply.target = self; apply.action = #selector(useScene)
        edit.target = self; edit.action = #selector(editScene)
        adjust.target = self; adjust.action = #selector(frameScene)
        adjust.bezelStyle = .rounded
        adjust.toolTip = "Adjust crop and picture settings without changing the source file"
        clearSearchButton.target = self; clearSearchButton.action = #selector(clearSearch)
        clearSearchButton.bezelStyle = .rounded
        clearSearchButton.isHidden = true
        remove.target = self; remove.action = #selector(removeScene)
        more.addItems(withTitles: ["More…", "Refresh Preview", "Make a Copy in Studio", "Remove from Library", "Adjust Framing…"])
        more.menu?.autoenablesItems = false
        more.target = self; more.action = #selector(moreAction)
        favorite.isBordered = false; favorite.setAccessibilityLabel("Favorite wallpaper")
        let heading = NSStackView(views: [titleLabel, NSView(), favorite])
        heading.orientation = .horizontal
        livePreviewButton.target = self
        livePreviewButton.action = #selector(toggleLivePreview)
        livePreviewButton.bezelStyle = .rounded
        livePreviewButton.toolTip = "Play a muted preview here without changing the desktop"
        desktopStatus.textColor = .secondaryLabelColor
        desktopStatus.font = .systemFont(ofSize: 12, weight: .medium)
        desktopStatus.isHidden = true
        livePreviewButton.isBordered = false
        livePreviewButton.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Preview")
        livePreviewButton.imagePosition = .imageLeading
        let playbackActions = NSStackView(views: [livePreviewButton, NSView(), desktopStatus, apply])
        playbackActions.spacing = 8
        adjust.isBordered = false
        adjust.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        adjust.imagePosition = .imageLeading
        edit.isBordered = false
        edit.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        edit.imagePosition = .imageLeading
        more.isBordered = false
        let editingActions = NSStackView(views: [adjust, NSView(), edit, more])
        editingActions.spacing = 12
        let primary = NSStackView(views: [editingActions, clearSearchButton])
        primary.spacing = 12
        apply.bezelStyle = .rounded
        apply.isBordered = false
        apply.wantsLayer = true
        apply.layer?.cornerRadius = 7
        apply.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        apply.widthAnchor.constraint(equalToConstant: 128).isActive = true
        apply.heightAnchor.constraint(equalToConstant: 28).isActive = true
        apply.contentTintColor = .white
        detail.font = .systemFont(ofSize: 12)
        let glassControls = NSVisualEffectView()
        glassControls.material = .hudWindow
        glassControls.blendingMode = .withinWindow
        glassControls.state = .active
        glassControls.wantsLayer = true
        glassControls.layer?.cornerRadius = 8
        glassControls.layer?.masksToBounds = true
        previewStage.addSubview(poster)
        previewStage.addSubview(glassControls)
        glassControls.addSubview(playbackActions)
        for view in [poster, glassControls, playbackActions] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            poster.leadingAnchor.constraint(equalTo: previewStage.leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: previewStage.trailingAnchor),
            poster.topAnchor.constraint(equalTo: previewStage.topAnchor),
            poster.bottomAnchor.constraint(equalTo: previewStage.bottomAnchor),
            glassControls.leadingAnchor.constraint(equalTo: previewStage.leadingAnchor, constant: 8),
            glassControls.trailingAnchor.constraint(equalTo: previewStage.trailingAnchor, constant: -8),
            glassControls.bottomAnchor.constraint(equalTo: previewStage.bottomAnchor, constant: -8),
            playbackActions.leadingAnchor.constraint(equalTo: glassControls.leadingAnchor, constant: 8),
            playbackActions.trailingAnchor.constraint(equalTo: glassControls.trailingAnchor, constant: -8),
            playbackActions.topAnchor.constraint(equalTo: glassControls.topAnchor, constant: 5),
            playbackActions.bottomAnchor.constraint(equalTo: glassControls.bottomAnchor, constant: -5),
        ])
        right.setViews([previewStage, heading, detail, primary], in: .leading)
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        browserSplit.splitView = LibrarySplitView()
        let browser = NSView()
        let browserController = NSViewController()
        browserController.view = browser
        let browserItem = NSSplitViewItem(viewController: browserController)
        browserItem.minimumThickness = 420
        let inspectorController = NSViewController()
        let inspector = NSView()
        inspector.wantsLayer = true
        inspector.layer?.backgroundColor = LibrarySurfaceColors.content.cgColor
        inspectorController.view = inspector
        let pane = NSSplitViewItem(viewController: inspectorController)
        pane.minimumThickness = 300
        pane.maximumThickness = 380
        pane.preferredThicknessFraction = 0.32
        pane.canCollapse = true
        inspectorItem = pane
        browserSplit.addSplitViewItem(browserItem)
        browserSplit.addSplitViewItem(pane)
        browserSplit.splitView.isVertical = true
        browserSplit.splitView.autosaveName = "IdlesseLibraryInspector"
        browserSplit.splitView.dividerStyle = .thin
        taskStatus.font = .systemFont(ofSize: 12)
        taskStatus.textColor = .secondaryLabelColor
        taskStatus.lineBreakMode = .byTruncatingMiddle
        dismissStatus.target = self
        dismissStatus.action = #selector(clearTaskStatus)
        dismissStatus.bezelStyle = .rounded
        taskStatusRow.setViews([taskStatus, dismissStatus], in: .leading)
        taskStatusRow.orientation = .horizontal
        taskStatusRow.spacing = 12
        taskStatusRow.isHidden = true
        for view in [toolbar, browserSplit.view, taskStatusRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [scroll, gridScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            browser.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: browser.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: browser.trailingAnchor),
                view.topAnchor.constraint(equalTo: browser.topAnchor),
                view.bottomAnchor.constraint(equalTo: browser.bottomAnchor),
            ])
        }
        right.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(right)
        poster.translatesAutoresizingMaskIntoConstraints = false
        primary.orientation = .vertical
        primary.alignment = .leading
        browserBottom = browserSplit.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        browserBottom?.isActive = true
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 2),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            browserSplit.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            browserSplit.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserSplit.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            taskStatusRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            taskStatusRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            taskStatusRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            right.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 12),
            right.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -16),
            right.bottomAnchor.constraint(lessThanOrEqualTo: inspector.bottomAnchor, constant: -12),
            previewStage.widthAnchor.constraint(equalTo: right.widthAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 9.0 / 16.0),
            heading.widthAnchor.constraint(equalTo: right.widthAnchor),

            editingActions.widthAnchor.constraint(equalTo: right.widthAnchor),
            detail.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        pane.isCollapsed = inspectorButton.state == .off
        viewModeChanged()
    }

    @objc private func viewModeChanged() {
        let isGrid = viewModeControl.selectedSegment == 1
        UserDefaults.standard.set(viewModeControl.selectedSegment, forKey: "Idlesse.library.viewMode")
        scroll.isHidden = isGrid
        gridScroll.isHidden = !isGrid
        if isGrid {
            gridView.update(items: items, selectedID: selected?.id)
            gridView.revealSelection()
        } else if let index = items.firstIndex(where: { $0.id == selected?.id }) {
            table.scrollRowToVisible(index)
        }
    }

    @objc private func mediaFilterChanged() { reload() }

    @objc private func toggleInspector() {
        let visible = inspectorButton.state == .on
        inspectorButton.toolTip = visible ? "Hide Inspector" : "Show Inspector"
        inspectorItem?.isCollapsed = !visible
        if !visible { stopLivePreview() }
        UserDefaults.standard.set(visible, forKey: "Idlesse.library.inspectorVisible")
    }

    weak var hostWindow: NSWindow?
    private var presentationWindow: NSWindow? { hostWindow ?? window }
    var embedded = false
    func refreshEmbedded() { if selected != nil { preview() } }
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.restoreManagedFrame(name: "IdlesseLibrary", defaultSize: NSSize(width: 1040, height: 640))
        NSApp.activate(ignoringOtherApps: true)
        if selected != nil { preview() }
    }
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
            + store.catalog.entries.filter { $0.availability == .present }
                .map { Item(id: $0.id, title: Self.displayTitle($0.title), builtin: nil, entry: $0) }
    }
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
    @objc private func showRefinements() {
        let menu = NSMenu()
        func option(_ title: String, _ tag: Int, _ checked: Bool, _ source: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(refineLibrary(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; item.state = checked ? .on : .off
            item.representedObject = source
            return item
        }
        menu.addItem(option("Favorites only", 1, favoriteOnly))
        menu.addItem(option("Never opened", 2, unopenedOnly))
        menu.addItem(.separator())
        let sources = NSMenu()
        sources.addItem(option("All sources", 3, sourceFilterID == nil))
        sources.addItem(option("Imported wallpapers", 3, sourceFilterID == "imported", "imported"))
        sources.addItem(option("Included wallpapers", 3, sourceFilterID == "included", "included"))
        for source in store.catalog.sources {
            sources.addItem(option(source.name, 3, sourceFilterID == source.id, source.id))
        }
        let sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        sourceItem.submenu = sources; menu.addItem(sourceItem)
        menu.addItem(.separator())
        menu.addItem(option("Reset filters", 4, false))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: refinementButton.bounds.minY), in: refinementButton)
    }
    @objc private func refineLibrary(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: favoriteOnly.toggle()
        case 2: unopenedOnly.toggle()
        case 3: sourceFilterID = sender.representedObject as? String
        default:
            favoriteOnly = false; unopenedOnly = false; sourceFilterID = nil
            mediaFilter.selectItem(at: 0)
        }
        reload()
    }

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
    @objc private func clearSearch() { search.stringValue = ""; reload() }
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
        } else if favoriteOnly || unopenedOnly || sourceFilterID != nil {
            titleLabel.stringValue = "No matching wallpapers"
            detail.stringValue = "Try another combination, or choose Filters → Reset filters."
            clearSearchButton.isHidden = true
        } else if homeNavigation && scope == .favorites && mediaFilter.indexOfSelectedItem == 0 {
            titleLabel.stringValue = "No favorites yet"
            detail.stringValue = "Star a wallpaper to find it here."
            clearSearchButton.isHidden = true
        } else if homeNavigation && scope == .recent && mediaFilter.indexOfSelectedItem == 0 {
            titleLabel.stringValue = "No recent wallpapers"
            detail.stringValue = "Wallpapers you open appear here."
            clearSearchButton.isHidden = true
        } else if homeNavigation && mediaFilter.indexOfSelectedItem > 0 {
            titleLabel.stringValue = "No matching media"
            detail.stringValue = "Choose All Media to browse this view."
            clearSearchButton.isHidden = true
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
    func controlTextDidChange(_ obj: Notification) {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pendingSearch = nil; self?.reload() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    @objc private func commitSearch() { reload() }
    private func reload(selecting id: String? = nil) {
        pendingSearch?.cancel()
        pendingSearch = nil
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
        let oldIDs = items.map(\.id)
        let catalog = allItems()
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        sort.isEnabled = query.isEmpty && activeCollection == nil && scope != .recent
        sort.toolTip = !query.isEmpty ? "Search results are ordered by relevance" : (activeCollection != nil ? "Collection order" : "Sort wallpapers")
        let scores: [String: Double] = query.isEmpty ? [:] : catalog.reduce(into: [:]) { scores, item in
            scores[item.id] = Self.fuzzyScore(query: query, in: item.title)
        }
        let collectionPositions: [String: Int] = (activeCollection?.sceneIDs ?? []).enumerated().reduce(into: [:]) { positions, entry in
            if positions[entry.element] == nil { positions[entry.element] = entry.offset }
        }
        let refinementCount = (favoriteOnly ? 1 : 0) + (unopenedOnly ? 1 : 0) + (sourceFilterID == nil ? 0 : 1)
        refinementButton.title = refinementCount == 0 ? "Filters" : "Filters · \(refinementCount)"
        let needsMediaType = homeNavigation ? mediaFilter.indexOfSelectedItem > 0 : (4...6).contains(filter.indexOfSelectedItem)
        items = catalog.filter { item in
            let matches = query.isEmpty || scores[item.id] != nil
            guard matches else { return false }
            if favoriteOnly && !store.catalog.favorites.contains(item.id) { return false }
            if unopenedOnly && store.catalog.recent[item.id] != nil { return false }
            if let sourceFilterID {
                if sourceFilterID == "included" {
                    if item.builtin == nil { return false }
                } else if sourceFilterID == "imported" {
                    if item.entry == nil { return false }
                } else if item.entry?.sourceID != sourceFilterID { return false }
            }
            let mediaType = needsMediaType ? (item.builtin != nil ? "scene" : item.entry?.inferredMediaType) : nil
            if homeNavigation {
                if mediaFilter.indexOfSelectedItem == 1 && mediaType != "video" { return false }
                if mediaFilter.indexOfSelectedItem == 2 && mediaType != "scene" { return false }
                if mediaFilter.indexOfSelectedItem == 3 && mediaType != "image" { return false }
                switch scope {
                case .favorites: return matches && store.catalog.favorites.contains(item.id)
                case .recent: return matches && store.catalog.recent[item.id] != nil
                case .library, .collection: break
                }
            }
            if activeCollection != nil { return collectionPositions[item.id] != nil }
            switch filter.indexOfSelectedItem {
            case 1: return matches && item.builtin != nil
            case 2: return matches && item.entry != nil
            case 3: return matches && store.catalog.favorites.contains(item.id)
            case 4: return matches && mediaType == "video"
            case 5: return matches && mediaType == "scene"
            case 6: return matches && mediaType == "image"
            default: return matches
            }
        }.sorted {
            if activeCollection != nil {
                return (collectionPositions[$0.id] ?? Int.max) < (collectionPositions[$1.id] ?? Int.max)
            }
            if !query.isEmpty {
                let a = scores[$0.id] ?? .infinity
                let b = scores[$1.id] ?? .infinity
                if a != b { return a < b }
            }
            if (homeNavigation && scope == .recent) || sort.indexOfSelectedItem == 1 || sort.indexOfSelectedItem == 3 {
                let a = store.catalog.recent[$0.id] ?? .distantPast, b = store.catalog.recent[$1.id] ?? .distantPast
                if a != b { return sort.indexOfSelectedItem == 3 && scope != .recent ? a < b : a > b }
            }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == (sort.indexOfSelectedItem == 2 ? .orderedDescending : .orderedAscending)
        }
        table.reloadData()
        gridView.update(items: items, selectedID: selected?.id)
        updateEmptyState(activeCollection: activeCollection)
        if let index = items.firstIndex(where: { $0.id == previous }) ?? (items.isEmpty ? nil : 0) {
            selected = items[index]
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            gridView.select(id: selected?.id)
            preview()
            if oldIDs != items.map(\.id) {
                table.scrollRowToVisible(index)
                if !gridScroll.isHidden { gridView.revealSelection() }
            }
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
        requestThumbnail(for: item) { [weak thumbnail] image in thumbnail?.image = image }
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
    func requestPlaybackArtwork(_ url: URL, completion: @escaping (NSImage) -> Void) {
        let item = Item(id: "playback:" + url.standardizedFileURL.path,
                        title: url.deletingPathExtension().lastPathComponent, builtin: url, entry: nil)
        requestThumbnail(for: item, completion: completion)
    }

    func requestThumbnail(for item: Item, completion: @escaping (NSImage) -> Void) {
        let revision = thumbnailRevisions[item.id, default: 0]
        let requestID = revision == 0 ? item.id : "\(item.id)|\(revision)"
        if pendingThumbnails[requestID] != nil {
            pendingThumbnails[requestID]?.append(completion)
            return
        }
        guard let opened = try? open(item) else { return }
        pendingThumbnails[requestID] = [completion]
        thumbnailJobsStarted += 1
        let finish: (NSImage?) -> Void = { [weak self] image in
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.pendingThumbnails.removeValue(forKey: requestID) ?? []
                guard self.thumbnailRevisions[item.id, default: 0] == revision else { return }
                if let image { callbacks.forEach { $0(image) } }
            }
        }
        let posterAccess: SceneLibraryStore.Access? = item.entry.flatMap { try? store.accessPoster($0) }
        thumbnailQueue.addOperation { [weak self, opened, posterAccess] in
            guard let self else { return }
            let source = opened.url
            let stamp = try? source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let framingData = Self.thumbnailFramingData(source)
            let framing = framingData.flatMap { try? JSONDecoder().decode(SceneFraming.self, from: $0) }
            let key = "\(item.id)|\(revision)|\(source.path)|\(stamp?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(stamp?.fileSize ?? 0)|\(framingData?.base64EncodedString() ?? "")" as NSString
            if let image = self.thumbnails.object(forKey: key) {
                finish(image)
                return
            }
            let image: CGImage?
            if let explicit = posterAccess?.url, let poster = Self.listThumbnail(explicit) {
                image = poster
            } else if source.pathExtension.lowercased() == "idlesse" {
                image = Self.listThumbnail(source.appendingPathComponent("preview.jpg"))
                    ?? Self.listThumbnail(source.appendingPathComponent("preview.png"))
                    ?? Self.packageAssetThumbnail(source)
            } else if let still = Self.listThumbnail(source) {
                image = still
            } else if let sidecar = Self.listThumbnail(source.deletingPathExtension().appendingPathExtension("jpg"))
                ?? Self.listThumbnail(source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-Restored-4K60", with: "") + ".jpg")) {
                image = sidecar
            } else if ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 180)
                image = try? generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil)
            } else { image = nil }
            guard let image else { finish(nil); return }
            let rendered = Self.framedThumbnail(image, framing: framing,
                video: ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased())) ?? image
            let result = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            self.thumbnails.setObject(result, forKey: key, cost: Int(rendered.width * rendered.height * 4))
            finish(result)
        }
    }
    private static let thumbnailColorContext = CIContext(options: [.cacheIntermediates: false])

    private static func thumbnailFramingData(_ media: URL) -> Data? {
        guard media.pathExtension.lowercased() != "idlesse",
              let handle = try? FileHandle(forReadingFrom: SceneFraming.url(for: media)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return data
    }

    /// Work on the bounded poster, never a second live renderer or full video decode.
    /// Gallery cards use a 16:9 viewport; each actual display can crop differently.
    private static func framedThumbnail(_ original: CGImage, framing: SceneFraming?, video: Bool) -> CGImage? {
        guard let framing else { return original }
        var image = original
        if video, let tone = framing.tone, !tone.isNeutral {
            let source = CIImage(cgImage: image)
            image = thumbnailColorContext.createCGImage(tone.apply(to: source), from: source.extent) ?? image
        }
        guard framing.focus != nil || framing.bleed?.isEmpty == false else { return image }
        guard let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
            bytesPerRow: 1280, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        let frame = (framing.focus ?? .centre).filledFrame(
            content: CGSize(width: image.width, height: image.height), in: bounds, bleed: framing.bleed)
        context.interpolationQuality = .high
        context.draw(image, in: frame)
        return context.makeImage()
    }

    private static func listThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ] as CFDictionary)
    }
    private static func packageAssetThumbnail(_ package: URL) -> CGImage? {
        guard let scene = try? LocalSceneSource.read(package) else { return nil }
        let candidates: [URL] = ([scene.assetURL] + scene.allNodes.map(\.assetURL)).compactMap { $0 }
        for url in candidates {
            if let thumb = listThumbnail(url) { return thumb }
            if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 180)
                if let frame = try? generator.copyCGImage(at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil) { return frame }
            }
        }
        return proceduralThumbnail(scene)
    }
    private static func proceduralThumbnail(_ scene: SceneDescriptor) -> CGImage? {
        let width = 320, height = 180
        let previewTime = scene.metadata?.previewTime ?? 2
        do {
            let clock = SceneClock(now: { 0 })
            try clock.configure(timeline: scene.timeline)
            try clock.seek(to: previewTime)
            let renderer = try MetalSceneRenderer(playable: scene,
                bounds: NSRect(x: 0, y: 0, width: width, height: height), scale: 1,
                clock: clock, onError: { _ in })
            defer { renderer.releaseResources() }
            let bytes = try renderer.renderFrame(signals: .init(time: clock.time),
                width: width, height: height, sampleVideo: false)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        } catch {
            return nil
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let next = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        guard next?.id != selected?.id else { return }
        selected = next
        gridView.select(id: selected?.id)
        preview()
    }
    private func open(_ item: Item) throws -> OpenedItem {
        if let builtin = item.builtin {
            resolvedMediaURLs[item.id] = builtin.standardizedFileURL
            return OpenedItem(url: builtin, access: nil)
        }
        guard let entry = item.entry else { throw CocoaError(.fileNoSuchFile) }
        let access = try store.access(entry)
        resolvedMediaURLs[item.id] = access.url.standardizedFileURL
        return OpenedItem(url: access.url, access: access)
    }
    private func invalidatePreview(id: String) {
        knownDetails.removeValue(forKey: id)
        cache.removeValue(forKey: id)
        cacheOrder.removeAll { $0 == id }
        thumbnailRevisions[id, default: 0] &+= 1
        gridView.refreshThumbnail(id: id)
        if let index = items.firstIndex(where: { $0.id == id }) {
            table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        }
    }

    /// Refresh already visited rows without resolving every bookmark or mounting sources.
    func mediaDidChange(_ url: URL) {
        let key = url.standardizedFileURL
        let ids = resolvedMediaURLs.compactMap { $0.value == key ? $0.key : nil }
        for id in ids { invalidatePreview(id: id) }
        if let selected, ids.contains(selected.id) { preview() }
    }

    @objc private func refreshPreview() {
        if let selected { invalidatePreview(id: selected.id) }
        preview()
    }
    @objc private func clearTaskStatus() { reportTask("") }
    private func reportTask(_ message: String) {
        taskStatus.stringValue = message
        taskStatus.toolTip = message
        taskStatusRow.isHidden = message.isEmpty
        browserBottom?.constant = message.isEmpty ? 0 : -34
    }

    func stopLivePreview() {
        liveGeneration += 1
        liveTask?.cancel()
        liveTask = nil
        previewHost.renderer?.view.removeFromSuperview()
        previewHost.stop()
        liveAccess = nil
        livePreviewButton.title = "Play Preview"
    }

    @objc private func toggleLivePreview() {
        if liveTask != nil || previewHost.renderer != nil { stopLivePreview(); return }
        guard let selected, inspectorItem?.isCollapsed == false else { return }
        let token = liveGeneration
        livePreviewButton.title = "Cancel Preview"
        liveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == self.liveGeneration { self.liveTask = nil } }
            do {
                let opened = try self.open(selected)
                defer { withExtendedLifetime(opened.access) {} }
                let scene = try await LocalSceneSource().resolve(opened.url)
                try Task.checkCancellation()
                guard token == self.liveGeneration else { return }
                try self.previewHost.clock.configure(timeline: scene.timeline)
                self.previewHost.clock.pointerEnabled = false
                self.previewHost.clock.audioEnabled = false
                let bounds = NSRect(x: 0, y: 0, width: min(600, max(1, self.poster.bounds.width)),
                                    height: min(338, max(1, self.poster.bounds.height)))
                let renderer = try self.previewHost.prepare(scene: scene, bounds: bounds, scale: 1, metal: true,
                    onError: { [weak self] message in
                        guard let self, token == self.liveGeneration else { return }
                        self.detail.stringValue = "Preview: " + message
                        self.stopLivePreview()
                    })
                guard token == self.liveGeneration, !Task.isCancelled else {
                    renderer.releaseResources()
                    return
                }
                self.previewHost.renderer = renderer
                self.liveAccess = opened.access
                renderer.setMuted(true)
                renderer.setPreferredFrameRate(30)
                renderer.view.frame = self.poster.bounds
                renderer.view.autoresizingMask = [.width, .height]
                self.poster.addSubview(renderer.view)
                self.previewHost.setPaused(false)
                self.livePreviewButton.title = "Stop Preview"
            } catch {
                guard token == self.liveGeneration, !Task.isCancelled else { return }
                self.stopLivePreview()
                self.detail.stringValue = "Preview unavailable: " + error.localizedDescription
            }
        }
    }

    private func preview() {
        stopLivePreview()
        livePreviewButton.isEnabled = selected != nil
        task?.cancel(); task = nil; generation += 1
        let token = generation
        if posterItemID != selected?.id { poster.image = nil }
        posterItemID = selected?.id
        favorite.isEnabled = selected != nil
        updateApplyState()
        edit.isEnabled = selected != nil
        remove.isEnabled = selected?.entry != nil
        more.isEnabled = selected != nil
        more.item(at: 3)?.isEnabled = selected?.entry != nil
        adjust.isEnabled = canAdjustSelection
        more.item(at: 4)?.isEnabled = canAdjustSelection
        collectionActions.removeAllItems()
        collectionActions.addItems(withTitles: [rotationTimer == nil ? "Collections…" : "Collections · Rotating every \(rotationMinutes)m", "New Collection…"])
        if filter.selectedItem?.representedObject is String {
            collectionActions.addItems(withTitles: ["Rename Collection…", "Delete Collection…",
                "Move Collection Up", "Move Collection Down", "Move Scene Earlier", "Move Scene Later", "Play Collection in Order", "Shuffle Collection", "Playback & Schedule…"])
        }
        collectionActions.addItems(withTitles: ["Change Every 5 Minutes", "Change Every 15 Minutes", "Change Every 30 Minutes", "Change Every 60 Minutes"])
        if rotationTimer != nil { collectionActions.addItem(withTitle: "Stop Collection Rotation") }
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
        if titleLabel.stringValue != selected.title { titleLabel.stringValue = selected.title }
        favorite.title = store.catalog.favorites.contains(selected.id) ? "★" : "☆"
        setDetail(knownDetails[selected.id] ?? "")
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
                    self.knownDetails[selected.id] = cached.note
                    self.setDetail(cached.note)
                    return
                }
                self.cache.removeValue(forKey: selected.id)
                let scene = try await LocalSceneSource().resolve(url)
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let image: NSImage
                let previewTime = scene.metadata?.previewTime ?? 2
                let sourceDetails = try await Self.sourceDetails(url)
                let note = sourceDetails.isEmpty ? (scene.animated ? "Animated scene" : "Scene") : String(sourceDetails.dropFirst(3))
                let clock = SceneClock(now: { 0 })
                try clock.configure(timeline: scene.timeline)
                try clock.seek(to: previewTime)
                let renderer = try MetalSceneRenderer(playable: scene, bounds: NSRect(x: 0, y: 0, width: 1024, height: 576), scale: 1, clock: clock, onError: { _ in })
                defer { renderer.releaseResources() }
                try await renderer.prepareOfflineVideo(at: scene.timeline?.videosFollowScene == true ? clock.time : previewTime,
                                                       size: CGSize(width: 1024, height: 576))
                try Task.checkCancellation()
                let bytes = try renderer.renderFrame(signals: .init(time: clock.time), width: 1024, height: 576, sampleVideo: false)
                guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                      let frame = CGImage(width: 1024, height: 576, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                else { throw SceneError.invalid("Could not prepare the Library preview.") }
                image = NSImage(cgImage: frame, size: NSSize(width: 1024, height: 576))
                try Task.checkCancellation()
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
                self.knownDetails[selected.id] = note
                self.setDetail(note)
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.detail.stringValue = "Preview unavailable: \(error.localizedDescription). Use Relink Source… for a moved Source root, Rescan Source… for changed descendants, or re-add a moved individual file."
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
            sourceActions.addItem(withTitle: "Rescan \(source.name)…")
            sourceActions.lastItem?.representedObject = ["action": "reconcile", "id": source.id]
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
        if action == "reconcile" { reconcileSource(id); return }
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
                self.reportTask("Removed \(source.name) from the Library. Source files were preserved.")
            } catch { self.reportTask(error.localizedDescription) }
        }
    }

    private func reconcileSource(_ id: String) {
        guard conversionTask == nil else {
            reportTask("A Library import or Source scan is already running.")
            return
        }
        guard let source = store.catalog.sources.first(where: { $0.id == id }), let window = presentationWindow else { return }
        let access: SceneLibraryStore.Access
        do { access = try store.accessSource(id) }
        catch { reportTask(error.localizedDescription); return }

        conversionTask = Task { @MainActor [weak self, access] in
            guard let self else { return }
            defer { self.conversionTask = nil; withExtendedLifetime(access) {} }
            self.reportTask("Scanning \(source.name)…")
            do {
                var drafts = try await Task.detached(priority: .utility) { try Self.scanSource(access.url) }.value
                try Task.checkCancellation()
                var diff = try self.store.prepareReconciliation(sourceID: id, scanned: drafts)
                let digestLengths = Set(diff.missingEntryIDs.compactMap { entryID -> Int64? in
                    guard let entry = self.store.catalog.entries.first(where: { $0.id == entryID }),
                          entry.observation?.hasDigest == true else { return nil }
                    return entry.observation?.byteLength
                })
                let digestCandidates = diff.addedScannedIndices.filter { index in
                    guard drafts.indices.contains(index), let bytes = drafts[index].observation?.byteLength else { return false }
                    return digestLengths.contains(bytes) && drafts[index].observation?.hasDigest != true
                }
                if !digestCandidates.isEmpty {
                    self.reportTask("Checking a bounded set of move candidates…")
                    let observations = try await Task.detached(priority: .utility) {
                        try SceneLibraryStore.boundedDigests(root: access.url, drafts: drafts, indices: digestCandidates)
                    }.value
                    try Task.checkCancellation()
                    for (index, observation) in observations where drafts.indices.contains(index) {
                        drafts[index].observation = observation
                    }
                    diff = try self.store.prepareReconciliation(sourceID: id, scanned: drafts)
                }
                self.reportTask("Review \(source.name) reconciliation.")
                guard let accepted = await SourceReconciliationReview.choose(diff: diff, sourceName: source.name, window: window) else {
                    self.reportTask("\(source.name) rescan canceled. Library unchanged.")
                    return
                }
                try Task.checkCancellation()
                try self.store.applyReconciliation(diff, accepting: accepted)
                self.cache.removeAll(); self.cacheOrder.removeAll(); self.thumbnails.removeAllObjects()
                self.reload()
                let present = self.store.catalog.entries.filter { $0.sourceID == id && $0.availability == .present }.count
                let missing = self.store.catalog.entries.filter { $0.sourceID == id && $0.availability == .missing }.count
                self.reportTask("\(source.name) reconciled: \(present) present, \(missing) missing.")
            } catch {
                guard !Task.isCancelled else { return }
                self.reportTask("Source rescan failed: \(error.localizedDescription)")
            }
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
            : "Choose the folder that now contains this Source. Saved entry IDs and relative paths stay unchanged; use Rescan afterward to reconcile descendants."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let root = panel.url else { return }
            if let id {
                do {
                    try self.store.relinkSource(id, to: root)
                    self.cache.removeAll(); self.cacheOrder.removeAll(); self.thumbnails.removeAllObjects()
                    self.reload()
                    self.reportTask("Source relinked. Run Rescan to reconcile changed descendants.")
                } catch { self.reportTask(error.localizedDescription) }
            } else { self.importSource(root) }
        }
    }

    private func importSource(_ root: URL) {
        guard conversionTask == nil else {
            reportTask("An import is already running. Try again when it finishes.")
            return
        }
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.conversionTask = nil }
            self.reportTask("Scanning Source…")
            do {
                let drafts = try await Task.detached(priority: .utility) { try Self.scanSource(root) }.value
                try Task.checkCancellation()
                let oldIDs = Set(self.store.catalog.entries.map(\.id))
                let source = try self.store.addSource(root, entries: drafts)
                let firstNew = self.store.catalog.entries.first { $0.sourceID == source.id && !oldIDs.contains($0.id) }?.id
                    ?? self.store.catalog.entries.first { $0.sourceID == source.id && $0.availability == .present }?.id
                self.search.stringValue = ""
                self.filter.selectItem(at: 2); self.revealImportedScope()
                self.reload(selecting: firstNew)
                self.reportTask("\(source.name): \(self.store.catalog.entries.filter { $0.sourceID == source.id && $0.availability == .present }.count) wallpapers in Library.")
            } catch {
                guard !Task.isCancelled else { return }
                self.reportTask("Source import failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func scanSource(_ root: URL) throws -> [SceneLibraryStore.SourceEntry] {
        let maxSourceScanItems = 20_000
        let sourceNativeExtensions: Set<String> = ["idlesse", "jpg", "jpeg", "png", "heic", "mp4", "mov"]
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        var enumerationError: Error?
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw SceneLibraryStore.libraryFailure("The Source folder could not be scanned.")
        }
        var visited = 0
        var entries: [SceneLibraryStore.SourceEntry] = []
        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            guard visited <= maxSourceScanItems else {
                throw SceneLibraryStore.libraryFailure("The Source contains more than 20,000 items. Choose a narrower folder.")
            }
            let values = try candidate.resourceValues(forKeys: Set(keys))
            let ext = candidate.pathExtension.lowercased()
            if values.isDirectory == true {
                if ext == "idlesse" {
                    let relative = try SceneLibraryStore.relativePath(from: root, to: candidate)
                    entries.append(.init(relativeMediaPath: relative,
                        title: candidate.deletingPathExtension().lastPathComponent, mediaType: "scene",
                        observation: packageObservation(candidate, modifiedAt: values.contentModificationDate)))
                    enumerator.skipDescendants()
                }
            } else if sourceNativeExtensions.contains(ext) {
                let relative = try SceneLibraryStore.relativePath(from: root, to: candidate)
                let type = ext == "idlesse" ? "scene" : (["mp4", "mov"].contains(ext) ? "video" : "image")
                entries.append(.init(relativeMediaPath: relative,
                    title: candidate.deletingPathExtension().lastPathComponent, mediaType: type,
                    observation: .init(byteLength: values.fileSize.map(Int64.init), modifiedAt: values.contentModificationDate)))
            }
            guard entries.count <= SceneLibraryStore.maxSourceEntries else {
                throw SceneLibraryStore.libraryFailure("The Library supports up to 4096 source-backed entries.")
            }
        }
        if let enumerationError { throw enumerationError }
        return entries.sorted { $0.relativeMediaPath.localizedStandardCompare($1.relativeMediaPath) == .orderedAscending }
    }

    nonisolated private static func packageObservation(_ package: URL, modifiedAt: Date?) -> SceneLibraryStore.ReconciliationObservation {
        var parts: [String] = []
        for name in ["manifest.json", "scene.json"] {
            let url = package.appendingPathComponent(name)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               let size = values.fileSize {
                let stamp = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
                parts.append("\(name):\(size):\(stamp)")
            }
        }
        return .init(modifiedAt: modifiedAt, packageRevision: parts.isEmpty ? nil : parts.joined(separator: "|"))
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
    private static func supportedImport(_ url: URL) -> Bool { url.isFileURL && MediaImport.supports(url) }
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
    /// Adds a file the export pipeline just installed, as if it were imported by hand.
    func importInstalledMedia(_ url: URL) { importScenes([url]) }
    private func importScenes(_ urls: [URL]) {
        guard conversionTask == nil else {
            reportTask("An import is already running. Try again when it finishes.")
            return
        }
        conversionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.conversionTask = nil }
            var firstID: String?
            var failures: [String] = []
            for (index, source) in urls.enumerated() {
                if Task.isCancelled { return }
                self.reportTask("Importing \(index + 1) of \(urls.count)…")
                do {
                    guard Self.supportedImport(source) else { throw SceneError.invalid("This file type is not supported.") }
                    let convert = try await MediaImport.needsConversion(source)
                    try Task.checkCancellation()
                    let imported: URL
                    if convert {
                        self.reportTask("Converting \(index + 1) of \(urls.count)…")
                        imported = try await MediaImport.convert(source)
                    } else { imported = source }
                    try Task.checkCancellation()
                    let entry = try self.store.add(imported, title: convert ? source.deletingPathExtension().lastPathComponent : nil)
                    if firstID == nil { firstID = entry.id }
                } catch {
                    if Task.isCancelled { return }
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if firstID != nil { self.search.stringValue = ""; self.filter.selectItem(at: 2); self.revealImportedScope() }
            self.reload(selecting: firstID)
            self.reportTask("Imported \(urls.count - failures.count) of \(urls.count) wallpapers" + (failures.isEmpty ? "" : " · \(failures.count) failed"))
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
        case 4: frameScene()
        default: break
        }
    }
    @objc private func toggleFavorite() {
        guard let selected else { return }
        do { try store.favorite(selected.id); reload() } catch { reportTask(error.localizedDescription) }
    }
    @objc private func removeScene() {
        guard let selected, selected.entry != nil else { return }
        do { try store.remove(selected.id); cache.removeValue(forKey: selected.id); cacheOrder.removeAll { $0 == selected.id }; reload() }
        catch { reportTask(error.localizedDescription) }
    }
    @objc private func useScene() { act(editing: false) }
    var hasCycleCandidates: Bool { items.count > 1 }

    private func cycleIndex(delta: Int, from playingURL: URL?) -> Int? {
        guard hasCycleCandidates else { return nil }
        // Browsing a poster must not silently move the transport's starting point.
        let playingIndex = playingURL.flatMap { url in
            items.firstIndex { item in
                (try? open(item).url.standardizedFileURL) == url.standardizedFileURL
            }
        }
        let current = playingIndex ?? (delta >= 0 ? -1 : 0)
        return (current + delta + items.count * 2) % items.count
    }

    func cycle(delta: Int, from playingURL: URL? = nil) {
        guard let next = cycleIndex(delta: delta, from: playingURL) else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        selected = items[next]
        gridView.select(id: selected?.id)
        preview()
        act(editing: false)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === libraryActions.menu else { return }
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }
        for (title, source, action) in [
            ("Collections", collectionActions, #selector(performCollectionMenuAction(_:))),
            ("Sources", sourceActions, #selector(performSourceMenuAction(_:)))
        ] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            for (index, original) in source.itemArray.enumerated() where index > 0 {
                let item = NSMenuItem(title: original.title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = index
                item.isEnabled = original.isEnabled
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    @objc private func performCollectionMenuAction(_ item: NSMenuItem) {
        guard collectionActions.itemArray.indices.contains(item.tag) else { return }
        collectionActions.selectItem(at: item.tag)
        collectionAction()
    }

    @objc private func performSourceMenuAction(_ item: NSMenuItem) {
        guard sourceActions.itemArray.indices.contains(item.tag) else { return }
        sourceActions.selectItem(at: item.tag)
        sourceAction()
    }

    func createCollection() {
        collectionActions.selectItem(withTitle: "New Collection…")
        collectionAction()
    }

    @objc private func collectionAction() {
        guard let item = collectionActions.selectedItem else { return }
        if ["Move Collection Up", "Move Collection Down"].contains(item.title), let id = filter.selectedItem?.representedObject as? String {
            do { try store.moveCollection(id, by: item.title == "Move Collection Up" ? -1 : 1); reload() }
            catch { reportTask(error.localizedDescription) }
            return
        }
        if ["Move Scene Earlier", "Move Scene Later"].contains(item.title),
           let id = filter.selectedItem?.representedObject as? String, let selected {
            do { try store.moveScene(selected.id, in: id, by: item.title == "Move Scene Earlier" ? -1 : 1); reload(selecting: selected.id) }
            catch { reportTask(error.localizedDescription) }
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
                catch { reportTask(error.localizedDescription); return }
            }
            let editedID = filter.selectedItem?.representedObject as? String
            if rotationCollectionID == nil || editedID == rotationCollectionID {
                rotationMinutes = minutes
                if rotationTimer != nil { armRotationTimer(); preview() }
            }
            reportTask("Collections change every \(minutes) minutes.")
            return
        }
        if item.title == "Play Collection in Order" || item.title == "Shuffle Collection" {
            guard let id = filter.selectedItem?.representedObject as? String,
                  let collection = store.catalog.collections.first(where: { $0.id == id }),
                  !collection.sceneIDs.isEmpty else { reportTask("Add scenes to this collection first."); return }
            stopRotation()
            var settings = collection.playback ?? SceneLibraryStore.Playback()
            settings.shuffle = item.title == "Shuffle Collection"
            do { try store.setPlayback(id, settings) }
            catch { reportTask(error.localizedDescription); return }
            beginRotation(store.catalog.collections.first { $0.id == id }!, shuffle: settings.shuffle)
            preview()
            return
        }
        if let id = item.representedObject as? String, let selected {
            do { try store.toggleMembership(sceneID: selected.id, collectionID: id); reload() }
            catch { reportTask(error.localizedDescription) }
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
                if deleting, let activeID { try self.store.removeCollection(activeID); self.filter.selectItem(at: 0); self.revealImportedScope() }
                else if renaming, let activeID { try self.store.renameCollection(activeID, name: field.stringValue) }
                else {
                    let collection = try self.store.createCollection(name: field.stringValue)
                    self.reload()
                    self.filter.selectItem(at: self.filter.itemArray.firstIndex { ($0.representedObject as? String) == collection.id }!)
                    self.search.stringValue = ""
                    if self.homeNavigation {
                        self.scope = .collection(collection.id)
                        self.onScopeChange?(self.scope)
                    }
                }
                self.reload()
            } catch { self.reportTask(error.localizedDescription) }
        }
    }
    private func editPlayback() {
        guard let id = filter.selectedItem?.representedObject as? String,
              let collection = store.catalog.collections.first(where: { $0.id == id }), let window = presentationWindow else { return }
        let settings = collection.playback ?? SceneLibraryStore.Playback()
        let enabled = LibraryHoverButton(checkboxWithTitle: "Play on a schedule", target: nil, action: nil)
        enabled.state = settings.startMinute == nil ? .off : .on
        let shuffle = LibraryHoverButton(checkboxWithTitle: "Shuffle without repeats", target: nil, action: nil)
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
            let button = LibraryHoverButton(checkboxWithTitle: Calendar.current.shortWeekdaySymbols[day - 1], target: nil, action: nil)
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
            } catch { self.reportTask(error.localizedDescription) }
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
    private var canAdjustSelection: Bool {
        selected?.entry != nil && selected?.entry?.mediaType != "scene"
    }

    @objc private func frameScene() {
        guard let selected, selected.entry != nil else { return }
        do {
            let opened = try open(selected)
            guard MediaFramingController.canFrame(opened.url) else {
                opened.access?.close()
                detail.stringValue = "Framing applies to imported pictures and videos. Scenes keep theirs in Studio."
                return
            }
            onFrame?(opened.url, opened.access)
        } catch { detail.stringValue = error.localizedDescription }
    }
    @objc private func duplicateScene() { act(editing: true, asCopy: true) }
    private func act(editing: Bool, asCopy: Bool = false) {
        guard let selected else { return }
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
        } catch { reportTask(error.localizedDescription) }
    }
    func windowWillClose(_ notification: Notification) {
        pendingSearch?.cancel(); pendingSearch = nil
        stopLivePreview()
        conversionTask?.cancel()
        task?.cancel(); generation += 1
        cache.removeAll(); cacheOrder.removeAll(); poster.image = nil
    }
    func windowDidMove(_ notification: Notification) { (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlesseLibrary") }
    func windowDidResize(_ notification: Notification) { (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlesseLibrary") }
    deinit {
        pendingSearch?.cancel()
        previewObservers.forEach(NotificationCenter.default.removeObserver)
        liveTask?.cancel()
        previewHost.stop()
        conversionTask?.cancel(); task?.cancel(); rotationTimer?.invalidate(); scheduleTimer?.invalidate()
    }

    static func smokeTest(outputURL: URL, videoURL: URL? = nil) throws {
        let preferenceKeys = ["Idlesse.library.inspectorVisible", "Idlesse.library.viewMode",
                              "Idlesse.library.selectedID", "Idlesse.library.sortMode", "Idlesse.library.filterTitle"]
        let preferences = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(preferenceKeys, preferences) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("revision.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: raw)
        let bookmark = try raw.bookmarkData(options: [], includingResourceValuesForKeys: [.pathKey], relativeTo: nil)
        let legacyImage = SceneLibraryStore.Entry(id: "legacy-image", title: "Legacy", bookmark: bookmark)
        precondition(legacyImage.inferredMediaType == "image")
        let legacyVideoURL = folder.appendingPathComponent("legacy.MP4")
        try Data().write(to: legacyVideoURL)
        let videoBookmark = try legacyVideoURL.bookmarkData(options: [], includingResourceValuesForKeys: [.pathKey], relativeTo: nil)
        let legacyVideo = SceneLibraryStore.Entry(id: "legacy-video", title: "Legacy", bookmark: videoBookmark)
        precondition(legacyVideo.inferredMediaType == "video", "Legacy video bookmarks must not become images")
        precondition(SceneLibraryStore.Entry(id: "source-scene", title: "Scene", relativeMediaPath: "scene.idlesse").inferredMediaType == "scene")
        let oldRevision = try PosterRevision.read(raw)
        try Data([1, 2]).write(to: raw)
        let newRevision = try PosterRevision.read(raw)
        precondition(oldRevision != newRevision)
        try Data(#"{"focus":{"x":0.2,"y":0.5}}"#.utf8).write(to: SceneFraming.url(for: raw))
        let croppedRevision = try PosterRevision.read(raw)
        precondition(croppedRevision != newRevision, "Sidecar creation must invalidate posters")
        try Data(#"{"focus":{"x":0.8,"y":0.5}}"#.utf8).write(to: SceneFraming.url(for: raw))
        let changedCropRevision = try PosterRevision.read(raw)
        precondition(changedCropRevision != croppedRevision, "Same-size framing edits must invalidate posters")
        try FileManager.default.removeItem(at: SceneFraming.url(for: raw))
        let resetCropRevision = try PosterRevision.read(raw)
        precondition(resetCropRevision == newRevision, "Resetting framing must invalidate the cropped poster")
        let pixels = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
            bytesPerRow: 1280, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(CGColor(red: 0.5, green: 0, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 160, height: 180))
        pixels.setFillColor(CGColor(red: 0, green: 0.5, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 160, y: 0, width: 160, height: 180))
        let original = pixels.makeImage()!
        let cropped = framedThumbnail(original, framing: SceneFraming(bleed: SceneBleed(left: 0.4)), video: false)!
        let cropBytes = Array((cropped.dataProvider!.data!) as Data)
        let originalBytes = Array((original.dataProvider!.data!) as Data)
        let sample = (90 * 320 + 120) * 4
        precondition(originalBytes[sample] > originalBytes[sample + 1])
        precondition(cropBytes[sample + 1] > cropBytes[sample], "Gallery crop must hide the declared left margin")
        let darker = framedThumbnail(original, framing: SceneFraming(tone: SceneTone(exposure: -1)), video: true)!
        let darkBytes = Array((darker.dataProvider!.data!) as Data)
        precondition(darker.width == 320 && darker.height == 180)
        precondition(darkBytes != originalBytes, "Video tone must change the bounded poster")
        let untouched = framedThumbnail(original, framing: SceneFraming(tone: SceneTone(exposure: -1)), video: false)!
        precondition(untouched === original, "Image thumbnails must match the video-only tone policy")
        var copied = false
        var applied = false
        let controller = try SceneLibraryController(indexURL: folder.appendingPathComponent("index.json"),
            onUse: { _ in applied = true }, onEdit: { _, asCopy in copied = asCopy })
        let originalSort = controller.sort.indexOfSelectedItem
        controller.useHomeNavigation()
        controller.setScope(.recent)
        precondition(controller.items.isEmpty, "Recent excludes wallpapers never opened")
        precondition(controller.sort.indexOfSelectedItem == originalSort, "Recent must preserve browser sort")
        controller.setScope(.library)
        let remembered = controller.items.last!
        controller.selected = remembered
        controller.setScope(.favorites)
        precondition(controller.selected == nil, "Empty Favorites must have no selection")
        precondition(controller.titleLabel.stringValue == "No favorites yet")
        controller.setScope(.library)
        precondition(controller.selected?.id == remembered.id, "Returning to Library must restore its selection")
        controller.viewModeControl.selectedSegment = 1
        controller.viewModeChanged()
        precondition(!controller.right.isHidden, "Grid must retain selection details")
        controller.inspectorButton.state = .off
        controller.toggleInspector()
        precondition(controller.inspectorItem?.isCollapsed == true)
        controller.inspectorButton.state = .on
        controller.toggleInspector()
        controller.viewModeControl.selectedSegment = 0
        controller.viewModeChanged()
        controller.homeNavigation = false
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([raw as NSURL, folder.appendingPathComponent("ignored.txt") as NSURL])
        precondition(controller.droppedURLs(pasteboard) == [raw])
        precondition(controller.items.count == 8 && controller.items.contains { $0.title == "Desk Clock" })
        precondition(controller.sourceActions.itemArray.contains { $0.title == "Add Source…" })
        let fullCatalog = controller.items
        controller.items = []
        precondition(!controller.hasCycleCandidates && controller.cycleIndex(delta: 1, from: nil) == nil)
        controller.items = [fullCatalog[0]]
        precondition(!controller.hasCycleCandidates && controller.cycleIndex(delta: -1, from: nil) == nil)
        controller.cycle(delta: 1)
        precondition(!applied, "Single-item transport must not restart or apply wallpaper")
        controller.items = fullCatalog
        precondition(controller.hasCycleCandidates)
        let playing = try controller.open(controller.items[0]).url
        controller.selected = controller.items[3]
        precondition(controller.cycleIndex(delta: 1, from: playing) == 1,
            "Transport must follow playback, not the selected poster")
        precondition(controller.cycleIndex(delta: -1, from: playing) == controller.items.count - 1)
        precondition(controller.cycleIndex(delta: 1, from: nil) == 0)
        precondition(controller.cycleIndex(delta: -1, from: nil) == controller.items.count - 1)

        let index = controller.items.firstIndex { $0.title == "Undertow" }!
        controller.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        controller.selected = controller.items[index]
        controller.preview()
        let deadline = Date().addingTimeInterval(10)
        while controller.task != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        controller.updatePlayingURL(try controller.open(controller.selected!).url)
        precondition(controller.apply.title == "✓ On Desktop" && !controller.apply.isEnabled && !controller.apply.isHidden)
        let playingMenu = controller.gridView.onMenu!(controller.selected!)
        precondition(playingMenu.item(at: 0)?.title == "On Desktop" && playingMenu.item(at: 0)?.isEnabled == false)
        precondition(!controller.adjust.isEnabled && playingMenu.item(at: 1)?.isEnabled == false,
                     "Package scenes use Studio, not raw-media adjustments")
        controller.updatePlayingURL(nil)
        precondition(controller.apply.title == "Set Wallpaper" && controller.apply.isEnabled)

        let duplicateRequest = Item(id: "smoke.shared-thumbnail", title: "Undertow", builtin: controller.selected!.builtin, entry: nil)
        let jobsBefore = controller.thumbnailJobsStarted
        var thumbnailCompletions = 0
        let thumbnailStart = ProcessInfo.processInfo.systemUptime
        controller.requestThumbnail(for: duplicateRequest) { _ in thumbnailCompletions += 1 }
        controller.requestThumbnail(for: duplicateRequest) { _ in thumbnailCompletions += 1 }
        precondition(controller.thumbnailJobsStarted == jobsBefore + 1, "Duplicate requests must share one job")
        let thumbDeadline = Date().addingTimeInterval(10)
        while thumbnailCompletions < 2 && Date() < thumbDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(thumbnailCompletions == 2 && controller.pendingThumbnails[duplicateRequest.id] == nil)
        print("Shared thumbnail: 2 consumers, 1 job, \(Int((ProcessInfo.processInfo.systemUptime - thumbnailStart) * 1000)) ms")

        let beforeSaveRevision = controller.thumbnailRevisions[duplicateRequest.id, default: 0]
        let selectedBeforeSave = controller.selected?.id
        controller.mediaDidChange(controller.resolvedMediaURLs[duplicateRequest.id]!)
        precondition(controller.thumbnailRevisions[duplicateRequest.id] == beforeSaveRevision + 1)
        precondition(controller.selected?.id == selectedBeforeSave && !applied,
                     "Saving framing refreshes previews without selecting or applying a wallpaper")

        var staleDelivered = false
        var refreshedThumbnail: NSImage?
        controller.requestThumbnail(for: duplicateRequest) { _ in staleDelivered = true }
        controller.thumbnailRevisions[duplicateRequest.id, default: 0] &+= 1
        controller.requestThumbnail(for: duplicateRequest) { refreshedThumbnail = $0 }
        let refreshDeadline = Date().addingTimeInterval(10)
        while (refreshedThumbnail == nil || !controller.pendingThumbnails.isEmpty) && Date() < refreshDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(!staleDelivered, "A refreshed thumbnail must reject the older in-flight result")
        precondition(refreshedThumbnail != nil)
        precondition(max(refreshedThumbnail!.size.width, refreshedThumbnail!.size.height) <= 320)

        let originalDetail = controller.detail.stringValue
        controller.reportTask("Importing 1 of 2…")
        precondition(controller.detail.stringValue == originalDetail, "Import status must not replace artwork details")
        controller.clearTaskStatus()
        precondition(controller.taskStatusRow.isHidden)
        controller.toggleLivePreview()
        let liveDeadline = Date().addingTimeInterval(10)
        while controller.liveTask != nil && Date() < liveDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(controller.previewHost.renderer != nil, controller.detail.stringValue)
        precondition(!applied, "Local preview must not apply a wallpaper")
        precondition(controller.previewHost.renderer?.diagnostics.audioMuted == true)
        let liveGenerationBeforeReselect = controller.liveGeneration
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        precondition(controller.liveGeneration == liveGenerationBeforeReselect && controller.previewHost.renderer != nil,
                     "Reselecting the same row must preserve its live preview")
        controller.stopLivePreview()
        precondition(controller.previewHost.renderer == nil && controller.liveAccess == nil)
        controller.toggleLivePreview()
        controller.stopLivePreview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(controller.previewHost.renderer == nil, "Canceled resolution must not install a late renderer")

        precondition(!applied, "Browsing and generating a preview must not apply a desktop wallpaper")
        let colors = NSBitmapImageRep(data: controller.poster.image!.tiffRepresentation!)!
        var hasWarmColor = false
        for y in stride(from: 0, to: colors.pixelsHigh, by: 32) {
            for x in stride(from: 0, to: colors.pixelsWide, by: 32) {
                if let color = colors.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent - color.blueComponent > 0.2 { hasWarmColor = true }
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
        controller.filter.selectItem(at: 0)
        controller.favoriteOnly = true
        controller.reload()
        precondition(controller.items.count == 1 && controller.items[0].title == "Undertow", "Favorites refinement must work independently of scope")
        controller.unopenedOnly = true
        controller.reload()
        precondition(controller.items.allSatisfy { controller.store.catalog.recent[$0.id] == nil }, "Unopened and favorites filters must intersect")
        controller.favoriteOnly = false; controller.unopenedOnly = false
        controller.sort.selectItem(at: 0); controller.reload()
        let ascendingIDs = controller.items.map(\.id)
        controller.sort.selectItem(at: 2); controller.reload()
        precondition(controller.items.map(\.id) == Array(ascendingIDs.reversed()), "Reverse name sort must reverse the library")
        controller.sort.selectItem(at: originalSort)
        controller.filter.selectItem(at: 3); controller.reload()
        let collection = try controller.store.createCollection(name: "Psychedelic")
        try controller.store.toggleMembership(sceneID: controller.selected!.id, collectionID: collection.id)
        controller.reload()
        controller.filter.selectItem(at: controller.filter.itemArray.firstIndex { ($0.representedObject as? String) == collection.id }!)
        controller.reload()
        precondition(controller.items.count == 1 && controller.selected?.title == "Undertow")
        precondition(controller.collectionActions.itemArray.contains { $0.title == "Rename Collection…" })
        controller.homeNavigation = true
        controller.setScope(.favorites)
        precondition(controller.items.count == 1 && controller.selected?.title == "Undertow")
        try controller.store.used(controller.selected!.id)
        controller.setScope(.recent)
        precondition(controller.items.count == 1 && controller.selected?.title == "Undertow")
        precondition(controller.sort.indexOfSelectedItem == originalSort)
        controller.setScope(.collection(collection.id))
        precondition(controller.items.count == 1 && controller.selected?.title == "Undertow")
        controller.homeNavigation = false
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
        while controller.task != nil && Date() < posterDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(controller.poster.image != nil, controller.detail.stringValue)
        let root = controller.window!.contentView!
        root.layoutSubtreeIfNeeded()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL, options: .withoutOverwriting)
        controller.viewModeControl.selectedSegment = 1
        controller.viewModeChanged()
        root.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let gridBitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: gridBitmap)
        let gridOutput = outputURL.deletingPathExtension().appendingPathExtension("grid.png")
        try gridBitmap.representation(using: .png, properties: [:])!.write(to: gridOutput, options: .withoutOverwriting)
        precondition(!controller.right.isHidden && controller.inspectorItem?.isCollapsed == false)
        controller.search.stringValue = "No matching scene"
        controller.reload()
        precondition(controller.items.isEmpty && !controller.apply.isEnabled)
        precondition(controller.titleLabel.stringValue == "No matches" && !controller.clearSearchButton.isHidden,
            "Search misses need an explicit empty state with a way out")
        controller.filter.selectItem(at: 0)
        controller.clearSearch()
        precondition(controller.search.stringValue.isEmpty && controller.items.count == 8 && controller.clearSearchButton.isHidden,
            "Clearing the search must restore browsing")
        let beforeTyping = controller.items.map(\.id)
        controller.search.stringValue = "Aurora"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        controller.search.stringValue = "Undertow"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        precondition(controller.items.map(\.id) == beforeTyping, "Typing should not rebuild synchronously")
        let searchDeadline = Date().addingTimeInterval(2)
        while controller.pendingSearch != nil && Date() < searchDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(controller.items.count == 1 && controller.items.first?.title == "Undertow")
        controller.search.stringValue = "Aurora"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        controller.commitSearch()
        precondition(controller.pendingSearch == nil && controller.items.allSatisfy { $0.title.contains("Aurora") })
        controller.clearSearch()
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
            while controller.conversionTask != nil && Date() < importDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(controller.conversionTask == nil, "Async import timed out")
            precondition(importFailures.count == 1 && importFailures[0].contains("invalid.webm"),
                         "Failed conversion must be reported while later native media imports")
            precondition(controller.search.stringValue.isEmpty && controller.filter.indexOfSelectedItem == 2)
            precondition(controller.items.count == 1 && controller.selected?.id == controller.items[0].id,
                         "Import must reveal and select its scene despite previous search/filter")
            let videoDeadline = Date().addingTimeInterval(10)
            while controller.task != nil && Date() < videoDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(controller.poster.image != nil && controller.detail.stringValue.contains("fps") && controller.detail.stringValue.contains("×"), controller.detail.stringValue)
            applied = false
            controller.toggleLivePreview()
            let videoPreviewDeadline = Date().addingTimeInterval(10)
            while controller.liveTask != nil && Date() < videoPreviewDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(controller.previewHost.renderer != nil, controller.detail.stringValue)
            precondition(controller.previewHost.renderer?.diagnostics.audioMuted == true && !applied)
            controller.stopLivePreview()
            precondition(controller.previewHost.renderer == nil)

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

private final class CenteredLibrarySearchCell: NSSearchFieldCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        var button = super.searchButtonRect(forBounds: rect)
        button.origin.y = rect.midY - button.height / 2
        return button
    }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        var button = super.cancelButtonRect(forBounds: rect)
        button.origin.y = rect.midY - button.height / 2
        return button
    }
}

/// The inspector artwork is a drag source, just like a gallery card.
private final class LibraryDraggablePreview: NSImageView, NSDraggingSource {
    var onDragURL: (() -> URL?)?
    var onDragEnd: (() -> Void)?
    private var origin: NSPoint?
    override func mouseDown(with event: NSEvent) { origin = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, let image else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 5, let url = onDragURL?() else { return }
        self.origin = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { origin = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDragEnd?() }
}
