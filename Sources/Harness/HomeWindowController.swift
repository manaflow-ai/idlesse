import AppKit
import ImageIO

/// Primary Idlesse window. Library keeps ownership of its original NSWindow;
/// Home wraps Library content inside that same window and never reparents it
/// into Settings.
final class HomeWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private enum SidebarRow: Equatable {
        case group(String)
        case library
        case displays
        case favorites
        case recent
        case collection(id: String, name: String)

        var title: String {
            switch self {
            case .group(let title): return title
            case .library: return "All Wallpapers"
            case .displays: return "Displays"
            case .favorites: return "Favorites"
            case .recent: return "Recent"
            case .collection(_, let name): return name
            }
        }
        var symbol: String? {
            switch self {
            case .group: return nil
            case .library: return "photo.on.rectangle.angled"
            case .displays: return "display.2"
            case .favorites: return "star.fill"
            case .recent: return "clock"
            case .collection: return "rectangle.stack"
            }
        }
        var selectable: Bool {
            if case .group = self { return false }
            return true
        }
    }

    private let library: SceneLibraryController
    private let wallpaper: WallpaperController
    private let comfort: DesktopComfortController
    private let indexURL: URL
    private let libraryView: NSView
    /// Optional visual Displays destination supplied by #31. Home owns this
    /// controller directly; its view has never belonged to another window.
    private let displaysDestinationController: NSViewController?
    private let activateDisplaysDestination: (() -> Void)?
    private let sidebar = NSTableView()
    private let contentHost = NSView(frame: .zero)
    private let displaysView = NSView(frame: .zero)
    private let displaySummary = NSTextField(wrappingLabelWithString: "")
    private let filesButton = NSButton(checkboxWithTitle: "Files", target: nil, action: nil)
    private let widgetsButton = NSButton(checkboxWithTitle: "Widgets", target: nil, action: nil)
    private let sameDisplaysButton = NSButton(checkboxWithTitle: "Same wallpaper on all displays", target: nil, action: nil)
    private var rows: [SidebarRow] = []
    private var currentRow: SidebarRow = .library
    private var sidebarItem: NSSplitViewItem?
    private var refreshTimer: Timer?

    private let nowPlayingButton = NSButton(title: "No Wallpaper", target: nil, action: nil)
    private let destinationLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(frame: .zero)
    private let pauseButton = NSButton(frame: .zero)
    private let nextButton = NSButton(frame: .zero)
    private var nowPlayingPopover: NSPopover?
    private var refreshPlaybackPopover: (() -> Void)?
    private var cachedThumbnailURL: URL?
    private var cachedThumbnail: NSImage?

    var window: NSWindow { library.window! }

    init(library: SceneLibraryController, wallpaper: WallpaperController, comfort: DesktopComfortController,
         indexURL: URL? = nil, displaysDestinationController: NSViewController? = nil,
         activateDisplaysDestination: (() -> Void)? = nil) {
        self.library = library
        self.wallpaper = wallpaper
        self.comfort = comfort
        self.libraryView = library.window!.contentView!
        self.displaysDestinationController = displaysDestinationController
        self.activateDisplaysDestination = activateDisplaysDestination
        if let indexURL {
            self.indexURL = indexURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.indexURL = support.appendingPathComponent("Idlesse/Library/index.json")
        }
        super.init()
        // main.swift installs the legacy Settings owner before AppSettings is
        // created. Home becomes the sheet/panel owner as soon as it exists.
        wallpaper.presentingWindow = { [weak library] in library?.window }
        library.onScopeChange = { [weak self] scope in
            guard let self else { return }
            self.refreshSidebar()
            let row = self.rows.first { row in
                switch (row, scope) {
                case (.library, .library), (.favorites, .favorites), (.recent, .recent): return true
                case (.collection(let id, _), .collection(let target)): return id == target
                default: return false
                }
            } ?? .library
            self.showLibraryScope(row)
            if let index = self.rows.firstIndex(of: row) {
                self.sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        library.useHomeNavigation()
        installShell()
        installToolbar()
        buildDisplaysView()
        refreshSidebar()
        refreshState()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshState() }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        NotificationCenter.default.addObserver(self, selector: #selector(desktopVisibilityChanged),
            name: DesktopComfortController.desktopVisibilityChanged, object: nil)
    }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func presentLibrary() {
        refreshSidebar()
        showLibraryScope(.library)
        presentWindow()
    }

    func presentDisplays() {
        refreshSidebar()
        showDisplays()
        presentWindow()
    }

    private func presentWindow() {
        library.show()
        window.title = currentRow.title
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Shell

    private func installShell() {
        libraryView.removeFromSuperview()

        let sidebarScroll = NSScrollView(frame: .zero)
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.documentView = sidebar
        sidebar.style = .plain
        sidebar.backgroundColor = .clear
        sidebar.selectionHighlightStyle = .regular
        sidebar.headerView = nil
        sidebar.rowHeight = 28
        sidebar.allowsEmptySelection = false
        sidebar.delegate = self
        sidebar.dataSource = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HomeSource"))
        column.resizingMask = .autoresizingMask
        sidebar.addTableColumn(column)
        sidebar.setAccessibilityLabel("Idlesse destinations")

        let sidebarController = NSViewController()
        let sidebarRoot = NSView()
        sidebarController.view = sidebarRoot
        sidebarRoot.wantsLayer = true
        sidebarRoot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let settings = NSButton(title: "Settings…", target: self, action: #selector(openPreferences))
        settings.bezelStyle = .inline
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        settings.contentTintColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator
        for view in [sidebarScroll, divider, settings] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebarRoot.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: sidebarRoot.topAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarRoot.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarRoot.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),
            divider.leadingAnchor.constraint(equalTo: sidebarRoot.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: sidebarRoot.trailingAnchor, constant: -12),
            divider.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -10),
            settings.leadingAnchor.constraint(equalTo: sidebarRoot.leadingAnchor, constant: 16),
            settings.bottomAnchor.constraint(equalTo: sidebarRoot.bottomAnchor, constant: -12),
        ])
        let sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        self.sidebarItem = sidebarItem
        sidebarItem.isCollapsed = UserDefaults.standard.bool(forKey: "Idlesse.home.sidebarHidden")

        let contentController = NSViewController()
        contentController.view = contentHost
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 700

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.dividerStyle = .thin
        window.contentViewController = split
        window.minSize = NSSize(width: 960, height: 560)
        window.setContentSize(NSSize(width: 1120, height: 680))

        libraryView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(libraryView)
        NSLayoutConstraint.activate([
            libraryView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            libraryView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            libraryView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            libraryView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    @objc private func newCollection() { library.createCollection() }

    private func refreshSidebar() {
        var next: [SidebarRow] = [
            .library, .favorites, .recent,
            .group("Collections"),
        ]
        if let store = try? SceneLibraryStore(file: indexURL) {
            next.append(contentsOf: store.catalog.collections.map { .collection(id: $0.id, name: $0.name) })
        }
        next.append(contentsOf: [.group("Workspace"), .displays])
        rows = next
        sidebar.reloadData()
        if let index = rows.firstIndex(of: currentRow), rows[index].selectable {
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let index = rows.firstIndex(of: .library) {
            currentRow = .library
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LibraryNavigationRow()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].selectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let text = NSTextField(labelWithString: entry.title)
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingTail
        if case .group = entry {
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .secondaryLabelColor
            if entry == .group("Collections") {
                let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Collection")!, target: self, action: #selector(newCollection))
                add.bezelStyle = .inline
                add.toolTip = "New Collection"
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [text, spacer, add])
                row.spacing = 4
                return row
            }
            return text
        }
        let cell = NSTableCellView(frame: .zero)
        let image = NSImageView(frame: .zero)
        image.image = entry.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: entry.title) }
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.textField = text
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = sidebar.selectedRow
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .library, .favorites, .recent, .collection(_, _): showLibraryScope(rows[index])
        case .displays: showDisplays()
        case .group: break
        }
    }

    private func showLibraryScope(_ row: SidebarRow) {
        library.setSearchEnabled(true)
        currentRow = row
        libraryView.isHidden = false
        displaysView.isHidden = true
        window.title = row.title
        switch row {
        case .library: library.setScope(.library)
        case .favorites: library.setScope(.favorites)
        case .recent: library.setScope(.recent)
        case .collection(let id, _): library.setScope(.collection(id))
        default: break
        }
        library.refreshEmbedded()
    }

    private func showDisplays() {
        library.setSearchEnabled(false)
        library.stopLivePreview()
        currentRow = .displays
        window.title = "Displays"
        activateDisplaysDestination?()
        libraryView.isHidden = true
        displaysView.isHidden = false
        refreshDisplaysSummary()
    }

    private func rotationSummary() -> String? { library.rotationSummary }

    @objc private func toggleSidebar() {
        guard let sidebarItem else { return }
        sidebarItem.isCollapsed.toggle()
        UserDefaults.standard.set(sidebarItem.isCollapsed, forKey: "Idlesse.home.sidebarHidden")
    }

    // MARK: - Displays destination

    private func configureDesktopControls() {
        sameDisplaysButton.target = self
        sameDisplaysButton.action = #selector(changeSameDisplays)
        filesButton.target = self
        filesButton.action = #selector(toggleFiles)
        widgetsButton.target = self
        widgetsButton.action = #selector(toggleWidgets)
    }

    private func desktopControlsRow() -> NSStackView {
        let desktopTitle = NSTextField(labelWithString: "Desktop")
        desktopTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let spacer = NSView(frame: .zero)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [desktopTitle, spacer, filesButton, widgetsButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    private func buildDisplaysView() {
        displaysView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(displaysView)
        NSLayoutConstraint.activate([
            displaysView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            displaysView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            displaysView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            displaysView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        displaysView.isHidden = true
        configureDesktopControls()

        if let destinationController = displaysDestinationController {
            let destination = destinationController.view
            destination.translatesAutoresizingMaskIntoConstraints = false
            let desktop = desktopControlsRow()
            desktop.translatesAutoresizingMaskIntoConstraints = false
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            displaysView.addSubview(destination)
            displaysView.addSubview(separator)
            displaysView.addSubview(desktop)
            NSLayoutConstraint.activate([
                destination.leadingAnchor.constraint(equalTo: displaysView.leadingAnchor),
                destination.trailingAnchor.constraint(equalTo: displaysView.trailingAnchor),
                destination.topAnchor.constraint(equalTo: displaysView.topAnchor),
                destination.bottomAnchor.constraint(equalTo: separator.topAnchor),
                separator.leadingAnchor.constraint(equalTo: displaysView.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: displaysView.trailingAnchor),
                desktop.leadingAnchor.constraint(equalTo: displaysView.leadingAnchor, constant: 26),
                desktop.trailingAnchor.constraint(equalTo: displaysView.trailingAnchor, constant: -26),
                desktop.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
                desktop.bottomAnchor.constraint(equalTo: displaysView.bottomAnchor, constant: -12),
            ])
            return
        }

        let title = NSTextField(labelWithString: "Displays")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString:
            "Choose how Idlesse treats the desktop. Display layout and per-display Library assignment live here.")
        intro.textColor = .secondaryLabelColor
        displaySummary.textColor = .secondaryLabelColor

        let desktopControls = desktopControlsRow()
        let stack = NSStackView(views: [title, intro, sameDisplaysButton, displaySummary, desktopControls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        displaysView.addSubview(stack)
        intro.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true
        displaySummary.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true
        desktopControls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: displaysView.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: displaysView.trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: displaysView.topAnchor, constant: 32),
        ])
    }

    @objc private func changeSameDisplays() {
        wallpaper.sameWallpaperOnAllDisplays = sameDisplaysButton.state == .on
        refreshState()
    }
    @objc private func toggleFiles() { comfort.toggleDesktopIcons(); refreshState() }
    @objc private func toggleWidgets() { comfort.toggleDesktopWidgets(); refreshState() }
    @objc private func desktopVisibilityChanged() { refreshState() }

    private func refreshDisplaysSummary() {
        let count = NSScreen.screens.count
        let mode = wallpaper.sameWallpaperOnAllDisplays ? "Same on All Displays" : "Per Display"
        displaySummary.stringValue = "\(count) connected display\(count == 1 ? "" : "s") · \(mode)"
        sameDisplaysButton.state = wallpaper.sameWallpaperOnAllDisplays ? .on : .off
        filesButton.state = comfort.desktopIconsVisible ? .on : .off
        widgetsButton.state = comfort.desktopWidgetsVisible ? .on : .off
        filesButton.isEnabled = !comfort.changingDesktopIcons
        widgetsButton.isEnabled = !comfort.changingDesktopWidgets
    }

    // MARK: - Now Playing

    private static let sidebarToggleItem = NSToolbarItem.Identifier("Idlesse.Home.Sidebar")
    private static let searchItem = NSToolbarItem.Identifier("Idlesse.Home.Search")
    private static let importItem = NSToolbarItem.Identifier("Idlesse.Home.Import")
    private static let transportItem = NSToolbarItem.Identifier("Idlesse.Home.Transport")
    private static let settingsItem = NSToolbarItem.Identifier("Idlesse.Home.Settings")
    private static let nowPlayingItem = NSToolbarItem.Identifier("Idlesse.Home.NowPlaying")

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("Idlesse.Home.Toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleItem, .sidebarTrackingSeparator, Self.searchItem, Self.importItem, .space, Self.nowPlayingItem, .flexibleSpace, Self.settingsItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleItem, .sidebarTrackingSeparator, Self.searchItem, Self.importItem, .space, Self.nowPlayingItem, .flexibleSpace, Self.settingsItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.searchItem {
            return library.makeSearchToolbarItem(identifier: itemIdentifier)
        }
        if itemIdentifier == Self.importItem {
            return library.makeImportToolbarItem(identifier: itemIdentifier)
        }
        if itemIdentifier == Self.sidebarToggleItem {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.label = "Sidebar"
            item.target = self
            item.action = #selector(toggleSidebar)
            return item
        }
        if itemIdentifier == Self.settingsItem {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.label = "Settings"
            item.toolTip = "Idlesse Settings (⌘,)"
            item.target = self
            item.action = #selector(openPreferences)
            return item
        }
        if itemIdentifier == Self.transportItem {
            configureTransport(previousButton, symbol: "backward.end.fill", label: "Previous wallpaper", action: #selector(previousWallpaper))
            configureTransport(pauseButton, symbol: "pause.fill", label: "Pause wallpaper", action: #selector(togglePause))
            configureTransport(nextButton, symbol: "forward.end.fill", label: "Next wallpaper", action: #selector(nextWallpaper))
            let transport = NSStackView(views: [previousButton, pauseButton, nextButton])
            transport.spacing = 4
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = transport
            item.label = "Playback"
            return item
        }
        guard itemIdentifier == Self.nowPlayingItem else { return nil }
        nowPlayingButton.isBordered = false
        nowPlayingButton.target = self
        nowPlayingButton.action = #selector(showNowPlaying)
        nowPlayingButton.imagePosition = .imageLeading
        nowPlayingButton.alignment = .left
        nowPlayingButton.toolTip = "Current wallpaper and playback options"
        nowPlayingButton.font = .systemFont(ofSize: 13, weight: .medium)
        (nowPlayingButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        destinationLabel.font = .systemFont(ofSize: 11)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [nowPlayingButton, destinationLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.widthAnchor.constraint(equalToConstant: 170).isActive = true
        configureTransport(previousButton, symbol: "backward.end.fill", label: "Previous wallpaper", action: #selector(previousWallpaper))
        configureTransport(pauseButton, symbol: "pause.fill", label: "Pause wallpaper", action: #selector(togglePause))
        configureTransport(nextButton, symbol: "forward.end.fill", label: "Next wallpaper", action: #selector(nextWallpaper))
        let controls = NSStackView(views: [labels, previousButton, pauseButton, nextButton])
        controls.spacing = 7
        controls.alignment = .centerY
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = controls
        item.label = "Now Playing"
        item.paletteLabel = "Now Playing"
        return item
    }

    private func configureTransport(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.toolTip = label
    }

    @objc private func previousWallpaper() { library.cycle(delta: -1, from: wallpaper.selectedURL); refreshState() }
    @objc private func nextWallpaper() { library.cycle(delta: 1, from: wallpaper.selectedURL); refreshState() }
    @objc private func openPreferences() { wallpaper.onShowSettings?() }

    @objc private func togglePause() { wallpaper.togglePause(); refreshState() }

    @objc private func showNowPlaying() {
        nowPlayingPopover?.close()
        let popover = NSPopover()
        let controller = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: wallpaper.hasSceneControls ? 180 : 142))
        let title = NSTextField(labelWithString: nowPlayingButton.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let destination = NSTextField(labelWithString: destinationLabel.stringValue)
        destination.textColor = .secondaryLabelColor
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopWallpaper))
        stop.bezelStyle = .rounded
        stop.isEnabled = wallpaper.selectedURL != nil
        let pause = NSButton(title: wallpaper.pausedByUser ? "Resume" : "Pause", target: self, action: #selector(togglePopoverPause))
        pause.isEnabled = wallpaper.canPausePlayback
        let sound = NSButton(checkboxWithTitle: "Wallpaper Sound", target: self, action: #selector(togglePopoverSound))
        sound.state = wallpaper.soundEnabled ? .on : .off
        sound.isEnabled = wallpaper.hasVideoContent
        let controls = NSButton(title: "Scene Controls…", target: self, action: #selector(openSceneControls))
        controls.isHidden = !wallpaper.hasSceneControls
        let playback = NSStackView(views: [pause, stop])
        playback.spacing = 8
        let stack = NSStackView(views: [title, destination, playback, sound, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        controller.view = container
        popover.contentViewController = controller
        popover.behavior = .transient
        nowPlayingPopover = popover
        refreshPlaybackPopover = { [weak self, weak popover, weak title, weak destination, weak pause, weak stop, weak sound, weak controls] in
            guard let self, let popover, popover.isShown else { return }
            title?.stringValue = self.nowPlayingButton.title
            destination?.stringValue = self.destinationLabel.stringValue
            pause?.title = self.wallpaper.pausedByUser ? "Resume" : "Pause"
            pause?.isEnabled = self.wallpaper.canPausePlayback
            stop?.isEnabled = self.wallpaper.selectedURL != nil
            sound?.state = self.wallpaper.soundEnabled ? .on : .off
            sound?.isEnabled = self.wallpaper.hasVideoContent
            controls?.isHidden = !self.wallpaper.hasSceneControls
            popover.contentSize = NSSize(width: 320, height: self.wallpaper.hasSceneControls ? 180 : 142)
        }
        popover.show(relativeTo: nowPlayingButton.bounds, of: nowPlayingButton, preferredEdge: .maxY)
    }

    @objc private func togglePopoverPause(_ sender: NSButton) {
        wallpaper.togglePause()
        sender.title = wallpaper.pausedByUser ? "Resume" : "Pause"
        refreshState()
    }
    @objc private func togglePopoverSound(_ sender: NSButton) {
        wallpaper.soundEnabled = sender.state == .on
    }
    @objc private func openSceneControls() {
        nowPlayingPopover?.close()
        wallpaper.editControls()
    }

    @objc private func stopWallpaper() {
        wallpaper.stop()
        nowPlayingPopover?.close()
        refreshState()
    }

    private func refreshState() {
        let url = wallpaper.selectedURL
        library.updatePlayingURL(url)
        let title = wallpaper.currentSceneTitle ?? url.map { SceneLibraryController.displayTitle($0.deletingPathExtension().lastPathComponent) } ?? "No Wallpaper"
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        let assignments = screens.map { screen -> String in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            return wallpaper.displayURL(for: id).map {
                SceneLibraryController.displayTitle($0.deletingPathExtension().lastPathComponent)
            } ?? "None"
        }
        nowPlayingButton.title = wallpaper.sameWallpaperOnAllDisplays ? title : assignments.joined(separator: " | ")
        nowPlayingButton.toolTip = wallpaper.sameWallpaperOnAllDisplays ? "Shared wallpaper · playback options" : zip(screens, assignments).map { "\($0.0.localizedName): \($0.1)" }.joined(separator: "\n")
        let standardized = url?.standardizedFileURL
        if standardized != cachedThumbnailURL {
            cachedThumbnailURL = standardized
            cachedThumbnail = thumbnail(for: url)
        }
        nowPlayingButton.image = cachedThumbnail ?? NSImage(systemSymbolName: "photo", accessibilityDescription: title)
        pauseButton.image = NSImage(systemSymbolName: wallpaper.pausedByUser ? "play.fill" : "pause.fill",
            accessibilityDescription: wallpaper.pausedByUser ? "Resume wallpaper" : "Pause wallpaper")
        pauseButton.toolTip = wallpaper.pausedByUser ? "Resume wallpaper" : "Pause wallpaper"
        pauseButton.setAccessibilityLabel(pauseButton.toolTip)
        pauseButton.isEnabled = wallpaper.canPausePlayback
        previousButton.isEnabled = library.hasCycleCandidates
        nextButton.isEnabled = library.hasCycleCandidates
        previousButton.toolTip = library.hasCycleCandidates ? "Previous wallpaper in the current Library view" : "Open a Library view with at least two wallpapers"
        nextButton.toolTip = library.hasCycleCandidates ? "Next wallpaper in the current Library view" : "Open a Library view with at least two wallpapers"
        var parts: [String] = []
        if wallpaper.isLoading { parts.insert("Loading…", at: 0) }
        if let rotation = rotationSummary() { parts.append(rotation) }
        destinationLabel.stringValue = parts.joined(separator: " · ")
        destinationLabel.isHidden = parts.isEmpty
        refreshPlaybackPopover?()
        refreshDisplaysSummary()
    }

    private func thumbnail(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        let ext = url.pathExtension.lowercased()
        let candidate: URL
        if ext == "idlesse" {
            let jpg = url.appendingPathComponent("preview.jpg")
            let png = url.appendingPathComponent("preview.png")
            candidate = FileManager.default.fileExists(atPath: jpg.path) ? jpg : png
        } else if ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"].contains(ext) {
            candidate = url
        } else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(candidate as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 36,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 36, height: 24))
    }

    static func smokeTest() throws {
        let selection = UserDefaults.standard.object(forKey: "Idlesse.library.selectedID")
        defer {
            if let selection { UserDefaults.standard.set(selection, forKey: "Idlesse.library.selectedID") }
            else { UserDefaults.standard.removeObject(forKey: "Idlesse.library.selectedID") }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-home-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = folder.appendingPathComponent("index.json")
        let library = try SceneLibraryController(indexURL: index, onUse: { _ in }, onEdit: { _, _ in })
        for content in [SceneNode.Content.image(URL(fileURLWithPath: "/image.png")),
                        .video(URL(fileURLWithPath: "/video.mp4"))] {
            let plain = SceneDescriptor(title: "Plain", nodes: [SceneNode(content: content)])
            precondition(WallpaperSurface.usesMetal(plain, menuAnimation: true),
                         "Menu animation must select Metal for plain images and videos")
            if ProcessInfo.processInfo.environment["IDLESSE_METAL_COMPOSITOR"] != "1" {
                precondition(!WallpaperSurface.usesMetal(plain, menuAnimation: false))
            }
        }
        let wallpaper = WallpaperController()
        wallpaper.presentsWindows = false
        let comfort = DesktopComfortController()
        let displayDestination = NSViewController()
        displayDestination.view = NSView(frame: .zero)
        var displayActivated = false
        let home = HomeWindowController(
            library: library, wallpaper: wallpaper, comfort: comfort, indexURL: index,
            displaysDestinationController: displayDestination,
            activateDisplaysDestination: { displayActivated = true })
        precondition(home.window.contentViewController is NSSplitViewController)
        precondition(home.rows.contains(.library) && home.rows.contains(.displays))
        precondition(home.rows.contains(.favorites) && home.rows.contains(.recent))
        precondition(home.window.toolbar != nil)
        precondition(home.window.toolbar!.items.map(\.itemIdentifier).contains(Self.settingsItem))
        let searchItem = home.window.toolbar!.items.first { $0.itemIdentifier == Self.searchItem }
        precondition(searchItem is NSSearchToolbarItem)
        precondition(home.window.toolbar!.items.contains { $0.itemIdentifier == Self.importItem })
        var openedSettings = false
        wallpaper.onShowSettings = { openedSettings = true }
        home.openPreferences()
        precondition(openedSettings)

        precondition(displayDestination.view.superview === home.displaysView)
        home.showLibraryScope(.favorites)
        precondition(home.currentRow == .favorites && !home.libraryView.isHidden)
        home.showDisplays()
        precondition(displayActivated)
        precondition(home.currentRow == .displays && !home.displaysView.isHidden && home.libraryView.isHidden)
        home.showLibraryScope(.library)
        precondition(home.currentRow == .library && !home.libraryView.isHidden)
    }
}

/// Neutral selection keeps navigation subordinate to the artwork.
private final class LibraryNavigationRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.labelColor.withAlphaComponent(isEmphasized ? 0.12 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}
