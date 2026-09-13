import MetalKit
import AppKit
import ApplicationServices
import AVFoundation
import UniformTypeIdentifiers

private final class DesktopWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var desktopClick: (() -> Void)?
    var desktopMenu: (() -> NSMenu)?
    var desktopForwardRightClick: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            if desktopForwardRightClick?(event) == true { return }
            if let desktopMenu, let view = contentView { NSMenu.popUpContextMenu(desktopMenu(), with: event, for: view) }
            return
        }
        if event.type == .leftMouseDown, let desktopClick {
            if event.clickCount == 1 { desktopClick() }
            return
        }
        super.sendEvent(event)
    }
}

/// Keeps a per-display security-scoped Library asset alive for exactly as long
/// as the surface that uses it, including scene transitions.
final class WallpaperScopeLease {
    let url: URL
    private let started: Bool
    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

final class WallpaperSurface {
    fileprivate static var liveMenuStripEnabled: Bool {
        ProcessInfo.processInfo.environment["IDLESSE_LIVE_MENU_STRIP"] == "1" ||
            UserDefaults.standard.bool(forKey: "comfort.liveMenuStrip")
    }
    static func usesMetal(_ scene: SceneDescriptor, menuAnimation: Bool) -> Bool {
        menuAnimation || scene.canvas == .desktopSpan || scene.requiresMetal ||
            ProcessInfo.processInfo.environment["IDLESSE_METAL_COMPOSITOR"] == "1"
    }
    let window: NSWindow
    let displayID: UInt32
    let usesSharedVideoHub: Bool
    private let renderer: SceneRenderer
    private let securityScope: WallpaperScopeLease?
    private var menuStrip: MenuBarStrip?
    var diagnostics: RendererDiagnostics { renderer.diagnostics }
    var presentedFrameCount: Int? { renderer.presentedFrameCount }
    var gpuTotals: (seconds: Double, frames: Int)? { renderer.gpuTotals }
    var menuStripFrames: Int { menuStrip?.frames ?? 0 }
    var menuStripTiming: String { menuStrip?.timing.summary ?? "disabled" }
    var menuStripWindowNumber: Int? { menuStrip?.window.windowNumber }
    func updateScene(_ scene: SceneDescriptor) -> Bool { renderer.updateScene(scene) }

    init(screen: NSScreen, playable: SceneDescriptor, clock: SceneClock, sharedHub: SharedVideoHub? = nil,
         securityScope: WallpaperScopeLease? = nil, onError: @escaping (String) -> Void) throws {
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        self.usesSharedVideoHub = sharedHub != nil
        self.securityScope = securityScope
        window = DesktopWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        (window as? NSPanel)?.isFloatingPanel = false
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "Idlesse Wallpaper"

        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        if Self.usesMetal(playable, menuAnimation: Self.liveMenuStripEnabled) {
            renderer = try MetalSceneRenderer(playable: playable, bounds: bounds,
                scale: screen.backingScaleFactor, clock: clock, onError: onError, sharedHub: sharedHub)
        } else {
            renderer = try LayeredSceneRenderer(playable: playable, bounds: bounds,
                scale: screen.backingScaleFactor, clock: clock, onError: onError)
        }
        if let metal = renderer as? MetalSceneRenderer, playable.canvas == .desktopSpan {
            metal.desktopFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            metal.displayFrame = screen.frame
        }
        window.contentView = renderer.view
        if let metal = renderer as? MetalSceneRenderer {
            // Keep the native still wallpaper visible until the GPU has a full
            // composition. A newly attached CAMetalLayer otherwise flashes black.
            window.isOpaque = false
            window.backgroundColor = .clear
            renderer.view.layer?.opacity = 0
            metal.onFirstFrameReady = { [weak self] in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.renderer.view.layer?.opacity = 1
                CATransaction.commit()
            }
        }
        if Self.liveMenuStripEnabled,
           let metal = renderer as? MetalSceneRenderer {
            let strip = MenuBarStrip(screen: screen)
            menuStrip = strip
            strip.onDrawableCatchUp = { [weak metal] in metal?.refreshSceneTime() }
            metal.mirrorFrame = { [weak strip] command, drawable in strip?.copy(command: command, source: drawable) }
        }
        updateFrameRate()
    }

    func setCleanDesktop(_ enabled: Bool, hideWidgets: Bool = false, click: @escaping () -> Void, menu: @escaping () -> NSMenu) {
        guard let desktop = window as? DesktopWindow else { return }
        desktop.desktopClick = enabled ? click : nil
        desktop.desktopMenu = enabled ? menu : nil
        desktop.desktopForwardRightClick = enabled ? { [weak self] event in self?.forwardRightClickToFinder(event) ?? false } : nil
        desktop.ignoresMouseEvents = !enabled
        // Widgets occupy desktopIconWindow + 2 on Tahoe, above Finder icons.
        // Cover them with the same surface when the whole desktop is kept clear.
        let offset = enabled && hideWidgets ? 3 : 1
        desktop.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(enabled ? .desktopIconWindow : .desktopWindow)) + offset)
        if desktop.isVisible {
            if enabled { desktop.orderFront(nil) } else { desktop.orderBack(nil) }
        }
    }

    func updateFrameRate() {
        renderer.setPreferredFrameRate(SceneFrameRate.selected.requested(maximum: window.screen?.maximumFramesPerSecond ?? 60))
    }

    var isReadyForDisplay: Bool { renderer.isReadyForDisplay }
    func prepareForDisplay() {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        renderer.setMuted(true)
        renderer.setPaused(false)
        renderer.refreshSceneTime()
    }
    func refreshPreparation() { renderer.refreshSceneTime() }

    func show(paused: Bool) {
        window.orderBack(nil)
        menuStrip?.window.orderFront(nil)
        setPaused(paused)
    }

    private(set) var pausedState = false
    func setPaused(_ paused: Bool) { pausedState = paused; renderer.setPaused(paused || covered) }
    /// Set by the coverage monitor: a fully covered display rests its own
    /// renderer without affecting other displays or the pause state.
    private var covered = false
    var isCovered: Bool { covered }
    func setCovered(_ value: Bool) {
        guard covered != value else { return }
        covered = value
        renderer.setPaused(pausedState || covered)
    }
    func setMuted(_ muted: Bool) { renderer.setMuted(muted) }

    /// Native Finder menu on right-click: our window only covers Finder's desktop,
    /// so briefly go click-through and replay the click to Finder underneath.
    /// Icons stay covered (no flash) and the Finder menu renders above us.
    /// Falls back to our own menu when Accessibility trust (needed to repost
    /// the click) is missing.
    static var nativeDesktopMenuEnabled: Bool {
        UserDefaults.standard.object(forKey: "comfort.nativeDesktopMenu") == nil ||
            UserDefaults.standard.bool(forKey: "comfort.nativeDesktopMenu")
    }

    func forwardRightClickToFinder(_ event: NSEvent) -> Bool {
        guard Self.nativeDesktopMenuEnabled, AXIsProcessTrusted() else { return false }
        let cocoa = window.convertPoint(toScreen: event.locationInWindow)
        guard let main = NSScreen.main else { return false }
        let point = CGPoint(x: cocoa.x, y: main.frame.height - cocoa.y)
        // Click-through instead of hiding: icons stay covered, Finder still gets the click.
        let wasIgnoring = window.ignoresMouseEvents
        window.ignoresMouseEvents = true
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
            mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
            mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.window.ignoresMouseEvents = wasIgnoring
        }
        return true
    }

    func close() {
        (renderer as? MetalSceneRenderer)?.mirrorFrame = nil
        menuStrip?.window.close()
        menuStrip = nil
        renderer.releaseResources()
        window.contentView = nil
        window.close()
    }

    deinit { close() }
}

enum WallpaperError: LocalizedError {
    case unreadableImage, noVideo, unsupported, preparationTimeout
    var errorDescription: String? {
        switch self {
        case .preparationTimeout: return "The new wallpaper did not produce a frame. Your previous wallpaper is still selected."
        case .unreadableImage: return "That image could not be opened."
        case .noVideo: return "Choose a playable video with a finite duration and a video track."
        case .unsupported: return "Choose a JPG, PNG, HEIC, MP4 or MOV file."
        }
    }
}

/// A sibling to the saver. Interactive playback also prepares a matching system wallpaper still.
final class WallpaperController: NSObject, NSMenuItemValidation {
    private(set) var surfaces: [WallpaperSurface] = []
    private(set) var selectedURL: URL?
    private(set) var pausedByUser = false
    private var playable: SceneDescriptor?
    private var activeSharedVideoHub: SharedVideoHub?
    private var retiringSharedVideoHub: SharedVideoHub?
    // Only the interactive host persists state; smoke/qualification controllers stay isolated.
    var persistsSelection = false
    var resumeDefaults = UserDefaults.standard
    private static let resumeKey = "wallpaperResumeBookmark"
    private static let pauseKey = "wallpaperResumePaused"
    private static let sameDisplaysKey = "wallpaperSameOnAllDisplays"
    private static let origBackdropPrefix = "wallpaperOrigBackdrop."
    private static let stillsDirName = "Idlesse/Desktop Backdrops"

