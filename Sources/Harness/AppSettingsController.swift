import AppKit
import UniformTypeIdentifiers

/// Session frame restore that refuses garbage: a saved frame from a different
/// screen layout (or a runaway resize) that dwarfs the default size is
/// discarded in favor of a centered default. Self-heals poisoned defaults.
///
/// Deliberately manual (no setFrameAutosaveName): AppKit's lazy autosave
/// restore races validation and re-applies rejected frames after showing.
extension NSWindow {
    private static func managedFrameKey(_ name: String) -> String { "NSWindow Frame \(name)" }
    func restoreManagedFrame(name: String, defaultSize: NSSize) {
        var applied = false
        if let saved = NSWindow.managedFrame(name: name),
           saved.width <= defaultSize.width + 320, saved.height <= defaultSize.height + 230,
           saved.width >= 400, saved.height >= 300 {
            setFrame(saved, display: false)
            applied = true
        }
        if !applied {
            setContentSize(defaultSize)
            center()
            saveManagedFrame(name: name)
        }
        NSAccessibility.post(element: self, notification: .windowMoved)
        NSAccessibility.post(element: self, notification: .windowResized)
    }
    private static func managedFrame(name: String) -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: managedFrameKey(name)) else { return nil }
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 4 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
    func saveManagedFrame(name: String) {
        let f = frame
        guard f.width <= 1500, f.height <= 950, f.width >= 400, f.height >= 300 else { return }
        UserDefaults.standard.set(
            "\(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height)) 0 0 0 0",
            forKey: Self.managedFrameKey(name))
    }
}

/// Conventional preferences window. Library/Home owns browsing, collections,
/// display targeting and desktop visibility; this controller keeps preferences
/// for playback, automation and the screen saver.
final class AppSettingsController: NSWindowController, NSWindowDelegate {
    private var outsideClickMonitor: Any?
    private let comfort: DesktopComfortController
    private let wallpaper: WallpaperController
    private let showSaver: () -> Void
    private let tabs = NSTabView()
    private var navigation: [NSButton] = []
    private var home: HomeWindowController?
    private weak var libraryWindow: NSWindow?
    var onLibraryVisible: (() -> Void)?
    /// Kept as a compatibility hook for older callers. Closing Settings no
    /// longer tears down Library because Library is a separate primary window.
    var onClose: (() -> Void)?

    private let liveMenu = NSButton(checkboxWithTitle: "Animate menu bar", target: nil, action: nil)
    private let batteryThrottle = NSButton(checkboxWithTitle: "Cap to 30 fps on battery", target: nil, action: nil)
    private let coveragePause = NSButton(checkboxWithTitle: "Rest fully covered displays", target: nil, action: nil)
    private let rate = NSPopUpButton()
    private let transition = NSPopUpButton()
    private let transitionStyle = NSPopUpButton()
    private let schedule = NSButton(checkboxWithTitle: "Schedule dimming", target: nil, action: nil)
    private let amount = NSSlider(value: 90, minValue: 20, maxValue: 98, target: nil, action: nil)
    private let percent = NSTextField(labelWithString: "90%")
    private let from = NSDatePicker()
    private let until = NSDatePicker()
    private let dim = NSButton(title: "Dim Now", target: nil, action: nil)
    var modes: AmbientModesController?
    private let nightChoose = NSButton(title: "Choose night wallpaper…", target: nil, action: nil)
    private let nightClear = NSButton(title: "Clear", target: nil, action: nil)
    private let followSun = NSButton(checkboxWithTitle: "Follow the sun", target: nil, action: nil)
    private let sunTimes = NSTextField(labelWithString: "")
    private let myLocation = NSButton(checkboxWithTitle: "Use my location", target: nil, action: nil)
    private let latField = NSTextField(string: "")
    private let lonField = NSTextField(string: "")
    private let weatherEnabled = NSButton(checkboxWithTitle: "Weather scenes", target: nil, action: nil)
    private let clearSceneBtn = NSButton(title: "Clear", target: nil, action: nil)
    private let cloudySceneBtn = NSButton(title: "Cloudy", target: nil, action: nil)
    private let precipSceneBtn = NSButton(title: "Precipitation", target: nil, action: nil)

