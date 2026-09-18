import AppKit

extension Notification.Name {
    static let idlesseDisplayPreparationChanged = Notification.Name("IdlesseDisplayPreparationChanged")
    static let idlesseDisplayAssignmentsChanged = Notification.Name("IdlesseDisplayAssignmentsChanged")
}

private final class DisplayMapView: NSView {
    var preparing: [UInt32: URL] = [:] { didSet { needsDisplay = true } }
    var allowsSelection = true
    var artwork: [URL: NSImage] = [:] { didSet { needsDisplay = true } }
    var requestArtwork: ((URL, @escaping (NSImage) -> Void) -> Void)?
    private var pendingArtwork = Set<URL>()
    private var dropTarget: UInt32?
    private var dropURL: URL?
    private func loadArtwork(_ url: URL) {
        guard artwork[url] == nil, !pendingArtwork.contains(url), let requestArtwork else { return }
        pendingArtwork.insert(url)
        requestArtwork(url) { [weak self] image in
            self?.pendingArtwork.remove(url)
            self?.artwork[url] = image
        }
    }
    var topology = DisplayTopology(displays: []) { didSet { needsDisplay = true } }
    var plan: ResolvedWallpaperAssignmentPlan? { didSet { needsDisplay = true } }
    var selectedID: UInt32? { didSet { needsDisplay = true; onSelection?(selectedID) } }
    var onSelection: ((UInt32?) -> Void)?
    var onDrop: ((UInt32, URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    private var allTargetFrame: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: 64)
    }
    private var displayFrames: [UInt32: NSRect] {
        let frames = topology.normalizedFrames(
            in: NSSize(width: bounds.width, height: max(0, bounds.height - 96)), padding: 0)
        let top = frames.values.map(\.minY).min() ?? 0
        return frames.mapValues { $0.offsetBy(dx: 0, dy: allTargetFrame.maxY + 24 - top) }
    }
    private func previewsDrop(on displayID: UInt32) -> Bool {
        guard let dropTarget else { return false }
        if dropTarget == 0 { return true }
        guard let target = topology.displays.first(where: { $0.liveID == dropTarget }),
              let display = topology.displays.first(where: { $0.liveID == displayID }) else { return false }
        return topology.master(for: target).liveID == topology.master(for: display).liveID
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let frames = displayFrames
        let targetPath = NSBezierPath(roundedRect: allTargetFrame, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.3).setFill()
        targetPath.fill()
        var sources: [URL] = []
        for display in topology.displays {
            if let source = dropTarget == 0 ? dropURL : plan?.assignment(for: display.liveID)?.sourceURL,
               !sources.contains(source) { sources.append(source) }
        }
        NSGraphicsContext.saveGraphicsState()
        targetPath.addClip()
        for (index, source) in sources.enumerated() {
            loadArtwork(source)
            guard let image = artwork[source] else { continue }
            let width = allTargetFrame.width / CGFloat(sources.count)
            let slice = NSRect(x: allTargetFrame.minX + CGFloat(index) * width, y: 0, width: width, height: 64)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: slice).addClip()
            let scale = max(width / max(1, image.size.width), 64 / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: slice.midX - size.width / 2, y: slice.midY - size.height / 2,
                                 width: size.width, height: size.height), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(colors: [.black.withAlphaComponent(0.2), .black.withAlphaComponent(0.75)])?.draw(in: allTargetFrame, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(dropTarget == 0 ? 0.65 : 0.14).setStroke()
        targetPath.lineWidth = dropTarget == 0 ? 1.5 : 0.5
        targetPath.stroke()
        let label = dropTarget == 0 ? "Release to apply to all displays" : "All displays"
        (label as NSString).draw(at: NSPoint(x: allTargetFrame.minX + 12, y: 14), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        let caption = sources.count == 1 ? displayName(sources[0]) : (sources.isEmpty ? "No wallpaper" : "Different wallpapers")
        (caption as NSString).draw(in: NSRect(x: allTargetFrame.minX + 12, y: 34, width: allTargetFrame.width - 24, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        for display in topology.displays {
            guard let frame = frames[display.liveID] else { continue }
            let selected = allowsSelection && selectedID == display.liveID
            let mirrored = display.mirrorMasterID != nil
            let master = topology.master(for: display)
            let path = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
            NSColor.black.withAlphaComponent(0.75).setFill()
            path.fill()
            let source = previewsDrop(on: display.liveID) ? dropURL : plan?.assignment(for: display.liveID)?.sourceURL
            if let source {
                loadArtwork(source)
                if let image = artwork[source] {
                    NSGraphicsContext.saveGraphicsState()
                    path.addClip()
                    var canvas = frame
                    if plan?.mode == .desktopSpan && dropTarget == nil {
                        canvas = frames.values.reduce(NSRect.null) { $0.union($1) }
                    }
                    let scale = max(canvas.width / max(1, image.size.width), canvas.height / max(1, image.size.height))
                    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: NSRect(x: canvas.midX-size.width/2, y: canvas.midY-size.height/2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    NSGradient(colors: [.black.withAlphaComponent(0.55), .clear, .black.withAlphaComponent(0.65)])?.draw(in: frame, angle: 90)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            (previewsDrop(on: display.liveID) ? NSColor.white : (selected ? NekoIcons.accent.withAlphaComponent(0.7) : NSColor.white.withAlphaComponent(0.16))).setStroke()
            path.lineWidth = selected ? 1.2 : 0.5
            path.stroke()

            if mirrored {
                let inset = NSBezierPath(roundedRect: frame.insetBy(dx: 7, dy: 7), xRadius: 7, yRadius: 7)
                NSColor.secondaryLabelColor.setStroke()
                inset.lineWidth = 1
                inset.stroke()
            }

            let assignment = plan?.assignment(for: display.liveID)
            var title = display.identity.name
            if display.isMain { title += " · Main" }
            if mirrored { title += " · Mirrored" }
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            (title as NSString).draw(
                in: NSRect(x: frame.minX + 10, y: frame.minY + 9,
                           width: max(10, frame.width - 20), height: 17),
                withAttributes: titleAttributes)
            if mirrored, master.liveID != display.liveID {
                ("Follows \(master.identity.name)" as NSString).draw(
                    in: NSRect(x: frame.minX + 10, y: frame.minY + 27,
                               width: max(10, frame.width - 20), height: 15),
                    withAttributes: detailAttributes)
            }
            let pending = preparing[master.liveID]
            let sourceCaption = previewsDrop(on: display.liveID) ? "Release to assign" :
                (pending.map { "Preparing · " + displayName($0) } ?? assignment?.sourceURL.map(displayName) ?? "No Wallpaper")
            (sourceCaption as NSString).draw(
                in: NSRect(x: frame.minX + 10, y: frame.maxY - 26,
                           width: max(10, frame.width - 20), height: 15),
                withAttributes: detailAttributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsSelection else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frames = displayFrames
        selectedID = topology.displays.reversed().first {
            frames[$0.liveID]?.contains(point) == true
        }?.liveID
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = destination(for: sender)
        dropTarget = target?.0
        dropURL = target?.1
        if let dropURL { loadArtwork(dropURL) }
        needsDisplay = true
        return target == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = destination(for: sender)
        dropTarget = target?.0
        dropURL = target?.1
        if let dropURL { loadArtwork(dropURL) }
        needsDisplay = true
        return target == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = nil; dropURL = nil; needsDisplay = true }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTarget = nil; dropURL = nil; needsDisplay = true
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        destination(for: sender) != nil && onDrop != nil
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTarget = nil; dropURL = nil; needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (displayID, url) = destination(for: sender) else { return false }
        dropTarget = nil; dropURL = nil; needsDisplay = true
        selectedID = displayID
        onDrop?(displayID, url)
        return true
    }

    private func destination(for sender: NSDraggingInfo) -> (UInt32, URL)? {
        let point = convert(sender.draggingLocation, from: nil)
        let frames = displayFrames
        guard let item = sender.draggingPasteboard.pasteboardItems?.first,
              let value = item.string(forType: .fileURL),
              let url = URL(string: value), url.isFileURL else { return nil }
        guard let display = topology.displays.reversed().first(where: {
            frames[$0.liveID]?.contains(point) == true
        }) else { return allTargetFrame.contains(point) ? (0, url) : nil }
        return (display.liveID, url)
    }

    private func displayName(_ url: URL) -> String {
        SceneLibraryController.displayTitle(url.deletingPathExtension().lastPathComponent)
    }
}

/// Reusable visual Displays destination. #52 can host this in its conventional
/// standalone window and #30 Home can host the exact same controller in its
/// content split without moving a view out of another window.
final class DisplayAssignmentViewController: NSViewController {
    private struct PendingLibraryTarget {
        let liveID: UInt32
        let previousDefault: URL?
        let expires: Date
    }

    var requestArtwork: ((URL, @escaping (NSImage) -> Void) -> Void)? {
        didSet { mapView.requestArtwork = requestArtwork; mapView.needsDisplay = true }
    }
    private let compact: Bool
    private weak var wallpaper: WallpaperController?
    private let mode = NSSegmentedControl(
        labels: ["Same Wallpaper Everywhere", "Customize Each Display"],
        trackingMode: .selectOne, target: nil, action: nil)
    private let arrangement = NSTextField(labelWithString: "")
    private let spanStatus = NSTextField(wrappingLabelWithString: "This wallpaper spans the desktop. Your individual display assignments are kept for later.")
    private let rememberArrangement = NSButton(title: "Remember This Setup", target: nil, action: nil)
    private let mapView = DisplayMapView(frame: .zero)
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let useDefault = NSButton(title: "Use Shared Wallpaper", target: nil, action: nil)
    private let openLibrary = NSButton(title: "Choose in Library…", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var topology = DisplayTopology(displays: [])
    private var plan: ResolvedWallpaperAssignmentPlan?
    private var selectedID: UInt32?
    func applyLibraryWallpaper(_ url: URL) {
        wallpaper?.assignLibraryWallpaper(url, to: nil)
    }

    func libraryTargetContains(_ url: URL) -> Bool {
        !topology.displays.isEmpty && topology.displays.allSatisfy {
            plan?.assignment(for: $0.liveID)?.sourceURL?.standardizedFileURL == url.standardizedFileURL
        }
    }
    var onLibraryTargetChange: (() -> Void)?
    private var pendingLibraryTarget: PendingLibraryTarget?
    private var reconcilingLibraryTarget = false
    private var topologyRefreshWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private let arrangements = KnownDisplayArrangementsStore(defaults: .standard)

    init(wallpaper: WallpaperController, compact: Bool = false) {
        self.compact = compact
        self.wallpaper = wallpaper
        super.init(nibName: nil, bundle: nil)
        observers.append(NotificationCenter.default.addObserver(
            forName: .idlesseDisplayAssignmentsChanged, object: wallpaper, queue: .main) { [weak self] _ in
                self?.assignmentDidChange()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .idlesseDisplayPreparationChanged, object: wallpaper, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.mapView.preparing = self.wallpaper?.preparingDisplayURLs ?? [:]
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.pendingLibraryTarget = nil
                self?.scheduleTopologyRefresh()
            })
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        topologyRefreshWorkItem?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 650))
        view = root
        installContent(in: root)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
    }

    /// Refresh before presenting or embedding this destination. Keeping this
    /// explicit also gives Home a deterministic lifecycle hook in smoke tests.
    func activate() {
        pendingLibraryTarget = nil
        _ = view
        rebuild()
    }

    private func installContent(in content: NSView) {
        let title = NSTextField(labelWithString: "Displays")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        mode.selectedSegmentBezelColor = NekoIcons.accent
        mode.target = self
        mode.action = #selector(changeMode(_:))
        mode.setContentHuggingPriority(.required, for: .horizontal)
        arrangement.setAccessibilityLabel("Known display arrangement")
        arrangement.setContentHuggingPriority(.required, for: .horizontal)
        arrangement.textColor = NekoIcons.ivory
        arrangement.font = .systemFont(ofSize: 12, weight: .medium)
        spanStatus.textColor = .secondaryLabelColor
        spanStatus.font = .systemFont(ofSize: 12)
        rememberArrangement.target = self
        rememberArrangement.action = #selector(rememberCurrentArrangement)
        rememberArrangement.bezelStyle = .rounded
        rememberArrangement.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView(frame: .zero)
        let controls = NSStackView(views: [mode, spanStatus, spacer, arrangement, rememberArrangement])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        mapView.allowsSelection = !compact
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.heightAnchor.constraint(equalToConstant: compact ? 250 : 375).isActive = true
        mapView.onSelection = { [weak self] id in self?.select(id) }
        mapView.onDrop = { [weak self] id, url in self?.assign(url, to: id) }

        detailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        detailText.textColor = .secondaryLabelColor
        detailText.maximumNumberOfLines = 3
        useDefault.target = self
        useDefault.action = #selector(clearSelected)
        openLibrary.target = self
        openLibrary.action = #selector(showLibrary)
        let buttons = NSStackView(views: [useDefault, openLibrary])
        buttons.spacing = 8
        hint.textColor = .secondaryLabelColor
        mapView.toolTip = "Drop a wallpaper onto a screen to assign it, or onto All displays to use it everywhere."

        let detailBox = NSBox()
        detailBox.boxType = .custom
        detailBox.borderType = .noBorder
        detailBox.cornerRadius = 10
        detailBox.contentViewMargins = NSSize(width: 14, height: 12)
        if let boxContent = detailBox.contentView {
            let detailStack = NSStackView(views: [detailTitle, detailText, buttons])
            detailStack.orientation = .vertical
            detailStack.alignment = .leading
            detailStack.spacing = 8
            detailStack.translatesAutoresizingMaskIntoConstraints = false
            boxContent.addSubview(detailStack)
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 650).isActive = true
            NSLayoutConstraint.activate([
                detailStack.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor),
                detailStack.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor),
                detailStack.topAnchor.constraint(equalTo: boxContent.topAnchor),
                detailStack.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor),
            ])
        }

        let stack = NSStackView(views: compact ? [mapView] : [title, controls, mapView, detailBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        spanStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 410).isActive = true
        if !compact { controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        mapView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if !compact { detailBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: compact ? 0 : 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: compact ? 0 : -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: compact ? 8 : 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: compact ? -8 : -24),
        ])
    }

    /// Dock transitions often emit several intermediate screen-parameter events.
    /// Coalesce those for 300 ms before identity matching or assignment restore.
    private func scheduleTopologyRefresh() {
        topologyRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.topologyRefreshWorkItem = nil
            guard self?.isViewLoaded == true else { return }
            self?.rebuild()
        }
        topologyRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rebuild() {
        guard isViewLoaded, let wallpaper else { return }
        topology = .current()
        wallpaper.reconcileDurableDisplayAssignments(topology: topology)
        plan = wallpaper.resolvedDisplayAssignmentPlan(topology: topology)
        let current = arrangements.touchKnown(topology)
        reloadArrangements(current: current)
        mapView.topology = topology
        mapView.plan = plan
        mapView.preparing = wallpaper.preparingDisplayURLs
        mapView.setAccessibilityElement(true)
        mapView.setAccessibilityRole(.image)
        mapView.setAccessibilityLabel(topology.displays.map { display in
            let title = plan?.assignment(for: display.liveID)?.sourceURL?.deletingPathExtension().lastPathComponent ?? "No wallpaper"
            return "\(display.identity.name): \(title)"
        }.joined(separator: "; "))

        switch plan?.mode {
        case .sameOnAll: mode.selectedSegment = 0
        case .perDisplay: mode.selectedSegment = 1
        case .desktopSpan: mode.selectedSegment = -1
        case nil: mode.selectedSegment = 0
        }
        mode.isHidden = plan?.mode == .desktopSpan
        spanStatus.isHidden = plan?.mode != .desktopSpan
        if selectedID == nil || !topology.displays.contains(where: { $0.liveID == selectedID }) {
            selectedID = topology.displays.first(where: { $0.isMain })?.liveID
                ?? topology.displays.first?.liveID
        }
        mapView.selectedID = selectedID
        onLibraryTargetChange?()
        refreshDetail()
    }

    private func reloadArrangements(current: DisplayArrangementProfile?) {
        arrangement.stringValue = current?.name ?? ""
        arrangement.isHidden = current == nil
        arrangement.toolTip = current == nil ? nil : "Remembered display setup"
        rememberArrangement.isHidden = current != nil || topology.displays.isEmpty
        rememberArrangement.isEnabled = !topology.displays.isEmpty

    }

    @objc private func rememberCurrentArrangement() {
        guard !topology.displays.isEmpty else { return }
        let profile = arrangements.saveCurrent(topology)
        reloadArrangements(current: profile)
    }

    private func select(_ id: UInt32?) {
        selectedID = id
        pendingLibraryTarget = nil
        refreshDetail()
    }

    private func refreshDetail() {
        guard let selectedID,
              let display = topology.displays.first(where: { $0.liveID == selectedID }) else {
            detailTitle.stringValue = "No display selected"
            detailText.stringValue = ""
            useDefault.isEnabled = false
            openLibrary.isEnabled = false
            return
        }
        let assignment = plan?.assignment(for: display.liveID)
        detailTitle.stringValue = display.identity.name + (display.isMain ? " · Main Display" : "")
        var details = [
            display.resolutionDescription,
        ]
        if let mirrorID = display.mirrorMasterID,
           let mirrored = topology.displays.first(where: { $0.liveID == mirrorID }) {
            details.append("Mirrors \(mirrored.identity.name)")
        }
        if let url = assignment?.sourceURL {
            let title = SceneLibraryController.displayTitle(url.deletingPathExtension().lastPathComponent)
            details.append((assignment?.explicit == true ? "Assigned: " : "Using: ") + title)
        } else {
            details.append("No wallpaper selected")
        }

        detailText.stringValue = details.joined(separator: " · ")
        useDefault.isEnabled = plan?.mode == .perDisplay
            && assignment?.explicit == true
            && display.mirrorMasterID == nil
        useDefault.isHidden = !useDefault.isEnabled
        openLibrary.isEnabled = true
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        guard let wallpaper, !wallpaper.desktopSpanActive else { rebuild(); return }
        pendingLibraryTarget = nil
        switch sender.selectedSegment {
        case 0: wallpaper.sameWallpaperOnAllDisplays = true
        case 1: wallpaper.sameWallpaperOnAllDisplays = false
        default: break
        }
        rebuild()
    }

    private func assign(_ url: URL, to displayID: UInt32) {
        guard let wallpaper else { return }
        pendingLibraryTarget = nil
        if displayID == 0 {
            wallpaper.assignLibraryWallpaper(url, to: nil)
            return
        }
        let display = topology.displays.first(where: { $0.liveID == displayID })
        let target = display.map { topology.master(for: $0).liveID } ?? displayID
        wallpaper.assignLibraryWallpaper(url, to: target, allowsDesktopSpan: false)
    }

    @objc private func clearSelected() {
        guard let wallpaper, let selectedID,
              let display = topology.displays.first(where: { $0.liveID == selectedID }) else { return }
        pendingLibraryTarget = nil
        wallpaper.clearDisplayURL(for: topology.master(for: display).liveID)
    }

    /// Reuse the real Library. In Per Display mode, the next ordinary Library
    /// Set Wallpaper becomes the selected monitor's override, then the prior
    /// shared/default wallpaper is restored. Desktop Span remains global.
    @objc private func showLibrary() {
        guard let selectedID, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Wallpaper"
        panel.message = "Choose a wallpaper for the selected display."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.assign(url, to: selectedID)
        }
    }

    private func assignmentDidChange() {
        guard isViewLoaded, !reconcilingLibraryTarget else { return }
        guard let pending = pendingLibraryTarget else { rebuild(); return }
        guard pending.expires > Date() else {
            pendingLibraryTarget = nil
            rebuild()
            return
        }
        guard let wallpaper, let chosen = wallpaper.selectedURL else { rebuild(); return }
        if wallpaper.desktopSpanActive {
            pendingLibraryTarget = nil
            rebuild()
            return
        }

        pendingLibraryTarget = nil
        reconcilingLibraryTarget = true
        wallpaper.setDisplayURL(chosen, for: pending.liveID)
        if let previous = pending.previousDefault,
           previous.standardizedFileURL != chosen.standardizedFileURL {
            wallpaper.select(previous, automatic: true)
        }
        reconcilingLibraryTarget = false
        rebuild()
    }
}

/// Standalone compatibility shell used by the existing #52 menu/command path.
/// Home embeds `destinationController` directly, preserving one visual Displays
/// implementation across both windows.
final class DisplayAssignmentController: NSWindowController {
    let destinationController: DisplayAssignmentViewController

    init(wallpaper: WallpaperController) {
        destinationController = DisplayAssignmentViewController(wallpaper: wallpaper)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Displays"
        window.minSize = NSSize(width: 700, height: 560)
        window.isReleasedWhenClosed = false
        window.contentViewController = destinationController
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        destinationController.activate()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
