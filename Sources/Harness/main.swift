import AppKit
import ScreenSaver

final class IdlesseAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var saverView: IdlesseView!
    private var settingsButton: NSButton!
    private var pauseButton: NSButton!
    private let wallpaper = WallpaperController()
    private let comfort = DesktopComfortController()
    private lazy var modes = AmbientModesController(wallpaper: wallpaper, comfort: comfort)
    private let hotKeys = HotKeysController()
    private var recentSceneURLs: [URL] = []
    private lazy var appSettings = AppSettingsController(comfort: comfort, wallpaper: wallpaper,
        showSaver: { [weak self] in self?.showSaverSettings(asSheet: true) })
    private var library: SceneLibraryController?
    private func prepareLibrary() throws {
        if library == nil {
        library = try SceneLibraryController(onUse: { [weak self] url in self?.wallpaper.select(url, automatic: true) },
            onEdit: { [weak self] url, asCopy in
                guard let self else { return }
                self.scenePreview.onClose = { [weak self] in
                    self?.library?.releaseActiveEditAccess()
                    self?.showLibrary()
                }
                self.scenePreview.openLibraryScene(url, asCopy: asCopy)
            })
        library?.onPeek = { [weak self] url in self?.wallpaper.peek(url) }
        library?.onEndPeek = { [weak self] reverting in
            self?.wallpaper.endPeek(reverting: reverting)
            self?.modes.refresh()
        }
        }
        wallpaper.onManualSelection = { [weak self] in
            self?.library?.stopRotation()
            self?.library?.releaseActiveUseAccess()
        }
        library?.startSchedules()
    }
    private var onboarding: OnboardingController?
    private func showOnboarding() {
        let scenes = SceneLibraryController.builtinScenes()
        guard !scenes.isEmpty else { showLibrary(); return }
        let controller = OnboardingController(
            builtins: scenes.map { (title: $0.title, url: $0.url) },
            onPick: { [weak self] url in self?.wallpaper.select(url) },
            onMirror: { [weak self] in self?.mirrorActiveWallpaper() ?? "No wallpaper is playing yet." },
            onOpenSaver: { [weak self] in self?.showSaverSettings(asSheet: false) },
            onDone: { [weak self] in self?.onboarding = nil; self?.showLibrary() })
        onboarding = controller
        controller.show()
    }
    private func mirrorActiveWallpaper() -> String {
        guard let url = wallpaper.selectedURL else { return "Pick a wallpaper first, then mirror it." }
        do {
            let targetURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            try IdlessePreferences.shared.saveFolder(targetURL)
            NotificationCenter.default.post(name: IdlessePreferences.settingsChangedNotification, object: nil)
            return "Screensaver now mirrors “\(url.lastPathComponent)”."
        } catch {
            return "Could not update the screensaver: \(error.localizedDescription)"
        }
    }
    @objc private func showLibrary() {
        do {
            try prepareLibrary()
            saverView?.stopAnimation()
            window?.orderOut(nil)
            if let library, let content = library.window?.contentView {
                library.embedded = true
                library.hostWindow = appSettings.window
                appSettings.installLibrary(content)
                appSettings.onLibraryVisible = { [weak library] in library?.refreshEmbedded() }
                appSettings.onClose = { [weak library] in library?.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
            }
            appSettings.present(tab: 3)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open the Library"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    private var pendingSceneURL: URL?
    private lazy var scenePreview = StudioWindowController { [weak self] url in self?.wallpaper.select(url) }
    @objc private func showScenePreview() {
        saverView?.stopAnimation()
        window?.orderOut(nil)
        scenePreview.onClose = { [weak self] in
            self?.library?.releaseActiveEditAccess()
            self?.showLibrary()
        }
        scenePreview.show()
    }


    private lazy var settingsController = ConfigureSheetController(preferences: IdlessePreferences.shared) { [weak self] in
        self?.saverView?.reloadFromPreferences()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let stampURL = Bundle.main.url(forResource: "build-stamp", withExtension: "txt"),
           let stamp = try? String(contentsOf: stampURL).trimmingCharacters(in: .whitespacesAndNewlines),
           !stamp.isEmpty {
            NSLog("Idlesse build %@", stamp)
            try? ("Idlesse build \(stamp)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/idlesse-state.log")))
        }
        installMenu()
        wallpaper.persistsSelection = true
        wallpaper.onStart = { [weak self] in
            self?.saverView?.stopAnimation()
            self?.window?.orderOut(nil)
        }
        wallpaper.onStop = { [weak self] in
            self?.library?.releaseActiveUseAccess()
            self?.showLibrary()
        }
        wallpaper.onShowPreview = { [weak self] in self?.showPreview() }
        wallpaper.presentingWindow = { [weak self] in self?.appSettings.window }
        wallpaper.extraMenuItemsProvider = { [weak self] in self?.menuExtras() ?? [] }
        wallpaper.onSelectionCommitted = { [weak self] url in
            self?.modes.adoptManualSelection(url)
            self?.noteRecentScene(url)
        }
        hotKeys.onNext = { [weak self] in self?.stepWallpaper(delta: 1) }
        hotKeys.onPrevious = { [weak self] in self?.stepWallpaper(delta: -1) }
        hotKeys.onTogglePause = { [weak self] in self?.wallpaper.togglePause() }
        hotKeys.start()
        wallpaper.comfort = comfort
        comfort.onDimmingChanged = { [weak self] value in
            self?.wallpaper.setDimmedForBedtime(value)
            self?.appSettings.updateDimming()
            self?.modes.refresh()
        }
        comfort.onShowSettings = { [weak self] in self?.showLibrary(); self?.appSettings.present(tab: 1) }
        wallpaper.onShowSettings = { [weak self] in self?.showSettings() }
        comfort.start()
        appSettings.modes = modes
        modes.start()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "Screen Saver Preview"
        window.center()

        guard let contentView = window.contentView else { return }
        saverView = IdlesseView(frame: contentView.bounds, isPreview: false)
        saverView.autoresizingMask = [.width, .height]
        contentView.addSubview(saverView)

        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 14
        bar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)

        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        pauseButton.toolTip = "Pause or resume (Space)"
        let nextButton = NSButton(title: "Next", target: self, action: #selector(nextImage))
        nextButton.toolTip = "Next picture (→)"
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealImage))
        settingsButton = NSButton(title: "Settings…", target: self, action: #selector(showSettings))
        let wallpaperButton = NSButton(title: "Wallpaper…", target: wallpaper, action: #selector(WallpaperController.chooseWallpaper))
        wallpaperButton.bezelStyle = .rounded
        let sceneButton = NSButton(title: "Studio…", target: self, action: #selector(showScenePreview))
        sceneButton.bezelStyle = .rounded
        let libraryButton = NSButton(title: "Library…", target: self, action: #selector(showLibrary))
        libraryButton.bezelStyle = .rounded
        let controls = NSStackView(views: [pauseButton, nextButton, revealButton, settingsButton, wallpaperButton, sceneButton, libraryButton])
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        for button in [pauseButton!, nextButton, revealButton, settingsButton!] {
            button.bezelStyle = .rounded
        }
        bar.addSubview(controls)
        NSLayoutConstraint.activate([
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            bar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            controls.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            controls.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            controls.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12),
        ])
        window.minSize = NSSize(width: 900, height: 360)

        wallpaper.restoreSelection()
        if OnboardingController.needed && pendingSceneURL == nil {
            showOnboarding()
        } else {
            showLibrary()
        }
        NSApp.activate(ignoringOtherApps: true)

        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let catalog = try SceneLibraryStore(file: support.appendingPathComponent("Idlesse/Library/index.json")).catalog
            if catalog.collections.contains(where: { $0.playback?.startMinute != nil }) { try prepareLibrary() }
        } catch { NSLog("Idlesse: saved Library schedules unavailable: %@", error.localizedDescription) }

        if let pendingSceneURL {
            route(pendingSceneURL)
            self.pendingSceneURL = nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil { pendingSceneURL = url }
        else { route(url) }
    }

    private func route(_ url: URL) {
        switch IdlesseExternalOpenRoute.classify(url) {
        case .sceneDocument:
            saverView?.stopAnimation()
            window?.orderOut(nil)
            scenePreview.onClose = { [weak self] in self?.showLibrary() }
            scenePreview.openLibraryScene(url, asCopy: false)
        case .wallpaperMedia:
            wallpaper.select(url)
        case .deepLink:
            switch url.host {
            case "wallpapers": showLibrary()
            case "screensaver":
                showLibrary()
                appSettings.present(tab: 2)
                showSaverSettings(asSheet: true)
            case "desktop-icons": comfort.toggleDesktopIcons()
            default: break
            }
        }
    }

    // MARK: - Hotkeys, menu extra, recents

    private func stepWallpaper(delta: Int) {
        do {
            try prepareLibrary()
            library?.cycle(delta: delta)
        } catch {
            NSSound.beep()
        }
    }
    private func noteRecentScene(_ url: URL) {
        recentSceneURLs.removeAll { $0 == url }
        recentSceneURLs.insert(url, at: 0)
        recentSceneURLs = Array(recentSceneURLs.prefix(5))
    }
    private func menuExtras() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let next = NSMenuItem(title: "Next Wallpaper  (⌃⌥⌘→)", action: #selector(nextWallpaper), keyEquivalent: "")
        next.target = self
        next.isEnabled = wallpaper.isRunning
        let previous = NSMenuItem(title: "Previous Wallpaper  (⌃⌥⌘←)", action: #selector(previousWallpaper), keyEquivalent: "")
        previous.target = self
        previous.isEnabled = wallpaper.isRunning
        items += [next, previous]
        let recents = recentSceneURLs.filter { $0 != wallpaper.selectedURL }.prefix(4)
        for url in recents {
            let item = NSMenuItem(title: SceneLibraryController.displayTitle(url.deletingPathExtension().lastPathComponent),
                action: #selector(applyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url as NSURL
            items.append(item)
        }
        return items
    }
    @objc private func nextWallpaper() { stepWallpaper(delta: 1) }
    @objc private func previousWallpaper() { stepWallpaper(delta: -1) }
    @objc private func applyRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        wallpaper.select(url)
    }

    @objc private func copyDiagnostics() {
        let bundle = Bundle.main
        var lines = ["Idlesse \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GiB"]
        for (index, screen) in NSScreen.screens.enumerated() {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let mode = id.flatMap { CGDisplayCopyDisplayMode($0) }
            lines.append("Display \(index + 1): \(mode?.pixelWidth ?? 0) × \(mode?.pixelHeight ?? 0) pixels; maximum \(screen.maximumFramesPerSecond) Hz; scale \(screen.backingScaleFactor)")
        }
        lines.append(wallpaper.diagnosticSummary)
        lines.append("Report excludes scene titles, file paths, display names, and asset contents.")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        scenePreview.mayQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.stop()
        library?.windowWillClose(notification)
        library?.releaseActiveUseAccess()
        library?.releaseActiveEditAccess()
        wallpaper.onStop = nil
        wallpaper.shutdown()
        saverView?.stopAnimation()
    }

    func windowDidMiniaturize(_ notification: Notification) { saverView?.stopAnimation() }
    func windowDidDeminiaturize(_ notification: Notification) { saverView?.startAnimation() }
    func windowWillClose(_ notification: Notification) { saverView?.stopAnimation() }
    func applicationDidHide(_ notification: Notification) { saverView?.stopAnimation(); scenePreview.applicationVisibilityChanged() }
    func applicationDidUnhide(_ notification: Notification) {
        scenePreview.applicationVisibilityChanged()
        if window.isVisible && !window.isMiniaturized { saverView?.startAnimation() }
    }

    @objc private func showPreview() {
        window.makeKeyAndOrderFront(nil)
        saverView.startAnimation()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePause() {
        saverView.togglePlaybackPause()
        pauseButton.title = saverView.isPlaybackPaused ? "Resume" : "Pause"
    }

    @objc private func nextImage() { saverView.showNextImage() }

    @objc private func revealImage() {
        if let url = saverView.displayedFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func showSettings() { showLibrary() }

    private func showSaverSettings(asSheet: Bool = false) {
        let settingsWindow = settingsController.window
        // Repeated Options clicks should focus the draft, not discard it or
        // silently return while its parent is behind another application.
        if settingsWindow.isVisible {
            let parent = settingsWindow.sheetParent ?? settingsWindow
            parent.deminiaturize(nil)
            parent.makeKeyAndOrderFront(nil)
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        settingsController.reload()
        if asSheet, let parent = appSettings.window {
            guard settingsWindow.sheetParent == nil else { return }
            settingsWindow.orderOut(nil)
            parent.deminiaturize(nil)
            parent.makeKeyAndOrderFront(nil)
            parent.beginSheet(settingsWindow)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveStudio() { scenePreview.saveDocument() }
    @objc private func saveStudioAs() { scenePreview.saveAsDocument() }
    @objc private func duplicateStudioLayer() { scenePreview.duplicateLayer() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePause) || menuItem.action == #selector(nextImage) {
            return window.isKeyWindow && !window.isMiniaturized
        }
        if [#selector(saveStudio), #selector(saveStudioAs), #selector(duplicateStudioLayer)].contains(menuItem.action) {
            return scenePreview.acceptsDocumentCommands
        }
        return true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let about = NSMenuItem(title: "About Idlesse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Idlesse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Idlesse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        for (title, action, key) in [("Save", #selector(saveStudio), "s"), ("Save As…", #selector(saveStudioAs), "S")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == key.uppercased() ? [.command, .shift] : [.command]
            item.target = self
            fileMenu.addItem(item)
        }
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == key.uppercased() ? [.command, .shift] : [.command]
            edit.addItem(item)
        }

        let duplicate = NSMenuItem(title: "Duplicate Layer", action: #selector(duplicateStudioLayer), keyEquivalent: "d")
        duplicate.target = self
        edit.addItem(duplicate)
        let playbackItem = NSMenuItem()
        let playback = NSMenu(title: "Playback")
        playbackItem.submenu = playback
        mainMenu.addItem(playbackItem)
        for (title, action, key) in [
            ("Pause / Resume", #selector(togglePause), " "),
            ("Next Picture", #selector(nextImage), String(UnicodeScalar(NSRightArrowFunctionKey)!))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            item.target = self
            playback.addItem(item)
        }
        let wallpaperItem = NSMenuItem()
        let wallpaperMenu = NSMenu(title: "Wallpaper")
        wallpaperItem.submenu = wallpaperMenu
        mainMenu.addItem(wallpaperItem)
        for (title, action) in [
            ("Choose Wallpaper…", #selector(WallpaperController.chooseWallpaper)),
            ("Pause / Resume Video", #selector(WallpaperController.togglePause)),
            ("Stop Wallpaper", #selector(WallpaperController.stop)),
            ("Show / Restore Windows", #selector(WallpaperController.revealDesktop))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = wallpaper
            wallpaperMenu.addItem(item)
        }
        let show = NSMenuItem(title: "Screen Saver Preview", action: #selector(showPreview), keyEquivalent: "")
        show.target = self
        wallpaperMenu.addItem(show)
        let scenePreviewItem = NSMenuItem(title: "Studio…", action: #selector(showScenePreview), keyEquivalent: "o")
        scenePreviewItem.target = self
        wallpaperMenu.addItem(scenePreviewItem)
        let libraryItem = wallpaperMenu.addItem(withTitle: "Library…", action: #selector(showLibrary), keyEquivalent: "l")
        libraryItem.target = self
        wallpaperMenu.addItem(.separator())
        comfort.addDesktopIconsItem(to: wallpaperMenu)
        let bedtime = wallpaperMenu.addItem(withTitle: "Bedtime Display…", action: #selector(DesktopComfortController.showSettings), keyEquivalent: "")
        bedtime.target = comfort
        let dim = wallpaperMenu.addItem(withTitle: "Dim / Restore Display", action: #selector(DesktopComfortController.toggle), keyEquivalent: "d")
        dim.keyEquivalentModifierMask = [.command, .option]
        dim.target = comfort
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        let diagnostics = help.addItem(withTitle: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared

if let index = CommandLine.arguments.firstIndex(of: "--smoke-library"), CommandLine.arguments.count > index + 1 {
    do {
        let video = CommandLine.arguments.count > index + 2 ? URL(fileURLWithPath: CommandLine.arguments[index + 2]) : nil
        try SceneLibraryController.smokeTest(outputURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]), videoURL: video)
        exit(0)
    }
    catch { fputs("Library check failed: \(error.localizedDescription)\n", stderr); exit(1) }
}

// Deterministic, offscreen preview: no desktop windows, input grants, or UI activation.
if let index = CommandLine.arguments.firstIndex(of: "--smoke-export"), CommandLine.arguments.count > index + 1 {
    let video = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task { @MainActor in
        do { try await SceneVideoExporter.smokeTest(videoURL: video); exit(0) }
        catch { fputs("Export checks failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--export-video") {
    guard CommandLine.arguments.count > index + 5,
          let seconds = Double(CommandLine.arguments[index + 3]),
          let fps = Int(CommandLine.arguments[index + 4]),
          let width = Int(CommandLine.arguments[index + 5]), [1920, 3840].contains(width) else {
        fputs("Usage: --export-video input.idlesse output.mp4 seconds fps width(1920|3840)\n", stderr); exit(1)
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task { @MainActor in
        do {
            let scene = try await LocalSceneSource().resolve(input)
            try await SceneVideoExporter.export(scene, to: output, width: width, height: width * 9 / 16,
                                                fps: fps, duration: seconds, progress: { _ in })
            print("Exported " + output.path); exit(0)
        } catch { fputs("Export failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--qualify-desktop") {
    guard CommandLine.arguments.count == index + 5,
          let seconds = Double(CommandLine.arguments[index + 3]), seconds.isFinite, (1...7200).contains(seconds),
          let cycles = Int(CommandLine.arguments[index + 4]), (1...100).contains(cycles) else {
        fputs("Usage: --qualify-desktop source report.json seconds-per-cycle cycles\n", stderr); exit(1)
    }
    do {
        try DesktopQualification.run(source: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            output: URL(fileURLWithPath: CommandLine.arguments[index + 2]), seconds: seconds, cycles: cycles)
        exit(0)
    } catch { fputs("Qualification failed: \(error.localizedDescription)\n", stderr); exit(1) }
}

if let index = CommandLine.arguments.firstIndex(of: "--conformance") {
    guard CommandLine.arguments.count == index + 2 else {
        fputs("Usage: --conformance corpus.json\n", stderr); exit(1)
    }
    let corpus = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task { @MainActor in
        do { try await SceneConformance.run(corpus); exit(0) }
        catch { fputs("Conformance failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-scene") {
    guard CommandLine.arguments.count > index + 3,
          let seconds = Double(CommandLine.arguments[index + 3]), seconds.isFinite, (0...86400).contains(seconds) else {
        fputs("Usage: --render-scene input.idlesse output.png seconds\n", stderr); exit(1)
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task { @MainActor in
        do {
            let scene = try await LocalSceneSource().resolve(input)
            guard !scene.allNodes.contains(where: { $0.kind == .video }) else {
                throw SceneError.invalid("Offscreen export supports images and procedural scenes. Use Studio for video previews.")
            }
            let clock = SceneClock(now: { 0 })
            try clock.configure(timeline: scene.timeline)
            try clock.seek(to: seconds)
            let renderer = try MetalSceneRenderer(playable: scene, bounds: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                scale: 1, clock: clock) { fputs(($0 + "\n"), stderr) }
            defer { renderer.releaseResources() }
            let pixels = try renderer.renderProbe(signals: .init(time: clock.time), dimension: 1024)
            let data = Data(pixels)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw SceneError.invalid("Could not encode scene preview.")
            }
            try png.write(to: output, options: .withoutOverwriting)
            print("Rendered 1024×1024 preview at \(seconds)s; input permissions remain disabled.")
            exit(0)
        } catch { fputs((error.localizedDescription + "\n"), stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--benchmark"),
   CommandLine.arguments.count > index + 2 {
    do {
        try PlaybackBenchmark.run(mode: CommandLine.arguments[index + 1],
            folder: URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Benchmark failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--smoke-audio"), CommandLine.arguments.count > index + 1 {
    do {
        try AudioSmoke.run(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Audio checks failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--smoke-resume"), CommandLine.arguments.count > index + 1 {
    do {
        try WallpaperController.smokeResume(url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Resume checks failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--smoke-wallpaper"),
   CommandLine.arguments.count > index + 1 {
    do {
        try WallpaperSmoke.run(videoURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Wallpaper checks failed: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--smoke-options") {
    let controller = ConfigureSheetController(preferences: IdlessePreferences.shared) {}
    controller.window.contentView?.layoutSubtreeIfNeeded()
    precondition(controller.window.canBecomeKey)
    precondition(ConfigureSheetController.timingNumber("2oops") == nil)
    precondition(ConfigureSheetController.timingNumber("") == nil)
    precondition(ConfigureSheetController.timingNumber("2") == 2)
    let content = controller.window.contentView!
    func checkButtons(_ view: NSView) {
        if let button = view as? NSButton, ["Choose…", "Save", "Cancel"].contains(button.title) {
            let frame = button.convert(button.bounds, to: content)
            precondition(frame.minX >= 16 && frame.maxX <= content.bounds.width - 16,
                         "Settings button escapes content margins: \(button.title)")
        }
        view.subviews.forEach(checkButtons)
    }
    checkButtons(content)
    print("Idlesse settings UI smoke test passed")
    exit(EXIT_SUCCESS)
}

let delegate = IdlesseAppDelegate()
app.delegate = delegate
app.run()