    init(comfort: DesktopComfortController, wallpaper: WallpaperController, showSaver: @escaping () -> Void) {
        self.comfort = comfort
        self.wallpaper = wallpaper
        self.showSaver = showSaver
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Idlesse Settings"
        window.minSize = NSSize(width: 700, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let window = self?.window, window.isVisible, window.attachedSheet == nil,
               let clickedWindow = event.window, clickedWindow !== window,
               clickedWindow.parent !== window {
                window.orderOut(nil)
            }
            return event
        }
        window.restoreManagedFrame(name: "IdlessePreferences", defaultSize: NSSize(width: 760, height: 580))
        installContent(in: window)
        retargetSettingsCommand()
        // main.swift installs this before AppSettings is lazily created. Own it
        // here so menu-extra/settings requests open preferences, not Home.
        wallpaper.onShowSettings = { [weak self] in self?.present(tab: 0) }
        wallpaper.onStateChange = { [weak self] in self?.reload() }
        reload()
    }

    deinit { if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) } }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Compatibility seam for old showLibrary(): recover the controller that
    /// owns the supplied view and wrap it in Home inside its existing window.
    /// The view never becomes a child of Settings.
    func installLibrary(_ view: NSView) {
        guard home == nil else { return }
        libraryWindow = view.window
        guard let library = view.window?.windowController as? SceneLibraryController else { return }
        library.hostWindow = library.window
        home = HomeWindowController(library: library, wallpaper: wallpaper, comfort: comfort)
    }

    func present(tab: Int? = nil) {
        let requested = tab ?? 3
        if requested == 3 {
            onLibraryVisible?()
            if let home {
                home.presentLibrary()
            } else {
                libraryWindow?.deminiaturize(nil)
                libraryWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        reload()
        selectPage(max(0, min(2, requested)))
        window?.level = comfort.isDimmed ? .mainMenu : .normal
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.restoreManagedFrame(name: "IdlessePreferences", defaultSize: NSSize(width: 760, height: 580))
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) { present(tab: 0) }

    private func retargetSettingsCommand() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let item = appMenu.items.first(where: { $0.title == "Settings…" }) else { return }
        item.target = self
        item.action = #selector(openSettingsFromMenu(_:))
    }

    private func installContent(in window: NSWindow) {
        guard let root = window.contentView else { return }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let destinations: [(String, String)] = [
            ("Playback", "play.circle"),
            ("Automation", "moon.stars"),
            ("Screen Saver", "sparkles.tv"),
        ]
        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(navStack)
        for (index, entry) in destinations.enumerated() {
            let button = NSButton(title: entry.0, target: self, action: #selector(navigate(_:)))
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.0)
            button.imagePosition = .imageLeading
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.widthAnchor.constraint(equalToConstant: 156).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            navStack.addArrangedSubview(button)
            navigation.append(button)
        }

        tabs.tabViewType = .noTabsNoBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 180),
            navStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            navStack.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -12),
            navStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22),
            tabs.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: root.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        rate.addItems(withTitles: SceneFrameRate.allCases.map { $0 == .automatic ? "Auto" : $0.title })
        rate.target = self
        rate.action = #selector(changePlayback)
        rate.setAccessibilityLabel("Frame rate")
        transition.addItems(withTitles: ["None", "0.5 seconds", "1 second", "2 seconds"])
        transition.target = self
        transition.action = #selector(changePlayback)
        transition.setAccessibilityLabel("Transition duration")
        transitionStyle.addItems(withTitles: WallpaperController.TransitionStyle.allCases.map(\.title))
        transitionStyle.target = self
        transitionStyle.action = #selector(changePlayback)
        transitionStyle.setAccessibilityLabel("Transition style")
        let transitionRow = NSStackView(views: [transition, transitionStyle])
        transitionRow.spacing = 8
        liveMenu.target = self
        liveMenu.action = #selector(changeMenuAnimation)
        batteryThrottle.target = self
        batteryThrottle.action = #selector(changeBatteryThrottle)
        batteryThrottle.toolTip = "Automatically cap frame rate to 30 fps on battery."
        coveragePause.target = self
        coveragePause.action = #selector(changeCoveragePause)
        coveragePause.toolTip = "Pause a renderer after its display stays fully covered."
        addTab("Playback", rows: [
            [label("Frame rate"), rate],
            [label("Transition"), transitionRow],
            [NSView(), liveMenu],
            [NSView(), batteryThrottle],
            [NSView(), coveragePause],
        ])

        schedule.target = self
        schedule.action = #selector(changeBedtime)
        amount.target = self
        amount.action = #selector(changeBedtime)
        amount.isContinuous = true
        amount.setAccessibilityLabel("Dimming")
        percent.alignment = .right
        let level = NSStackView(views: [amount, percent])
        level.spacing = 8
        amount.widthAnchor.constraint(equalToConstant: 170).isActive = true
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for (picker, name) in [(from, "Dim at"), (until, "Restore at")] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.hourMinute]
            picker.target = self
            picker.action = #selector(changeBedtime)
            picker.setAccessibilityLabel(name)
        }
        dim.bezelStyle = .rounded
        dim.target = self
        dim.action = #selector(toggleDim)
        nightChoose.bezelStyle = .rounded
        nightChoose.target = self
        nightChoose.action = #selector(chooseModeScene(_:))
        nightChoose.tag = 0
        nightClear.bezelStyle = .rounded
        nightClear.target = self
        nightClear.action = #selector(clearModeScene(_:))
        nightClear.tag = 0
        let nightRow = NSStackView(views: [nightChoose, nightClear])
        nightRow.spacing = 8
        followSun.target = self
        followSun.action = #selector(changeModes)
        followSun.toolTip = "Follow local sunrise and sunset for dimming and night scenes."
        sunTimes.textColor = .secondaryLabelColor
        let sunRow = NSStackView(views: [followSun, sunTimes])
        sunRow.spacing = 8
        myLocation.target = self
        myLocation.action = #selector(changeModes)
        myLocation.toolTip = "Use current location for sun times and condition scenes; otherwise enter coordinates."
        latField.target = self
        latField.action = #selector(changeCoords)
        lonField.target = self
        lonField.action = #selector(changeCoords)
        latField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        lonField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let locRow = NSStackView(views: [myLocation, NSTextField(labelWithString: "Lat"), latField,
            NSTextField(labelWithString: "Lon"), lonField])
        locRow.spacing = 6
        weatherEnabled.target = self
        weatherEnabled.action = #selector(changeModes)
        weatherEnabled.toolTip = "Switch scenes by current condition, checked every 15 minutes."
        for (index, button) in [clearSceneBtn, cloudySceneBtn, precipSceneBtn].enumerated() {
            button.bezelStyle = .rounded
            button.target = self
            button.action = #selector(chooseModeScene(_:))
            button.tag = index + 1
        }
        let weatherRow = NSStackView(views: [weatherEnabled, clearSceneBtn, cloudySceneBtn, precipSceneBtn])
        weatherRow.spacing = 8
        addTab("Automation", rows: [
            [label("Dimming"), level],
            [NSView(), schedule],
            [label("Dim at"), from],
            [label("Restore at"), until],
            [NSView(), dim],
            [label("Night"), nightRow],
            [label("Sun"), sunRow],
            [label("Location"), locRow],
            [label("Conditions"), weatherRow],
        ])

        let saver = NSButton(title: "Screen Saver Options…", target: self, action: #selector(openSaver))
        saver.bezelStyle = .rounded
        let mirror = NSButton(title: "Mirror Active Wallpaper to Screen Saver", target: self,
                              action: #selector(mirrorWallpaperToSaver))
        mirror.bezelStyle = .rounded
        addTab("Screen Saver", rows: [[NSView(), saver], [NSView(), mirror]])
        selectPage(0)
    }

    @objc private func navigate(_ sender: NSButton) { selectPage(sender.tag) }

    private func selectPage(_ index: Int) {
        guard (0..<tabs.numberOfTabViewItems).contains(index) else { return }
        tabs.selectTabViewItem(at: index)
        for button in navigation {
            let selected = button.tag == index
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .clear).cgColor
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
    }

    private func addTab(_ title: String, rows: [[NSView]]) {
        let page = NSView()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(heading)
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 16
        grid.columnSpacing = 16
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).width = 110
            grid.column(at: 0).xPlacement = .trailing
        }
        if grid.numberOfColumns > 1 { grid.column(at: 1).xPlacement = .leading }
        grid.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(grid)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: page.topAnchor, constant: 28),
            heading.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 30),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 26),
            grid.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 26),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -26),
        ])
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = page
        tabs.addTabViewItem(item)
    }

    func updateStatus() {
        liveMenu.state = UserDefaults.standard.bool(forKey: "comfort.liveMenuStrip") ? .on : .off
    }

    private func reload() {
        guard window?.isVisible == true || home == nil else { return }
        updateStatus()
        rate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        transition.selectItem(at: [0.0, 0.5, 1, 2].firstIndex(of: wallpaper.transitionDuration) ?? 0)
        transitionStyle.selectItem(at: WallpaperController.TransitionStyle.allCases.firstIndex(of: wallpaper.transitionStyle) ?? 0)
        batteryThrottle.state = SceneFrameRate.throttleOnBattery ? .on : .off
        coveragePause.state = wallpaper.coveragePauseEnabled ? .on : .off
        let values = comfort.bedtimeSettings
        schedule.state = values.enabled ? .on : .off
        amount.doubleValue = values.amount * 100
        percent.stringValue = "\(Int(amount.doubleValue.rounded()))%"
        from.dateValue = DimSchedule.pickerDate(minute: values.start, on: Date())
        until.dateValue = DimSchedule.pickerDate(minute: values.end, on: Date())
        from.isEnabled = values.enabled
        until.isEnabled = values.enabled
        dim.title = comfort.isDimmed ? "Restore Display" : "Dim Now"
        reloadModes()
    }

    func windowDidBecomeKey(_ notification: Notification) { reload() }
    func windowDidMove(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlessePreferences")
    }
    func windowDidResize(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlessePreferences")
    }

    @objc private func changeMenuAnimation() {
        UserDefaults.standard.set(liveMenu.state == .on, forKey: "comfort.liveMenuStrip")
        if let url = wallpaper.selectedURL {
            wallpaper.select(url, automatic: true, restoringPause: wallpaper.pausedByUser)
        }
    }

    @objc private func changePlayback() {
        guard SceneFrameRate.allCases.indices.contains(rate.indexOfSelectedItem),
              WallpaperController.TransitionStyle.allCases.indices.contains(transitionStyle.indexOfSelectedItem) else { return }
        SceneFrameRate.selected = SceneFrameRate.allCases[rate.indexOfSelectedItem]
        let durations = [0.0, 0.5, 1.0, 2.0]
        if durations.indices.contains(transition.indexOfSelectedItem) {
            wallpaper.transitionDuration = durations[transition.indexOfSelectedItem]
        }
        wallpaper.transitionStyle = WallpaperController.TransitionStyle.allCases[transitionStyle.indexOfSelectedItem]
    }

    @objc private func changeBatteryThrottle() {
        SceneFrameRate.throttleOnBattery = batteryThrottle.state == .on
    }

    @objc private func changeCoveragePause() {
        wallpaper.coveragePauseEnabled = coveragePause.state == .on
    }

    private func modeSlotTitle(_ slot: String, fallback: String) -> String {
        modes?.sceneURL(for: slot)?.lastPathComponent ?? fallback
    }

    private func reloadModes() {
        guard let modes else {
            for control in [nightChoose, nightClear, followSun, myLocation, latField, lonField,
                            weatherEnabled, clearSceneBtn, cloudySceneBtn, precipSceneBtn] as [NSControl] {
                control.isEnabled = false
            }
            return
        }
        nightChoose.title = modeSlotTitle("night", fallback: "Choose night wallpaper…")
        followSun.state = modes.followSun ? .on : .off
        if let sun = modes.solarTimes {
            func clock(_ minutes: Int) -> String { String(format: "%d:%02d", (minutes / 60) % 24, minutes % 60) }
            sunTimes.stringValue = "Rise \(clock(sun.rise)) · Set \(clock(sun.set))"
        } else {
            sunTimes.stringValue = modes.followSun ? "Sun times unavailable" : ""
        }
        myLocation.state = modes.useMyLocation ? .on : .off
        latField.stringValue = String(format: "%.4f", modes.manualLatitude)
        lonField.stringValue = String(format: "%.4f", modes.manualLongitude)
        latField.isEnabled = !modes.useMyLocation
        lonField.isEnabled = !modes.useMyLocation
        weatherEnabled.state = modes.weatherEnabled ? .on : .off
        clearSceneBtn.title = modeSlotTitle("weather.clear", fallback: "Clear")
        cloudySceneBtn.title = modeSlotTitle("weather.cloudy", fallback: "Cloudy")
        precipSceneBtn.title = modeSlotTitle("weather.precip", fallback: "Precipitation")
        for button in [clearSceneBtn, cloudySceneBtn, precipSceneBtn] { button.isEnabled = modes.weatherEnabled }
    }

    @objc private func changeModes() {
        guard let modes else { return }
        modes.followSun = followSun.state == .on
        modes.useMyLocation = myLocation.state == .on
        modes.weatherEnabled = weatherEnabled.state == .on
        reloadModes()
    }

    @objc private func changeCoords() {
        guard let modes else { return }
        modes.manualLatitude = min(90, max(-90, latField.doubleValue))
        modes.manualLongitude = min(180, max(-180, lonField.doubleValue))
        reloadModes()
    }

    private static let modeSlots = ["night", "weather.clear", "weather.cloudy", "weather.precip"]
    private func modeSlot(for sender: NSButton) -> String? {
        guard Self.modeSlots.indices.contains(sender.tag) else { return nil }
        return Self.modeSlots[sender.tag]
    }

    @objc private func chooseModeScene(_ sender: NSButton) {
        guard let modes, let slot = modeSlot(for: sender) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose scene"
        panel.prompt = "Use Scene"
        panel.allowedContentTypes = [.jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie,
            UTType(exportedAs: "com.teamleaderleo.idlesse.scene", conformingTo: .package)]
        panel.treatsFilePackagesAsDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            modes.setScene(url, for: slot)
            self?.reloadModes()
        }
    }

    @objc private func clearModeScene(_ sender: NSButton) {
        guard let modes, let slot = modeSlot(for: sender) else { return }
        modes.setScene(nil, for: slot)
        reloadModes()
    }

    @objc private func changeBedtime() {
        func minute(_ picker: NSDatePicker) -> Int {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        comfort.applyBedtime(amount: amount.doubleValue / 100, enabled: schedule.state == .on,
            start: minute(from), end: minute(until))
        percent.stringValue = "\(Int(amount.doubleValue.rounded()))%"
        from.isEnabled = schedule.state == .on
        until.isEnabled = schedule.state == .on
        updateDimming()
    }

    func updateDimming() {
        dim.title = comfort.isDimmed ? "Restore Display" : "Dim Now"
        window?.level = comfort.isDimmed ? .mainMenu : .normal
    }

    @objc private func toggleDim() {
        comfort.toggle()
        reload()
        updateDimming()
    }

    @objc private func mirrorWallpaperToSaver() {
        guard let url = wallpaper.selectedURL else {
            let alert = NSAlert()
            alert.messageText = "No Active Wallpaper"
            alert.informativeText = "Choose or play a wallpaper first before mirroring to the Screen Saver."
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
            return
        }
        do {
            let targetURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            try IdlessePreferences.shared.saveFolder(targetURL)
            NotificationCenter.default.post(name: IdlessePreferences.settingsChangedNotification, object: nil)
            let alert = NSAlert()
            alert.messageText = "Screen Saver Synchronized"
            alert.informativeText = "The Idlesse screen saver now mirrors “\(url.lastPathComponent)”."
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Update Screen Saver"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    @objc private func openSaver() { showSaver() }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }
}
