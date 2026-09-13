import AppKit
import AVFoundation
import MetalKit

enum WallpaperSmoke {
    static func run(videoURL: URL) throws {
        // This suite inspects Standard's child views; do not let the user's
        // animated menu preference select Metal for those structural checks.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var testArguments = arguments
        testArguments["comfort.liveMenuStrip"] = false
        UserDefaults.standard.setVolatileDomain(testArguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let sourceDuration = AVURLAsset(url: videoURL).duration.seconds
        guard sourceDuration.isFinite, sourceDuration >= 1 else {
            throw SceneError.invalid("Wallpaper smoke tests need a moving video at least one second long.")
        }

        let overnight = DimSchedule(start: 22 * 60, end: 7 * 60)
        precondition(overnight.contains(minute: 22 * 60) && overnight.contains(minute: 0))
        precondition(overnight.contains(minute: 7 * 60 - 1) && !overnight.contains(minute: 7 * 60))
        precondition(!overnight.contains(minute: 12 * 60))
        let daytime = DimSchedule(start: 9 * 60, end: 17 * 60)
        precondition(daytime.contains(minute: 9 * 60) && !daytime.contains(minute: 17 * 60))
        precondition(!DimSchedule(start: 10, end: 10).contains(minute: 10))
        precondition(!DimSchedule(start: -1, end: 10).contains(minute: 0))
        // Focal crop: a 16:9 source on a 16:10 display overflows horizontally, and
        // where that overflow is spent is the whole point of a focus.
        let wide = CGSize(width: 3840, height: 2160)
        let display = CGRect(x: 0, y: 0, width: 2880, height: 1864)
        let overflow = (display.height / wide.height) * wide.width - display.width
        precondition(overflow > 0, "16:9 content should overflow a 16:10 display horizontally")
        let centred = SceneFocus.centre.filledFrame(content: wide, in: display)
        precondition(abs(centred.minX + overflow / 2) < 0.01, "centre should split the overflow evenly")
        precondition(abs(centred.height - display.height) < 0.01, "the bound axis should match exactly")
        let leftward = SceneFocus(x: 0, y: 0.5).filledFrame(content: wide, in: display)
        precondition(abs(leftward.minX) < 0.01, "focus at the left edge keeps the left of the source")
        let rightward = SceneFocus(x: 1, y: 0.5).filledFrame(content: wide, in: display)
        precondition(abs(rightward.minX + overflow) < 0.01, "focus at the right edge keeps the right of the source")
        // Hina's bleed sits on the right, so biasing left must not crop further right.
        precondition(leftward.maxX > display.maxX, "biasing left still covers the display")
        precondition(rightward.minX < display.minX, "biasing right still covers the display")
        // Out-of-range authoring is clamped, not honoured and not rejected.
        precondition(SceneFocus(x: -3, y: 9).filledFrame(content: wide, in: display) == leftward.offsetBy(dx: 0, dy: 0),
            "a focus outside the frame clamps to the edge")
        // A focus never changes the scale, only the offset: same size either way.
        precondition(abs(leftward.width - centred.width) < 0.01 && abs(rightward.width - centred.width) < 0.01)
        // Degenerate input renders centred rather than collapsing.
        precondition(SceneFocus.centre.filledFrame(content: .zero, in: display) == display)
        // A taller-than-display source spends its overflow vertically instead.
        let tall = SceneFocus(x: 0.5, y: 0).filledFrame(content: CGSize(width: 1000, height: 4000), in: display)
        precondition(abs(tall.maxY - display.maxY) < 0.01, "focus at the top keeps the top of the source")
        // Round-trip, because SceneDescriptor codes through explicit CodingKeys: a
        // field added to the struct alone is silently dropped on both encode and
        // decode, which is how this shipped unreachable the first time.
        let focused = SceneDescriptor(title: "focus", nodes: [SceneNode(content: .gradient)], focus: SceneFocus(x: 0.25, y: 0.75))
        let reread = try JSONDecoder().decode(SceneDescriptor.self, from: JSONEncoder().encode(focused))
        precondition(reread.focus == SceneFocus(x: 0.25, y: 0.75), "focus must survive an encode/decode round-trip")
        let unfocused = try JSONDecoder().decode(SceneDescriptor.self,
            from: JSONEncoder().encode(SceneDescriptor(title: "plain", nodes: [SceneNode(content: .gradient)])))
        precondition(unfocused.focus == nil, "absent focus must stay absent rather than defaulting to a centre")
        // Transforms rebuild the descriptor field by field, so each one can drop it.
        precondition(focused.replacingNodes(focused.nodes).focus == SceneFocus(x: 0.25, y: 0.75),
            "replacingNodes must carry focus forward")

        // Bleed, on the two displays this was built for. Hina's margin is on the
        // right: the 16:9 panel crops nothing by itself and must be made to, while
        // the 1.545 panel already crops 13% and must be left exactly as it was.
        let margin = SceneBleed(right: 0.05)
        let wideBleed = SceneFocus.centre.filledFrame(content: wide, in: display, bleed: margin)
        let wideNone = SceneFocus.centre.filledFrame(content: wide, in: display)
        precondition(abs(wideBleed.width - wideNone.width) < 0.01,
            "a narrow display already crops past the margin, so bleed must not rescale it")
        precondition(abs(wideBleed.minX - wideNone.minX) < 0.01,
            "nor reposition it: its natural crop already excludes the margin")

        let matching = CGRect(x: 0, y: 0, width: 3840, height: 2160)   // 16:9 panel, 16:9 source
        let exact = SceneFocus.centre.filledFrame(content: wide, in: matching)
        precondition(abs(exact.width - matching.width) < 0.01, "matching aspects fill exactly, cropping nothing")
        let cropped = SceneFocus.centre.filledFrame(content: wide, in: matching, bleed: margin)
        precondition(cropped.width > matching.width + 1, "bleed must force a crop where the fill would not")
        precondition(abs(cropped.minX) < 0.01, "and push it all to the margin's side, not split it")
        let marginEdge = cropped.minX + cropped.width * (1 - 0.05)
        precondition(marginEdge >= matching.maxX - 0.01, "the margin must end up off screen")
        // Bleed on both sides has to split, since neither side can be favoured.
        let both = SceneFocus.centre.filledFrame(content: wide, in: matching, bleed: SceneBleed(left: 0.04, right: 0.04))
        precondition(abs(both.minX + (both.width - matching.width) / 2) < 0.01, "symmetric margin crops symmetrically")
        // Same round-trip trap as focus: explicit CodingKeys drop unknown fields.
        let bled = SceneDescriptor(title: "bleed", nodes: [SceneNode(content: .gradient)], bleed: margin)
        let bledBack = try JSONDecoder().decode(SceneDescriptor.self, from: JSONEncoder().encode(bled))
        precondition(bledBack.bleed == margin, "bleed must survive an encode/decode round-trip")
        precondition(bled.replacingNodes(bled.nodes).bleed == margin, "replacingNodes must carry bleed forward")
        precondition(SceneBleed(right: 9).clamped.right <= 0.45, "a margin cannot exceed the frame")

        // Framing sidecar: the only way a plain imported file can carry either,
        // since the Library keeps a bookmark rather than a scene.
        let framingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("idlesse-framing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: framingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: framingDir) }
        let media = framingDir.appendingPathComponent("clip.mp4")
        try Data().write(to: media)
        let absent = try SceneFraming.beside(media)
        precondition(absent == nil, "no sidecar is not an error")
        try #"{"bleed":{"right":0.052},"focus":{"x":0.25,"y":0.5}}"#
            .data(using: .utf8)!.write(to: SceneFraming.url(for: media))
        let read = try SceneFraming.beside(media)
        precondition(read?.bleed == SceneBleed(right: 0.052), "sidecar bleed must load")
        precondition(read?.focus == SceneFocus(x: 0.25, y: 0.5), "sidecar focus must load")
        // Tone rides in the same sidecar, alongside framing rather than instead of it.
        try #"{"bleed":{"right":0.052},"tone":{"soften":0.35}}"#
            .data(using: .utf8)!.write(to: SceneFraming.url(for: media))
        let toned = try SceneFraming.beside(media)
        precondition(toned?.bleed == SceneBleed(right: 0.052) && toned?.tone == SceneTone(soften: 0.35),
            "tone must load without displacing framing")
        precondition(SceneTone.beside(media)?.soften == 0.35, "the renderer's read must find it")
        precondition(SceneTone(soften: 4).clamped.soften == 1 && SceneTone(soften: -1).clamped.soften == 0
            && SceneTone(soften: .nan).clamped.soften == 0, "soften stays within 0...1")
        let curve = SceneTone(soften: 1).curve
        precondition(curve[0] == .zero && curve[1] == CGPoint(x: 0.25, y: 0.25),
            "shadows are left alone")
        precondition(abs(curve[4].y - 0.82) < 1e-9, "full softening lowers the peak to 0.82")
        try #"{"tone":{"soften":0}}"#.data(using: .utf8)!.write(to: SceneFraming.url(for: media))
        precondition(SceneTone.beside(media) == nil, "a neutral tone builds no composition")
        try "not json at all".data(using: .utf8)!.write(to: SceneFraming.url(for: media))
        precondition((try? SceneFraming.beside(media)) == nil,
            "a malformed sidecar must fail rather than pretend to a framing")

        var viewport = TimelineViewport()
        viewport.resize(to: 10)
        precondition(viewport.start == 0 && viewport.span == 10)
        viewport.zoom(0.5, around: 5)
        precondition(viewport.start == 2.5 && viewport.span == 5)
        viewport.pan(10)
        precondition(viewport.start == 5)
        viewport.pan(-10)
        precondition(viewport.start == 0)
        viewport.resize(to: 2)
        precondition(viewport.start == 0 && viewport.span == 2)
        viewport.resize(to: 0.01)
        viewport.zoom(0.5, around: 0)
        precondition(viewport.span == 0.01 && viewport.start == 0)
        viewport.resize(to: 10)
        for _ in 0..<20 { viewport.zoom(0.5, around: 5) }
        precondition(viewport.span == 0.1 && viewport.start >= 0 && viewport.start + viewport.span <= 10)
        viewport.fit()
        precondition(viewport.start == 0 && viewport.span == 10)
        let document = SceneDocument()
        var allowUndo = true
        document.prepareRestore = { _ in allowUndo }
        for index in 1...40 {
            let before = SceneDocument.Snapshot(scene: document.scene, selected: 0, draft: document.draft)
            document.scene = SceneDescriptor(title: "Edit \(index)", nodes: [SceneNode(content: .gradient)])
            document.draft = true
            document.record(before, name: "Move Layer")
        }
        precondition(document.undoTargets.count == 32 && document.undoManager.undoActionName == "Move Layer")
        allowUndo = false
        document.undoManager.undo()
        precondition(document.scene.title == "Edit 40" && document.undoTargets.count == 32 && !document.undoManager.canRedo)
        allowUndo = true
        for _ in 0..<32 { document.undoManager.undo() }
        precondition(document.scene.title == "Edit 8" && !document.undoManager.canUndo)
        for _ in 0..<32 { document.undoManager.redo() }
        precondition(document.scene.title == "Edit 40" && !document.undoManager.canRedo)
        document.undoManager.undo()
        let branch = SceneDocument.Snapshot(scene: document.scene, selected: 0, draft: true)
        document.scene = SceneDescriptor(title: "Branch", nodes: [SceneNode(content: .gradient)])
        document.record(branch, name: "Rename Layer")
        precondition(!document.undoManager.canRedo && document.redoTargets.isEmpty)
        StudioWindowController.smokeTestResetRecovery()
        SceneDragOverlay.smokeTestNestedGeometry()
        let counter = PresentedFrameCounter()
        counter.record(presentedTime: 0)
        counter.record(presentedTime: .nan)
        precondition(counter.total == 0)
        counter.record(presentedTime: 1)
        precondition(counter.total == 1)
        counter.recordGPU(start: 0, end: 2)
        counter.recordGPU(start: 2, end: 1)
        precondition(counter.gpuTotals.frames == 0)
        counter.recordGPU(start: 1, end: 1.002)
        precondition(counter.gpuTotals.frames == 1)
        precondition(abs(counter.gpuTotals.seconds - 0.002) < 0.000001)
        var rateSample = PresentationRateSample()
        precondition(rateSample.sample(count: 0, time: 10) == nil)
        precondition(rateSample.sample(count: 160, time: 11) == 160)
        precondition(rateSample.sample(count: 160, time: 12) == 0)
        precondition(rateSample.sample(count: 0, time: 13) == nil)
        precondition(SceneFrameRate.matchDisplay.requested(maximum: 160) == 160)
        precondition(SceneFrameRate.matchDisplay.requested(maximum: 240) == 240)
        precondition(SceneFrameRate.fps160.requested(maximum: 60) == 60)
        precondition(SceneFrameRate.fps120.requested(maximum: 160) == 120)
        precondition(SceneFrameRate.automatic.requested(maximum: 160) == nil)
        guard !NSScreen.screens.isEmpty else { fatalError("Wallpaper tests need a logged-in display session") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("idlesse-wallpaper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("test.png")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<32 {
            for x in 0..<32 {
                let offset = y * image.bytesPerRow + x * 4
                image.bitmapData![offset] = 26
                image.bitmapData![offset + 1] = 179
                image.bitmapData![offset + 2] = 153
                image.bitmapData![offset + 3] = 255
            }
        }
        try image.representation(using: .png, properties: [:])!.write(to: imageURL)
        try compositionChecks(imageURL: imageURL)
        try WallpaperController.smokeTransitions(imageURL: imageURL)
        try animatedImageChecks(folder: folder)
        coverageChecks()
        let controller = WallpaperController()
        let assignmentSuite = "Idlesse.WallpaperSmoke." + UUID().uuidString
        controller.resumeDefaults = UserDefaults(suiteName: assignmentSuite)!
        defer { controller.resumeDefaults.removePersistentDomain(forName: assignmentSuite) }
        controller.presentsWindows = false
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        func wait(timeout: TimeInterval = 15, line: UInt = #line, until condition: () -> Bool) {
            let end = Date(timeIntervalSinceNow: timeout)
            while !condition() && Date() < end {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
            }
            precondition(condition(), "Timed out waiting for wallpaper state at line \(line); errors: \(errors)")
        }
        controller.select(imageURL)
        wait { controller.isRunning || !errors.isEmpty }
        precondition(errors.isEmpty)
        precondition(controller.surfaces.count == NSScreen.screens.count)
        for surface in controller.surfaces {
            precondition(!surface.window.canBecomeKey && !surface.window.canBecomeMain)
            precondition(surface.window.ignoresMouseEvents)
            precondition(surface.diagnostics.activeResources == 1 && !surface.diagnostics.animated)
            precondition(surface.window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        }
        controller.setAsleep(true)
        precondition(controller.surfaces.isEmpty && controller.isRunning)
        controller.setSystemAsleep(true)
        controller.setAsleep(false)
        precondition(controller.surfaces.isEmpty, "Display wake cannot override system sleep")
        controller.setSystemAsleep(false)
        precondition(controller.surfaces.count == NSScreen.screens.count)
        controller.setSessionInactive(true)
        precondition(controller.surfaces.isEmpty)
        controller.setSessionInactive(false)
        precondition(!controller.surfaces.isEmpty)

        let suite = "idlesse.async-saver-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = IdlessePreferences(defaults: defaults)
        try preferences.saveFolder(folder)
        let saver = IdlesseView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), preferences: preferences)
        saver.startAnimation()
        wait { saver.retainedImageCount == 1 }
        saver.stopAnimation()
        precondition(saver.retainedImageCount == 0)
        saver.startAnimation()
        saver.stopAnimation()
        let stoppedEnd = Date(timeIntervalSinceNow: 0.3)
        while Date() < stoppedEnd { _ = RunLoop.current.run(mode: .default, before: stoppedEnd) }
        precondition(saver.retainedImageCount == 0, "Cancelled preparation must not repopulate a stopped saver")

        let broken = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        controller.select(broken)
        wait { !errors.isEmpty }
        precondition(controller.selectedURL == imageURL && !controller.surfaces.isEmpty,
                     "A failed replacement must preserve the existing wallpaper")
        errors.removeAll()

        // Exercise the package path through the same production host.
        let package = folder.appendingPathComponent("Test.idlesse")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: videoURL, to: package.appendingPathComponent("assets/loop.mp4"))
        try Data(#"{"version":1,"title":"Test scene","capabilities":[]}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"))
        controller.select(package)
        wait { !controller.isLoading }
        precondition(errors.isEmpty && controller.selectedURL == package && controller.surfaces.first?.diagnostics.animated == true)
        controller.setAsleep(true)
        controller.setAsleep(false)
        precondition(controller.surfaces.first?.diagnostics.animated == true, "Package must survive display sleep")

        try FileManager.default.copyItem(at: imageURL, to: package.appendingPathComponent("assets/overlay.png"))
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"},{"type":"image","asset":"assets/overlay.png","opacity":0.25}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"))
        controller.select(package)
        wait { !controller.isLoading }
        precondition(errors.isEmpty)
        precondition(controller.surfaces[0].diagnostics.activeResources == 2,
                     "The video and overlay must both be present in the compositor")
        controller.togglePause()
        precondition(controller.surfaces[0].diagnostics.state == .paused)
        controller.togglePause()

        // A real filesystem event must apply an atomic edit without resetting pause.
        controller.togglePause()
        let beforeRevision = controller.revision
        let beforeTime = controller.sceneTime
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"},{"type":"image","asset":"assets/overlay.png","opacity":0.6}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"), options: .atomic)
        wait { controller.revision > beforeRevision }
        precondition(controller.pausedByUser && controller.sceneTime == beforeTime)
        precondition(controller.surfaces[0].diagnostics.state == .paused)
        precondition(controller.surfaces[0].sceneDescriptor.allNodes[1].opacity == 0.6, "Live edits must reach the running scene")
        let goodRevision = controller.revision
        try Data("unfinished edit".utf8).write(to: package.appendingPathComponent("scene.json"), options: .atomic)
        wait { controller.lastReloadError != nil }
        precondition(controller.revision == goodRevision && !controller.surfaces.isEmpty)
        try Data(#"{"layers":[{"type":"video","asset":"assets/loop.mp4"}]}"#.utf8)
            .write(to: package.appendingPathComponent("scene.json"), options: .atomic)
        wait { controller.revision > goodRevision }
        precondition(controller.lastReloadError == nil && controller.pausedByUser)

        let span = SceneDescriptor(title: "Span", nodes: [SceneNode(content: .gradient)], canvas: .desktopSpan)
        let spanClock = SceneClock()
        let spanRenderer = try MetalSceneRenderer(playable: span, bounds: CGRect(x: 0, y: 0, width: 128, height: 64), scale: 1, clock: spanClock) { errors.append($0) }
        spanRenderer.desktopFrame = CGRect(x: -64, y: 0, width: 128, height: 64)
        spanRenderer.displayFrame = spanRenderer.desktopFrame
        let whole = try spanRenderer.renderFrame(width: 128, height: 64)
        spanRenderer.displayFrame = CGRect(x: -64, y: 0, width: 64, height: 64)
        let spanLeft = try spanRenderer.renderFrame(width: 64, height: 64)
        spanRenderer.displayFrame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let spanRight = try spanRenderer.renderFrame(width: 64, height: 64)
        for y in 0..<64 {
            for x in 0..<128 {
                let half = x < 64 ? spanLeft : spanRight
                for c in 0..<4 {
                    precondition(abs(Int(whole[(y * 128 + x) * 4 + c]) - Int(half[(y * 64 + x % 64) * 4 + c])) <= 1, "Desktop viewports must reconstruct one continuous scene")
                }
            }
        }
        spanRenderer.releaseResources()
        precondition(span.replacingNodes(span.nodes).canvas == .desktopSpan)
        let evaluatedSpan = try span.evaluated(); precondition(evaluatedSpan.canvas == .desktopSpan)

        var instant = 0.0
        let sceneClock = SceneClock(now: { instant })
        sceneClock.setPaused(false)
        let gradient = try GradientRenderer(bounds: NSRect(x: 0, y: 0, width: 32, height: 32), clock: sceneClock) { errors.append($0) }
        gradient.setPreferredFrameRate(160)
        precondition((gradient.view as? MTKView)?.preferredFramesPerSecond == 160)
        gradient.setPreferredFrameRate(nil)
        precondition((gradient.view as? MTKView)?.preferredFramesPerSecond == 30)
        let frame = try gradient.renderProbe()
        precondition(Set(frame).count > 16 && stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 255 })
        instant = 10
        let laterFrame = try gradient.renderProbe()
        precondition(laterFrame != frame, "Scene time must animate actual GPU output")
        gradient.setPaused(true)
        precondition(gradient.diagnostics.state == .paused)
        gradient.releaseResources()
        precondition(gradient.diagnostics.activeResources == 0)

        let checkerURL = folder.appendingPathComponent("checker.png")
        let checker = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<32 { for x in 0..<32 {
            let offset = y * checker.bytesPerRow + x * 4
            let value: UInt8 = ((x / 4 + y / 4) % 2 == 0) ? 240 : 20
            for channel in 0..<3 { checker.bitmapData![offset + channel] = value }
            checker.bitmapData![offset + 3] = 255
        } }
        try checker.representation(using: .png, properties: [:])!.write(to: checkerURL)
        let rippleClock = SceneClock(now: { 0 })
        var rippleNode = SceneNode(content: .image(checkerURL))
        rippleNode.style.effects = [.init(type: .displacement, amount: 0.06)]
        let ripple = try MetalSceneRenderer(playable: SceneDescriptor(title: "Ripple", nodes: [rippleNode]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: rippleClock) { errors.append($0) }
        precondition(ripple.diagnostics.animated)
        try rippleClock.seek(to: 1)
        let rippleA = try ripple.renderProbe()
        try rippleClock.seek(to: 3)
        let rippleB = try ripple.renderProbe()
        try rippleClock.seek(to: 1)
        let rippleAgain = try ripple.renderProbe()
        precondition(rippleA != rippleB && rippleA == rippleAgain, "Displacement must animate static pixels and seek deterministically")
        rippleNode.style.effects[0].amount = 0
        precondition(ripple.updateScene(SceneDescriptor(title: "Still", nodes: [rippleNode])) && !ripple.diagnostics.animated)
        let stillA = try ripple.renderProbe()
        try rippleClock.seek(to: 5)
        let stillB = try ripple.renderProbe()
        precondition(stillA == stillB && stillA != rippleA)
        ripple.releaseResources()
        let particleClock = SceneClock(now: { 0 })
        var particleNode = SceneNode(content: .particles(.init(size: 0.04)))
        particleNode.style.effects = [.init(type: .bloom, amount: 0.7)]
        let particles = try MetalSceneRenderer(playable: SceneDescriptor(title: "Particles", nodes: [particleNode]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: particleClock) { errors.append($0) }
        try particleClock.seek(to: 1.25)
        let particlesA = try particles.renderProbe()
        try particleClock.seek(to: 4.75)
        let particlesB = try particles.renderProbe()
        try particleClock.seek(to: 1.25)
        let particlesAgain = try particles.renderProbe()
        precondition(particlesA != particlesB && particlesA == particlesAgain, "Particles must be deterministic when seeking")
        try particleClock.seek(to: 7.25)
        let loopedParticles = try particles.renderProbe(); precondition(loopedParticles == particlesA, "A particle lifetime must repeat exactly")
        let particleSizeTarget = ScenePropertyAddress(nodeID: particleNode.id, property: .particleSize)
        let reactiveParticles = SceneDescriptor(title: "Reactive particles", nodes: [particleNode], bindings: [
            .init(target: particleSizeTarget, scale: 0.05, offset: 0.001, signal: .audioBass)
        ])
        precondition(particles.updateScene(reactiveParticles))
        let tinyParticles = try particles.renderProbe(signals: .init(audio: .init(bass: 0)))
        let bigParticles = try particles.renderProbe(signals: .init(audio: .init(bass: 1)))
        precondition(tinyParticles != bigParticles)
        particles.releaseResources()
        wait { particles.intermediateTextureBytes == 0 }
        precondition(particles.intermediateTextureBytes == 0)
        let shaderClock = SceneClock(now: { 0 })
        var shaderNode = SceneNode(content: .shader(.init()))
        let waves = try MetalSceneRenderer(playable: SceneDescriptor(title: "Waves", nodes: [shaderNode]),
            bounds: NSRect(x: 0, y: 0, width: 64, height: 64), scale: 1, clock: shaderClock) { errors.append($0) }
        defer { waves.releaseResources() }
        let wavePixels = try waves.renderProbe()
        let lit = stride(from: 0, to: wavePixels.count, by: 4).filter { wavePixels[$0] > 8 || wavePixels[$0 + 1] > 8 || wavePixels[$0 + 2] > 8 }.count
        precondition(lit > 100, "A shader layer must paint procedural pixels")
        for preset in SceneNode.Shader.studioPresets {
            try MetalShaderCompiler.validate(.init(source: preset.source, speed: preset.speed))
        }
        let parsedDiagnostic = MetalShaderCompiler.parseDiagnostics("StudioShader:7:4: error: expected expression")
        precondition(parsedDiagnostic.first?.line == 7 && parsedDiagnostic.first?.column == 4)
        let brokenSource = """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float3 color = float3(1.0);
            return float4(color broken_token, u.opacity);
        }
        """
        do {
            _ = try MetalSceneRenderer(playable: SceneDescriptor(title: "Broken", nodes: [SceneNode(content: .shader(.init(source: brokenSource, speed: 1)))]),
                bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: shaderClock) { errors.append($0) }
            preconditionFailure("Invalid shader source must fail surface preparation")
        } catch let failure as MetalShaderCompilationError {
            precondition(failure.diagnostics.contains(where: { $0.line != nil }), "Metal diagnostics should report a user-source line")
        }
        let lastValid = try waves.renderProbe()
        var invalidNode = shaderNode
        invalidNode.content = .shader(.init(source: brokenSource, speed: 1))
        precondition(!waves.updateScene(SceneDescriptor(title: "Broken edit", nodes: [invalidNode])))
        let afterRejectedShader = try waves.renderProbe()
        precondition(afterRejectedShader == lastValid, "A rejected source edit must preserve the last valid shader")
        try shaderClock.seek(to: 1)
        let normalSpeed = try waves.renderProbe()
        shaderNode.content = .shader(.init(source: SceneNode.Shader.plasma, speed: 2))
        precondition(waves.updateScene(SceneDescriptor(title: "Faster", nodes: [shaderNode])))
        let doubleSpeed = try waves.renderProbe()
        precondition(normalSpeed != doubleSpeed, "Shader speed edits must reach the working preview")
        print("Shader checks passed: templates compile, diagnostics map lines, failed source preserves preview, speed edits render")
        let sixteenImages = SceneDescriptor(title: "Sixteen", nodes: (0..<16).map { _ in SceneNode(content: .image(imageURL), opacity: 0.2) })
        let audioNode = SceneNode(content: .gradient)
        let audioScene = SceneDescriptor(title: "Audio", nodes: [audioNode], bindings: [
            .init(target: .init(nodeID: audioNode.id, property: .opacity), scale: 1, offset: 0.1, signal: .audioLevel)
        ])
        let audioRenderer = try MetalSceneRenderer(playable: audioScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let quietAudioPixels = try audioRenderer.renderProbe(signals: .init(audio: .init(level: 0)))
        let loudAudioPixels = try audioRenderer.renderProbe(signals: .init(audio: .init(level: 0.8)))
        precondition(quietAudioPixels != loudAudioPixels, "Audio levels must affect Metal output")
        audioRenderer.releaseResources()
        var effectNode = SceneNode(content: .gradient)
        effectNode.style.effects = [.init(type: .exposure, amount: 1), .init(type: .bloom, amount: 1)]
        let effectRenderer = try MetalSceneRenderer(playable: SceneDescriptor(title: "Effects", nodes: [effectNode]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let bloomAddress = ScenePropertyAddress(nodeID: effectNode.id, property: .effectAmount, effectID: effectNode.style.effects[1].id)
        let reactiveGlow = SceneDescriptor(title: "Reactive glow", nodes: [effectNode], bindings: [
            .init(target: bloomAddress, scale: 10, signal: .audioBass)
        ])
        precondition(effectRenderer.updateScene(reactiveGlow))
        let silentGlow = try effectRenderer.renderProbe(signals: .init(audio: .init(bass: 0)))
        let loudGlow = try effectRenderer.renderProbe(signals: .init(audio: .init(bass: 0.2)))
        precondition(silentGlow != loudGlow, "Audio must modulate the actual bloom pass")
        precondition(effectRenderer.updateScene(SceneDescriptor(title: "Effects", nodes: [effectNode])))
        let glowPixels = try effectRenderer.renderProbe()
        effectNode.style.effects.reverse()
        precondition(effectRenderer.updateScene(SceneDescriptor(title: "Reordered", nodes: [effectNode])))
        let reorderedPixels = try effectRenderer.renderProbe()
        precondition(glowPixels != reorderedPixels, "Effect order must change GPU output")
        effectNode.style.effects = [.init(type: .blur, amount: 24)]
        precondition(effectRenderer.updateScene(SceneDescriptor(title: "Blur", nodes: [effectNode])))
        let blurredPixels = try effectRenderer.renderProbe()
        effectNode.style.effects = []
        precondition(effectRenderer.updateScene(SceneDescriptor(title: "Plain", nodes: [effectNode])))
        let plainPixels = try effectRenderer.renderProbe()
        precondition(blurredPixels != plainPixels, "Blur must change GPU output")
        effectRenderer.releaseResources()
        let manyStandard = try LayeredSceneRenderer(playable: sixteenImages,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        precondition(manyStandard.view.subviews.count == 16)
        precondition(manyStandard.updateScene(SceneDescriptor(title: "Reordered", nodes: sixteenImages.nodes.reversed())))
        manyStandard.releaseResources()
        let manyMetal = try MetalSceneRenderer(playable: sixteenImages,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let manyPixels = try manyMetal.renderProbe()
        precondition(Set(manyPixels).count > 1)
        precondition(manyMetal.updateScene(SceneDescriptor(title: "Reordered", nodes: sixteenImages.nodes.reversed())))
        let effectedImages = sixteenImages.nodes.map { original -> SceneNode in
            var node = original
            node.style.effects = [.init(type: .blur, amount: 8), .init(type: .bloom, amount: 0.5)]
            return node
        }
        precondition(manyMetal.updateScene(SceneDescriptor(title: "Sixteen effects", nodes: effectedImages)))
        _ = try manyMetal.renderProbe()
        precondition(manyMetal.intermediateTextureBytes > 0 && manyMetal.intermediateTextureBytes <= SceneBudget.intermediateTextureBytes)
        manyMetal.releaseResources()
        wait { manyMetal.intermediateTextureBytes == 0 }
        precondition(manyMetal.intermediateTextureBytes == 0)
        // Exercise the experimental compositor through real GPU readback.
        let metalImage = try MetalSceneRenderer(playable: SceneDescriptor(title: "image", nodes: [
            SceneNode(content: .image(imageURL), opacity: 0.5,
                transform: .init(x: 0.25, y: 0, scale: 0.5, rotation: 0))]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let imageFrame = try metalImage.renderProbe()
        precondition(imageFrame[0] == 0 && imageFrame[1] == 0, "Translated image must leave backdrop visible")
        let center = (16 * 32 + 24) * 4
        precondition(abs(Int(imageFrame[center]) - 77) <= 3 && abs(Int(imageFrame[center+1]) - 90) <= 3,
            "Image upload, translation, scale and premultiplied opacity must compose correctly")
        metalImage.releaseResources()
        try MetalSceneRenderer.smokeTestGroupTextureBudget()
        // Opaque overlapping children should still fade to 50%, not 75%.
        var groupNode = SceneNode(content: .group([SceneNode(content: .image(imageURL)), SceneNode(content: .image(imageURL))]), opacity: 0.5)
        let groupScene = SceneDescriptor(title: "Group", nodes: [groupNode])
        let groupedMetal = try MetalSceneRenderer(playable: groupScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let groupFrame = try groupedMetal.renderProbe()
        let groupCenter = (16 * 32 + 16) * 4
        precondition(abs(Int(groupFrame[groupCenter]) - 77) <= 3 && abs(Int(groupFrame[groupCenter + 1]) - 90) <= 3,
            "Group opacity must apply once to the composed subtree")
        let retainedGroupBytes = groupedMetal.intermediateTextureBytes
        precondition(retainedGroupBytes > 0 && retainedGroupBytes <= SceneBudget.intermediateTextureBytes)
        _ = try groupedMetal.renderProbe()
        precondition(groupedMetal.intermediateTextureBytes == retainedGroupBytes, "Group targets should be reused")
        groupNode.transform = .init(x: 0.25, y: 0, scale: 0.5, rotation: 0)
        precondition(groupedMetal.updateScene(SceneDescriptor(title: "Moved", nodes: [groupNode])))
        let groupMovedFrame = try groupedMetal.renderProbe()
        precondition(groupMovedFrame[0] == 0 && abs(Int(groupMovedFrame[center]) - 77) <= 3)
        groupNode.visible = false
        precondition(groupedMetal.updateScene(SceneDescriptor(title: "Hidden", nodes: [groupNode])))
        let groupHiddenFrame = try groupedMetal.renderProbe()
        precondition(stride(from: 0, to: groupHiddenFrame.count, by: 4).allSatisfy { groupHiddenFrame[$0] == 0 })
        groupNode.visible = true
        groupNode.transform = .identity
        groupNode.style = .init(mask: .ellipse, exposure: -1, saturation: 0)
        precondition(groupedMetal.updateScene(SceneDescriptor(title: "Styled", nodes: [groupNode])))
        let styledPixels = try groupedMetal.renderProbe()
        precondition(styledPixels[0] == 0 && styledPixels[1] == 0 && styledPixels[2] == 0, "Ellipse mask must clear corners")
        precondition(styledPixels[groupCenter] > 20 && styledPixels[groupCenter] < 60)
        precondition(abs(Int(styledPixels[groupCenter]) - Int(styledPixels[groupCenter + 1])) <= 1 &&
                     abs(Int(styledPixels[groupCenter]) - Int(styledPixels[groupCenter + 2])) <= 1, "Zero saturation should produce gray")
        precondition(groupedMetal.intermediateTextureBytes <= retainedGroupBytes * 2, "Color and mask use only the existing two-frame group target allowance")
        groupNode.style = .plain
        precondition(groupedMetal.updateScene(SceneDescriptor(title: "Plain", nodes: [groupNode])))
        let plainVignettePixels = try groupedMetal.renderProbe()
        let vignetteControl = SceneDescriptor(title: "Vignette", nodes: [groupNode],
            parameters: ["edges": .init(name: "Edges", value: 1, min: 0, max: 1)],
            bindings: [.init(target: .init(nodeID: groupNode.id, property: .vignette), parameter: "edges")])
        precondition(vignetteControl.requiresMetal && groupedMetal.updateScene(vignetteControl))
        let vignettePixels = try groupedMetal.renderProbe()
        precondition(abs(Int(vignettePixels[groupCenter]) - Int(plainVignettePixels[groupCenter])) <= 1,
                     "Vignette must leave the center unchanged")
        precondition(vignettePixels[0] < plainVignettePixels[0] / 4, "Vignette must darken corners")
        precondition(groupedMetal.intermediateTextureBytes <= retainedGroupBytes * 2,
                     "Vignette must not allocate additional group targets")
        let breathing = SceneDescriptor(title: "Breathing", nodes: [groupNode], bindings: [
            .init(target: .init(nodeID: groupNode.id, property: .vignette), scale: 0.5, offset: 0.5, signal: .sine, period: 4)])
        precondition(groupedMetal.updateScene(breathing) && groupedMetal.diagnostics.animated)
        let bright = try groupedMetal.renderProbe(signals: .init(time: 3))
        let dark = try groupedMetal.renderProbe(signals: .init(time: 1))
        precondition(dark[0] < bright[0] / 4, "Time signal must reach the actual compositor")
        groupedMetal.setPaused(true)
        sceneClock.setPaused(true)
        try sceneClock.seek(to: 3)
        groupedMetal.refreshSceneTime()
        let seekBright = try groupedMetal.renderProbe()
        try sceneClock.seek(to: 1)
        groupedMetal.refreshSceneTime()
        let seekDark = try groupedMetal.renderProbe()
        precondition(seekDark[0] < seekBright[0] / 4 && groupedMetal.diagnostics.state == .paused,
                     "Seeking must redraw motion while remaining paused")
        precondition(groupedMetal.updateScene(breathing))
        let editedPaused = try groupedMetal.renderProbe()
        precondition(abs(Int(editedPaused[0]) - Int(seekDark[0])) <= 1,
                     "Paused scene edits must retain the playhead position")
        sceneClock.setPaused(false)
        var modulated = breathing
        modulated.parameters["strength"] = .init(name: "Strength", value: 0, min: 0, max: 1)
        modulated.bindings[0].modifiers = [.init(operation: .multiply, parameter: "strength")]
        precondition(groupedMetal.updateScene(modulated))
        let disabledMotion = try groupedMetal.renderProbe(signals: .init(time: 1))
        precondition(abs(Int(disabledMotion[0]) - Int(bright[0])) <= 1)
        modulated.parameters["strength"]?.value = 1
        precondition(groupedMetal.updateScene(modulated))
        let enabledMotion = try groupedMetal.renderProbe(signals: .init(time: 1))
        precondition(abs(Int(enabledMotion[0]) - Int(dark[0])) <= 1,
                     "Driver control edits must reach the existing compositor")
        precondition(groupedMetal.intermediateTextureBytes <= retainedGroupBytes * 2)
        let reactive = SceneDescriptor(title: "Pointer", nodes: [groupNode], bindings: [
            .init(target: .init(nodeID: groupNode.id, property: .vignette), scale: 0.5, offset: 0.5, signal: .pointerX)])
        precondition(groupedMetal.updateScene(reactive) && !groupedMetal.diagnostics.animated)
        sceneClock.pointerEnabled = true
        precondition(groupedMetal.updateScene(reactive) && groupedMetal.diagnostics.animated)
        let left = try groupedMetal.renderProbe(signals: .init(pointerX: -1))
        let right = try groupedMetal.renderProbe(signals: .init(pointerX: 1))
        precondition(right[0] < left[0] / 4)
        sceneClock.pointerEnabled = false
        precondition(groupedMetal.updateScene(reactive) && !groupedMetal.diagnostics.animated)
        groupedMetal.releaseResources()
        // Live signal edits may leave a drawable in flight; disposal releases its
        // leased group targets when that command completes.
        wait { groupedMetal.intermediateTextureBytes == 0 }
        precondition(groupedMetal.intermediateTextureBytes == 0)
        let nestedGroup = SceneNode(content: .group([SceneNode(content: .group([
            SceneNode(content: .image(imageURL)), SceneNode(content: .image(imageURL))]), opacity: 0.5)]), opacity: 0.5)
        let nestedMetal = try MetalSceneRenderer(playable: SceneDescriptor(title: "Nested", nodes: [nestedGroup]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let nestedPixels = try nestedMetal.renderProbe()
        precondition(abs(Int(nestedPixels[groupCenter]) - 38) <= 3, "Nested isolated opacity should multiply once per group")
        nestedMetal.releaseResources()
        let metalScene = try MetalSceneRenderer(playable: SceneDescriptor(title: "mixed", nodes: [
            SceneNode(content: .gradient), SceneNode(content: .image(imageURL), opacity: 0.5)]),
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let mixedFrame = try metalScene.renderProbe()
        precondition(Set(mixedFrame).count > 16 && mixedFrame != imageFrame)
        instant = 20
        let changedMixedFrame = try metalScene.renderProbe()
        precondition(changedMixedFrame != mixedFrame)
        metalScene.releaseResources()
        var idleInstant = 0.0
        let idleClock = SceneClock(now: { idleInstant })
        try idleClock.configure(timeline: .init(duration: 1, mode: .once))
        idleClock.setPaused(false)
        let idleScene = SceneDescriptor(title: "Once", nodes: [SceneNode(content: .gradient)], timeline: .init(duration: 1, mode: .once))
        let idleRenderer = try MetalSceneRenderer(playable: idleScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: idleClock) { errors.append($0) }
        idleRenderer.setPaused(false)
        let idleView = idleRenderer.view as! MTKView
        precondition(!idleView.isPaused)
        idleInstant = 2
        idleRenderer.refreshSceneTime()
        precondition(idleView.isPaused, "Completed Once scene must stop timed draws")
        try idleClock.seek(to: 0)
        idleRenderer.refreshSceneTime()
        precondition(!idleView.isPaused, "Seeking back must restart timed draws")
        idleRenderer.releaseResources()
        let standardTransform = try LayeredSceneRenderer(playable: SceneDescriptor(title: "Centered", nodes: [
            SceneNode(content: .gradient, transform: .init(x: 0, y: 0, scale: 0.7, rotation: 0))]),
            bounds: NSRect(x: 0, y: 0, width: 100, height: 80), scale: 1, clock: sceneClock) { errors.append($0) }
        let transformHost = NSView(frame: standardTransform.view.frame)
        transformHost.addSubview(standardTransform.view)
        transformHost.layoutSubtreeIfNeeded()
        let layerTransform = standardTransform.view.subviews[0].layer!.sublayerTransform
        precondition(abs(layerTransform.m11 - 0.7) < 0.001)
        precondition(abs(layerTransform.m41 - 15) < 0.001 && abs(layerTransform.m42 - 12) < 0.001)
        standardTransform.releaseResources()
        let liveVideoScene = SceneDescriptor(title: "video", assetURL: videoURL, kind: .video)
        let standardLive = try LayeredSceneRenderer(playable: liveVideoScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let originalVideoView = standardLive.view.subviews[0].subviews[0]
        var editedVideo = liveVideoScene.nodes
        editedVideo[0].opacity = 0.4
        editedVideo[0].transform = .init(x: 0.1, y: 0, scale: 0.8, rotation: 10)
        precondition(standardLive.updateScene(SceneDescriptor(title: "edit", nodes: editedVideo)))
        precondition(standardLive.view.subviews[0].subviews[0] === originalVideoView)
        precondition(abs(originalVideoView.alphaValue - 0.4) < 0.001)
        editedVideo[0].visible = false
        precondition(standardLive.updateScene(SceneDescriptor(title: "hidden", nodes: editedVideo)))
        precondition(originalVideoView.alphaValue == 0)
        editedVideo[0].visible = true
        precondition(!standardLive.updateScene(SceneDescriptor(title: "replacement", nodes: [SceneNode(content: .gradient)])))
        standardLive.releaseResources()
        let metalVideo = try MetalSceneRenderer(playable: liveVideoScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        metalVideo.setPaused(false)
        var videoFrame: [UInt8] = []
        wait {
            videoFrame = (try? metalVideo.renderProbe()) ?? []
            return Set(videoFrame).count > 20
        }
        // A growing loop counter alone can hide a stale output on the next replica.
        // Require changing decoded pixels during three successive loop iterations.
        for iteration in 1...3 {
            wait { _ = try? metalVideo.renderProbe(); return metalVideo.diagnostics.loopCount >= iteration }
            let first = try metalVideo.renderProbe()
            wait {
                let next = (try? metalVideo.renderProbe()) ?? []
                return next != first && Set(next).count > 20
            }
        }
        let loopsBeforeEdit = metalVideo.diagnostics.loopCount
        precondition(metalVideo.updateScene(SceneDescriptor(title: "edit", nodes: editedVideo)))
        precondition(metalVideo.diagnostics.loopCount == loopsBeforeEdit)
        editedVideo[0].visible = false
        precondition(metalVideo.updateScene(SceneDescriptor(title: "hidden", nodes: editedVideo)))
        let hiddenPixels = try metalVideo.renderProbe()
        precondition(hiddenPixels.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 255 : $0.element == 0 })
        precondition(!metalVideo.diagnostics.animated)
        editedVideo[0].visible = true
        precondition(metalVideo.updateScene(SceneDescriptor(title: "shown", nodes: editedVideo)))
        wait { _ = try? metalVideo.renderProbe(); return metalVideo.diagnostics.loopCount > loopsBeforeEdit }
        metalVideo.setPaused(true)
        precondition(metalVideo.diagnostics.state == .paused)
        let pausedLoops = metalVideo.diagnostics.loopCount
        metalVideo.setPaused(false)
        wait { _ = try? metalVideo.renderProbe(); return metalVideo.diagnostics.loopCount > pausedLoops }
        precondition(errors.isEmpty)
        metalVideo.releaseResources()
        precondition(metalVideo.diagnostics.activeResources == 0)

        let followClock = SceneClock()
        var following = liveVideoScene
        following.timeline = .init(duration: max(2, sourceDuration + 1), mode: .loop, videosFollowScene: true)
        try followClock.configure(timeline: following.timeline)
        let followVideo = try MetalSceneRenderer(playable: following,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: followClock) { errors.append($0) }
        followVideo.setPaused(true)
        try followClock.seek(to: 0.2)
        var followPixels: [UInt8] = []
        wait {
            followPixels = (try? followVideo.renderProbe()) ?? []
            return abs((followVideo.videoTransportPositions.first ?? -1) - 0.2) < 0.01 && Set(followPixels).count > 20
        }
        let firstFollowPixels = followPixels
        try followClock.seek(to: 0.7)
        followVideo.refreshSceneTime()
        wait {
            followPixels = (try? followVideo.renderProbe()) ?? []
            return abs((followVideo.videoTransportPositions.first ?? -1) - 0.7) < 0.01 && followPixels != firstFollowPixels
        }
        try followClock.seek(to: 0.1)
        followVideo.refreshSceneTime()
        try followClock.seek(to: 1.8) // A newer seek wins; wrap using the actual source duration.
        followVideo.refreshSceneTime()
        wait {
            _ = try? followVideo.renderProbe()
            return abs((followVideo.videoTransportPositions.first ?? -1) - 1.8.truncatingRemainder(dividingBy: sourceDuration)) < 0.01
        }
        try followClock.configure(time: 0.2, rate: 0.5, loop: nil)
        followClock.setPaused(false)
        followVideo.setPaused(false)
        wait {
            _ = try? followVideo.renderProbe()
            let position = followVideo.videoTransportPositions.first ?? -1
            return position > 0.3 && abs(position - followClock.time) < 0.15
        }
        try followClock.seek(to: sourceDuration + 0.1)
        followVideo.refreshSceneTime()
        wait {
            _ = try? followVideo.renderProbe()
            let position = followVideo.videoTransportPositions.first ?? -1
            return followClock.time > sourceDuration && position >= 0 && position < 0.5
                && abs(position - followClock.time.truncatingRemainder(dividingBy: sourceDuration)) < 0.15
        }
        followClock.setPaused(true)
        followVideo.setPaused(true)
        precondition(followVideo.updateScene(following))
        followVideo.releaseResources()
        precondition(followVideo.diagnostics.activeResources == 0 && errors.isEmpty)

        var videoGroup = SceneNode(content: .group([SceneNode(content: .video(videoURL))]))
        let groupVideoScene = SceneDescriptor(title: "Grouped video", nodes: [videoGroup])
        let standardGroupVideo = try LayeredSceneRenderer(playable: groupVideoScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        let metalGroupVideo = try MetalSceneRenderer(playable: groupVideoScene,
            bounds: NSRect(x: 0, y: 0, width: 32, height: 32), scale: 1, clock: sceneClock) { errors.append($0) }
        standardGroupVideo.setPaused(false)
        metalGroupVideo.setPaused(false)
        wait { _ = try? metalGroupVideo.renderProbe(); return metalGroupVideo.diagnostics.loopCount >= 1 && standardGroupVideo.diagnostics.loopCount >= 1 }
        let groupVideoLoops = metalGroupVideo.diagnostics.loopCount
        let standardLoops = standardGroupVideo.diagnostics.loopCount
        let controlledVideo = SceneDescriptor(title: "Controlled video", nodes: [videoGroup],
            parameters: ["opacity": .init(name: "Opacity", value: 0.6, min: 0, max: 1)],
            bindings: [.init(target: .init(nodeID: videoGroup.id, property: .opacity), parameter: "opacity")])
        precondition(standardGroupVideo.updateScene(controlledVideo) && metalGroupVideo.updateScene(controlledVideo))
        precondition(standardGroupVideo.diagnostics.loopCount >= standardLoops && metalGroupVideo.diagnostics.loopCount >= groupVideoLoops)
        videoGroup.opacity = 0.4
        videoGroup.transform = .init(x: 0.1, y: 0, scale: 0.8, rotation: 10)
        let updatedGroupVideo = SceneDescriptor(title: "Moved video", nodes: [videoGroup])
        precondition(standardGroupVideo.updateScene(updatedGroupVideo) && metalGroupVideo.updateScene(updatedGroupVideo))
        precondition(metalGroupVideo.diagnostics.loopCount >= groupVideoLoops)
        videoGroup.visible = false
        let hiddenVideoGroup = SceneDescriptor(title: "Hidden video", nodes: [videoGroup])
        precondition(standardGroupVideo.updateScene(hiddenVideoGroup) && metalGroupVideo.updateScene(hiddenVideoGroup))
        precondition(!metalGroupVideo.diagnostics.animated && !standardGroupVideo.diagnostics.animated)
        videoGroup.visible = true
        precondition(metalGroupVideo.updateScene(SceneDescriptor(title: "Shown video", nodes: [videoGroup])))
        wait { _ = try? metalGroupVideo.renderProbe(); return metalGroupVideo.diagnostics.loopCount > groupVideoLoops }
        standardGroupVideo.releaseResources()
        metalGroupVideo.releaseResources()
        precondition(errors.isEmpty)

        try Data(#"{"version":99,"title":"Future scene","capabilities":[]}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        controller.select(package)
        wait { !controller.isLoading }
        precondition(!errors.isEmpty && controller.surfaces.first?.diagnostics.animated == true,
                     "Unsupported scene must preserve the current renderer")
        errors.removeAll()
        controller.stop()

        controller.select(videoURL)
        wait { controller.surfaces.first?.diagnostics.animated == true || !errors.isEmpty }
        precondition(errors.isEmpty)
        let surface = controller.surfaces[0]
        precondition(surface.diagnostics.audioMuted)
        precondition(surface.diagnostics.allowsDisplaySleep)
        surface.setPaused(false)
        wait(timeout: 60) { surface.diagnostics.loopCount >= 1 || !errors.isEmpty }
        precondition(errors.isEmpty)
        controller.togglePause()
        precondition(surface.diagnostics.state == .paused)
        controller.togglePause()
        let audible = VideoRenderer(url: videoURL, bounds: NSRect(x: 0, y: 0, width: 64, height: 64), onError: { errors.append($0) })
        defer { audible.releaseResources() }
        precondition(audible.diagnostics.audioMuted, "Video starts muted")
        audible.setPaused(false)
        audible.setMuted(false)
        precondition(!audible.diagnostics.audioMuted, "Sound toggle must reach the player")
        audible.setMuted(true)
        precondition(audible.diagnostics.audioMuted)
        controller.stop()
        precondition(controller.surfaces.isEmpty && !controller.isRunning)
        precondition(surface.diagnostics.activeResources == 0, "Stop must release the player, including externally retained surfaces")

        // A pending async selection cannot recreate windows after Stop.
        controller.select(videoURL)
        controller.stop()
        let end = Date(timeIntervalSinceNow: 0.5)
        while Date() < end { _ = RunLoop.current.run(mode: .default, before: end) }
        precondition(!controller.isRunning && controller.surfaces.isEmpty)
        precondition(errors.isEmpty)
        let styledPackage = folder.appendingPathComponent("styled.idlesse")
        try ScenePackageWriter.write(SceneDescriptor(title: "Styled image", nodes: [
            SceneNode(style: .init(mask: .ellipse), content: .image(imageURL))]), to: styledPackage)
        controller.select(styledPackage)
        wait { controller.isRunning || !errors.isEmpty }
        precondition(errors.isEmpty && controller.surfaces.allSatisfy { $0.window.contentView is MTKView },
            "Styled desktop scenes must choose Metal automatically")
        controller.stop()
        print("Wallpaper checks passed: async saver cancellation, image, two-layer scene package, hot reload, GPU gradient, isolated/nested groups, masks/color, automatic Metal selection and bounded target allocation, mixed compositor, grouped video live edits, Metal video decode/loop, unsupported version, video loop, click-through, sleep/session overlap, pause, stop, cancellation")
    }
    private static func animatedImageChecks(folder: URL) throws {
        // Two-frame GIF: red then blue, 0.05 s per frame.
        let gifURL = folder.appendingPathComponent("anim.gif")
        guard let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, "com.compuserve.gif" as CFString, 2, nil) else {
            throw SceneError.invalid("Could not stage the animated fixture.")
        }
        for rgb in [(255, 0, 0), (0, 0, 255)] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<16 {
                for x in 0..<16 {
                    let offset = y * rep.bytesPerRow + x * 4
                    rep.bitmapData![offset] = UInt8(rgb.2)
                    rep.bitmapData![offset + 1] = UInt8(rgb.1)
                    rep.bitmapData![offset + 2] = UInt8(rgb.0)
                    rep.bitmapData![offset + 3] = 255
                }
            }
            let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.05]] as CFDictionary
            CGImageDestinationAddImage(dest, rep.cgImage!, frameProps)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        let still = try AnimatedImageRenderer(url: gifURL, bounds: NSRect(x: 0, y: 0, width: 64, height: 64))
        defer { still.releaseResources() }
        let focal = SceneFocus(x: 0.2, y: 0.7)
        let imageNode = SceneNode(content: .image(folder.appendingPathComponent("test.png")))
        let animatedNode = SceneNode(content: .image(gifURL))
        var focusedScene = SceneDescriptor(title: "Nested focus", nodes: [
            SceneNode(content: .group([imageNode, animatedNode]))
        ], focus: focal)
        let focusedRenderer = try LayeredSceneRenderer(playable: focusedScene,
            bounds: NSRect(x: 0, y: 0, width: 64, height: 64), scale: 1,
            clock: SceneClock(), onError: { preconditionFailure($0) })
        defer { focusedRenderer.releaseResources() }
        func canvases(_ view: NSView) -> [ImageCanvasView] {
            if let canvas = view as? ImageCanvasView { return [canvas] }
            return view.subviews.flatMap(canvases)
        }
        let originalCanvases = canvases(focusedRenderer.view)
        precondition(originalCanvases.count == 2)
        precondition(originalCanvases.allSatisfy { $0.fillFocus == CGPoint(x: focal.x, y: focal.y) })
        focusedScene.focus = SceneFocus(x: 0.8, y: 0.1)
        precondition(focusedRenderer.updateScene(focusedScene))
        precondition(zip(originalCanvases, canvases(focusedRenderer.view)).allSatisfy { $0 === $1 })
        precondition(originalCanvases.allSatisfy { $0.fillFocus == CGPoint(x: 0.8, y: 0.1) })
        focusedScene.bleed = SceneBleed(top: 0.05, left: 0.1, right: 0.2)
        precondition(focusedRenderer.updateScene(focusedScene))
        for canvas in originalCanvases {
            let image = canvas.currentImage!
            let expected = focusedScene.focus!.filledFrame(content: image.size, in: canvas.bounds, bleed: focusedScene.bleed)
            precondition(canvas.destinationRect(for: image) == expected, "Nested still and animated images must share crop geometry")
        }
        focusedScene.bleed = nil
        focusedScene.focus = nil
        precondition(focusedRenderer.updateScene(focusedScene))
        precondition(originalCanvases.allSatisfy { $0.fillFocus == nil })
        precondition(still.diagnostics.animated)
        still.setPaused(false)
        let deadline = Date(timeIntervalSinceNow: 5)
        while still.diagnostics.loopCount < 1 && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        precondition(still.diagnostics.loopCount >= 1, "Animated stills must advance frames on their delays")
        still.setPaused(true)
        precondition(still.diagnostics.state == .paused)
        // Single-frame files stay on the static path.
        do {
            _ = try AnimatedImageRenderer(url: folder.appendingPathComponent("test.png"), bounds: .zero)
            preconditionFailure("Still images must fall back to the static renderer")
        } catch { }
        print("Animated image checks passed: GIF loops natively without conversion")
    }

    private static func coverageChecks() {
        let rect = NSRect(x: 0, y: 0, width: 120, height: 120)
        precondition(CoverageMonitor.coveredFraction(of: rect, by: []) == 0)
        precondition(CoverageMonitor.coveredFraction(of: rect, by: [rect]) == 1)
        let half = CoverageMonitor.coveredFraction(of: rect, by: [NSRect(x: 0, y: 0, width: 60, height: 120)])
        precondition(abs(half - 0.5) < 0.1, "Coverage sampling must approximate half cover")
        print("Coverage checks passed: window-list sampling without occlusion state")
    }

    private static func compositionChecks(imageURL: URL) throws {
        let clock = SceneClock()
        func pixels(_ nodes: [SceneNode]) throws -> [UInt8] {
            let renderer = try MetalSceneRenderer(playable: SceneDescriptor(title: "Composition", nodes: nodes),
                bounds: CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1, clock: clock) { fatalError($0) }
            defer { renderer.releaseResources() }
            let pixels = try renderer.renderProbe(dimension: 64)
            precondition(renderer.intermediateTextureBytes <= SceneBudget.intermediateTextureBytes)
            return pixels
        }
        let base = SceneNode(content: .image(imageURL))
        let plain = try pixels([base])
        for blend in [SceneNode.Blend.multiply, .screen, .add] {
            var foreground = base; foreground.blend = blend
            let isolated = try pixels([foreground])
            precondition(zip(plain, isolated).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                         "Blending against transparency must preserve a layer")
            foreground.id = UUID(); foreground.opacity = 0.5
            let pair = try pixels([base, foreground])
            let channel = 0 // BGRA blue
            let source = Double(plain[channel]) / 255
            let expected = blend == .multiply ? source * 0.5 + source * source * 0.5 :
                blend == .screen ? source * 1.5 - source * source * 0.5 : min(1, source * 1.5)
            precondition(abs(Double(pair[channel]) / 255 - expected) < 0.02, "Premultiplied blend equation")
        }
        var masked = base; masked.maskAsset = imageURL
        let alpha = try pixels([masked])
        precondition(alpha == plain)
        masked.maskChannel = .luma
        let luma = try pixels([masked])
        precondition(luma[0] > 0 && Int(luma[0]) < Int(plain[0]) * 3 / 4)
        var mask = SceneNode(content: .image(imageURL), visible: false,
            transform: .init(x: 0, y: 0, scale: 0.5, rotation: 0))
        masked.maskAsset = nil; masked.maskChannel = nil; masked.maskNodeID = mask.id
        let nodeMask = try pixels([masked, mask])
        precondition(nodeMask[0] == 0 && nodeMask[(32 * 64 + 32) * 4] == plain[0],
                     "Hidden node masks retain their transform without painting the desktop")
        mask.content = .gradient
        precondition(SceneDescriptor(title: "Hidden reactive mask", nodes: [masked, mask]).animated)
        var particle = SceneNode(content: .particles(.init(count: 128, size: 0.04)))
        particle.sprite = imageURL
        let sprite = try pixels([particle])
        let colored = stride(from: 0, to: sprite.count, by: 4).filter { sprite[$0] > 10 }
        precondition(!colored.isEmpty && colored.allSatisfy { sprite[$0] > sprite[$0 + 2] },
                     "Particles must sample the authored sprite instead of the procedural gold disc")
        let again = try pixels([particle])
        precondition(sprite == again, "Sprite positions must remain deterministic")
        var grouped = SceneNode(content: .group([masked, mask]), opacity: 0.5)
        grouped.blend = .screen
        _ = try pixels([grouped])
    }

}