    private static func isOurStill(_ url: URL?) -> Bool {
        url?.path.contains(stillsDirName) ?? false
    }

    var sameWallpaperOnAllDisplays: Bool {
        get {
            if resumeDefaults.object(forKey: Self.sameDisplaysKey) == nil { return true }
            return resumeDefaults.bool(forKey: Self.sameDisplaysKey)
        }
        set {
            resumeDefaults.set(newValue, forKey: Self.sameDisplaysKey)
            refreshDisplayAssignments()
        }
    }

    static func persistentDisplayIdentifier(_ displayID: UInt32) -> String {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(displayID)) else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(kCFAllocatorDefault, unmanaged.takeRetainedValue()) as String
    }

    private var displayAssignmentStore: DisplayAssignmentStore {
        DisplayAssignmentStore(defaults: resumeDefaults, prefix: Self.resumeKey)
    }

    private func bookmarkData(for url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func explicitDisplayURL(for displayID: UInt32) -> URL? {
        let persistentID = Self.persistentDisplayIdentifier(displayID)
        guard let data = displayAssignmentStore.bookmarkData(
            persistentID: persistentID, legacyDisplayID: displayID) else { return nil }
        var stale = false
        let url: URL?
        if let scoped = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = scoped
        } else {
            url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        if stale, let url, let refreshed = try? bookmarkData(for: url) {
            displayAssignmentStore.setBookmarkData(refreshed, persistentID: persistentID)
        }
        return url
    }

    func displayURL(for displayID: UInt32) -> URL? {
        explicitDisplayURL(for: displayID) ?? selectedURL
    }

    /// Whether any display is playing `media`, directly or as a display override.
    func isShowing(_ media: URL) -> Bool {
        let path = media.standardizedFileURL.path
        return NSScreen.screens.contains { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            return displayURL(for: id)?.standardizedFileURL.path == path
        }
    }

    /// Reloads the desktop once when it is showing `media`, so an edited sidecar
    /// takes effect; anything else on screen is left alone.
    func reloadIfShowing(_ media: URL) {
        guard isShowing(media), let selectedURL else { return }
        select(selectedURL, reloading: true)
    }

    func setDisplayURL(_ url: URL, for displayID: UInt32) {
        do {
            displayAssignmentStore.setBookmarkData(try bookmarkData(for: url),
                persistentID: Self.persistentDisplayIdentifier(displayID))
            refreshDisplayAssignments()
        } catch {
            showError("The display assignment could not be saved: " + error.localizedDescription)
        }
    }

    func clearDisplayURL(for displayID: UInt32) {
        displayAssignmentStore.clear(persistentID: Self.persistentDisplayIdentifier(displayID),
                                     legacyDisplayID: displayID)
        Self.appendLine("Idlesse-display display=\(Self.persistentDisplayIdentifier(displayID)) action=follow-main")
        refreshDisplayAssignments()
    }

    var desktopSpanActive: Bool { playable?.canvas == .desktopSpan }

    /// Entry point used by the native Library display chooser. The optional
    /// `retainedAccess` keeps a source-root grant alive while we mint a scoped
    /// bookmark for the chosen Library item. A desktop-span scene is always
    /// global; ordinary scenes can become stable per-display overrides.
    func assignLibraryWallpaper(_ url: URL, to displayID: UInt32?, retaining retainedAccess: AnyObject? = nil, allowsDesktopSpan: Bool = true) {
        do {
            let data = try bookmarkData(for: url)
            var stale = false
            let scopedURL = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
            withExtendedLifetime(retainedAccess) {}
            guard let displayID else {
                resumeDefaults.set(true, forKey: Self.sameDisplaysKey)
                Self.appendLine("Idlesse-display target=all action=library-selection")
                select(scopedURL, automatic: true)
                return
            }
            let assignmentRequest = UUID()
            displayAssignmentRequests[displayID] = assignmentRequest
            let assignmentGeneration = generation
            Task { @MainActor [weak self] in
                guard let self else { return }
                let access = scopedURL.startAccessingSecurityScopedResource()
                defer { if access { scopedURL.stopAccessingSecurityScopedResource() } }
                do {
                    let candidate = try await self.source.resolve(scopedURL)
                    if candidate.canvas == .desktopSpan {
                        guard allowsDesktopSpan else {
                            self.showError("This wallpaper spans all displays. Use Set Wallpaper to apply it across the desktop.")
                            return
                        }
                        Self.appendLine("Idlesse-display target=\(Self.persistentDisplayIdentifier(displayID)) action=desktop-span-all-displays")
                        self.select(scopedURL, automatic: true)
                        return
                    }
                    var replacement: WallpaperSurface?
                    var adopted = false
                    defer { if !adopted { replacement?.close() } }
                    if self.selectedURL != nil, self.playable?.canvas != .desktopSpan, !self.suspended,
                       let screen = NSScreen.screens.first(where: {
                           ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
                       }) {
                        var preparationError: String?
                        let surface = try WallpaperSurface(screen: screen, playable: candidate, clock: self.clock,
                            securityScope: WallpaperScopeLease(scopedURL)) { [weak self] message in
                            guard let self, self.generation == assignmentGeneration,
                                  self.displayAssignmentRequests[displayID] == assignmentRequest else { return }
                            preparationError = message
                            if adopted { self.showError(message) }
                        }
                        replacement = surface
                        self.configureDesktopInteraction(surface)
                        if self.presentsWindows {
                            surface.prepareForDisplay()
                            let deadline = ProcessInfo.processInfo.systemUptime + 10
                            while !surface.isReadyForDisplay {
                                guard self.generation == assignmentGeneration,
                                      self.displayAssignmentRequests[displayID] == assignmentRequest,
                                      !self.suspended else { throw CancellationError() }
                                if let preparationError { throw SceneError.invalid(preparationError) }
                                guard ProcessInfo.processInfo.systemUptime < deadline else { throw WallpaperError.preparationTimeout }
                                try await Task.sleep(nanoseconds: 30_000_000)
                                surface.refreshPreparation()
                            }
                        }
                    }
                    guard self.generation == assignmentGeneration,
                          self.displayAssignmentRequests[displayID] == assignmentRequest else { throw CancellationError() }
                    // Keep every other connected screen on its visible shared wallpaper
                    // when a targeted assignment changes the mode to per-display.
                    if self.sameWallpaperOnAllDisplays, let current = self.selectedURL {
                        let sharedData = try self.bookmarkData(for: current)
                        for screen in NSScreen.screens {
                            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                                  id != displayID else { continue }
                            self.displayAssignmentStore.setBookmarkData(sharedData,
                                persistentID: Self.persistentDisplayIdentifier(id))
                        }
                    }
                    self.displayAssignmentStore.setBookmarkData(data,
                        persistentID: Self.persistentDisplayIdentifier(displayID))
                    self.resumeDefaults.set(false, forKey: Self.sameDisplaysKey)
                    Self.appendLine("Idlesse-display target=\(Self.persistentDisplayIdentifier(displayID)) action=library-assignment")
                    if self.selectedURL == nil || self.playable?.canvas == .desktopSpan {
                        self.select(scopedURL, automatic: true)
                    } else if let replacement {
                        let previous = self.surfaces.filter { $0.displayID == displayID }
                        self.surfaces.removeAll { $0.displayID == displayID }
                        self.surfaces.append(replacement)
                        adopted = true
                        replacement.setMuted(!self.soundEnabled)
                        replacement.setPaused(self.shouldPause)
                        if self.presentsWindows { replacement.show(paused: self.shouldPause) }
                        previous.forEach { $0.close() }
                        if !self.surfaces.contains(where: { $0.usesSharedVideoHub }) {
                            self.activeSharedVideoHub?.close()
                            self.activeSharedVideoHub = nil
                        }
                        if let scene = self.playable, let sourceURL = self.selectedURL {
                            self.syncSystemBackdrop(scene: scene, sourceURL: sourceURL,
                                request: self.generation, onlyDisplayID: displayID)
                        }
                        self.updateMenu()
                        NotificationCenter.default.post(name: .idlesseDisplayAssignmentsChanged, object: self)
                    } else {
                        self.refreshDisplayAssignments()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.showError("The Library wallpaper could not be assigned: " + error.localizedDescription)
                }
            }
        } catch {
            showError("The Library wallpaper could not be assigned: " + error.localizedDescription)
        }
    }

    private func refreshDisplayAssignments() {
        rebuild()
        if let playable, let selectedURL {
            syncSystemBackdrop(scene: playable, sourceURL: selectedURL, request: generation)
        }
        updateMenu()
        NotificationCenter.default.post(name: .idlesseDisplayAssignmentsChanged, object: self)
    }

    func restoreSelection() {
        guard persistsSelection, !isRunning, !isLoading,
              let data = resumeDefaults.data(forKey: Self.resumeKey) else { return }
        logState("restore-begin")
        do {
            var stale = false
            let url: URL
            if let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = resolved
            } else {
                url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            select(url, automatic: true)
        } catch {
            lastReloadError = "The previous wallpaper is unavailable. Choose it again in Wallpapers."
            updateMenu()
        }
    }

    static func smokeSelectionTransactions() throws {
        final class ControlledSource: SceneSource {
            var blocked = false
            var entered = false
            func resolve(_ url: URL) async throws -> SceneDescriptor {
                if url.lastPathComponent == "slow" {
                    entered = true
                    // Deliberately ignore cancellation: stale providers must not win.
                    while blocked { await Task.yield(); try? await Task.sleep(nanoseconds: 5_000_000) }
                }
                if url.lastPathComponent == "bad" { throw SceneError.invalid("Expected load failure") }
                return SceneDescriptor(title: url.lastPathComponent, nodes: [SceneNode(content: .gradient)])
            }
        }
        let source = ControlledSource()
        let host = WallpaperController()
        host.source = source
        host.presentsWindows = false
        var errors = [String]()
        host.onError = { errors.append($0) }
        defer { host.shutdown() }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            precondition(condition(), "Selection transaction timed out")
        }
        let first = URL(fileURLWithPath: "/transaction/first")
        let latest = URL(fileURLWithPath: "/transaction/latest")
        host.select(first); wait { !host.isLoading }
        precondition(host.selectedURL == first)
        let original = host.surfaces.first
        source.blocked = true
        host.select(URL(fileURLWithPath: "/transaction/slow"))
        wait { source.entered }
        precondition(host.selectedURL == first && host.surfaces.first === original,
                     "Loading must retain the active surface")
        host.select(latest); wait { !host.isLoading }
        source.blocked = false
        // Let the stale provider return after the newer selection has committed.
        let drainUntil = Date().addingTimeInterval(0.1)
        while Date() < drainUntil { _ = RunLoop.current.run(mode: .default, before: drainUntil) }
        precondition(host.selectedURL == latest && errors.isEmpty, "Late cancelled loads must not replace playback or report errors")
        let working = host.surfaces.first
        host.select(URL(fileURLWithPath: "/transaction/bad")); wait { !host.isLoading }
        precondition(host.selectedURL == latest && host.surfaces.first === working,
                     "Failed loads must retain the active surface")
        precondition(errors.count == 1, "Only the current failed load should report an error")
        print("Selection transactions passed: retain active surface, latest wins, late cancellation, failed load")
    }

    static func smokeVideoPreparation(url: URL) throws {
        guard let screen = NSScreen.main else { throw SceneError.invalid("A display is required for preparation checks") }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            precondition(condition(), "Video preparation timed out")
        }
        var errors = [String]()
        let scene = try LocalSceneSource.read(url)
        let clock = SceneClock()
        let hub = SharedVideoHub(scene: scene, clock: clock) { errors.append($0) }
        let candidate = try WallpaperSurface(screen: screen, playable: scene, clock: clock, sharedHub: hub) { errors.append($0) }
        defer { candidate.close(); hub.close() }
        hub.setMuted(true); hub.setPaused(false)
        candidate.prepareForDisplay()
        wait { candidate.isReadyForDisplay || !errors.isEmpty }
        precondition(errors.isEmpty && candidate.isReadyForDisplay, "Real video must prepare a complete frame")
        precondition(candidate.window.alphaValue == 0 && candidate.window.ignoresMouseEvents,
                     "Preparation must remain invisible and noninteractive")
        candidate.close(); hub.close()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".mp4")
        let badScene = SceneDescriptor(title: "Missing media", nodes: [SceneNode(content: .video(missing))])
        let badClock = SceneClock()
        let badHub = SharedVideoHub(scene: badScene, clock: badClock) { errors.append($0) }
        let failed = try WallpaperSurface(screen: screen, playable: badScene, clock: badClock, sharedHub: badHub) { errors.append($0) }
        defer { failed.close(); badHub.close() }
        badHub.setMuted(true); badHub.setPaused(false)
        failed.prepareForDisplay()
        wait { !errors.isEmpty }
        precondition(!failed.isReadyForDisplay && failed.window.alphaValue == 0,
                     "A decoder failure must never reveal the candidate")
        failed.close(); badHub.close()
        precondition(!failed.window.isVisible, "Cancelled or failed candidate windows must close")
        print("Video preparation passed: shared decoder first frame, invisible preparation, decoder failure, teardown")
    }

    static func smokeResume(url: URL) throws {
        let suite = "Idlesse.ResumeTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func host() -> WallpaperController {
            let c = WallpaperController()
            c.resumeDefaults = defaults
            c.persistsSelection = true
            c.presentsWindows = false
            c.onError = { _ in }
            return c
        }
        func settle(_ c: WallpaperController) {
            let deadline = Date().addingTimeInterval(15)
            while c.isLoading && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            precondition(!c.isLoading, "Resume timed out")
        }
        let first = host()
        first.select(url)
        settle(first)
        precondition(first.isRunning)
        first.togglePause()
        first.shutdown()
        precondition(defaults.data(forKey: resumeKey) != nil)
        let second = host()
        second.restoreSelection()
        settle(second)
        precondition(second.selectedURL == url && !second.pausedByUser, "Startup must autoplay, never restore paused")
        second.select(url.appendingPathComponent("missing.mp4"))
        settle(second)
        precondition(second.selectedURL == url, "Failed replacement must retain scene")
        second.stop()
        let third = host()
        third.restoreSelection()
        precondition(!third.isRunning && !third.isLoading, "Stop must suppress restart")
        print("Resume checks passed: selection, autoplay-resume, quit, failed replacement, explicit stop")
    }

    private func saveSelection() {
        guard persistsSelection, let selectedURL else { return }
        do {
            let data: Data
            if let scoped = try? selectedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                data = scoped
            } else {
                data = try selectedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            resumeDefaults.set(data, forKey: Self.resumeKey)
            resumeDefaults.set(pausedByUser, forKey: Self.pauseKey)
        } catch {
            // Never resume an older wallpaper after the latest selection could not be saved.
            resumeDefaults.removeObject(forKey: Self.resumeKey)
        }
    }

    func shutdown() {
        saveSelection()
        persistsSelection = false
        stop()
    }

    /// One-line state trace for diagnosing pause/suspend transitions. Grep logs for "Idlesse-state".
    private static func appendLine(_ line: String) {
        NSLog("%@", line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let path = "/tmp/idlesse-state.log"
        if FileManager.default.fileExists(atPath: path),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    private func logState(_ site: String) {
        let b = { (v: Bool) in v ? 1 : 0 }
        let line = String(format: "Idlesse-state %@: running=%d loading=%d suspended=%d shouldPause=%d (byUser=%d bedtime=%d lowPower=%d) surfaces=%d scene=%@",
            site, b(isRunning), b(isLoading), b(suspended), b(shouldPause), b(pausedByUser),
            b(dimmedForBedtime), b(ProcessInfo.processInfo.isLowPowerModeEnabled),
            surfaces.count, playable?.title ?? selectedURL?.lastPathComponent ?? "none")
        NSLog("%@", line)
        if let data = (line + "\n").data(using: .utf8) {
            let path = "/tmp/idlesse-state.log"
            if FileManager.default.fileExists(atPath: path),
               let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    var diagnosticSummary: String {
        let nodes = playable?.allNodes ?? []
        return """
        Wallpaper active: \(isRunning)
        Loading: \(isLoading)
        Paused by user: \(pausedByUser)
        Suspended: \(suspended)
        Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)
        Surfaces: \(surfaces.count)
        Retiring surfaces: \(retiring.count)
        Nodes: \(nodes.count)
        Video nodes: \(nodes.filter { $0.kind == .video }.count)
        Creative renderer required: \(playable?.requiresMetal ?? false)
        Same wallpaper on all displays: \(sameWallpaperOnAllDisplays)
        Desktop span active: \(desktopSpanActive)
        Coverage rest enabled: \(coveragePauseEnabled)
        Coverage rest/resume thresholds: \(coverageMonitor.policy.restThreshold) / \(coverageMonitor.policy.resumeThreshold)
        Coverage stable samples: \(coverageMonitor.policy.stableSamples)
        Covered surfaces: \(surfaces.filter(\.isCovered).count)
        Menu strip timing: \(surfaces.map { "\($0.displayID): \($0.menuStripTiming)" }.joined(separator: "; "))
        Crossfade seconds: \(transitionDuration)
        """
    }

    private var selectedIsAnimated: Bool { playable?.animated ?? false }
    private var clock = SceneClock()
    private var audioSession: SceneAudioSession?
    private var watcher: SceneWatcher?
    private(set) var lastReloadError: String?
    private(set) var revision = 0
    var sceneTime: TimeInterval { clock.time }
    private var source: SceneSource = LocalSceneSource()
    private var scopeStarted = false
    private var retiring: [WallpaperSurface] = []
    private var retiringURL: URL?
    private var transitionTimer: Timer?
    var transitionDuration: Double {
        get { let value = UserDefaults.standard.double(forKey: "wallpaperTransitionSeconds"); return [0, 0.5, 1, 2].contains(value) ? value : 0 }
        set { UserDefaults.standard.set([0, 0.5, 1, 2].contains(newValue) ? newValue : 0, forKey: "wallpaperTransitionSeconds") }
    }
    private var asleep = false
    private var systemAsleep = false
    var presentsWindows = true
    var onError: ((String) -> Void)?
    private var sessionInactive = false
    private var generation = 0
    private var displayAssignmentRequests: [UInt32: UUID] = [:]
    private var surfaceGeneration = 0
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var backdropTask: Task<Void, Never>?
    private var screenRefresh: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var statusItem: NSStatusItem?
    private var chooser: NSOpenPanel?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowLibrary: (() -> Void)?
    var onShowPreview: (() -> Void)?
    private lazy var displayAssignmentController = DisplayAssignmentController(wallpaper: self)
    /// Menu items contributed by the host (next/previous, recents). Rebuilt on every menu open.
    var extraMenuItemsProvider: (() -> [NSMenuItem])?
    var presentingWindow: (() -> NSWindow?)?
    var onStateChange: (() -> Void)?
    weak var comfort: DesktopComfortController?
    private var dimmedForBedtime = false

    var statusDescription: String {
        let title = playable?.title ?? selectedURL?.deletingPathExtension().lastPathComponent ?? "No wallpaper selected"
        let span = desktopSpanActive ? "Desktop Span · " : ""
        if isLoading { return "Loading… · " + span + title }
        guard isRunning else { return title }
        if !suspended, !shouldPause, !surfaces.isEmpty, surfaces.allSatisfy(\.isCovered) {
            return "Covered — resting · " + span + title
        }
        let state = suspended ? "Suspended" : (shouldPause ? "Paused" : "Playing")
        return state + " · " + span + title
    }
    var isRunning: Bool { selectedURL != nil }
    private var suspended: Bool { asleep || systemAsleep || sessionInactive }
    /// Set by AmbientModesController while a scheduled scene is showing so the
    /// bedtime shade doesn't pause the night scene it just switched to.
    var modeOverrideActive = false
    private var shouldPause: Bool { pausedByUser || (dimmedForBedtime && !modeOverrideActive) || ProcessInfo.processInfo.isLowPowerModeEnabled }

    override init() {
        super.init()
        observe(.default, SceneFrameRate.changed) { controller in
            controller.surfaces.forEach { $0.updateFrameRate() }
        }
        observe(.default, DesktopComfortController.desktopVisibilityChanged) { controller in
            controller.surfaces.forEach { controller.configureDesktopInteraction($0) }
            controller.updateMenu()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setAsleep(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setAsleep(false) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSystemAsleep(true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSystemAsleep(false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSessionInactive(true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSessionInactive(false) }
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange) { controller in
            controller.clock.setPaused(controller.suspended || controller.shouldPause)
            controller.applySharedHubPause()
            controller.surfaces.forEach { $0.setPaused(controller.shouldPause) }
            controller.surfaces.forEach { $0.updateFrameRate() }
            controller.logState("power-change")
            controller.updateMenu()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.screenRefresh?.cancel()
            let work = DispatchWorkItem { [weak controller] in controller?.rebuild() }
            controller.screenRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        let coverage = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.pollCoverage() }
        coverage.tolerance = 1
        RunLoop.main.add(coverage, forMode: .common)
        coverageTimer = coverage
    }

    private var coverageTimer: Timer?
    private let coverageMonitor = CoverageMonitor()
    /// Rest fully covered displays to save GPU. Kept opt-in while fullscreen,
    /// Stage Manager, Mission Control and translucent-window behavior is qualified.
    var coveragePauseEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "coveragePauseEnabled") == nil ? false : UserDefaults.standard.bool(forKey: "coveragePauseEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "coveragePauseEnabled")
            if !newValue {
                coverageMonitor.reset()
                surfaces.forEach { $0.setCovered(false) }
                applySharedHubPause()
            }
            pollCoverage()
            updateMenu()
        }
    }
    private func applySharedHubPause() {
        let resting = coveragePauseEnabled ? surfaces.map(\.isCovered) : []
        activeSharedVideoHub?.setPaused(CoverageRestPolicy.shouldRestSharedPlayback(
            globalPause: shouldPause, displayResting: resting))
    }
    private var desktopReveal = DesktopRevealPolicy()

    private func pollCoverage() {
        guard desktopReveal.allowsCoverage(at: ProcessInfo.processInfo.systemUptime) else { return }
        guard presentsWindows, coveragePauseEnabled, !surfaces.isEmpty, !suspended else { return }
        var own = Set<CGWindowID>()
        for surface in surfaces {
            own.insert(CGWindowID(surface.window.windowNumber))
            if let strip = surface.menuStripWindowNumber { own.insert(CGWindowID(strip)) }
        }
        var changed = false
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        for surface in surfaces {
            let measurement = coverageMonitor.measurement(of: surface.window.frame,
                above: surface.window.level.rawValue, excluding: own, ownPID: pid)
            let key = Self.persistentDisplayIdentifier(surface.displayID)
            let decision = coverageMonitor.evaluate(displayKey: key, fraction: measurement.fraction,
                currentResting: surface.isCovered)
            let candidate = decision.candidate.map { $0 ? "rest" : "resume" } ?? "hold"
            Self.appendLine(String(format:
                "Idlesse-coverage display=%@ frame=%@ fraction=%.2f resting=%d candidate=%@ stable=%d/%d windows=%d chrome=%d transparent=%d thresholds=%.2f/%.2f",
                key, NSStringFromRect(surface.window.frame), measurement.fraction, decision.isResting ? 1 : 0,
                candidate, decision.consecutiveSamples, coverageMonitor.policy.stableSamples,
                measurement.consideredWindows, measurement.ignoredChromeWindows,
                measurement.ignoredTransparentWindows, coverageMonitor.policy.restThreshold,
                coverageMonitor.policy.resumeThreshold))
            if decision.changed {
                surface.setCovered(decision.isResting)
                changed = true
            }
        }
        applySharedHubPause()
        if changed { logState("coverage"); updateMenu() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (WallpaperController) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { action(self) }
        }
        observers.append((center, observer))
    }

    @objc func chooseWallpaper() {
        if let chooser { chooser.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Choose your wallpaper"
        panel.message = "One image or muted looping video, on every display. Stop any time from the Idlesse menu."
        panel.prompt = "Use Wallpaper"
        panel.allowedContentTypes = [.directory, .jpeg, .png, .heic, .mpeg4Movie, .quickTimeMovie, UTType(exportedAs: "com.teamleaderleo.idlesse.scene", conformingTo: .package)]
        panel.treatsFilePackagesAsDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedURL?.deletingLastPathComponent()
        chooser = panel
        NSApp.activate(ignoringOtherApps: true)
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.chooser = nil
            guard response == .OK, let url = panel.url else {
                if self?.isRunning == true { self?.onStart?() }
                return
            }
            self?.select(url)
        }
        onShowLibrary?()
        if let owner = presentingWindow?() {
            panel.beginSheetModal(for: owner, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    static func isVideo(_ url: URL) throws -> Bool {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic": return false
        case "mp4", "mov": return true
        default: throw WallpaperError.unsupported
        }
    }

    /// Opt-in audible video (off by default; every player starts muted).
    /// Applies to new surfaces and live ones, including the shared video hub.
    var soundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "wallpaperSoundEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "wallpaperSoundEnabled")
            applyMute()
            updateMenu()
        }
    }
    private func applyMute() {
        activeSharedVideoHub?.setMuted(!soundEnabled)
        surfaces.forEach { $0.setMuted(!soundEnabled) }
    }

    var onManualSelection: (() -> Void)?
    /// Fires after any successful (non-reload) selection with the adopted URL.
    var onSelectionCommitted: ((URL) -> Void)?

    func select(_ url: URL, reloading: Bool = false, automatic: Bool = false, restoringPause: Bool? = nil) {
        if !reloading && !automatic { onManualSelection?() }
        if !reloading { watcher = nil }
        generation += 1
        let request = generation
        loadTask?.cancel()
        finishTransition()
        isLoading = true
        ensureStatusItem()
        updateMenu()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let access = url.startAccessingSecurityScopedResource()
            var adopted = false
            defer {
                if access && !adopted { url.stopAccessingSecurityScopedResource() }
                if request == self.generation {
                    self.isLoading = false
                    self.updateMenu()
                }
            }
            do {
                let playable = try await self.source.resolve(url)
                for node in playable.allNodes where node.kind == .video {
                    guard let assetURL = node.assetURL else { continue }
                    let asset = AVURLAsset(url: assetURL)
                    let playable = try await asset.load(.isPlayable)
                    let duration = try await asset.load(.duration)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard playable, duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else {
                        throw WallpaperError.noVideo
                    }
                }
                guard !Task.isCancelled, request == self.generation else { return }
                // Build before replacing the old wallpaper, so a bad file leaves it intact.
                let reuseClock = reloading && self.playable?.timeline == playable.timeline
                let candidateClock = reuseClock ? self.clock : SceneClock()
                if !reuseClock {
                    try candidateClock.configure(timeline: playable.timeline)
                    candidateClock.pointerEnabled = reloading && self.clock.pointerEnabled
                    candidateClock.audioEnabled = reloading && self.clock.audioEnabled && playable.usesAudio
                }
                var preparationError: String?
                let (replacement, newHub) = self.suspended ? ([], nil) :
                    try self.makeSurfaces(playable: playable, clock: candidateClock, request: request, onError: { [weak self] message in
                        if adopted { self?.stop(); self?.showError(message) }
                        else { preparationError = message }
                    })
                let preparedGeneration = self.surfaceGeneration
                defer {
                    if !adopted { replacement.forEach { $0.close() }; newHub?.close() }
                }
                if self.presentsWindows && !replacement.isEmpty {
                    newHub?.setMuted(true)
                    newHub?.setPaused(false)
                    replacement.forEach { $0.prepareForDisplay() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 10
                    while !replacement.allSatisfy({ $0.isReadyForDisplay }) {
                        try Task.checkCancellation()
                        guard request == self.generation, preparedGeneration == self.surfaceGeneration, !self.suspended else { throw CancellationError() }
                        if let preparationError { throw SceneError.invalid(preparationError) }
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw WallpaperError.preparationTimeout }
                        try await Task.sleep(nanoseconds: 30_000_000)
                        replacement.forEach { $0.refreshPreparation() }
                    }
                    try Task.checkCancellation()
                    guard request == self.generation, preparedGeneration == self.surfaceGeneration, !self.suspended else { throw CancellationError() }
                    if let preparationError { throw SceneError.invalid(preparationError) }
                }
                let fade = !reloading && self.presentsWindows && !self.suspended && !self.shouldPause &&
                    !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && self.transitionDuration > 0 && !self.surfaces.isEmpty
                if fade {
                    self.retiring = self.surfaces
                    self.retiring.forEach { $0.setPaused(true) }
                    self.retiringSharedVideoHub = self.activeSharedVideoHub
                    self.retiringURL = self.scopeStarted ? self.selectedURL : nil
                    self.surfaces = []
                    self.activeSharedVideoHub = nil
                } else {
                    self.releaseSurfaces()
                    if self.scopeStarted { self.selectedURL?.stopAccessingSecurityScopedResource() }
                }
                self.selectedURL = url
                self.scopeStarted = access
                self.playable = playable
                adopted = true
                if !reloading { self.pausedByUser = restoringPause ?? false }
                if !reuseClock {
                    self.audioSession = nil
                    self.audioSession = SceneAudioSession(clock: candidateClock) { [weak self] message in
                        self?.onError?(message)
                        self?.lastReloadError = message
                        self?.updateMenu()
                    }
                }
                if !playable.usesAudio { candidateClock.audioEnabled = false }
                self.clock = candidateClock
                self.clock.setPaused(self.suspended || self.shouldPause)
                self.lastReloadError = nil
                self.revision += 1
                self.watch(url: url, scene: playable)
                self.coverageMonitor.reset()
                self.surfaces = replacement
                self.activeSharedVideoHub = newHub
                self.applySharedHubPause()
                replacement.forEach { $0.setPaused(self.shouldPause) }
                self.activeSharedVideoHub?.setMuted(!self.soundEnabled)
                replacement.forEach { $0.setMuted(!self.soundEnabled) }
                if self.suspended { self.releaseSurfaces() }
                else if self.presentsWindows {
                    replacement.forEach {
                        self.configureDesktopInteraction($0)
                        $0.window.alphaValue = fade ? 0 : 1
                        $0.show(paused: self.shouldPause)
                    }
                    if fade { self.beginTransition() }
                }
                self.ensureStatusItem()
                self.updateMenu()
                NotificationCenter.default.post(name: .idlesseDisplayAssignmentsChanged, object: self)
                self.syncSystemBackdrop(scene: playable, sourceURL: url, request: request)
                self.saveSelection()
                self.logState("select-done")
                if !reloading { self.onSelectionCommitted?(url) }
                self.onStart?()
            } catch {
                guard !Task.isCancelled, request == self.generation else { return }
                if error is CancellationError {
                    if let previousURL = self.selectedURL, let previousScene = self.playable {
                        self.watch(url: previousURL, scene: previousScene)
                    }
                    return
                }
                if reloading {
                    self.lastReloadError = error.localizedDescription
                    self.updateMenu()
                } else {
                    if let previousURL = self.selectedURL, let previousScene = self.playable {
                        self.watch(url: previousURL, scene: previousScene)
                    }
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func watch(url: URL, scene: SceneDescriptor) {
        watcher = nil
        guard url.pathExtension.lowercased() == "idlesse" else { return }
        watcher = SceneWatcher(package: url, assets: scene.assetNodes.flatMap { $0.assets }) { [weak self] in
            guard let self, self.selectedURL == url else { return }
            self.select(url, reloading: true)
        }
    }

    private func makeSurfaces(playable: SceneDescriptor, clock: SceneClock, request: Int, onError: ((String) -> Void)? = nil) throws -> (surfaces: [WallpaperSurface], hub: SharedVideoHub?) {
        surfaceGeneration += 1
        let surfaceRequest = surfaceGeneration
        var result: [WallpaperSurface] = []
        let hasVideo = playable.allNodes.contains { $0.kind == .video }
        let sharesSceneAcrossDisplays = sameWallpaperOnAllDisplays || playable.canvas == .desktopSpan
        let needsMetal = WallpaperSurface.usesMetal(playable, menuAnimation: WallpaperSurface.liveMenuStripEnabled)
        let sharedHub = (sharesSceneAcrossDisplays && hasVideo && needsMetal) ? SharedVideoHub(scene: playable, clock: clock) { [weak self] message in
            guard let self, self.generation == request,
                  self.surfaceGeneration == surfaceRequest else { return }
            if let onError { onError(message); return }
            self.stop()
            self.showError(message)
        } : nil
        do {
            for screen in NSScreen.screens {
                var screenPlayable = playable
                var screenHub = sharesSceneAcrossDisplays ? sharedHub : nil
                var screenScope: WallpaperScopeLease?
                if !sharesSceneAcrossDisplays {
                    let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
                    if let overrideURL = explicitDisplayURL(for: displayID), overrideURL != selectedURL {
                        let lease = WallpaperScopeLease(overrideURL)
                        if let resolved = try? LocalSceneSource.read(overrideURL) {
                            if resolved.canvas == .desktopSpan {
                                Self.appendLine("Idlesse-display display=\(Self.persistentDisplayIdentifier(displayID)) action=ignore-saved-desktop-span")
                            } else {
                                screenPlayable = resolved
                                screenHub = nil
                                screenScope = lease
                            }
                        }
                    }
                }
                let surface = try autoreleasepool {
                    try WallpaperSurface(screen: screen, playable: screenPlayable, clock: clock,
                        sharedHub: screenHub, securityScope: screenScope) { [weak self] message in
                        guard let self, self.generation == request,
                              self.surfaceGeneration == surfaceRequest else { return }
                        if let onError { onError(message); return }
                        self.stop()
                        self.showError(message)
                    }
                }
                configureDesktopInteraction(surface)
                result.append(surface)
            }
            return (result, sharedHub)
        } catch {
            sharedHub?.close()
            result.forEach { $0.close() }
            throw error
        }
    }

    /// Remember the user's plain wallpaper once per display, before our stills
    /// replace it. Never records one of our own stills as the original.
    private func rememberOriginalBackdrop(for screen: NSScreen) {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        let key = Self.origBackdropPrefix + String(displayID)
        guard resumeDefaults.string(forKey: key) == nil else { return }
        guard persistsSelection else { return }
        if let current = try? NSWorkspace.shared.desktopImageURL(for: screen),
           !Self.isOurStill(current) {
            resumeDefaults.set(current.path, forKey: key)
        }
    }

    /// After Idlesse stops, put the plain wallpaper back where our still was.
    /// If the user already changed it themselves, their choice wins.
    private func restoreOriginalBackdrops() {
        for screen in NSScreen.screens {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
            let key = Self.origBackdropPrefix + String(displayID)
            defer { resumeDefaults.removeObject(forKey: key) }
            guard let path = resumeDefaults.string(forKey: key) else { continue }
            guard let current = try? NSWorkspace.shared.desktopImageURL(for: screen),
                  Self.isOurStill(current) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen,
                options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
        }
    }

    /// A full-resolution SDR still gives macOS matching material for menu-bar/Show Desktop
    /// regions it composites from the system wallpaper rather than our window.
    private func syncSystemBackdrop(scene: SceneDescriptor, sourceURL: URL, request: Int, onlyDisplayID: UInt32? = nil) {
        guard persistsSelection && presentsWindows else { return }
        backdropTask?.cancel()
        backdropTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("Idlesse/Desktop Backdrops")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let screens = NSScreen.screens.filter { screen in
                    onlyDisplayID == nil || (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == onlyDisplayID
                }
                for screen in screens {
                    try Task.checkCancellation()
                    rememberOriginalBackdrop(for: screen)
                    let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
                    var backdropScene = scene
                    var displayScope: WallpaperScopeLease?
                    if !sameWallpaperOnAllDisplays, scene.canvas != .desktopSpan,
                       let overrideURL = explicitDisplayURL(for: displayID), overrideURL != sourceURL {
                        let lease = WallpaperScopeLease(overrideURL)
                        if let resolved = try? LocalSceneSource.read(overrideURL), resolved.canvas != .desktopSpan {
                            backdropScene = resolved
                            displayScope = lease
                        }
                    }
                    // Native backing resolution (within probe limits) so the still
                    // stays sharp in Mission Control, lock screen and Spaces.
                    let scale = max(1, screen.backingScaleFactor)
                    var width = Int((screen.frame.width * scale).rounded())
                    var height = Int((screen.frame.height * scale).rounded())
                    let fit = min(1.0, 3840 / Double(max(1, width)), 2160 / Double(max(1, height)))
                    width = max(32, Int((Double(width) * fit).rounded()))
                    height = max(32, Int((Double(height) * fit).rounded()))
                    let clock = SceneClock(now: { 0 })
                    try clock.configure(timeline: backdropScene.timeline)
                    let time = backdropScene.metadata?.previewTime ?? 2
                    try clock.seek(to: time)
                    let renderer = try MetalSceneRenderer(playable: backdropScene,
                        bounds: NSRect(x: 0, y: 0, width: width, height: height), scale: 1, clock: clock, onError: { _ in })
                    defer { renderer.releaseResources() }
                    if backdropScene.canvas == .desktopSpan {
                        renderer.desktopFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
                        renderer.displayFrame = screen.frame
                    }
                    try await renderer.prepareOfflineVideo(at: backdropScene.timeline?.videosFollowScene == true ? clock.time : time,
                        size: CGSize(width: width, height: height))
                    try Task.checkCancellation()
                    guard self.generation == request else { return }
                    let bytes = try renderer.renderFrame(signals: .init(time: clock.time), width: width, height: height, sampleVideo: false)
                    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                          let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                    else { throw SceneError.invalid("Could not prepare the system wallpaper still.") }
                    withExtendedLifetime(displayScope) {}
                    let slotKey = "wallpaperBackdropSlot.\(displayID)"
                    let slot = 1 - min(1, max(0, UserDefaults.standard.integer(forKey: slotKey)))
                    let destination = root.appendingPathComponent("display-\(displayID)-\(slot).jpg")
                    try jpeg.write(to: destination, options: .atomic)
                    try NSWorkspace.shared.setDesktopImageURL(destination, for: screen,
                        options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
                    UserDefaults.standard.set(slot, forKey: slotKey)
                }
            } catch {
                guard !Task.isCancelled, self.generation == request else { return }
                self.lastReloadError = "System wallpaper still: " + error.localizedDescription
                self.updateMenu()
            }
        }
    }

    private func configureDesktopInteraction(_ surface: WallpaperSurface) {
        surface.setCleanDesktop(comfort?.desktopIconsVisible == false,
            hideWidgets: comfort?.desktopWidgetsVisible == false,
            click: { [weak self] in self?.revealDesktop() },
            menu: { [weak self] in self?.cleanDesktopMenu() ?? NSMenu() })
    }

    @objc func revealDesktop() {
        // Wake covered surfaces before the system animation exposes them. This
        // preserves explicit pause/bedtime state and avoids waiting for polling.
        guard desktopReveal.begin() else { return }
        let started = ProcessInfo.processInfo.systemUptime
        coverageMonitor.reset()
        for surface in surfaces { surface.setCovered(false) }
        applySharedHubPause()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["1"]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
            configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.desktopReveal.complete(at: ProcessInfo.processInfo.systemUptime, succeeded: error == nil)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    NSLog("Idlesse desktop reveal dispatch completed in %.1f ms", elapsed)
                    if let error { self.showError(error.localizedDescription) }
                }
            }
    }

    @objc private func openDesktopFolder() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
    }
    @objc private func customizeDesktop() { onShowSettings?() }
    private func cleanDesktopMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Change Wallpaper…", #selector(customizeDesktop)),
                                ("Open Desktop Folder", #selector(openDesktopFolder)),
                                ("Show / Restore Windows", #selector(revealDesktop))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        let native = menu.addItem(withTitle: "Native Desktop Right-Click", action: #selector(toggleNativeDesktopMenu), keyEquivalent: "")
        native.target = self
        native.state = WallpaperSurface.nativeDesktopMenuEnabled ? .on : .off
        native.toolTip = "Right-click shows the Finder menu (needs Accessibility permission once). Off shows this Idlesse menu."
        menu.addItem(.separator())
        comfort?.addDesktopIconsItem(to: menu)
        return menu
    }

    @objc private func toggleNativeDesktopMenu() {
        UserDefaults.standard.set(!WallpaperSurface.nativeDesktopMenuEnabled, forKey: "comfort.nativeDesktopMenu")
        if !WallpaperSurface.nativeDesktopMenuEnabled {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }

    private func rebuild() {
        guard let playable, !suspended else { return }
        // Release first on display changes to avoid temporarily doubling players.
        releaseSurfaces()
        do {
            let (newSurfaces, newHub) = try makeSurfaces(playable: playable, clock: clock, request: generation)
            surfaces = newSurfaces
            activeSharedVideoHub = newHub
            applySharedHubPause()
            surfaces.forEach { $0.setPaused(shouldPause) }
            activeSharedVideoHub?.setMuted(!soundEnabled)
            surfaces.forEach { $0.setMuted(!soundEnabled) }
            if presentsWindows { surfaces.forEach { $0.show(paused: shouldPause) } }
        } catch {
            stop()
            showError(error.localizedDescription)
        }
        updateMenu()
    }

    func setSystemAsleep(_ value: Bool) {
        guard systemAsleep != value else { return }
        systemAsleep = value
        clock.setPaused(suspended || shouldPause)
        if suspended { releaseSurfaces() } else { rebuild() }
        logState("system-sleep")
        updateMenu()
    }

    func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value
        clock.setPaused(suspended || shouldPause)
        if suspended { releaseSurfaces() } else { rebuild() }
        logState("screens-sleep")
        updateMenu()
    }

    func setSessionInactive(_ value: Bool) {
        guard sessionInactive != value else { return }
        sessionInactive = value
        clock.setPaused(suspended || shouldPause)
        if suspended { releaseSurfaces() } else { rebuild() }
        logState("session")
        updateMenu()
    }

    func setDimmedForBedtime(_ value: Bool) {
        finishTransition()
        dimmedForBedtime = value
        clock.setPaused(suspended || shouldPause)
        applySharedHubPause()
        surfaces.forEach { $0.setPaused(shouldPause) }
        logState("bedtime")
        updateMenu()
    }

    @objc func togglePause() {
        finishTransition()
        pausedByUser.toggle()
        saveSelection()
        clock.setPaused(suspended || shouldPause)
        applySharedHubPause()
        surfaces.forEach { $0.setPaused(shouldPause) }
        logState("togglePause")
        updateMenu()
    }

    @objc func stop() {
        if persistsSelection {
            resumeDefaults.removeObject(forKey: Self.resumeKey)
            resumeDefaults.removeObject(forKey: Self.pauseKey)
        }
        onManualSelection?()
        let wasActive = isRunning || isLoading
        watcher = nil
        lastReloadError = nil
        clock.setPaused(true)
        activeSharedVideoHub?.close()
        activeSharedVideoHub = nil
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        backdropTask?.cancel()
        backdropTask = nil
        screenRefresh?.cancel()
        screenRefresh = nil
        releaseSurfaces()
        restoreOriginalBackdrops()
        if scopeStarted { selectedURL?.stopAccessingSecurityScopedResource() }
        scopeStarted = false
        selectedURL = nil
        playable = nil
        isLoading = false
        pausedByUser = false
        logState("stop")
        updateMenu()
        if wasActive { onStop?() }
    }

    private func releaseSurfaces() {
        finishTransition()
        surfaces.forEach { $0.close() }
        surfaces.removeAll()
        coverageMonitor.reset()
        activeSharedVideoHub?.close()
        activeSharedVideoHub = nil
    }

    static func smokeTargetedAssignment(imageURL: URL) throws {
        let suite = "Idlesse.TargetedAssignment." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = WallpaperController()
        controller.resumeDefaults = defaults
        controller.presentsWindows = false
        controller.persistsSelection = false
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        let scene = try LocalSceneSource.read(imageURL)
        controller.selectedURL = imageURL
        controller.playable = scene
        let initial = try controller.makeSurfaces(playable: scene, clock: controller.clock, request: controller.generation)
        controller.surfaces = initial.surfaces
        controller.activeSharedVideoHub = initial.hub
        defer { controller.releaseSurfaces() }
        guard let target = initial.surfaces.first, initial.surfaces.count > 1 else {
            throw SceneError.invalid("Targeted assignment check needs two connected displays")
        }
        let untouched = initial.surfaces.filter { $0 !== target }
        controller.assignLibraryWallpaper(imageURL, to: target.displayID)
        let deadline = Date().addingTimeInterval(10)
        while controller.surfaces.contains(where: { $0 === target }) && errors.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(errors.isEmpty, "Targeted assignment failed: \(errors)")
        precondition(!controller.surfaces.contains(where: { $0 === target }), "Target surface must be replaced")
        precondition(controller.surfaces.count == initial.surfaces.count)
        for surface in untouched {
            precondition(controller.surfaces.contains(where: { $0 === surface }), "Other displays must keep their renderer and playback state")
        }
        precondition(!controller.sameWallpaperOnAllDisplays)
        print("Targeted assignment passed: one surface replaced; \(untouched.count) unchanged display renderer(s) retained")
    }

    static func smokeTransitions(imageURL: URL) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "wallpaperTransitionSeconds")
        let previousStyle = defaults.object(forKey: "wallpaperTransitionStyle")
        defer {
            if let previous { defaults.set(previous, forKey: "wallpaperTransitionSeconds") }
            else { defaults.removeObject(forKey: "wallpaperTransitionSeconds") }
            if let previousStyle { defaults.set(previousStyle, forKey: "wallpaperTransitionStyle") }
            else { defaults.removeObject(forKey: "wallpaperTransitionStyle") }
        }
        let controller = WallpaperController()
        controller.presentsWindows = false
        controller.transitionDuration = 0.5
        let scene = SceneDescriptor(title: "Transition", assetURL: imageURL, kind: .image)
        controller.retiring = try controller.makeSurfaces(playable: scene, clock: SceneClock(), request: 0).surfaces
        let old = controller.retiring
        let (smokeSurfaces1, smokeHub1) = try controller.makeSurfaces(playable: scene, clock: SceneClock(), request: 0)
        controller.surfaces = smokeSurfaces1
        controller.activeSharedVideoHub = smokeHub1
        if let surface = controller.surfaces.first {
            let originalView = surface.window.contentView
            var clicks = 0
            surface.setCleanDesktop(true, click: { clicks += 1 }, menu: { NSMenu() })
            precondition(!surface.window.ignoresMouseEvents)
            precondition(surface.window.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)))
            precondition(surface.window.contentView === originalView, "Clean desktop must reuse the renderer")
            // Local dispatch to an unshown test window, never posted to the system.
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            surface.window.sendEvent(event)
            precondition(clicks == 1, "Clean desktop must handle a click instead of opening an invisible file")
            surface.setCleanDesktop(true, hideWidgets: true, click: { clicks += 1 }, menu: { NSMenu() })
            precondition(surface.window.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)) + 2, "Hidden widgets must remain below the clean desktop")
            precondition(surface.window.contentView === originalView, "Widget hiding must not replace the renderer")
            surface.window.sendEvent(event)
            precondition(clicks == 2)
            surface.setCleanDesktop(false, click: {}, menu: { NSMenu() })
            precondition(surface.window.ignoresMouseEvents)
            precondition(surface.window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        }
        controller.surfaces.forEach { $0.window.alphaValue = 0 }
        controller.beginTransition()
        let deadline = Date(timeIntervalSinceNow: 2)
        while controller.transitionTimer != nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        precondition(controller.transitionTimer == nil && controller.retiring.isEmpty)
        precondition(old.allSatisfy { $0.diagnostics.activeResources == 0 })
        precondition(controller.surfaces.allSatisfy { $0.window.alphaValue == 1 })
        for style in TransitionStyle.allCases {
            controller.transitionStyle = style
            controller.retiring = controller.surfaces
            let (styledSurfaces, styledHub) = try controller.makeSurfaces(playable: scene, clock: SceneClock(), request: 0)
            controller.surfaces = styledSurfaces
            controller.activeSharedVideoHub = styledHub
            controller.surfaces.forEach { $0.window.alphaValue = 0 }
            controller.beginTransition()
            let styleDeadline = Date(timeIntervalSinceNow: 2)
            while controller.transitionTimer != nil && Date() < styleDeadline {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            precondition(controller.transitionTimer == nil && controller.retiring.isEmpty, "\(style) must complete")
            precondition(controller.surfaces.allSatisfy { $0.window.alphaValue == 1 }, "\(style) must land opaque")
            precondition(controller.surfaces.allSatisfy { $0.window.contentView?.layer?.affineTransform().isIdentity ?? true },
                "\(style) must restore an identity transform")
        }
        controller.retiring = controller.surfaces
        let interrupted = controller.retiring
        let (smokeSurfaces2, smokeHub2) = try controller.makeSurfaces(playable: scene, clock: SceneClock(), request: 0)
        controller.surfaces = smokeSurfaces2
        controller.activeSharedVideoHub = smokeHub2
        controller.beginTransition()
        controller.setDimmedForBedtime(true)
        precondition(controller.transitionTimer == nil && controller.retiring.isEmpty)
        precondition(interrupted.allSatisfy { $0.diagnostics.activeResources == 0 })
        controller.stop()
        precondition(controller.surfaces.isEmpty)
    }

    /// Transition gallery for scene changes. Duration 0 means instant (also
    /// forced under Reduce Motion); otherwise the chosen style runs at 60 Hz.
    enum TransitionStyle: String, CaseIterable {
        case crossfade, dip, zoom
        var title: String {
            switch self {
            case .crossfade: return "Crossfade"
            case .dip: return "Dip to black"
            case .zoom: return "Zoom fade"
            }
        }
    }
    var transitionStyle: TransitionStyle {
        get { TransitionStyle(rawValue: UserDefaults.standard.string(forKey: "wallpaperTransitionStyle") ?? "") ?? .crossfade }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "wallpaperTransitionStyle") }
    }

    private func beginTransition() {
        if presentsWindows {
            for (next, old) in zip(surfaces, retiring) {
                next.window.order(.above, relativeTo: old.window.windowNumber)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let duration = transitionDuration
        let style = transitionStyle
        if style == .zoom {
            surfaces.forEach { surface in
                surface.window.contentView?.wantsLayer = true
                surface.window.contentView?.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / max(0.01, duration))
            let eased = progress * progress * (3 - 2 * progress)
            switch style {
            case .crossfade:
                self.surfaces.forEach { $0.window.alphaValue = eased }
            case .dip:
                // Old scene out in the first half, new scene in during the second.
                self.retiring.forEach { $0.window.alphaValue = 1 - min(1, eased * 2) }
                self.surfaces.forEach { $0.window.alphaValue = max(0, eased * 2 - 1) }
            case .zoom:
                self.surfaces.forEach { surface in
                    surface.window.alphaValue = eased
                    let scale = 1.06 - 0.06 * eased
                    if let view = surface.window.contentView, let layer = view.layer {
                        let size = view.bounds.size
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        layer.setAffineTransform(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                            .scaledBy(x: scale, y: scale)
                            .translatedBy(x: -size.width / 2, y: -size.height / 2))
                        CATransaction.commit()
                    }
                }
            }
            if progress >= 1 { self.finishTransition() }
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishTransition() {
        transitionTimer?.invalidate(); transitionTimer = nil
        surfaces.forEach {
            $0.window.alphaValue = 1
            if let layer = $0.window.contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.setAffineTransform(.identity)
                CATransaction.commit()
            }
        }
        retiring.forEach { $0.close() }; retiring.removeAll()
        retiringSharedVideoHub?.close(); retiringSharedVideoHub = nil
        retiringURL?.stopAccessingSecurityScopedResource(); retiringURL = nil
    }

    @objc private func changeTransition(_ sender: NSMenuItem) {
        transitionDuration = sender.representedObject as? Double ?? 0
        updateMenu()
    }
    @objc private func changeTransitionStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = TransitionStyle(rawValue: raw) {
            transitionStyle = style
        }
        updateMenu()
    }

    private func ensureStatusItem() {
        guard presentsWindows, statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "cat", accessibilityDescription: "Idlesse")
        item.button?.toolTip = "Idlesse Wallpaper"
        statusItem = item
    }

    private func updateMenu() {
        let menu = NSMenu()
        let state = isLoading ? "Opening wallpaper…" : selectedURL == nil ? "Wallpaper stopped" :
            (suspended ? "Waiting for your display" : (shouldPause && selectedIsAnimated ? "Scene paused" : "Wallpaper running"))
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        if let lastReloadError { menu.addItem(withTitle: "Edit not applied: " + lastReloadError, action: nil, keyEquivalent: "") }
        if let playable { menu.addItem(withTitle: playable.title, action: nil, keyEquivalent: "") }
        let sceneMenu = NSMenu()
        if let playable, !playable.parameters.isEmpty {
            let controls = addItem(sceneMenu, "Scene Controls…", #selector(editControls))
            controls.isEnabled = !isLoading
        }
        if playable?.usesPointer == true {
            let pointer = addItem(sceneMenu, "Enable Pointer Response", #selector(togglePointer))
            pointer.state = clock.pointerEnabled ? .on : .off
            pointer.isEnabled = !isLoading
        }
        if playable?.usesAudio == true {
            let audio = addItem(sceneMenu, "Enable Audio Response", #selector(toggleAudio))
            audio.state = clock.audioEnabled ? .on : .off
            audio.isEnabled = !isLoading
        }
        if isRunning {
            let sound = addItem(sceneMenu, "Play Wallpaper Audio", #selector(toggleSound))
            sound.state = soundEnabled ? .on : .off
            addItem(sceneMenu, "Stop Wallpaper", #selector(self.stop))
        }
        if !sceneMenu.items.isEmpty {
            let scene = NSMenuItem(title: "Scene", action: nil, keyEquivalent: "")
            sceneMenu.autoenablesItems = false
            scene.submenu = sceneMenu
            menu.addItem(scene)
        }
        menu.addItem(.separator())
        addItem(menu, "Open Library…", #selector(openLibrary))
        if NSScreen.screens.count > 1 {
            let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
            let displayMenu = NSMenu()
            let assignments = addItem(displayMenu, "Assign Library Wallpapers…", #selector(showDisplayAssignments))
            assignments.isEnabled = !isLoading
            let sameItem = addItem(displayMenu, "Same Wallpaper on All Displays", #selector(toggleSameDisplays))
            sameItem.state = sameWallpaperOnAllDisplays ? .on : .off
            if desktopSpanActive {
                displayMenu.addItem(.separator())
                let span = displayMenu.addItem(withTitle: "Desktop Span — one continuous canvas", action: nil, keyEquivalent: "")
                span.isEnabled = false
            }
            displaysItem.submenu = displayMenu
            menu.addItem(displaysItem)
        }
        let pause = addItem(menu, pausedByUser ? "Resume Scene" : "Pause Scene", #selector(togglePause))
        pause.isEnabled = isRunning && selectedIsAnimated
        if let extras = extraMenuItemsProvider?(), !extras.isEmpty {
            menu.addItem(.separator())
            extras.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        addItem(menu, "Settings…", #selector(showAppSettings))
        addItem(menu, "Quit Idlesse", #selector(quit))
        menu.autoenablesItems = false
        statusItem?.menu = menu
        onStateChange?()
    }

    @objc private func openLibrary() { onShowLibrary?() }
    @objc private func showAppSettings() { onShowSettings?() }
    @objc private func showDisplayAssignments() { displayAssignmentController.present() }
    @objc private func toggleSound() { soundEnabled.toggle() }
    @objc private func toggleSameDisplays() { sameWallpaperOnAllDisplays.toggle() }

    @discardableResult private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(togglePause) {
            item.title = pausedByUser ? "Resume Scene" : "Pause Scene"
            return isRunning && selectedIsAnimated
        }
        if item.action == #selector(stop) { return isRunning || isLoading }
        return true
    }

    @objc private func showPreview() { onShowPreview?() }
    @objc private func toggleAudio() {
        guard let playable, playable.usesAudio, !isLoading else { return }
        clock.audioEnabled.toggle()
        surfaces.forEach { _ = $0.updateScene(playable) }
        updateMenu()
    }
    @objc private func togglePointer() {
        guard let playable, !isLoading else { return }
        clock.pointerEnabled.toggle()
        surfaces.forEach { _ = $0.updateScene(playable) }
        updateMenu()
    }
    var currentSceneTitle: String? {
        selectedURL?.pathExtension.lowercased() == "idlesse" ? playable?.title : nil
    }
    var canPausePlayback: Bool { isRunning && selectedIsAnimated }
    var hasSceneControls: Bool { playable?.parameters.isEmpty == false && !isLoading }
    var hasVideoContent: Bool { playable?.allNodes.contains { $0.kind == .video } == true }
    @objc func editControls() {
        guard let original = playable, !isLoading else { return }
        SceneParameterControls.present(scene: original, window: nil) { [weak self] parameters in
            guard let self, self.playable?.parameters == original.parameters, !self.isLoading,
                  self.playable?.allNodes.map(\.id) == original.allNodes.map(\.id) else { return }
            var next = original
            next.parameters = parameters
            do { _ = try next.evaluated() } catch { self.showError(error.localizedDescription); return }
            for surface in self.surfaces {
                guard surface.updateScene(next) else {
                    self.surfaces.forEach { _ = $0.updateScene(original) }
                    self.showError("The scene controls could not be applied. The previous values were restored.")
                    return
                }
            }
            self.playable = next
            self.updateMenu()
        }
    }
    @objc private func quit() { onStop = nil; stop(); NSApp.terminate(nil) }

    private func showError(_ message: String) {
        if let onError { onError(message); return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t start that wallpaper"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    deinit {
        coverageTimer?.invalidate()
        backdropTask?.cancel()
        loadTask?.cancel()
        screenRefresh?.cancel()
        observers.forEach { $0.0.removeObserver($0.1) }
        releaseSurfaces()
        if scopeStarted { selectedURL?.stopAccessingSecurityScopedResource() }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}


/// Opt-in experiment: a narrow GPU copy, never a second decoder or a disk snapshot loop.
/// macOS may composite an opaque menu background above this window; do not enable by default.
private final class MenuStripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class MenuBarStrip {
    let window: NSPanel
    private let layer = CAMetalLayer()
    private let height: CGFloat
    private(set) var frames = 0
    let timing = MirrorPresentationTiming()
    var onDrawableCatchUp: (() -> Void)?
    private let acquisition = DispatchQueue(label: "Idlesse.MenuStrip.Drawable", qos: .userInteractive)
    // Accessed only on the main thread. At most one ready drawable and one request.
    private var readyDrawable: CAMetalDrawable?
    private var acquiring = false
    private var recovery = MirrorFrameRecovery()
    private func requestDrawable() {
        guard !acquiring, readyDrawable == nil else { return }
        acquiring = true
        acquisition.async { [weak self, layer] in
            let drawable = autoreleasepool { layer.nextDrawable() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.acquiring = false
                self.readyDrawable = drawable
                if self.recovery.drawableReady(available: drawable != nil) {
                    self.onDrawableCatchUp?()
                }
            }
        }
    }
    init(screen: NSScreen) {
        height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
            width: screen.frame.width, height: height)
        window = MenuStripPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        window.setFrame(frame, display: false)
        window.isReleasedWhenClosed = false
        window.title = "Idlesse Menu Strip Experiment"
        window.isOpaque = false
        window.backgroundColor = .clear
        layer.opacity = 0
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = false
        // The narrow strip can still have a drawable awaiting presentation when
        // the next copy arrives. A third slot avoids starving its asynchronous
        // acquisition without ever blocking the main wallpaper renderer.
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        view.layer = layer
        window.contentView = view
    }
    func copy(command: MTLCommandBuffer, source: CAMetalDrawable) {
        guard window.isVisible else { return }
        let texture = source.texture
        let scale = CGFloat(texture.width) / max(1, window.frame.width)
        let rows = min(texture.height, max(1, Int((height * scale).rounded())))
        let size = CGSize(width: texture.width, height: rows)
        if layer.device == nil { layer.device = texture.device }
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let target = readyDrawable else { timing.recordMiss(); recovery.missedCopy(); requestDrawable(); return }
        readyDrawable = nil
        guard target.texture.width == texture.width, target.texture.height == rows,
              let blit = command.makeBlitCommandEncoder() else { recovery.missedCopy(); requestDrawable(); return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: rows, depth: 1),
            to: target.texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let pair = timing.makePair()
        source.addPresentedHandler { drawable in pair.record(source: true, time: drawable.presentedTime) }
        target.addPresentedHandler { drawable in pair.record(source: false, time: drawable.presentedTime) }
        command.addCompletedHandler { [weak self] command in
            guard command.status == .completed else { return }
            DispatchQueue.main.async { [weak self] in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.layer.opacity = 1
                CATransaction.commit()
            }
        }
        command.present(target)
        frames += 1
        requestDrawable()
    }
}
