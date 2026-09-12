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
        // Bust stale accessibility caches (window managers, System Events):
        // programmatic frame changes can leave AX reporting ghost frames.
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
        // Never persist absurd frames: a externally-imposed giant rect must
        // not become the new normal.
        let f = frame
        guard f.width <= 1500, f.height <= 950, f.width >= 400, f.height >= 300 else { return }
        UserDefaults.standard.set(
            "\(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height)) 0 0 0 0",
            forKey: Self.managedFrameKey(name))
    }
}

final class AppSettingsController: NSWindowController, NSWindowDelegate {
    private let comfort: DesktopComfortController
    private let wallpaper: WallpaperController
    private let showSaver: () -> Void
    private let tabs = NSTabView()
    private let status = NSTextField(labelWithString: "")
    private let pause = NSButton(title: "Pause", target: nil, action: nil)
    private var navigation: [NSButton] = []
    var onLibraryVisible: (() -> Void)?
    var onClose: (() -> Void)?
    func installLibrary(_ view: NSView) {
        guard tabs.numberOfTabViewItems == 3 else { return }
        // Fill the tab page and track its size, so a resized window never
        // leaves the Library clustered with a void above it.
        view.frame = NSRect(x: 0, y: 0, width: tabs.frame.width, height: tabs.frame.height)
        view.autoresizingMask = [.width, .height]
        let item = NSTabViewItem(identifier: "Library"); item.view = view
        tabs.addTabViewItem(item)
    }
    func updateStatus() {
        status.stringValue = SceneLibraryController.displayTitle(wallpaper.statusDescription)
        pause.title = wallpaper.pausedByUser ? "Resume" : "Pause"
        pause.isEnabled = wallpaper.isRunning
        liveMenu.state = UserDefaults.standard.bool(forKey: "comfort.liveMenuStrip") ? .on : .off
        updateIcons()
    }
    @objc private func changeMenuAnimation() {
        UserDefaults.standard.set(liveMenu.state == .on, forKey: "comfort.liveMenuStrip")
        if let url = wallpaper.selectedURL {
            wallpaper.select(url, automatic: true, restoringPause: wallpaper.pausedByUser)
        }
    }
    @objc private func togglePlayback() { wallpaper.togglePause(); updateStatus() }
    @objc private func navigate(_ sender: NSButton) { selectPage(sender.tag) }
    private func selectPage(_ index: Int) {
        guard index < tabs.numberOfTabViewItems else { return }
        tabs.selectTabViewItem(at: index)
        for button in navigation {
            let selected = button.tag == index
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .clear).cgColor
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
        if index == 3 { onLibraryVisible?() }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func windowDidMove(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlesseSettings")
    }
    func windowDidResize(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveManagedFrame(name: "IdlesseSettings")
    }

    private let icons = NSButton(checkboxWithTitle: "Files", target: nil, action: nil)
    private let widgets = NSButton(checkboxWithTitle: "Widgets", target: nil, action: nil)
    private let liveMenu = NSButton(checkboxWithTitle: "Animate menu bar", target: nil, action: nil)
    private let batteryThrottle = NSButton(checkboxWithTitle: "Cap to 30 fps on battery", target: nil, action: nil)
    private let sameDisplays = NSButton(checkboxWithTitle: "Same wallpaper on all displays", target: nil, action: nil)
    private let coveragePause = NSButton(checkboxWithTitle: "Rest fully covered displays", target: nil, action: nil)
    private let replaceBackdrop = NSButton(checkboxWithTitle: "Replace system wallpaper", target: nil, action: nil)
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
        self.comfort = comfort; self.wallpaper = wallpaper; self.showSaver = showSaver
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Idlesse"
        window.minSize = NSSize(width: 1100, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        window.restoreManagedFrame(name: "IdlesseSettings", defaultSize: NSSize(width: 1180, height: 720))
        guard let root = window.contentView else { return }
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 180, height: 720))
        sidebar.material = .sidebar; sidebar.blendingMode = .behindWindow
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)
        for (row, entry) in [(3, "Wallpapers"), (0, "Playback & Desktop"), (1, "Bedtime"), (2, "Screen Saver")].enumerated() {
            let button = NSButton(title: entry.1, target: self, action: #selector(navigate(_:)))
            button.tag = entry.0; button.setButtonType(.pushOnPushOff); button.bezelStyle = .rounded
            button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.image = NSImage(systemSymbolName: ["photo.on.rectangle", "slider.horizontal.3", "moon", "sparkles.tv"][row], accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            button.frame = NSRect(x: 12, y: 660 - row * 42, width: 156, height: 32)
            button.autoresizingMask = [.minYMargin]
            sidebar.addSubview(button); navigation.append(button)
        }
        let desktopLabel = NSTextField(labelWithString: "Show on Desktop")
        desktopLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        desktopLabel.textColor = .secondaryLabelColor
        desktopLabel.frame = NSRect(x: 20, y: 446, width: 150, height: 18)
        desktopLabel.autoresizingMask = [.minYMargin]
        sidebar.addSubview(desktopLabel)
        for (index, control) in [icons, widgets].enumerated() {
            control.frame = NSRect(x: 20, y: 414 - index * 30, width: 148, height: 24)
            control.autoresizingMask = [.minYMargin]
            control.setAccessibilityLabel(index == 0 ? "Show desktop files" : "Show desktop widgets")
            sidebar.addSubview(control)
        }
        icons.toolTip = "Keep files covered by the active Idlesse wallpaper, even after clicking the desktop. Right-click for desktop controls."
        widgets.toolTip = "Show desktop widgets. With Files also hidden, the wallpaper keeps widgets covered when revealing the desktop."
        widgets.target = self; widgets.action = #selector(changeWidgets)
        status.frame = NSRect(x: 202, y: 670, width: 750, height: 24)
        status.autoresizingMask = [.width, .minYMargin]
        status.lineBreakMode = .byTruncatingMiddle
        root.addSubview(status)
        pause.frame = NSRect(x: 1060, y: 665, width: 96, height: 32)
        pause.autoresizingMask = [.minXMargin, .minYMargin]
        pause.bezelStyle = .rounded; pause.target = self; pause.action = #selector(togglePlayback)
        root.addSubview(pause)
        tabs.tabViewType = .noTabsNoBorder
        tabs.frame = NSRect(x: 180, y: 0, width: 1000, height: 645)
        tabs.autoresizingMask = [.width, .height]
        root.addSubview(tabs)
        wallpaper.onStateChange = { [weak self] in self?.updateStatus() }
        icons.target = self; icons.action = #selector(changeIcons)
        comfort.onDesktopIconsChanged = { [weak self] in self?.updateIcons() }
        rate.addItems(withTitles: SceneFrameRate.allCases.map { $0 == .automatic ? "Auto" : $0.title })
        rate.target = self; rate.action = #selector(changePlayback)
        rate.setAccessibilityLabel("Frame rate")
        transition.addItems(withTitles: ["None", "0.5 seconds", "1 second", "2 seconds"])
        transition.target = self; transition.action = #selector(changePlayback)
        transition.setAccessibilityLabel("Crossfade")
        transitionStyle.addItems(withTitles: WallpaperController.TransitionStyle.allCases.map(\.title))
        transitionStyle.target = self; transitionStyle.action = #selector(changePlayback)
        transitionStyle.setAccessibilityLabel("Transition style")
        let transitionRow = NSStackView(views: [transition, transitionStyle]); transitionRow.spacing = 8
        liveMenu.target = self; liveMenu.action = #selector(changeMenuAnimation)
        batteryThrottle.target = self; batteryThrottle.action = #selector(changeBatteryThrottle)
        batteryThrottle.toolTip = "Automatically caps frame rate to 30 fps when running on battery to conserve energy."
        sameDisplays.target = self; sameDisplays.action = #selector(changeSameDisplays)
        sameDisplays.toolTip = "Synchronizes the same wallpaper across all monitors for maximum performance and efficiency."
        coveragePause.target = self; coveragePause.action = #selector(changeCoveragePause)
        coveragePause.toolTip = "Pauses a display's renderer when other windows fully cover it. Off until the estimate proves itself."
        replaceBackdrop.target = self; replaceBackdrop.action = #selector(changeReplaceBackdrop)
        replaceBackdrop.toolTip = "On: Idlesse sets a matching system still for menu-bar and Show Desktop consistency, restoring yours on stop. Off: your native wallpaper stays untouched and Idlesse renders above it."
        addTab("Wallpaper", rows: [[label("Frame rate"), rate], [label("Transition"), transitionRow], [liveMenu], [batteryThrottle], [sameDisplays], [coveragePause], [replaceBackdrop]])
        schedule.target = self; schedule.action = #selector(changeBedtime)
        amount.target = self; amount.action = #selector(changeBedtime); amount.isContinuous = true
        amount.setAccessibilityLabel("Dimming")
        percent.alignment = .right
        let level = NSStackView(views: [amount, percent]); level.spacing = 8
        amount.widthAnchor.constraint(equalToConstant: 170).isActive = true
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for (picker, name) in [(from, "Dim at"), (until, "Restore at")] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.hourMinute]
            picker.target = self; picker.action = #selector(changeBedtime)
            picker.setAccessibilityLabel(name)
        }
        dim.bezelStyle = .rounded; dim.target = self; dim.action = #selector(toggleDim)
        nightChoose.bezelStyle = .rounded; nightChoose.target = self; nightChoose.action = #selector(chooseModeScene(_:))
        nightChoose.tag = 0
        nightClear.bezelStyle = .rounded; nightClear.target = self; nightClear.action = #selector(clearModeScene(_:))
        nightClear.tag = 0
        let nightRow = NSStackView(views: [nightChoose, nightClear]); nightRow.spacing = 8
        followSun.target = self; followSun.action = #selector(changeModes)
        followSun.toolTip = "Dim window and night scenes follow local sunrise and sunset."
        sunTimes.textColor = .secondaryLabelColor
        let sunRow = NSStackView(views: [followSun, sunTimes]); sunRow.spacing = 8
        myLocation.target = self; myLocation.action = #selector(changeModes)
        myLocation.toolTip = "Use your current location for sun times and weather. Otherwise enter coordinates."
        latField.target = self; latField.action = #selector(changeCoords)
        lonField.target = self; lonField.action = #selector(changeCoords)
        for field in [latField, lonField] {
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        let locRow = NSStackView(views: [myLocation, NSTextField(labelWithString: "Lat"), latField,
            NSTextField(labelWithString: "Lon"), lonField]); locRow.spacing = 6
        weatherEnabled.target = self; weatherEnabled.action = #selector(changeModes)
        weatherEnabled.toolTip = "Switch scenes by current condition (Open-Meteo, checked every 15 minutes)."
        for (index, entry) in [(clearSceneBtn, "weather.clear"), (cloudySceneBtn, "weather.cloudy"), (precipSceneBtn, "weather.precip")].enumerated() {
            entry.0.bezelStyle = .rounded; entry.0.target = self; entry.0.action = #selector(chooseModeScene(_:))
            entry.0.tag = index + 1
        }
        let weatherRow = NSStackView(views: [weatherEnabled, clearSceneBtn, cloudySceneBtn, precipSceneBtn]); weatherRow.spacing = 8
        addTab("Bedtime", rows: [[label("Dimming"), level], [NSView(), schedule],
            [label("Dim at"), from], [label("Restore at"), until], [NSView(), dim],
            [label("Night"), nightRow], [label("Sun"), sunRow], [label("Location"), locRow],
            [label("Weather"), weatherRow]])
        let saver = NSButton(title: "Screen Saver Options…", target: self, action: #selector(openSaver))
        saver.bezelStyle = .rounded
        let mirror = NSButton(title: "Mirror Active Wallpaper to Screen Saver", target: self, action: #selector(mirrorWallpaperToSaver))
        mirror.bezelStyle = .rounded
        addTab("Screen Saver", rows: [[NSView(), saver], [NSView(), mirror]])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.alignment = .right
        return field
    }
    private func addTab(_ title: String, rows: [[NSView]]) {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 230))
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 16; grid.columnSpacing = 16
        grid.column(at: 0).width = 110
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: page.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -18)])
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = page
        tabs.addTabViewItem(item)
    }
    func present(tab: Int? = nil) {
        reload()
        selectPage(tab ?? 3)
        window?.level = comfort.isDimmed ? .mainMenu : .normal
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Re-validate after showing: AppKit can restore a saved frame lazily
        // on first show, after init-time validation already ran.
        window?.restoreManagedFrame(name: "IdlesseSettings", defaultSize: NSSize(width: 1180, height: 720))
        // Late re-validation: window managers can impose a remembered rect
        // after showing; absurd sizes get stomped back to sane bounds.
        if let window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
                window?.restoreManagedFrame(name: "IdlesseSettings", defaultSize: NSSize(width: 1180, height: 720))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) { reload() }
    private func updateIcons() {
        icons.state = comfort.desktopIconsVisible ? .on : .off
        icons.isEnabled = wallpaper.isRunning && !comfort.changingDesktopIcons
        widgets.state = comfort.desktopWidgetsVisible ? .on : .off
        widgets.isEnabled = !comfort.changingDesktopWidgets
    }
    private func reload() {
        updateStatus()
        updateIcons()
        rate.selectItem(at: SceneFrameRate.allCases.firstIndex(of: SceneFrameRate.selected) ?? 0)
        transition.selectItem(at: [0.0, 0.5, 1, 2].firstIndex(of: wallpaper.transitionDuration) ?? 0)
        transitionStyle.selectItem(at: WallpaperController.TransitionStyle.allCases.firstIndex(of: wallpaper.transitionStyle) ?? 0)
        batteryThrottle.state = SceneFrameRate.throttleOnBattery ? .on : .off
        sameDisplays.state = wallpaper.sameWallpaperOnAllDisplays ? .on : .off
        coveragePause.state = wallpaper.coveragePauseEnabled ? .on : .off
        replaceBackdrop.state = wallpaper.replacesSystemBackdrop ? .on : .off
        let values = comfort.bedtimeSettings
        schedule.state = values.enabled ? .on : .off
        amount.doubleValue = values.amount * 100
        percent.stringValue = "\(Int(amount.doubleValue.rounded()))%"
        from.dateValue = DimSchedule.pickerDate(minute: values.start, on: Date())
        until.dateValue = DimSchedule.pickerDate(minute: values.end, on: Date())
        from.isEnabled = values.enabled; until.isEnabled = values.enabled
        dim.title = comfort.isDimmed ? "Restore Display" : "Dim Now"
        reloadModes()
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
            func clock(_ minutes: Int) -> String {
                String(format: "%d:%02d", (minutes / 60) % 24, minutes % 60)
            }
            sunTimes.stringValue = "Rise \(clock(sun.rise)) · Set \(clock(sun.set))"
        } else {
            sunTimes.stringValue = modes.followSun ? "Sun times unavailable" : ""
        }
        myLocation.state = modes.useMyLocation ? .on : .off
        latField.stringValue = String(format: "%.4f", modes.manualLatitude)
        lonField.stringValue = String(format: "%.4f", modes.manualLongitude)
        latField.isEnabled = !modes.useMyLocation; lonField.isEnabled = !modes.useMyLocation
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
        let lat = min(90, max(-90, latField.doubleValue))
        let lon = min(180, max(-180, lonField.doubleValue))
        modes.manualLatitude = lat
        modes.manualLongitude = lon
        reloadModes()
    }
    private static let modeSlots = ["night", "weather.clear", "weather.cloudy", "weather.precip"]
    private func modeSlot(for sender: NSButton) -> String? {
        guard (0..<Self.modeSlots.count).contains(sender.tag) else { return nil }
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
    @objc private func changeWidgets() { comfort.toggleDesktopWidgets(); updateIcons() }
    @objc private func changeIcons() { comfort.toggleDesktopIcons(); updateIcons() }
    @objc private func changePlayback() {
        SceneFrameRate.selected = SceneFrameRate.allCases[rate.indexOfSelectedItem]
        wallpaper.transitionDuration = [0.0, 0.5, 1, 2][transition.indexOfSelectedItem]
        wallpaper.transitionStyle = WallpaperController.TransitionStyle.allCases[transitionStyle.indexOfSelectedItem]
    }
    @objc private func changeBatteryThrottle() {
        SceneFrameRate.throttleOnBattery = batteryThrottle.state == .on
    }
    @objc private func changeSameDisplays() {
        wallpaper.sameWallpaperOnAllDisplays = sameDisplays.state == .on
    }
    @objc private func changeCoveragePause() {
        wallpaper.coveragePauseEnabled = coveragePause.state == .on
    }
    @objc private func changeReplaceBackdrop() {
        wallpaper.replacesSystemBackdrop = replaceBackdrop.state == .on
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
            alert.informativeText = "The Idlesse screen saver is now set to use \"\(url.lastPathComponent)\"."
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
    @objc private func changeBedtime() {
        func minute(_ picker: NSDatePicker) -> Int {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        comfort.applyBedtime(amount: amount.doubleValue / 100, enabled: schedule.state == .on,
            start: minute(from), end: minute(until))
        percent.stringValue = "\(Int(amount.doubleValue.rounded()))%"
        from.isEnabled = schedule.state == .on; until.isEnabled = schedule.state == .on
        updateDimming()
    }
    func updateDimming() {
        dim.title = comfort.isDimmed ? "Restore Display" : "Dim Now"
        window?.level = comfort.isDimmed ? .mainMenu : .normal
    }
    @objc private func toggleDim() {
        comfort.toggle(); reload()
        window?.level = comfort.isDimmed ? .mainMenu : .normal
    }
    @objc private func openSaver() { showSaver() }
}
