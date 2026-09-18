import AppKit
import ImageIO
import AVFoundation
import ScreenCaptureKit

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
    private let filesButton = LibraryHoverButton(checkboxWithTitle: "Files", target: nil, action: nil)
    private let widgetsButton = LibraryHoverButton(checkboxWithTitle: "Widgets", target: nil, action: nil)
    private let sameDisplaysButton = LibraryHoverButton(checkboxWithTitle: "Same wallpaper on all displays", target: nil, action: nil)
    private var rows: [SidebarRow] = []
    private var currentRow: SidebarRow = .library
    private var sidebarItem: NSSplitViewItem?
    private weak var navigationSplit: NSSplitView?
    private let persistLayout: Bool
    private var refreshTimer: Timer?

    private let nowPlayingTitle = NSTextField(labelWithString: "No Wallpaper")
    private let destinationLabel = NSTextField(labelWithString: "")
    private let previousButton = LibraryHoverButton(frame: .zero)
    private let playerBackdrop = WallpaperHeaderArtwork()
    private let playerHeader = NSView()
    private var audioProbe: Task<Void, Never>?
    private let playerArtwork = NSImageView()
    private let playerSound = LibraryHoverButton(frame: .zero)
    private let pauseButton = LibraryHoverButton(frame: .zero)
    private let nextButton = LibraryHoverButton(frame: .zero)
    private var nowPlayingPopover: NSPopover?
    private var aboutPopover: NSPopover?
    private var refreshPlaybackPopover: (() -> Void)?
    private var cachedThumbnailURL: URL?
    private var cachedThumbnail: NSImage?

    var window: NSWindow { library.window! }

    init(library: SceneLibraryController, wallpaper: WallpaperController, comfort: DesktopComfortController,
         indexURL: URL? = nil, displaysDestinationController: NSViewController? = nil,
         activateDisplaysDestination: (() -> Void)? = nil, persistLayout: Bool = true) {
        self.persistLayout = persistLayout
        self.library = library
        self.wallpaper = wallpaper
        self.comfort = comfort
        self.libraryView = library.window!.contentView!
        let destination = displaysDestinationController ?? DisplayAssignmentViewController(wallpaper: wallpaper)
        self.displaysDestinationController = destination
        self.activateDisplaysDestination = activateDisplaysDestination ?? { [weak destination] in
            (destination as? DisplayAssignmentViewController)?.activate()
        }
        if let indexURL {
            self.indexURL = indexURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.indexURL = support.appendingPathComponent("Idlesse/Library/index.json")
        }
        super.init()
        // main.swift installs the legacy Settings owner before AppSettings is
        // created. Home becomes the sheet/panel owner as soon as it exists.
        library.installDisplayCanvas(wallpaper: wallpaper)
        if let displays = self.displaysDestinationController as? DisplayAssignmentViewController {
            displays.requestArtwork = { [weak library] url, done in library?.requestPlaybackArtwork(url, completion: done) }
        }
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
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(captureDiagnosticWindow(_:)),
            name: Notification.Name("com.teamleaderleo.idlesse.capture-window"), object: nil)
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

    /// Capture the actual composited app window, including native glass.
    @objc private func captureDiagnosticWindow(_ notification: Notification) {
        guard let token = notification.object as? String, UUID(uuidString: token) != nil else { return }
        let output = URL(fileURLWithPath: "/tmp/idlesse-window-\(token).png")
        if notification.userInfo?["layoutOnly"] as? Bool == true {
            guard let view = window.contentView?.superview,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: output, options: .atomic)
            }
            return
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let target = content.windows.first(where: {
                    $0.windowID == UInt32(self.window.windowNumber) &&
                    $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                }) else { throw NSError(domain: "IdlesseCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Library window is not visible"]) }
                let config = SCStreamConfiguration()
                config.width = Int(target.frame.width * self.window.backingScaleFactor)
                config.height = Int(target.frame.height * self.window.backingScaleFactor)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "IdlesseCapture", code: 2)
                }
                try data.write(to: output, options: .atomic)
            } catch {
                try? error.localizedDescription.write(to: output.appendingPathExtension("error"), atomically: true, encoding: .utf8)
            }
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
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
        sidebar.intercellSpacing = NSSize(width: 0, height: 0)
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
        sidebarRoot.layer?.backgroundColor = LibrarySurfaceColors.sidebar.cgColor
        let settings = LibraryHoverButton(title: "", target: self, action: #selector(openPreferences))
        settings.squareHover = true
        settings.iconSize = 24
        settings.bezelStyle = .regularSquare
        settings.image = NekoIcons.image("settings")
        settings.imagePosition = .imageOnly
        settings.isBordered = false
        settings.toolTip = "Settings (⌘,)"
        settings.setAccessibilityLabel("Settings")
        settings.widthAnchor.constraint(equalToConstant: 36).isActive = true
        settings.heightAnchor.constraint(equalToConstant: 36).isActive = true
        settings.contentTintColor = .secondaryLabelColor
        let footerLine = NSView()
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        let about = LibraryHoverButton(title: "", target: self, action: #selector(openAbout(_:)))
        about.isBordered = false
        about.bezelStyle = .regularSquare
        // A dedicated small-size mark keeps the cat legible in the footer.
        let footerIcon = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSColor(white: 0.055, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            if let cat = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))?
                .withSymbolConfiguration(.init(paletteColors: [.white])) {
                cat.draw(in: NSRect(x: 3, y: 3, width: 18, height: 18))
            }
            return true
        }
        about.image = NekoIcons.image("cat")
        about.imagePosition = .imageOnly
        about.imageScaling = .scaleProportionallyDown
        about.setAccessibilityLabel("About Idlesse")
        let addWallpaper = LibrarySidebarAddButton(title: "Add wallpapers", target: self, action: #selector(addWallpaperFromSidebar))
        addWallpaper.isBordered = false
        addWallpaper.bezelStyle = .regularSquare
        addWallpaper.font = .systemFont(ofSize: 13)
        addWallpaper.alignment = .left
        addWallpaper.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addWallpaper.imagePosition = .imageLeading
        for view in [sidebarScroll, footerLine, about, settings, addWallpaper] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebarRoot.addSubview(view)
        }
        NSLayoutConstraint.activate([
            addWallpaper.topAnchor.constraint(equalTo: sidebarRoot.safeAreaLayoutGuide.topAnchor, constant: 12),
            addWallpaper.leadingAnchor.constraint(equalTo: sidebarRoot.leadingAnchor, constant: 14),
            addWallpaper.trailingAnchor.constraint(lessThanOrEqualTo: sidebarRoot.trailingAnchor, constant: -8),
            addWallpaper.heightAnchor.constraint(equalToConstant: 30),
            sidebarScroll.topAnchor.constraint(equalTo: addWallpaper.bottomAnchor, constant: 10),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarRoot.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarRoot.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor),
            footerLine.leadingAnchor.constraint(equalTo: sidebarRoot.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: sidebarRoot.trailingAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 0.5),
            footerLine.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -10),
            about.leadingAnchor.constraint(equalTo: sidebarRoot.leadingAnchor, constant: 12),
            about.centerYAnchor.constraint(equalTo: settings.centerYAnchor),
            about.heightAnchor.constraint(equalToConstant: 28),
            about.widthAnchor.constraint(equalToConstant: 28),
            settings.trailingAnchor.constraint(equalTo: sidebarRoot.trailingAnchor, constant: -8),
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
        split.splitView = LibrarySplitView()
        split.splitView.isVertical = true
        navigationSplit = split.splitView
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        if persistLayout { split.splitView.autosaveName = "IdlesseHomeSidebar" }
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
            .library, .favorites, .recent, .displays,
            .group("Collections"),
        ]
        if let store = try? SceneLibraryStore(file: indexURL) {
            next.append(contentsOf: store.catalog.collections.map { .collection(id: $0.id, name: $0.name) })
        }
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
        let view = LibraryNavigationRow()
        view.acceptsHover = rows[row].selectable
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 44 }
        return 28
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
            text.font = .systemFont(ofSize: 13, weight: .regular)
            text.textColor = .secondaryLabelColor
            if entry == .group("Collections") {
                let add = LibraryHoverButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Collection")!, target: self, action: #selector(newCollection))
                add.isBordered = false
                add.imagePosition = .imageOnly
                add.iconSize = 13
                add.widthAnchor.constraint(equalToConstant: 24).isActive = true
                add.heightAnchor.constraint(equalToConstant: 24).isActive = true
                add.toolTip = "New Collection"
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [text, spacer, add])
                row.alignment = .centerY
                row.spacing = 4
                let container = NSView()
                row.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                    row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                    row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
                    row.heightAnchor.constraint(equalToConstant: 26),
                ])
                return container
            }
            return text
        }
        let cell = NSTableCellView(frame: .zero)
        let image = NSImageView(frame: .zero)
        switch entry {
        case .library: image.image = NekoIcons.image("library")
        case .displays: image.image = NekoIcons.image("display")
        case .favorites: image.image = NekoIcons.image("favorite")
        case .collection: image.image = NekoIcons.image("folder")
        default: image.image = entry.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: entry.title) }
        }
        image.contentTintColor = NekoIcons.ivory
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.textField = text
        cell.imageView = image
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
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
        setLibraryToolbarVisible(true)
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

    private func routedLibraryItem(_ item: NSToolbarItem) -> NSToolbarItem {
        if case .displays = currentRow { item.view?.isHidden = true }
        return item
    }

    private func setLibraryToolbarVisible(_ visible: Bool) {
        let libraryItems: Set<NSToolbarItem.Identifier> = [Self.searchItem, Self.layoutItem, Self.inspectorControlItem]
        window.toolbar?.items.filter { libraryItems.contains($0.itemIdentifier) }.forEach { $0.view?.isHidden = !visible }
    }

    private func showDisplays() {
        setLibraryToolbarVisible(false)
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
                destination.topAnchor.constraint(equalTo: displaysView.safeAreaLayoutGuide.topAnchor),
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

    private static let columnDividerItem = NSToolbarItem.Identifier("Idlesse.Home.ColumnDivider")
    private static let sidebarToggleItem = NSToolbarItem.Identifier("Idlesse.Home.Sidebar")
    private static let inspectorControlItem = NSToolbarItem.Identifier("Idlesse.Home.InspectorControl")
    private static let layoutItem = NSToolbarItem.Identifier("Idlesse.Home.Layout")
    private static let inspectorDivider = NSToolbarItem.Identifier("Idlesse.Home.InspectorDivider")
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
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.backgroundColor = LibrarySurfaceColors.content
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sidebarToggleItem, Self.columnDividerItem, Self.searchItem, .flexibleSpace, Self.layoutItem, Self.nowPlayingItem, Self.inspectorControlItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sidebarToggleItem, Self.columnDividerItem, Self.searchItem, .flexibleSpace, Self.layoutItem, Self.nowPlayingItem, Self.inspectorControlItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.columnDividerItem, let navigationSplit {
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: navigationSplit, dividerIndex: 0)
        }
        if itemIdentifier == Self.inspectorControlItem { return routedLibraryItem(library.makeInspectorToolbarItem(identifier: itemIdentifier)) }
        if itemIdentifier == Self.layoutItem { return routedLibraryItem(library.makeViewToolbarItem(identifier: itemIdentifier)) }
        if itemIdentifier == Self.inspectorDivider { return library.makeInspectorDivider(identifier: itemIdentifier) }
        if itemIdentifier == Self.searchItem {
            return routedLibraryItem(library.makeSearchToolbarItem(identifier: itemIdentifier))
        }
        if itemIdentifier == Self.importItem {
            return library.makeImportToolbarItem(identifier: itemIdentifier)
        }
        if itemIdentifier == Self.sidebarToggleItem {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = LibraryHoverButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")!, target: self, action: #selector(toggleSidebar))
            button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.toolTip = "Show or hide sidebar"
            item.isBordered = false
            item.view = button
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
            pauseButton.wantsLayer = true
        pauseButton.layer?.cornerRadius = 8
        pauseButton.layer?.backgroundColor = NSColor.clear.cgColor
        for button in [previousButton, pauseButton, nextButton] { button.contentTintColor = .white }
        let transport = NSStackView(views: [previousButton, pauseButton, nextButton])
            transport.spacing = 4
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = transport
            item.label = "Playback"
            return item
        }
        guard itemIdentifier == Self.nowPlayingItem else { return nil }
        return makePlayerItem(itemIdentifier)
    }

    private func makePlayerItem(_ itemIdentifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        nowPlayingTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        nowPlayingTitle.textColor = .white
        nowPlayingTitle.lineBreakMode = .byTruncatingTail
        nowPlayingTitle.maximumNumberOfLines = 1
        nowPlayingTitle.setAccessibilityLabel("Current wallpaper")
        nowPlayingTitle.translatesAutoresizingMaskIntoConstraints = false
        let labels = NSView()
        labels.addSubview(nowPlayingTitle)
        NSLayoutConstraint.activate([
            labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            labels.heightAnchor.constraint(equalToConstant: 32),
            nowPlayingTitle.leadingAnchor.constraint(equalTo: labels.leadingAnchor, constant: 4),
            nowPlayingTitle.trailingAnchor.constraint(equalTo: labels.trailingAnchor, constant: -4),
            nowPlayingTitle.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
        ])
        configureTransport(previousButton, symbol: "backward.end.fill", label: "Previous wallpaper", action: #selector(previousWallpaper))
        configureTransport(pauseButton, symbol: "pause.fill", label: "Pause wallpaper", action: #selector(togglePause))
        configureTransport(nextButton, symbol: "forward.end.fill", label: "Next wallpaper", action: #selector(nextWallpaper))
        configureTransport(playerSound, symbol: "speaker.slash", label: "Wallpaper sound", action: #selector(togglePlayerSound))
        playerArtwork.imageScaling = .scaleProportionallyUpOrDown
        playerArtwork.wantsLayer = true
        playerArtwork.layer?.cornerRadius = 6
        playerArtwork.layer?.masksToBounds = true
        playerArtwork.widthAnchor.constraint(equalToConstant: 32).isActive = true
        playerArtwork.heightAnchor.constraint(equalToConstant: 32).isActive = true
        pauseButton.wantsLayer = true
        pauseButton.layer?.cornerRadius = 8
        pauseButton.layer?.backgroundColor = NSColor.clear.cgColor
        for button in [previousButton, pauseButton, nextButton] { button.contentTintColor = .white }
        let transport = NSStackView(views: [previousButton, pauseButton, nextButton])
        transport.spacing = 0
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let controls = NSView()
        for view in [labels, transport, playerSound] {
            view.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.heightAnchor.constraint(equalToConstant: 40),
            transport.widthAnchor.constraint(equalToConstant: 96),
            transport.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            transport.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: transport.leadingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            playerSound.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -8),
            playerSound.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
        ])
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = false
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 10
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 0.5
        surface.layer?.borderColor = NekoIcons.accent.withAlphaComponent(0.6).cgColor
        playerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(playerBackdrop)
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.alphaValue = 0.30
        glass.frame = surface.bounds
        glass.autoresizingMask = [.width, .height]
        surface.addSubview(glass)
        surface.addSubview(controls)
        NSLayoutConstraint.activate([
            playerBackdrop.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            playerBackdrop.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            playerBackdrop.topAnchor.constraint(equalTo: surface.topAnchor),
            playerBackdrop.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            controls.topAnchor.constraint(equalTo: surface.topAnchor),
            controls.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        item.view = surface
        let width = surface.widthAnchor.constraint(equalToConstant: 320)
        width.isActive = true
        library.alignPlaybackWidth(width)
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
        button.toolTip = nil
    }

    @objc private func togglePlayerSound() {
        wallpaper.soundEnabled.toggle()
        refreshState()
    }

    @objc private func previousWallpaper() { library.cycle(delta: -1, from: wallpaper.selectedURL); refreshState() }
    @objc private func nextWallpaper() { library.cycle(delta: 1, from: wallpaper.selectedURL); refreshState() }
    @objc private func openAbout(_ sender: NSButton) {
        if aboutPopover?.isShown == true { aboutPopover?.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        let content = NSView()
        controller.view = content
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let name = NSTextField(labelWithString: "Idlesse")
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        let identity = NSStackView(views: [name, versionLabel])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 3
        let header = NSStackView(views: [icon, identity])
        header.spacing = 10
        header.alignment = .centerY
        let description = NSTextField(wrappingLabelWithString: "A little life for your desktop. Made by Leo.")
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        let releases = LibraryHoverButton(title: "Releases & updates", target: self, action: #selector(openAppReleases))
        let repository = LibraryHoverButton(title: "Source code on GitHub", target: self, action: #selector(openAppRepository))
        for button in [releases, repository] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.font = .systemFont(ofSize: 13)
            button.alignment = .left
            button.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
            button.imagePosition = .imageTrailing
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        let stack = NSStackView(views: [header, description, releases, repository])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            description.widthAnchor.constraint(equalToConstant: 236),
            releases.widthAnchor.constraint(equalTo: stack.widthAnchor),
            repository.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 268, height: 204)
        aboutPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func openAppReleases() {
        aboutPopover?.close()
        NSWorkspace.shared.open(URL(string: "https://github.com/teamleaderleo/idlesse/releases")!)
    }

    @objc private func openAppRepository() {
        aboutPopover?.close()
        NSWorkspace.shared.open(URL(string: "https://github.com/teamleaderleo/idlesse")!)
    }

    @objc private func addWallpaperFromSidebar() { library.importWallpapers() }

    @objc private func openPreferences() { wallpaper.onShowSettings?() }

    @objc private func togglePause() { wallpaper.togglePause(); refreshState() }

    @objc private func showNowPlaying() {
        nowPlayingPopover?.close()
        let popover = NSPopover()
        let controller = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: wallpaper.hasSceneControls ? 350 : 320))
        let artwork = NSImageView()
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 10
        artwork.layer?.masksToBounds = true
        artwork.image = cachedThumbnail
        var artworkURL = wallpaper.selectedURL
        if let artworkURL {
            library.requestPlaybackArtwork(artworkURL) { [weak self, weak artwork] image in
                guard self?.wallpaper.selectedURL == artworkURL else { return }
                artwork?.image = image
            }
        }
        let title = NSTextField(labelWithString: nowPlayingTitle.stringValue)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let destination = NSTextField(labelWithString: destinationLabel.stringValue)
        destination.textColor = .secondaryLabelColor
        destination.isHidden = destination.stringValue.isEmpty
        let stop = LibraryHoverButton(title: "Stop", target: self, action: #selector(stopWallpaper))
        stop.bezelStyle = .rounded
        stop.isEnabled = wallpaper.selectedURL != nil
        let pause = LibraryHoverButton(title: wallpaper.pausedByUser ? "Resume" : "Pause", target: self, action: #selector(togglePopoverPause))
        pause.isEnabled = wallpaper.canPausePlayback
        let sound = LibraryHoverButton(checkboxWithTitle: "Wallpaper Sound", target: self, action: #selector(togglePopoverSound))
        sound.state = wallpaper.soundEnabled ? .on : .off
        sound.isEnabled = wallpaper.hasVideoContent
        let controls = LibraryHoverButton(title: "Scene Controls…", target: self, action: #selector(openSceneControls))
        controls.isHidden = !wallpaper.hasSceneControls
        pause.isBordered = false
        stop.isBordered = false
        let previous = LibraryHoverButton(image: NSImage(systemSymbolName: "backward.end.fill", accessibilityDescription: "Previous wallpaper")!, target: self, action: #selector(previousWallpaper))
        let next = LibraryHoverButton(image: NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: "Next wallpaper")!, target: self, action: #selector(nextWallpaper))
        previous.isBordered = false
        next.isBordered = false
        let playback = NSStackView(views: [previous, pause, next, NSView(), stop])
        playback.spacing = 8
        let stack = NSStackView(views: [artwork, title, destination, playback, sound, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            artwork.widthAnchor.constraint(equalTo: stack.widthAnchor),
            artwork.heightAnchor.constraint(equalToConstant: 184),
            playback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        controller.view = container
        popover.contentViewController = controller
        popover.behavior = .transient
        nowPlayingPopover = popover
        refreshPlaybackPopover = { [weak self, weak popover, weak title, weak destination, weak pause, weak stop, weak sound, weak controls, weak artwork] in
            guard let self, let popover, popover.isShown else { return }
            title?.stringValue = self.nowPlayingTitle.stringValue
            if self.wallpaper.selectedURL != artworkURL, let url = self.wallpaper.selectedURL {
                artworkURL = url
                self.library.requestPlaybackArtwork(url) { [weak self, weak artwork] image in
                    guard self?.wallpaper.selectedURL == url else { return }
                    artwork?.image = image
                }
            }
            destination?.stringValue = self.destinationLabel.stringValue
            destination?.isHidden = self.destinationLabel.stringValue.isEmpty
            pause?.title = self.wallpaper.pausedByUser ? "Resume" : "Pause"
            pause?.isEnabled = self.wallpaper.canPausePlayback
            stop?.isEnabled = self.wallpaper.selectedURL != nil
            sound?.state = self.wallpaper.soundEnabled ? .on : .off
            sound?.isEnabled = self.wallpaper.hasVideoContent
            controls?.isHidden = !self.wallpaper.hasSceneControls
            popover.contentSize = NSSize(width: 360, height: self.wallpaper.hasSceneControls ? 350 : 320)
        }
        popover.show(relativeTo: nowPlayingTitle.bounds, of: nowPlayingTitle, preferredEdge: .maxY)
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
        library.updatePlaybackState(wallpaper)
        let url = wallpaper.selectedURL
        let displayURLs = NSScreen.screens.map { screen in
            wallpaper.displayURL(for: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0)?.standardizedFileURL
        }
        let commonURL = displayURLs.first ?? nil
        library.updatePlayingURL(displayURLs.allSatisfy { $0 == commonURL } ? commonURL : nil)
        let title = wallpaper.currentSceneTitle ?? url.map { SceneLibraryController.displayTitle($0.deletingPathExtension().lastPathComponent) } ?? "No Wallpaper"
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        let assignments = screens.map { screen -> String in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            return wallpaper.displayURL(for: id).map {
                SceneLibraryController.displayTitle($0.deletingPathExtension().lastPathComponent)
            } ?? "None"
        }
        let distinctTitles = assignments.reduce(into: [String]()) { values, value in
            if !values.contains(value) { values.append(value) }
        }
        let displayedTitle = wallpaper.sameWallpaperOnAllDisplays ? title : distinctTitles.joined(separator: " · ")
        if nowPlayingTitle.stringValue != displayedTitle { nowPlayingTitle.stringValue = displayedTitle }
        nowPlayingTitle.toolTip = wallpaper.sameWallpaperOnAllDisplays ? title : zip(screens, assignments).map { "\($0.0.localizedName): \($0.1)" }.joined(separator: "\n")
        let standardized = url?.standardizedFileURL
        if standardized != cachedThumbnailURL {
            cachedThumbnailURL = standardized
            audioProbe?.cancel()
            playerSound.isHidden = true
            playerBackdrop.image = nil
            if let url {
                audioProbe = Task { @MainActor [weak self] in
                    let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
                    guard !Task.isCancelled, self?.cachedThumbnailURL == url.standardizedFileURL else { return }
                    self?.playerSound.isHidden = tracks?.isEmpty != false
                }
            }
            cachedThumbnail = thumbnail(for: url)
            if let url {
                library.requestPlaybackArtwork(url) { [weak self] image in
                    guard let self, self.cachedThumbnailURL == url.standardizedFileURL else { return }
                    let artwork = NSImage(size: NSSize(width: 60, height: 34))
                    artwork.lockFocus()
                    image.draw(in: NSRect(x: 0, y: 0, width: 60, height: 34))
                    artwork.unlockFocus()
                    self.cachedThumbnail = artwork
                    self.playerArtwork.image = artwork
                    self.playerBackdrop.image = image
                }
            }
        }
        playerArtwork.image = cachedThumbnail
        pauseButton.image = NSImage(systemSymbolName: wallpaper.pausedByUser ? "play.fill" : "pause.fill",
            accessibilityDescription: wallpaper.pausedByUser ? "Resume wallpaper" : "Pause wallpaper")
        pauseButton.toolTip = nil
        pauseButton.setAccessibilityLabel(wallpaper.pausedByUser ? "Resume wallpaper" : "Pause wallpaper")
        pauseButton.setAccessibilityLabel(pauseButton.toolTip)
        pauseButton.isEnabled = wallpaper.canPausePlayback
        previousButton.isEnabled = library.hasCycleCandidates
        nextButton.isEnabled = library.hasCycleCandidates
        previousButton.toolTip = nil
        nextButton.toolTip = nil
        var parts: [String] = []
        if wallpaper.isLoading { parts.insert("Loading…", at: 0) }
        if let rotation = rotationSummary() { parts.append(rotation) }
        destinationLabel.stringValue = parts.joined(separator: " · ")
        if parts.isEmpty {
            destinationLabel.stringValue = url == nil ? "Choose a wallpaper" : (wallpaper.pausedByUser ? "Paused" : "")
        }
        destinationLabel.isHidden = destinationLabel.stringValue.isEmpty
        playerSound.image = NSImage(systemSymbolName: wallpaper.soundEnabled ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: "Wallpaper sound")
        playerSound.isEnabled = wallpaper.hasVideoContent
        playerSound.toolTip = wallpaper.soundEnabled ? "Mute wallpaper" : "Unmute wallpaper"
        playerSound.setAccessibilityLabel(playerSound.toolTip)
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
            if case .video = content {
                precondition(WallpaperSurface.usesMetal(plain, menuAnimation: false),
                             "Video playback uses the shared Metal compositor without menu animation")
            } else if ProcessInfo.processInfo.environment["IDLESSE_METAL_COMPOSITOR"] != "1" {
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
            activateDisplaysDestination: { displayActivated = true }, persistLayout: false)
        precondition(home.window.contentViewController is NSSplitViewController)
        precondition(home.rows.contains(.library) && home.rows.contains(.displays))
        precondition(home.rows.contains(.favorites) && home.rows.contains(.recent))
        precondition(home.window.toolbar != nil)
        precondition(!home.window.toolbar!.items.map(\.itemIdentifier).contains(Self.settingsItem))
        let searchItem = home.window.toolbar!.items.first { $0.itemIdentifier == Self.searchItem }
        precondition(searchItem != nil, "Search belongs above the Library browsing controls")
        precondition(!home.window.toolbar!.items.contains { $0.itemIdentifier == Self.importItem })
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
        let libraryItemIDs: Set<NSToolbarItem.Identifier> = [Self.searchItem, Self.layoutItem, Self.inspectorControlItem]
        let libraryToolbarViews = home.window.toolbar!.items.filter { libraryItemIDs.contains($0.itemIdentifier) }.compactMap(\.view)
        precondition(libraryToolbarViews.allSatisfy(\.isHidden), "Displays must hide Library-only toolbar controls")
        home.showLibraryScope(.library)
        precondition(libraryToolbarViews.allSatisfy { !$0.isHidden }, "Returning to Library must restore its controls")
        precondition(home.currentRow == .library && !home.libraryView.isHidden)
    }
}

/// Neutral selection keeps navigation subordinate to the artwork.
private final class LibraryNavigationRow: NSTableRowView {
    var acceptsHover = true
    private var hoverTracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovered = acceptsHover }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard hovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NekoIcons.accent.withAlphaComponent(isEmphasized ? 0.55 : 0.36).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

/// A panoramic crop with a readable leading edge, independent of desktop playback.
private final class WallpaperHeaderArtwork: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).addClip()
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                             width: size.width, height: size.height))
        NSGradient(colors: [NSColor.windowBackgroundColor.withAlphaComponent(0.78),
                            NSColor.windowBackgroundColor.withAlphaComponent(0.62),
                            NSColor.windowBackgroundColor.withAlphaComponent(0.40)])?.draw(in: bounds, angle: 0)
    }
}

/// The navigation and content surfaces have distinct luminance, without black seams.
enum LibrarySurfaceColors {
    static let sidebar = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.073, green: 0.077, blue: 0.092, alpha: 1) : NSColor(white: 0.94, alpha: 1)
    }
    static let content = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.048, green: 0.052, blue: 0.063, alpha: 1) : NSColor(white: 1, alpha: 1)
    }
}
final class LibrarySplitView: NSSplitView {
    override var dividerColor: NSColor { NekoIcons.accent.withAlphaComponent(0.08) }
    override func drawDivider(in rect: NSRect) {
        dividerColor.setFill()
        NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
    }
}

/// Content-sized sidebar action with deliberate icon, text, and hover insets.
private final class LibrarySidebarAddButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: ceil(width) + 46, height: 32)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NekoIcons.accent.withAlphaComponent(isHighlighted ? 0.30 : 0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        NekoIcons.ivory.setStroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.5
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: 11, y: bounds.midY))
        plus.line(to: NSPoint(x: 23, y: bounds.midY))
        plus.move(to: NSPoint(x: 17, y: bounds.midY - 6))
        plus.line(to: NSPoint(x: 17, y: bounds.midY + 6))
        plus.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NekoIcons.ivory]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 31, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// A shared, quiet hover treatment for library actions.
class LibraryHoverButton: NSButton {
    var squareHover = false
    var iconSize: CGFloat = 19
    var iconTint: NSColor = .labelColor
    private var hoverTracking: NSTrackingArea?
    private var hovering = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let iconOnly = imagePosition == .imageOnly && image != nil
        if hovering && isEnabled || (iconOnly && isHighlighted) {
            NSColor(calibratedRed: 0.66, green: 0.57, blue: 0.73, alpha: isHighlighted ? 0.22 : 0.14).setFill()
            let side = min(bounds.width, bounds.height)
            let hoverRect = squareHover || iconOnly
                ? NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
                : bounds
            NSBezierPath(roundedRect: hoverRect, xRadius: 9, yRadius: 9).fill()
        }
        if iconOnly, let image {
            let side = iconSize
            let symbol = image.withSymbolConfiguration(.init(pointSize: side, weight: .regular)) ?? image
            let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [iconTint])) ?? symbol
            tinted.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                  width: side, height: side), from: .zero, operation: .sourceOver,
                        fraction: isEnabled ? 1 : 0.45, respectFlipped: true, hints: nil)
        } else { super.draw(dirtyRect) }
    }
}

/// Selection semantics with a menu that opens below the control.
final class LibraryFilterButton: NSPopUpButton {
    private var hoverTracking: NSTrackingArea?
    private var hovering = false
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 18
        return size
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovering && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
        let arrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        arrow?.draw(in: NSRect(x: bounds.maxX - 13, y: bounds.midY - 4, width: 9, height: 8), from: .zero, operation: .sourceOver, fraction: isEnabled ? 0.8 : 0.3)
    }
    override func performClick(_ sender: Any?) { showChoices() }

    override func mouseDown(with event: NSEvent) { showChoices() }
    private func showChoices() {
        guard isEnabled else { return }
        let choices = NSMenu()
        for (index, source) in itemArray.enumerated() {
            let item = NSMenuItem(title: source.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == indexOfSelectedItem ? .on : .off
            choices.addItem(item)
        }
        choices.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY : bounds.minY), in: self)
    }
    @objc private func choose(_ sender: NSMenuItem) {
        selectItem(at: sender.tag)
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

/// Shared 24-point vector masters. Feline details stay inside recognizable silhouettes.
enum NekoIcons {
    static let ivory = NSColor(calibratedRed: 0.91, green: 0.88, blue: 0.83, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.43, green: 0.36, blue: 0.53, alpha: 1)
    static func image(_ name: String) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
            ivory.setStroke(); ivory.setFill()
            func path(_ points: [(CGFloat, CGFloat)], close: Bool = false) {
                let p = NSBezierPath(); p.lineWidth = 1.65; p.lineCapStyle = .round; p.lineJoinStyle = .round
                for (i, v) in points.enumerated() {
                    if i == 0 { p.move(to: NSPoint(x: v.0, y: v.1)) }
                    else { p.line(to: NSPoint(x: v.0, y: v.1)) }
                }
                if close { p.close() }; p.stroke()
            }
            func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, fill: Bool = false) {
                let p = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h)); p.lineWidth = 1.65
                if fill { p.fill() } else { p.stroke() }
            }
            switch name {
            case "search":
                oval(3, 6, 14, 13); path([(4,8),(4,3),(8,6)]); path([(12,6),(16,3),(16,9)])
                let p = NSBezierPath(); p.lineWidth = 1.65; p.lineCapStyle = .round
                p.move(to: NSPoint(x: 16,y: 17)); p.line(to: NSPoint(x: 21,y: 22)); p.stroke()
            case "library", "folder", "display":
                path([(3,8),(3,4),(7,7),(17,7),(21,4),(21,18),(3,18),(3,8)])
                if name == "display" { path([(10,18),(10,22),(14,22),(16,20)]) }
                if name == "library" { path([(7,14),(10,11),(13,14),(15,12),(18,15)]) }
            case "filter":
                path([(3,6),(21,6)]); path([(3,12),(21,12)]); path([(3,18),(21,18)])
                for (x,y) in [(8.0,6.0),(16.0,12.0),(10.0,18.0)] { oval(x-1.8,y-1.8,3.6,3.6,fill:true) }
            case "sort":
                path([(7,19.8),(7,4.2),(3,8.2)]); path([(7,4.2),(11,8.2)])
                path([(17,4.2),(17,19.8),(13,15.8)]); path([(17,19.8),(21,15.8)])
            case "more":
                for x in [3.9, 12.0, 20.1] { oval(x - 1.8, 10.2, 3.6, 3.6, fill: true) }
            case "refresh":
                let p = NSBezierPath(); p.lineWidth = 1.7; p.lineCapStyle = .round
                p.move(to: NSPoint(x:19,y:8))
                p.curve(to:NSPoint(x:5,y:7),controlPoint1:NSPoint(x:16,y:2),controlPoint2:NSPoint(x:8,y:2))
                p.curve(to:NSPoint(x:6,y:19),controlPoint1:NSPoint(x:1,y:11),controlPoint2:NSPoint(x:2,y:16))
                p.curve(to:NSPoint(x:21,y:13),controlPoint1:NSPoint(x:12,y:24),controlPoint2:NSPoint(x:21,y:20)); p.stroke()
                path([(19,3),(19,8),(14,8)])
            case "favorite", "favoriteSelected":
                let p = NSBezierPath(); p.lineWidth = 1.7; p.lineJoinStyle = .round
                p.move(to:NSPoint(x:12,y:20))
                p.curve(to:NSPoint(x:3,y:9),controlPoint1:NSPoint(x:8,y:17),controlPoint2:NSPoint(x:3,y:14))
                p.curve(to:NSPoint(x:12,y:7),controlPoint1:NSPoint(x:3,y:3),controlPoint2:NSPoint(x:9,y:2))
                p.curve(to:NSPoint(x:21,y:9),controlPoint1:NSPoint(x:15,y:2),controlPoint2:NSPoint(x:21,y:3))
                p.curve(to:NSPoint(x:12,y:20),controlPoint1:NSPoint(x:21,y:14),controlPoint2:NSPoint(x:16,y:17))
                p.close(); if name == "favoriteSelected" { p.fill() } else { p.stroke() }
            case "settings":
                oval(7,11,10,9); oval(3,8,4,5); oval(7,3,4,6); oval(13,3,4,6); oval(17,8,4,5)
                oval(10,14,4,3)
            case "grid":
                for x in [3.0,14.0] { for y in [3.0,14.0] {
                    let p = NSBezierPath(roundedRect:NSRect(x:x,y:y,width:7,height:7),xRadius:2,yRadius:2); p.lineWidth=1.65; p.stroke()
                } }
            case "list":
                for y in [5.0,12.0,19.0] { oval(2,y-1,2,2,fill:true); path([(8,y),(21,y)]) }
            case "cat":
                let body = NSBezierPath(ovalIn: NSRect(x:5,y:11,width:15,height:10)); body.fill()
                let head = NSBezierPath(); head.move(to:NSPoint(x:14,y:13)); head.line(to:NSPoint(x:14,y:6)); head.line(to:NSPoint(x:18,y:9)); head.line(to:NSPoint(x:22,y:7)); head.line(to:NSPoint(x:22,y:15)); head.close(); head.fill()
                let tail = NSBezierPath(); tail.lineWidth=3; tail.lineCapStyle = .round
                tail.move(to:NSPoint(x:17,y:21)); tail.curve(to:NSPoint(x:4,y:4),controlPoint1:NSPoint(x:0,y:25),controlPoint2:NSPoint(x:0,y:11)); tail.stroke()
                NSColor(white:0.08,alpha:1).setStroke(); path([(17,13),(19,14),(21,12)])
            default: break
            }
            return true
        }
    }
}
