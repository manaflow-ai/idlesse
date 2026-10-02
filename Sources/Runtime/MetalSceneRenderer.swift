import AppKit
import AVFoundation
import MetalKit
import CoreVideo
import CoreText

struct MetalShaderDiagnostic: Equatable, Sendable {
    enum Severity: String, Sendable { case error, warning, note }
    var line: Int?
    var column: Int?
    var severity: Severity
    var message: String

    var displayText: String {
        let location: String
        if let line, let column { location = "Line \(line):\(column) — " }
        else if let line { location = "Line \(line) — " }
        else { location = "" }
        return location + message
    }
}

struct MetalShaderCompilationError: LocalizedError {
    var diagnostics: [MetalShaderDiagnostic]
    var fallback: String

    var errorDescription: String? {
        guard !diagnostics.isEmpty else { return "Shader failed to compile: \(fallback)" }
        return (["Shader failed to compile."] + diagnostics.map(\.displayText)).joined(separator: "\n")
    }
}

enum MetalShaderCompiler {
    static let sourceName = "StudioShader"
    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; float fade; float2 canvasUV; };
    struct ShaderU { float time; float2 resolution; float2 pointer; float audio; float opacity; };
    """
    private static let validationVertex = """
    vertex V studioShaderValidationVertex(uint id [[vertex_id]]) {
        const float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        const float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
        V out;
        out.position = float4(positions[id], 0.0, 1.0);
        out.uv = uvs[id];
        out.fade = 1.0;
        out.canvasUV = out.uv;
        return out;
    }
    """

    static func makeLibrary(_ shader: SceneNode.Shader, device: MTLDevice) throws -> MTLLibrary {
        try shader.validate()
        let combined = prelude + "\n" + validationVertex + "\n#line 1 \"\(sourceName)\"\n" + shader.source
        do {
            return try device.makeLibrary(source: combined, options: nil)
        } catch {
            throw MetalShaderCompilationError(diagnostics: parseDiagnostics(error.localizedDescription),
                                              fallback: error.localizedDescription)
        }
    }

    static func validate(_ shader: SceneNode.Shader, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw SceneError.invalid("Metal is unavailable on this Mac.") }
        let library = try makeLibrary(shader, device: device)
        guard let fragment = library.makeFunction(name: "shaderMain") else {
            throw SceneError.invalid("Shaders must define fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]).")
        }
        guard let vertex = library.makeFunction(name: "studioShaderValidationVertex") else {
            throw SceneError.invalid("The shader validation vertex function is unavailable.")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0]?.pixelFormat = .bgra8Unorm
        do {
            _ = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalShaderCompilationError(diagnostics: parseDiagnostics(error.localizedDescription),
                                              fallback: error.localizedDescription)
        }
    }

    static func parseDiagnostics(_ text: String) -> [MetalShaderDiagnostic] {
        let pattern = #"(?:^|\n)(?:StudioShader|program_source|[^:\n]+):(\d+)(?::(\d+))?:\s*(error|warning|note):\s*([^\n]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            func capture(_ index: Int) -> String? {
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
            guard let lineText = capture(1), let line = Int(lineText),
                  let severityText = capture(3), let severity = MetalShaderDiagnostic.Severity(rawValue: severityText),
                  let message = capture(4) else { return nil }
            return MetalShaderDiagnostic(line: line, column: capture(2).flatMap(Int.init), severity: severity,
                                         message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension SceneNode.Shader {
    struct Preset: Sendable {
        let name: String
        let source: String
        let speed: Double
    }

    static let studioPresets: [Preset] = [
        .init(name: "Plasma", source: plasma, speed: 1),
        .init(name: "Noise / Grain", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 cell = floor(in.uv * u.resolution + u.time * float2(37.0, 19.0));
            float n = fract(sin(dot(cell, float2(12.9898, 78.233))) * 43758.5453);
            float v = 0.12 + n * 0.18;
            return float4(float3(v) * u.opacity, u.opacity);
        }
        """, speed: 1),
        .init(name: "Star Field", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 p = in.uv * float2(36.0, 22.0);
            float2 id = floor(p);
            float2 f = fract(p) - 0.5;
            float seed = fract(sin(dot(id, float2(127.1, 311.7))) * 43758.5453);
            float twinkle = 0.55 + 0.45 * sin(u.time * (0.6 + seed) + seed * 31.0);
            float star = smoothstep(0.075 + seed * 0.025, 0.0, length(f)) * step(0.86, seed) * twinkle;
            float3 col = float3(0.008, 0.012, 0.025) + star * float3(0.72, 0.82, 1.0);
            return float4(col * u.opacity, u.opacity);
        }
        """, speed: 0.7),
        .init(name: "Water / Ripple", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 p = (in.uv - 0.5) * u.resolution / min(u.resolution.x, u.resolution.y);
            float r = length(p + float2(0.08 * sin(u.time * 0.27), 0.05 * cos(u.time * 0.21)));
            float wave = 0.5 + 0.5 * sin(r * 30.0 - u.time * 2.2);
            wave *= exp(-r * 1.7);
            float3 deep = float3(0.015, 0.09, 0.16);
            float3 crest = float3(0.10, 0.42, 0.52);
            float3 col = mix(deep, crest, 0.22 + 0.48 * wave);
            return float4(col * u.opacity, u.opacity);
        }
        """, speed: 1),
        .init(name: "CRT", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 p = in.uv;
            float scan = 0.86 + 0.14 * sin((p.y * u.resolution.y + u.time * 12.0) * 3.14159);
            float2 edge = p * (1.0 - p);
            float vignette = smoothstep(0.0, 0.10, edge.x * edge.y);
            float glow = 0.035 + 0.02 * sin(p.y * 18.0 + u.time * 0.45);
            float3 col = float3(glow * 0.75, glow, glow * 0.82) * scan * vignette;
            return float4(col * u.opacity, u.opacity);
        }
        """, speed: 0.8),
        .init(name: "Voronoi", source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 p = in.uv * 7.0;
            float2 cell = floor(p);
            float2 local = fract(p);
            float nearest = 10.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float2 offset = float2(x, y);
                    float2 key = cell + offset;
                    float2 point = fract(sin(float2(dot(key, float2(127.1, 311.7)), dot(key, float2(269.5, 183.3)))) * 43758.5453);
                    point = 0.5 + 0.34 * sin(u.time * 0.55 + 6.28318 * point);
                    nearest = min(nearest, length(offset + point - local));
                }
            }
            float edge = smoothstep(0.42, 0.03, nearest);
            float3 col = mix(float3(0.018, 0.025, 0.032), float3(0.16, 0.28, 0.31), edge);
            return float4(col * u.opacity, u.opacity);
        }
        """, speed: 0.65)
    ]
}

/// Experimental SDR compositor. One drawable per display; groups use bounded offscreen passes.
/// Keep the layer renderer as the default until color and power parity are measured.
public final class MetalSceneRenderer: NSObject, SceneRenderer, MTKViewDelegate {
    // Optional GPU-only presentation consumer; it must not retain the source drawable.
    var mirrorFrame: ((MTLCommandBuffer, CAMetalDrawable) -> Void)? {
        didSet { metal.framebufferOnly = mirrorFrame == nil }
    }

    private final class Input {
        var resolvedText: String?
        var node: SceneNode
        var texture: MTLTexture?
        var shaderPipeline: MTLRenderPipelineState?
        var videoTexture: CVMetalTexture?
        var pixelBuffer: CVPixelBuffer?
        var maskTexture: MTLTexture?
        var offlineGenerator: AVAssetImageGenerator?
        var offlineDuration: Double = 0
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var sharedHub: SharedVideoHub?
        var followsClock = false
        var seekInFlight = false
        var transportRevision: UInt64?
        var lastCorrection: Double = -.infinity
        var statusObserver: NSKeyValueObservation?
        init(_ node: SceneNode) { self.node = node }
        func prepareOutputs() {
            guard sharedHub == nil else { return }
            // Replicas arrive asynchronously when the looper becomes ready.
            // Outputs are not copied from the template; configure each replica.
            for replica in looper?.loopingPlayerItems ?? player?.items() ?? [] {
                replica.preferredForwardBufferDuration = 0.5
                guard !replica.outputs.contains(where: { $0 is AVPlayerItemVideoOutput }) else { continue }
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true])
                output.suppressesPlayerRendering = true
                replica.add(output)
            }
        }
        deinit {
            statusObserver?.invalidate()
            if sharedHub == nil {
                player?.pause()
                looper?.disableLooping()
                player?.removeAllItems()
            }
        }
    }
    /// Completion handlers may outlive renderer teardown. Release wrappers before their cache.
    private final class VideoFrameLifetime {
        let cache: CVMetalTextureCache?
        var wrappers: [CVMetalTexture]
        var buffers: [CVPixelBuffer]
        init(cache: CVMetalTextureCache?, wrappers: [CVMetalTexture], buffers: [CVPixelBuffer]) {
            self.cache = cache; self.wrappers = wrappers; self.buffers = buffers
        }
        deinit {
            wrappers.removeAll()
            buffers.removeAll()
            withExtendedLifetime(cache) {}
        }
    }
    // SIMD4 fields keep Swift/Metal layout identical (16-byte alignment).
    private struct Uniforms {
        var transform: SIMD4<Float> // normalized x/y, scale, rotation radians
        var media: SIMD4<Float> // crop x/y, opacity, gradient flag
        var viewport: SIMD4<Float> // width/height aspect, time, reserved
        var style: SIMD4<Float> // ellipse mask, exposure, saturation, vignette
        var emitter: SIMD4<Float> = .zero // lifetime, speed, size, seed
        var world: SIMD4<Float> = SIMD4(1, 1, 0, 0) // scene-to-display scale and offset
        var motion: SIMD4<Float> = .zero // wind, gravity, count, wrapped emitter time
        var framing: SIMD4<Float> = .zero // UV offset; crop scale lives in media.xy
    }
    /// Compact uniforms for user shader nodes. Field order matches the
    /// ShaderU struct in MetalShaderCompiler (8-byte alignment throughout).
    private struct ShaderUniforms {
        var time: Float
        var resolution: SIMD2<Float>
        var pointer: SIMD2<Float>
        var audio: Float
        var opacity: Float
    }
    private static func compileShader(_ shader: SceneNode.Shader, device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
        let userLibrary = try MetalShaderCompiler.makeLibrary(shader, device: device)
        guard let fragment = userLibrary.makeFunction(name: "shaderMain") else {
            throw SceneError.invalid("Shaders must define fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]).")
        }
        guard let vertex = library.makeFunction(name: "sceneQuad") else {
            throw SceneError.invalid("Metal is unavailable on this Mac.")
        }
        let spec = MTLRenderPipelineDescriptor()
        spec.vertexFunction = vertex
        spec.fragmentFunction = fragment
        let color = spec.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            return try device.makeRenderPipelineState(descriptor: spec)
        } catch {
            throw SceneError.invalid("Shader pipeline failed: \(error.localizedDescription)")
        }
    }
    private let presentations = PresentedFrameCounter()
    var presentedFrameCount: Int? { presentations.total }
    var gpuTotals: (seconds: Double, frames: Int)? { presentations.gpuTotals }
    public let view: NSView
    private let metal: MTKView
    var desktopFrame: CGRect?
    var displayFrame: CGRect?
    private let clock: SceneClock
    private let onError: (String) -> Void
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var inputs: [Input] = []
    private var roots: [SceneNode] = []
    private var sourceScene: SceneDescriptor?
    private let bindingSmoother = SceneBindingSmoother()
    private let targets = GroupTexturePool()
    var intermediateTextureBytes: Int { targets.allocatedBytes }
    var videoTransportPositions: [Double] { inputs.filter { $0.followsClock }.compactMap { $0.player?.currentTime().seconds } }
    private var visibleIDs: Set<UUID> {
        func visit(_ nodes: [SceneNode]) -> [UUID] {
            nodes.filter { $0.visible }.flatMap { [$0.id] + visit($0.children) }
        }
        var ids = Set(visit(roots))
        let nodes = roots.flatMap { $0.descendants }
        var changed = true
        while changed {
            let before = ids
            for node in nodes where ids.contains(node.id) {
                if let mask = node.maskNodeID, let source = nodes.first(where: { $0.id == mask }) {
                    ids.formUnion(source.descendants.map { $0.id })
                }
            }
            changed = before != ids
        }
        return ids
    }
    private var needsFrame = true
    private let gate = DispatchSemaphore(value: 2)
    private(set) var diagnostics = RendererDiagnostics(state: .ready, animated: false, activeResources: 0)
    private var framesSinceCacheFlush = 0
    private var lastObservedLoopCount = 0

    private var sharedHub: SharedVideoHub?

    /// Embedding hosts render a resolved scene into `view`, driven by `clock`.
    public convenience init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat, clock: SceneClock,
                            onError: @escaping (String) -> Void) throws {
        try self.init(playable: playable, bounds: bounds, scale: scale, clock: clock, onError: onError, sharedHub: nil)
    }

    init(playable: SceneDescriptor, bounds: NSRect, scale: CGFloat, clock: SceneClock,
         onError: @escaping (String) -> Void, sharedHub: SharedVideoHub?) throws {
        self.sharedHub = sharedHub
        let authored = playable
        let playable = try playable.evaluated()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SceneError.invalid("Metal is unavailable on this Mac.")
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let spec = MTLRenderPipelineDescriptor()
        spec.vertexFunction = library.makeFunction(name: "sceneQuad")
        spec.fragmentFunction = library.makeFunction(name: "shade")
        let color = spec.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: spec)
        metal = MTKView(frame: bounds, device: device)
        metal.colorPixelFormat = .bgra8Unorm
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metal.preferredFramesPerSecond = 60
        metal.isPaused = true
        metal.enableSetNeedsDisplay = false
        view = metal
        self.clock = clock
        self.queue = queue
        self.onError = onError
        super.init()
        sourceScene = authored
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw SceneError.invalid("Could not create the video texture cache.")
        }
        try SceneBudget.validate(playable.nodes)
        roots = playable.nodes
        for node in playable.allNodes {
            let input = Input(node)
            switch node.content {
            case .text, .shape:
                input.texture = try Self.upload(Self.rasterize(node, pixelLimit: SceneBudget.imagePixels(playable.nodes)), device: device)
            case .image(let url):
                guard let image = DisplayImageDecoder.load(url, target: metal.drawableSize, mode: .fill, pixelLimit: CGFloat(SceneBudget.imagePixels(playable.nodes))),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw SceneError.invalid("That image could not be opened.")
                }
                input.texture = try Self.upload(cg, device: device)
            case .video(let url):
                input.sharedHub = sharedHub
                input.followsClock = authored.timeline?.videosFollowScene == true
                if sharedHub == nil {
                    let item = AVPlayerItem(url: url)
                    item.preferredForwardBufferDuration = 0.5
                    // The same sidecar adjustments the layer renderer and shared hub apply;
                    // the video output reads composed frames, so they reach the texture.
                    if let tone = SceneTone.beside(url) { item.videoComposition = tone.videoComposition(for: item.asset) }
                    let player = AVQueuePlayer()
                    player.isMuted = true
                    player.preventsDisplaySleepDuringVideoPlayback = false
                    input.player = player
                    if input.followsClock {
                        player.actionAtItemEnd = .pause
                        player.insert(item, after: nil)
                        input.prepareOutputs()
                        input.statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak input] item, _ in
                            DispatchQueue.main.async { [weak self, weak input] in
                                guard let self, input != nil, self.diagnostics.state != .disposed else { return }
                                if item.status == .failed { onError(item.error?.localizedDescription ?? "Video transport failed.") }
                                if item.status == .readyToPlay { self.needsFrame = true; self.metal.draw() }
                            }
                        }
                    } else {
                        let looper = AVPlayerLooper(player: player, templateItem: item)
                        input.looper = looper
                        input.statusObserver = looper.observe(\.status, options: [.initial, .new]) { [weak input] looper, _ in
                            if looper.status == .ready {
                                DispatchQueue.main.async { [weak input] in input?.prepareOutputs() }
                            }
                            if looper.status == .failed {
                                DispatchQueue.main.async { onError(looper.error?.localizedDescription ?? "Video looping failed.") }
                            }
                        }
                    }
                }
            case .gradient, .group, .particles: break
            case .shader(let shader):
                input.shaderPipeline = try Self.compileShader(shader, device: device, library: library)
            }
            for (url, isMask) in [(node.maskAsset, true), (node.sprite, false)] {
                guard let url else { continue }
                guard let image = DisplayImageDecoder.load(url, target: metal.drawableSize, mode: .fill,
                    pixelLimit: CGFloat(SceneBudget.imagePixels(playable.nodes))),
                    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw SceneError.invalid("Could not open a mask or sprite image.")
                }
                let texture = try Self.upload(cg, device: device)
                if isMask { input.maskTexture = texture } else { input.texture = texture }
            }
            inputs.append(input)
        }
        diagnostics.animated = playable.animated || authored.usesTime || (authored.usesAudio && clock.audioEnabled) || (authored.usesPointer && clock.pointerEnabled)
        diagnostics.activeResources = inputs.count
        // Fail preparation before the host replaces the last working renderer.
        guard let preparedTargets = targets.acquire(device: device, size: metal.drawableSize,
            count: playable.allNodes.filter { $0.kind == .group }.count +
                3 * playable.allNodes.filter { !$0.style.effects.isEmpty }.count +
                (playable.allNodes.contains { $0.needsComposition } ? playable.allNodes.count + 2 : 0)) else {
            throw SceneError.invalid("Could not prepare the group render targets within the texture budget.")
        }
        targets.recycle(preparedTargets)
        metal.delegate = self
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsFrame = true
        if !diagnostics.animated { view.draw() }
    }
    @discardableResult private func updateVideos() -> Bool {
        var changed = false
        let visible = visibleIDs
        for input in inputs where visible.contains(input.node.id) {
            if let hub = input.sharedHub {
                if let sample = hub.sample(nodeID: input.node.id, clock: clock, isRunning: diagnostics.state == .running) {
                    if sample.buffer !== input.pixelBuffer {
                        input.pixelBuffer = sample.buffer
                        input.videoTexture = sample.wrapper
                        input.texture = sample.texture
                        changed = true
                    }
                }
            } else {
                guard let cache else { continue }
                if input.followsClock { synchronizeVideo(input) }
                guard let player = input.player,
                      let output = player.currentItem?.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first
                else { continue }
                let time = player.currentTime()
                guard output.hasNewPixelBuffer(forItemTime: time),
                      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
                var wrapper: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                    CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper) == kCVReturnSuccess,
                      let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else { continue }
                input.pixelBuffer = buffer
                input.videoTexture = wrapper
                input.texture = texture
                changed = true
            }
        }
        let currentLoops = sharedHub?.loopCount ?? (inputs.filter { $0.player != nil }.map { $0.looper?.loopCount ?? 0 }.min() ?? 0)
        diagnostics.loopCount = currentLoops
        if currentLoops != lastObservedLoopCount {
            lastObservedLoopCount = currentLoops
            if let cache { CVMetalTextureCacheFlush(cache, 0) }
        }
        return changed
    }
    private func synchronizeVideo(_ input: Input) {
        guard let player = input.player, let item = player.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let wrapped = clock.time.truncatingRemainder(dividingBy: duration)
        let target = clock.isAtEnd && wrapped < 0.000001 ? max(0, duration - 1.0 / 600) : wrapped
        let rate = diagnostics.state == .running ? clock.effectiveRate : 0
        let now = ProcessInfo.processInfo.systemUptime
        let needsSeek = input.transportRevision != clock.revision ||
            abs(player.currentTime().seconds - target) > (rate == 0 ? 0.002 : 0.12)
        guard !input.seekInFlight else { return }
        if needsSeek && (input.transportRevision != clock.revision || now - input.lastCorrection >= 0.1) {
            input.seekInFlight = true; input.lastCorrection = now
            let revision = clock.revision
            player.pause()
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak input] completed in
                DispatchQueue.main.async { [weak self, weak input] in
                    guard let self, let input, self.diagnostics.state != .disposed else { return }
                    input.seekInFlight = false
                    if completed { input.transportRevision = revision }
                    self.needsFrame = true
                    self.metal.draw()
                }
            }
        } else if !needsSeek {
            player.rate = Float(rate)
        }
    }
    private func encode(_ command: MTLCommandBuffer, _ pass: MTLRenderPassDescriptor, size: CGSize) -> Bool {
        guard let pipeline, let device = metal.device else { return false }
        let world = sourceScene?.canvas == .desktopSpan ? desktopFrame : nil
        let sceneAspect = Float((world?.width ?? size.width) / max(1, world?.height ?? size.height))
        let allNodes = roots.flatMap { $0.descendants }
        let advanced = allNodes.contains { $0.needsComposition }
        let groups = roots.flatMap { $0.descendants }.filter { $0.kind == .group }
        guard let lease = targets.acquire(device: device, size: size, count: groups.count + 3 * roots.flatMap { $0.descendants }.filter { !$0.style.effects.isEmpty }.count + (advanced ? allNodes.count + 2 : 0)) else { return false }
        let groupTextures = Dictionary(uniqueKeysWithValues: zip(groups.map { $0.id }, lease.textures))
        let effected = roots.flatMap { $0.descendants }.filter { !$0.style.effects.isEmpty }
        var effectTargets: [UUID: [MTLTexture]] = [:]
        for (index, node) in effected.enumerated() {
            let start = groups.count + index * 3
            effectTargets[node.id] = Array(lease.textures[start..<(start + 3)])
        }
        let extraStart = groups.count + effected.count * 3
        let nodeFrames: [UUID: MTLTexture] = advanced ? Dictionary(uniqueKeysWithValues:
            zip(allNodes.map { $0.id }, lease.textures[extraStart..<(extraStart + allNodes.count)])) : [:]
        let blendScratch = advanced ? lease.textures[lease.textures.count - 2] : nil
        let worldFrame = advanced ? lease.textures.last : nil
        var outputs: [UUID: MTLTexture] = [:]
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.node.id, $0) })
        func renderPass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
            let result = MTLRenderPassDescriptor()
            result.colorAttachments[0].texture = texture
            result.colorAttachments[0].loadAction = .clear
            result.colorAttachments[0].storeAction = .store
            result.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            return result
        }
        func configureEmitter(_ emitter: SceneNode.Emitter, uniforms: inout Uniforms) {
            uniforms.media.w = 2
            uniforms.emitter = SIMD4(Float(emitter.lifetime), Float(emitter.speed), Float(emitter.size), Float(emitter.seed))
            uniforms.motion = SIMD4(Float(emitter.wind), Float(emitter.gravity), Float(emitter.count),
                                    Float(clock.time.truncatingRemainder(dividingBy: emitter.lifetime)))
        }
        func mediaFraming(_ node: SceneNode, texture: MTLTexture?) -> SIMD4<Float>? {
            guard node.kind == .image || node.kind == .video, let texture,
                  let scene = sourceScene, scene.focus != nil || scene.bleed != nil else { return nil }
            return Self.mediaFraming(content: CGSize(width: texture.width, height: texture.height),
                                     aspect: CGFloat(sceneAspect), focus: scene.focus, bleed: scene.bleed)
        }
        func effectPass(source: MTLTexture?, original: MTLTexture? = nil, destination: MTLTexture,
                        mode: Float, amount: Float, gradient: Bool = false, emitter: SceneNode.Emitter? = nil, crop: SIMD2<Float> = SIMD2(1, 1), offset: SIMD2<Float> = .zero) -> Bool {
            guard let encoder = command.makeRenderCommandEncoder(descriptor: renderPass(destination)) else { return false }
            var u = Uniforms(transform: SIMD4(0, 0, 1, 0), media: SIMD4(crop.x, crop.y, 1, gradient ? 1 : 0),
                viewport: SIMD4(sceneAspect, Float(clock.time.truncatingRemainder(dividingBy: 3600)), mode, amount),
                style: SIMD4(0, 0, 1, 0))
            u.framing = SIMD4(offset.x, offset.y, 0, 0)
            if let emitter { configureEmitter(emitter, uniforms: &u); if let source { u.media.w = 3; u.viewport.z = Float(source.width) / Float(source.height) } }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(original, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: emitter?.count ?? 1)
            encoder.endEncoding()
            return true
        }
        func encodeNodes(_ nodes: [SceneNode], into target: MTLRenderPassDescriptor, root: Bool = false, isolated: Bool = false) -> Bool {
            // Children finish their offscreen passes before their parent encoder begins.
            for node in nodes where node.visible && node.kind == .group && !isolated {
                guard let texture = groupTextures[node.id] else { return false }
                let childPass = MTLRenderPassDescriptor()
                childPass.colorAttachments[0].texture = texture
                childPass.colorAttachments[0].loadAction = .clear
                childPass.colorAttachments[0].storeAction = .store
                childPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard encodeNodes(node.children, into: childPass) else { return false }
            }
            for node in nodes where node.visible && !node.style.effects.isEmpty {
                guard let scratch = effectTargets[node.id] else { return false }
                let source = node.kind == .group ? groupTextures[node.id] : byID[node.id]?.texture
                guard node.kind == .gradient || node.kind == .particles || source != nil else { continue }
                let aspect = sceneAspect
                let mediaAspect = node.kind == .group ? aspect : source.map { Float($0.width) / Float($0.height) } ?? aspect
                let fit = node.kind == .text || node.kind == .shape
                let framing = mediaFraming(node, texture: source)
                guard effectPass(source: source, destination: scratch[0], mode: 0, amount: 0, gradient: node.kind == .gradient, emitter: node.emitter,
                                 crop: framing.map { SIMD2($0.x, $0.y) } ?? SIMD2(fit ? max(1, aspect / mediaAspect) : min(1, aspect / mediaAspect), fit ? max(1, mediaAspect / aspect) : min(1, mediaAspect / aspect)),
                                 offset: framing.map { SIMD2($0.z, $0.w) } ?? .zero) else { return false }
                var current = scratch[0]
                for effect in node.style.effects {
                    let available = scratch.filter { $0 !== current }
                    let amount = Float(effect.amount)
                    switch effect.type {
                    case .blur, .bloom:
                        if amount == 0 { continue }
                        // Radius is relative to scene height, so budget downsampling preserves the visual extent.
                        let radius = (effect.type == .bloom ? Float(12) : amount) / 1080
                        guard effectPass(source: current, destination: available[0], mode: effect.type == .bloom ? 7 : 1, amount: radius),
                              effectPass(source: available[0], destination: available[1], mode: 2, amount: radius) else { return false }
                        if effect.type == .bloom {
                            guard effectPass(source: available[1], original: current, destination: available[0], mode: 3, amount: amount) else { return false }
                            current = available[0]
                        } else { current = available[1] }
                    case .exposure, .saturation, .vignette, .displacement:
                        let mode: Float = effect.type == .displacement ? 8 : effect.type == .exposure ? 4 : effect.type == .saturation ? 5 : 6
                        guard effectPass(source: current, destination: available[0], mode: mode, amount: amount) else { return false }
                        current = available[0]
                    }
                }
                outputs[node.id] = current
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: target) else { return false }
            let targetWidth = Float(target.colorAttachments[0].texture?.width ?? 1)
            let targetHeight = Float(target.colorAttachments[0].texture?.height ?? 1)
            for node in nodes where node.visible {
                let gradient = node.kind == .gradient && outputs[node.id] == nil
                let shaderPipeline = node.kind == .shader ? byID[node.id]?.shaderPipeline : nil
                let texture = outputs[node.id] ?? (node.kind == .group ? groupTextures[node.id] : byID[node.id]?.texture)
                guard gradient || node.kind == .particles || shaderPipeline != nil || texture != nil else { continue }
                let aspect = sceneAspect
                let mediaAspect = (node.kind == .group || outputs[node.id] != nil) ? aspect : texture.map { Float($0.width) / Float($0.height) } ?? aspect
                let fit = node.kind == .text || node.kind == .shape
                let t = node.transform
                var u = Uniforms(transform: SIMD4(Float(t.x ?? 0), Float(t.y ?? 0), Float(t.scale ?? 1), Float((t.rotation ?? 0) * .pi / 180)),
                    media: SIMD4(fit ? max(1, aspect / mediaAspect) : min(1, aspect / mediaAspect), fit ? max(1, mediaAspect / aspect) : min(1, mediaAspect / aspect), Float(node.opacity), gradient ? 1 : 0),
                    viewport: SIMD4(aspect, Float(clock.time.truncatingRemainder(dividingBy: 3600)), 0, 0),
                    style: SIMD4(node.style.mask == .ellipse ? 1 : 0, Float(node.style.exposure), Float(node.style.saturation), Float(node.style.vignette)))
                if outputs[node.id] == nil, let framing = mediaFraming(node, texture: texture) {
                    u.media.x = framing.x; u.media.y = framing.y
                    u.framing = SIMD4(framing.z, framing.w, 0, 0)
                }
                if outputs[node.id] == nil, let emitter = node.emitter { configureEmitter(emitter, uniforms: &u); if node.sprite != nil, let texture { u.media.w = 3; u.viewport.z = Float(texture.width) / Float(texture.height) } }
                if root, let world, let display = displayFrame {
                    u.world = SIMD4(Float(world.width / display.width), Float(world.height / display.height),
                        Float((world.midX - display.midX) * 2 / display.width),
                        Float((world.midY - display.midY) * 2 / display.height))
                }
                encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                if let shaderPipeline, let speed = node.shader?.speed {
                    var su = ShaderUniforms(
                        time: Float(clock.time * speed),
                        resolution: SIMD2(targetWidth, targetHeight),
                        pointer: SIMD2(Float(lastSignals.pointerX), Float(lastSignals.pointerY)),
                        audio: Float(lastSignals.audio.level),
                        opacity: Float(node.opacity))
                    encoder.setRenderPipelineState(shaderPipeline)
                    encoder.setFragmentBytes(&su, length: MemoryLayout<ShaderUniforms>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
                } else {
                    encoder.setRenderPipelineState(pipeline)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: outputs[node.id] == nil ? node.emitter?.count ?? 1 : 1)
                }
            }
            encoder.endEncoding()
            return true
        }
        var rendered = Set<UUID>()
        let metadata = Dictionary(uniqueKeysWithValues: allNodes.map { ($0.id, $0) })
        func renderNode(_ authored: SceneNode) -> Bool {
            if rendered.contains(authored.id) { return true }
            guard let frame = nodeFrames[authored.id], let scratch = blendScratch else { return false }
            if authored.kind == .group {
                guard let group = groupTextures[authored.id], renderList(authored.children, into: group) else { return false }
            }
            var node = authored
            node.visible = true // A hidden layer can still be explicitly used as a mask.
            guard encodeNodes([node], into: renderPass(frame), isolated: true) else { return false }
            let mask: MTLTexture?
            if let id = node.maskNodeID {
                guard let source = metadata[id], renderNode(source) else { return false }
                mask = nodeFrames[id]
            } else { mask = byID[node.id]?.maskTexture }
            if let mask {
                guard effectPass(source: frame, destination: scratch, mode: 0, amount: 0),
                      effectPass(source: scratch, original: mask, destination: frame,
                                 mode: node.maskChannel == .luma ? 10 : 9, amount: 0) else { return false }
            }
            rendered.insert(node.id)
            return true
        }
        func renderList(_ nodes: [SceneNode], into destination: MTLTexture) -> Bool {
            // Initialize even an empty/fully hidden subtree to transparent.
            guard let clear = command.makeRenderCommandEncoder(descriptor: renderPass(destination)) else { return false }
            clear.endEncoding()
            for node in nodes where node.visible {
                guard renderNode(node), let source = nodeFrames[node.id], let scratch = blendScratch else { return false }
                if node.blend == nil || node.blend == .normal {
                    let target = renderPass(destination); target.colorAttachments[0].loadAction = .load
                    guard let encoder = command.makeRenderCommandEncoder(descriptor: target) else { return false }
                    var u = Uniforms(transform: SIMD4(0, 0, 1, 0), media: SIMD4(1, 1, 1, 0),
                        viewport: SIMD4(sceneAspect, 0, 0, 0), style: SIMD4(0, 0, 1, 0))
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                    encoder.setFragmentTexture(source, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    encoder.endEncoding()
                } else {
                    guard effectPass(source: destination, destination: scratch, mode: 0, amount: 0),
                          effectPass(source: source, original: scratch, destination: destination,
                            mode: node.blend == .add ? 11 : node.blend == .multiply ? 12 : 13, amount: 0) else { return false }
                }
            }
            return true
        }
        if advanced {
            guard let worldFrame, renderList(roots, into: worldFrame),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { targets.recycle(lease); return false }
            var u = Uniforms(transform: SIMD4(0, 0, 1, 0), media: SIMD4(1, 1, 1, 0),
                viewport: SIMD4(sceneAspect, 0, 0, 0), style: SIMD4(0, 0, 1, 0))
            if let world, let display = displayFrame {
                u.world = SIMD4(Float(world.width / display.width), Float(world.height / display.height),
                    Float((world.midX - display.midX) * 2 / display.width), Float((world.midY - display.midY) * 2 / display.height))
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(worldFrame, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        } else if !encodeNodes(roots, into: pass, root: true) { targets.recycle(lease); return false }
        // Hold both the Core Video buffers and this frame's group targets through completion.
        let videoLifetime = VideoFrameLifetime(cache: cache, wrappers: inputs.compactMap { $0.videoTexture },
                                               buffers: inputs.compactMap { $0.pixelBuffer })
        let targets = self.targets
        command.addCompletedHandler { _ in
            withExtendedLifetime(videoLifetime) {}
            targets.recycle(lease)
        }
        return true
    }
    func updateScene(_ scene: SceneDescriptor) -> Bool {
        let authored = scene
        guard (sourceScene?.timeline?.videosFollowScene == true) == (scene.timeline?.videosFollowScene == true) else { return false }
        guard let scene = try? scene.evaluated(signals: currentSignals()) else { return false }
        let existing = Dictionary(uniqueKeysWithValues: inputs.map { ($0.node.id, $0.node) })
        for node in scene.allNodes where node.kind == .shader {
            guard let old = existing[node.id]?.shader, let shader = node.shader, old.source == shader.source else {
                // Shader source owns a Metal pipeline. Rebuild transactionally so Studio can
                // keep the current renderer alive until the replacement compiles successfully.
                return false
            }
        }
        guard diagnostics.state != .disposed,
              let order = sceneResourceOrder(from: inputs.map { $0.node }, to: scene.allNodes) else { return false }
        guard (try? SceneBudget.validate(scene.nodes)) != nil else { return false }
        roots = scene.nodes
        sourceScene = authored
        bindingSmoother.reset()
        inputs = order.map { inputs[$0] }
        for (input, node) in zip(inputs, scene.allNodes) { input.node = node }
        diagnostics.animated = scene.animated || authored.usesTime || (authored.usesAudio && clock.audioEnabled) || (authored.usesPointer && clock.pointerEnabled)
        setPaused(diagnostics.state != .running)
        metal.draw()
        return true
    }
    public var onFirstFrameReady: (() -> Void)?
    private var deliveredFirstFrame = false
    public var isReadyForDisplay: Bool { deliveredFirstFrame }

    public func draw(in view: MTKView) {
        guard diagnostics.state != .disposed, let queue, gate.wait(timeout: .now()) == .success else { return }
        if diagnostics.state == .running { updateSignals(sampledSignals()) }
        let changed = updateVideos()
        needsFrame = needsFrame || changed
        // Do not replace the desktop poster with an incomplete composition while
        // AVFoundation is still producing the first visible video textures.
        guard !inputs.contains(where: { visibleIDs.contains($0.node.id) && $0.node.kind == .video && $0.texture == nil }) else {
            gate.signal(); return
        }
        guard needsFrame || roots.flatMap({ $0.descendants }).contains(where: { visibleIDs.contains($0.id) && $0.hasAnimatedEffects }) || inputs.contains(where: { visibleIDs.contains($0.node.id) && ($0.node.kind == .gradient || $0.node.kind == .particles || $0.node.kind == .shader) }) else {
            gate.signal(); return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), encode(command, pass, size: view.drawableSize) else {
            gate.signal(); return
        }
        let gate = self.gate
        let gpuMetrics = presentations
        command.addCompletedHandler { [weak self] command in
            gate.signal()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.diagnostics.state != .disposed else { return }
                if command.status == .completed && !self.deliveredFirstFrame {
                    self.deliveredFirstFrame = true
                    let ready = self.onFirstFrameReady
                    self.onFirstFrameReady = nil
                    ready?()
                }
                if self.needsFrame && !self.diagnostics.animated { self.metal.draw() }
            }
            if command.status == .completed { gpuMetrics.recordGPU(start: command.gpuStartTime, end: command.gpuEndTime) }
            if command.status == .error {
                DispatchQueue.main.async { [weak self] in self?.onError("The compositor could not render a frame.") }
            }
        }
        let presentations = self.presentations
        drawable.addPresentedHandler { drawable in
            presentations.record(presentedTime: drawable.presentedTime)
        }
        mirrorFrame?(command, drawable)
        command.present(drawable)
        command.commit()
        needsFrame = false
        diagnostics.frameCount += 1
        framesSinceCacheFlush += 1
        if framesSinceCacheFlush >= 120 {
            framesSinceCacheFlush = 0
            if let cache { CVMetalTextureCacheFlush(cache, 0) }
        }
        updateDrawScheduling()
    }
    func refreshSceneTime() {
        guard diagnostics.state != .disposed else { return }
        updateSignals(sampledSignals())
        needsFrame = true
        updateDrawScheduling()
        metal.draw()
    }
    private let textOrigin = Date()
    private var textTimer: Timer?
    private func updateText(at date: Date) throws {
        guard let device = metal.device else { return }
        for input in inputs where input.node.typography?.liveSource != nil {
            let text = input.node.typography!.resolved(at: date)
            guard text != input.resolvedText else { continue }
            var node = input.node
            var typography = node.typography!
            typography.text = text; typography.liveSource = nil; node.content = .text(typography)
            input.texture = try Self.upload(Self.rasterize(node, pixelLimit: SceneBudget.imagePixels(sourceScene?.nodes ?? inputs.map(\.node))), device: device)
            input.resolvedText = text
            needsFrame = true
        }
    }
    private func updateDrawScheduling() {
        let liveText = diagnostics.state == .running && inputs.contains { $0.node.typography?.liveSource != nil }
        if liveText && textTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                do { try self.updateText(at: Date()); if self.needsFrame { self.metal.draw() } }
                catch { self.onError(error.localizedDescription) }
            }
            timer.tolerance = 0.1
            textTimer = timer; RunLoop.main.add(timer, forMode: .common)
        } else if !liveText { textTimer?.invalidate(); textTimer = nil }

        // A completed once scene has no moving clock. Independent videos,
        // pointer input and smoothing may still change its final composition.
        let independentVideo = inputs.contains { visibleIDs.contains($0.node.id) && $0.node.kind == .video && !$0.followsClock }
        let reactive = (sourceScene?.usesAudio == true && clock.audioEnabled) || sourceScene?.usesSmoothing == true || (sourceScene?.usesPointer == true && clock.pointerEnabled)
        let finished = clock.isAtEnd && !independentVideo && !reactive
        metal.isPaused = diagnostics.state != .running || !diagnostics.animated || finished
    }
    private var lastSignals = SceneSignals(time: 0)
    private func sampledSignals() -> SceneSignals {
        let signals = currentSignals()
        lastSignals = signals
        return signals
    }
    private func currentSignals() -> SceneSignals {
        var signals = SceneSignals(time: clock.time)
        if sourceScene?.usesAudio == true, clock.audioEnabled { signals.audio = clock.audioLevels() }
        if sourceScene?.usesPointer == true, clock.pointerEnabled, let window = metal.window {
            if sourceScene?.canvas == .desktopSpan, let world = desktopFrame {
                let point = NSEvent.mouseLocation
                signals.pointerX = min(1, max(-1, Double((point.x - world.minX) / max(1, world.width) * 2 - 1)))
                signals.pointerY = min(1, max(-1, Double((point.y - world.minY) / max(1, world.height) * 2 - 1)))
                return signals
            }
            let point = metal.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            signals.pointerX = min(1, max(-1, Double(point.x / max(1, metal.bounds.width) * 2 - 1)))
            let y = Double(point.y / max(1, metal.bounds.height) * 2 - 1)
            signals.pointerY = min(1, max(-1, metal.isFlipped ? -y : y))
        }
        return signals
    }
    private func updateSignals(_ signals: SceneSignals) {
        guard let sourceScene, sourceScene.usesSignals else { return }
        bindingSmoother.beginFrame(time: ProcessInfo.processInfo.systemUptime, revision: clock.revision)
        guard let evaluated = try? sourceScene.evaluated(signals: signals, validating: false, smooth: { [bindingSmoother] target, value, duration in
            bindingSmoother.sample(target: target, value: value, duration: duration)
        }) else { return }
        let changed = sourceScene.bindings.contains { binding in
            (try? binding.target.value(in: roots)) != (try? binding.target.value(in: evaluated.nodes))
        }
        guard changed else { return }
        roots = evaluated.nodes
        for (input, node) in zip(inputs, evaluated.allNodes) { input.node = node }
        needsFrame = true
    }
    static func smokeTestGroupTextureBudget() throws {
        let parsed = MetalShaderCompiler.parseDiagnostics("StudioShader:7:11: error: unknown identifier")
        precondition(parsed.first?.line == 7 && parsed.first?.column == 11,
            "Shader diagnostics must retain user-source line and column information")
        for preset in SceneNode.Shader.studioPresets {
            try MetalShaderCompiler.validate(.init(source: preset.source, speed: preset.speed))
        }
        let invalid = SceneNode.Shader(source: """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            return float4(missingStudioSymbol);
        }
        """, speed: 1)
        do {
            try MetalShaderCompiler.validate(invalid)
            preconditionFailure("Invalid Studio Metal source must fail compilation")
        } catch let error as MetalShaderCompilationError {
            precondition(!error.diagnostics.isEmpty, "Metal compiler errors should surface inline diagnostics")
            if let line = error.diagnostics.compactMap(\.line).first {
                precondition((1...3).contains(line), "Compiler line information must point into the user source")
            }
        }

        let shaderClock = SceneClock(now: { 0 })
        try shaderClock.seek(to: 1)
        let shaderNode = SceneNode(content: .shader(.init()))
        let shaderRenderer = try MetalSceneRenderer(playable: .init(title: "Shader transaction", nodes: [shaderNode]),
            bounds: NSRect(x: 0, y: 0, width: 64, height: 64), scale: 1, clock: shaderClock, onError: { _ in })
        let lastValidShaderPixels = try shaderRenderer.renderProbe(dimension: 64)
        var brokenShaderNode = shaderNode
        brokenShaderNode.content = .shader(.init(source: "this is not metal", speed: 1))
        precondition(!shaderRenderer.updateScene(.init(title: "Broken shader draft", nodes: [brokenShaderNode])),
            "Shader source changes must request transactional renderer replacement")
        do {
            _ = try MetalSceneRenderer(playable: .init(title: "Broken shader draft", nodes: [brokenShaderNode]),
                bounds: NSRect(x: 0, y: 0, width: 64, height: 64), scale: 1, clock: shaderClock, onError: { _ in })
            preconditionFailure("Invalid replacement shader source must fail renderer preparation")
        } catch { }
        let preservedShaderPixels = try shaderRenderer.renderProbe(dimension: 64)
        precondition(preservedShaderPixels == lastValidShaderPixels,
            "Rejected shader source edits must leave the last valid pipeline rendering")
        var speedShaderNode = shaderNode
        speedShaderNode.content = .shader(.init(source: shaderNode.shader!.source, speed: 2))
        precondition(shaderRenderer.updateScene(.init(title: "Shader speed", nodes: [speedShaderNode])),
            "Shader speed changes should stay on the in-place update path")
        let fasterShaderPixels = try shaderRenderer.renderProbe(dimension: 64)
        precondition(fasterShaderPixels != preservedShaderPixels, "Shader speed edits must affect rendered output")
        shaderRenderer.releaseResources()

        let shapeScene = SceneDescriptor(title: "Shape Test", nodes: [SceneNode(content: .shape(.init(primitive: .rectangle, fill: "#00FF00", width: 128, height: 128)))])
        let shape = try MetalSceneRenderer(playable: shapeScene, bounds: NSRect(x: 0, y: 0, width: 64, height: 64), scale: 1, clock: SceneClock(now: { 0 }), onError: { _ in })
        defer { shape.releaseResources() }
        let pixels = try shape.renderProbe(dimension: 64)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            precondition(pixels[index] <= 1 && pixels[index + 1] >= 254 && pixels[index + 2] <= 1, "Shape fill must preserve green through Metal")
        }
        var wideNode = SceneNode(content: .shape(.init(primitive: .rectangle, fill: "#00FF00", width: 128, height: 64)))
        wideNode.style.effects = [.init(id: UUID(), type: .exposure, amount: 0)]
        let wide = try MetalSceneRenderer(playable: .init(title: "Fit", nodes: [wideNode]), bounds: NSRect(x: 0, y: 0, width: 64, height: 64), scale: 1, clock: SceneClock(now: { 0 }), onError: { _ in })
        defer { wide.releaseResources() }
        let fit = try wide.renderProbe(dimension: 64)
        precondition(fit[(8 * 64 + 32) * 4 + 1] == 0 && fit[(32 * 64 + 32) * 4 + 1] >= 254,
            "Wide shapes must fit without cropping, including through effect passes")
        let textScene = SceneDescriptor(title: "Text Test", nodes: [SceneNode(content: .text(.init(text: "Hello", size: 80, width: 512, height: 256)))])
        let text = try MetalSceneRenderer(playable: textScene, bounds: NSRect(x: 0, y: 0, width: 256, height: 128), scale: 1, clock: SceneClock(now: { 0 }), onError: { _ in })
        defer { text.releaseResources() }
        let letters = try text.renderFrame(width: 256, height: 128)
        let lit = stride(from: 0, to: letters.count, by: 4).filter { letters[$0] > 16 }.count
        precondition(lit > 100 && lit < 16384, "CoreText should draw visible glyphs with a transparent surrounding canvas")
        let repeated = try text.renderFrame(width: 256, height: 128)
        precondition(repeated == letters, "Static text must be deterministic")
        let clockNode = SceneNode(content: .text(.init(liveSource: .timeWithSeconds, text: "", size: 60, width: 512, height: 128)))
        let clockRenderer = try MetalSceneRenderer(playable: .init(title: "Clock", nodes: [clockNode]),
            bounds: NSRect(x: 0, y: 0, width: 512, height: 128), scale: 1, clock: SceneClock(now: { 0 }), onError: { _ in })
        defer { clockRenderer.releaseResources() }
        let zero = try clockRenderer.renderFrame(signals: .init(time: 0), width: 512, height: 128, referenceDate: Date(timeIntervalSince1970: 0))
        let one = try clockRenderer.renderFrame(signals: .init(time: 1), width: 512, height: 128, referenceDate: Date(timeIntervalSince1970: 0))
        let zeroAgain = try clockRenderer.renderFrame(signals: .init(time: 0), width: 512, height: 128, referenceDate: Date(timeIntervalSince1970: 0))
        precondition(zero != one && zero == zeroAgain, "Clock text must update and offline seeking must reproduce glyphs")

        guard let device = MTLCreateSystemDefaultDevice() else { throw SceneError.invalid("Metal unavailable") }
        let pool = GroupTexturePool()
        let size = CGSize(width: 7680, height: 4320)
        guard let first = pool.acquire(device: device, size: size, count: 4),
              let second = pool.acquire(device: device, size: size, count: 4) else { throw SceneError.invalid("Group budget allocation failed") }
        precondition(pool.allocatedBytes <= SceneBudget.intermediateTextureBytes)
        precondition(pool.acquire(device: device, size: size, count: 4) == nil, "In-flight targets must not be reused or exceed the cap")
        pool.recycle(first)
        guard let resized = pool.acquire(device: device, size: CGSize(width: 1920, height: 1080), count: 4) else { throw SceneError.invalid("Group resize failed") }
        precondition(pool.allocatedBytes <= SceneBudget.intermediateTextureBytes)
        pool.dispose()
        pool.recycle(second)
        pool.recycle(resized)
        precondition(pool.allocatedBytes == 0)
        let effectPool = GroupTexturePool()
        let count = SceneBudget.maxGroups + 3 * SceneBudget.maxNodes
        guard let a = effectPool.acquire(device: device, size: size, count: count),
              let b = effectPool.acquire(device: device, size: size, count: count) else {
            throw SceneError.invalid("Effect budget allocation failed")
        }
        precondition(effectPool.allocatedBytes <= SceneBudget.intermediateTextureBytes)
        effectPool.dispose()
        effectPool.recycle(a); effectPool.recycle(b)
        precondition(effectPool.allocatedBytes == 0)
    }
    /// Small GPU readback for tests; never used by the display loop.
    func renderProbe(signals: SceneSignals? = nil, dimension: Int = 32) throws -> [UInt8] {
        try renderFrame(signals: signals, width: dimension, height: dimension)
    }
    func renderFrame(signals: SceneSignals? = nil, width: Int, height: Int, sampleVideo: Bool = true, referenceDate: Date? = nil) throws -> [UInt8] {
        guard (32...3840).contains(width), (32...2160).contains(height) else { throw SceneError.invalid("Frame size must be 32–3840 by 32–2160 pixels.") }
        if let signals { updateSignals(signals) }
        try updateText(at: (referenceDate ?? textOrigin).addingTimeInterval(signals?.time ?? 0))
        guard let device = metal.device, let queue else { throw SceneError.invalid("Renderer disposed.") }
        if sampleVideo { updateVideos() }
        let spec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        spec.storageMode = .shared
        spec.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: spec), let command = queue.makeCommandBuffer() else {
            throw SceneError.invalid("Probe allocation failed.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard encode(command, pass, size: CGSize(width: width, height: height)) else { throw SceneError.invalid("Probe encoding failed.") }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw SceneError.invalid("Probe GPU execution failed.") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return bytes
    }
    private static func upload(_ cg: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = cg.width, height = cg.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let pixels = context.data else {
            throw SceneError.invalid("Could not prepare image pixels.")
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let spec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        spec.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: spec) else { throw SceneError.invalid("Could not allocate image texture.") }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    /// Offline decoding has no dependency on AVPlayer wall-clock delivery.
    @MainActor func prepareOfflineVideo(at time: Double, size: CGSize) async throws {
        guard let device = metal.device else { throw SceneError.invalid("Renderer disposed.") }
        for input in inputs where input.node.kind == .video {
            try Task.checkCancellation()
            if input.offlineGenerator == nil, let url = input.node.assetURL {
                input.player?.pause()
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw SceneError.invalid("Offline export needs finite video durations.") }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = size
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                input.offlineGenerator = generator
                input.offlineDuration = duration
            }
            guard let generator = input.offlineGenerator else { throw SceneError.invalid("Missing video source.") }
            let sample = max(0, time).truncatingRemainder(dividingBy: input.offlineDuration)
            let (frame, _) = try await generator.image(at: CMTime(seconds: sample, preferredTimescale: 60000))
            try Task.checkCancellation()
            input.texture = try Self.upload(frame, device: device)
        }
    }

    public func setPreferredFrameRate(_ rate: Int?) {
        guard diagnostics.state != .disposed else { return }
        let targetRate = rate ?? 60
        let requiresHighRefresh = (sourceScene?.usesPointer == true && clock.pointerEnabled) ||
                                  (sourceScene?.usesAudio == true && clock.audioEnabled) ||
                                  (roots.flatMap { $0.descendants }.contains { $0.kind == .particles || $0.kind == .shader })
        metal.preferredFramesPerSecond = requiresHighRefresh ? targetRate : min(targetRate, 60)
    }
    public func setPaused(_ paused: Bool) {
        bindingSmoother.reset()
        guard diagnostics.state != .disposed else { return }
        diagnostics.state = paused ? .paused : .running
        needsFrame = true
        let visible = visibleIDs
        inputs.forEach { input in
            guard input.sharedHub == nil else { return }
            if input.followsClock || paused || !visible.contains(input.node.id) { input.player?.pause() } else { input.player?.play() }
        }
        updateDrawScheduling()
        if !diagnostics.animated || inputs.contains(where: { $0.followsClock }) { metal.draw() }
    }
    public func setMuted(_ muted: Bool) {
        guard diagnostics.state != .disposed else { return }
        inputs.forEach {
            $0.player?.isMuted = muted
            if !muted { $0.player?.volume = 1 }
        }
    }
    public func releaseResources() {
        textTimer?.invalidate(); textTimer = nil
        metal.isPaused = true
        metal.delegate = nil
        inputs.removeAll()
        roots.removeAll()
        sourceScene = nil
        bindingSmoother.reset()
        targets.dispose()
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
        cache = nil
        pipeline = nil
        queue = nil
        metal.releaseDrawables()
        diagnostics.state = .disposed
        diagnostics.activeResources = 0
    }
    deinit { releaseResources() }

    /// Convert the shared AppKit fill rectangle into top-down texture coordinates.
    static func mediaFraming(content: CGSize, aspect: CGFloat, focus: SceneFocus?, bleed: SceneBleed?) -> SIMD4<Float> {
        let bounds = CGRect(x: 0, y: 0, width: aspect, height: 1)
        let frame = (focus ?? .centre).filledFrame(content: content, in: bounds, bleed: bleed)
        return SIMD4(Float(bounds.width / frame.width), Float(bounds.height / frame.height),
                     Float((bounds.midX - frame.midX) / frame.width),
                     Float((frame.midY - bounds.midY) / frame.height))
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4 transform; float4 media; float4 viewport; float4 style; float4 emitter; float4 world; float4 motion; float4 framing; };
    struct V { float4 position [[position]]; float2 uv; float fade; float2 canvasUV; };
    uint randomBits(uint value) {
        value ^= value >> 16; value *= 0x7feb352du; value ^= value >> 15;
        value *= 0x846ca68bu; return value ^ (value >> 16);
    }
    float randomUnit(uint value) { return float(randomBits(value) & 0x00ffffffu) / 16777216.0; }
    vertex V sceneQuad(uint id [[vertex_id]], uint instance [[instance_id]], constant U &u [[buffer(0)]]) {
        float2 p = float2(id & 1, id >> 1) * 2.0 - 1.0;
        float2 local = p;
        float fade = 1;
        if (u.media.w > 1.5) {
            uint seed = uint(u.emitter.w) ^ (instance * 747796405u);
            float age = fmod(u.motion.w + float(instance) / u.motion.z * u.emitter.x, u.emitter.x);
            float phase = age / u.emitter.x;
            fade = smoothstep(0.0, 0.12, phase) * (1.0 - smoothstep(0.75, 1.0, phase));
            float2 origin = float2(randomUnit(seed) * 1.8 - 0.9, randomUnit(seed + 1u) * 1.8 - 0.9);
            float2 velocity = float2(u.motion.x, u.emitter.y * (0.5 + randomUnit(seed + 2u)));
            local = origin + velocity * age + float2(0, 0.5 * u.motion.y * age * age);
            local += float2(p.x * (u.media.w > 2.5 ? u.viewport.z : 1.0) / u.viewport.x, p.y) * u.emitter.z * (0.6 + randomUnit(seed + 3u));
        }
        float2 q = local * float2(u.viewport.x, 1.0) * u.transform.z;
        float c = cos(u.transform.w), s = sin(u.transform.w);
        q = float2(c*q.x - s*q.y, s*q.x + c*q.y) / float2(u.viewport.x, 1.0);
        q += u.transform.xy * 2.0;
        q = q * u.world.xy + u.world.zw;
        return {float4(q, 0, 1), float2((p.x+1)*0.5, (1-p.y)*0.5), fade, float2(local.x * 0.5 + 0.5, 0.5 - local.y * 0.5)};
    }
    float4 styled(float4 pixel, float2 uv, constant U &u) {
        if (u.style.x == 0.0 && u.style.y == 0.0 && u.style.z == 1.0 && u.style.w == 0.0) return pixel * u.media.z;
        float3 color = pixel.rgb / max(pixel.a, 0.00001);
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = clamp(mix(float3(luma), color, u.style.z) * exp2(u.style.y), 0.0, 1.0);
        float2 radial = uv * 2.0 - 1.0;
        color *= 1.0 - u.style.w * smoothstep(0.15, 1.5, dot(radial, radial));
        float coverage = 1.0;
        if (u.style.x > 0.5) {
            float distance = length(uv * 2.0 - 1.0);
            float edge = max(fwidth(distance), 0.0001);
            coverage = 1.0 - smoothstep(1.0 - edge, 1.0, distance);
        }
        return float4(color * pixel.a, pixel.a) * (coverage * u.media.z);
    }
    fragment float4 shade(V v [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> image [[texture(0)]], texture2d<float> original [[texture(1)]]) {

        if (u.media.w > 1.5) {
            if (u.media.w > 2.5) {
                constexpr sampler spriteSample(filter::linear, address::clamp_to_zero);
                return styled(image.sample(spriteSample, v.uv) * v.fade, v.canvasUV, u);
            }
            float r = length(v.uv * 2 - 1);
            float alpha = (1.0 - smoothstep(0.05, 1.0, r)) * v.fade;
            return styled(float4(float3(1.0, 0.72, 0.22) * alpha, alpha), v.canvasUV, u);
        }
        constexpr sampler effectSample(filter::linear, address::clamp_to_edge);
        int mode = int(u.viewport.z);
        float amount = u.viewport.w;
        if (mode == 9 || mode == 10) {
            float4 base = image.sample(effectSample, v.uv);
            float4 mask = original.sample(effectSample, v.uv);
            float coverage = mode == 9 ? mask.a : dot(mask.rgb, float3(0.2126, 0.7152, 0.0722));
            return base * clamp(coverage, 0.0, 1.0);
        }
        if (mode >= 11 && mode <= 13) {
            float4 s = image.sample(effectSample, v.uv), d = original.sample(effectSample, v.uv);
            float a = s.a + d.a * (1.0 - s.a);
            float3 color = mode == 11 ? s.rgb + d.rgb :
                mode == 12 ? s.rgb * (1.0 - d.a) + d.rgb * (1.0 - s.a) + s.rgb * d.rgb :
                s.rgb + d.rgb - s.rgb * d.rgb;
            return float4(clamp(color, 0.0, a), a);
        }
        if (mode == 1 || mode == 2 || mode == 7) {
            float2 step = mode == 2 ? float2(0, amount / 4) : float2(amount / (4 * u.viewport.x), 0);
            float4 result = 0;
            float total = 0;
            for (int i = -4; i <= 4; ++i) {
                float weight = exp(-float(i*i) / 8.0);
                float4 pixel = image.sample(effectSample, v.uv + float(i) * step);
                if (mode == 7) pixel.rgb *= smoothstep(0.55, 0.85, max(pixel.r, max(pixel.g, pixel.b)));
                result += pixel * weight;
                total += weight;
            }
            return result / total;
        }
        if (mode == 3) {
            float4 base = original.sample(effectSample, v.uv);
            float4 glow = image.sample(effectSample, v.uv);
            float a = max(base.a, min(1.0, max(glow.r, max(glow.g, glow.b)) * amount));
            return float4(min(float3(a), base.rgb + glow.rgb * amount), a);
        }
        if (mode == 8) {
            float phase = u.viewport.y * (6.28318530718 / 8.0);
            float2 offset = float2(sin(v.uv.y * 18.0 + phase) / u.viewport.x,
                                   sin(v.uv.x * 15.0 - phase)) * amount;
            return image.sample(effectSample, v.uv + offset);
        }
        if (mode >= 4 && mode <= 6) {
            float4 pixel = image.sample(effectSample, v.uv);
            float3 color = pixel.rgb / max(pixel.a, 0.00001);
            if (mode == 4) color *= exp2(amount);
            if (mode == 5) color = mix(float3(dot(color, float3(0.2126,0.7152,0.0722))), color, amount);
            if (mode == 6) { float2 radial = v.uv * 2 - 1; color *= 1 - amount * smoothstep(0.15, 1.5, dot(radial, radial)); }
            return float4(clamp(color, 0.0, 1.0) * pixel.a, pixel.a);
        }

        if (u.media.w > 0.5) {
            float2 uv = float2(v.uv.x, 1.0-v.uv.y);
            float t = u.viewport.y;
            float wave = 0.5 + 0.5 * sin(uv.x*5.0 + sin(uv.y*3.0+t*0.2)+t*0.15);
            float3 high = mix(float3(0.1,0.6,0.5), float3(0.5,0.15,0.65), wave);
            return styled(float4(mix(float3(0.025,0.035,0.12),high,smoothstep(0.0,1.2,wave*(1.0-uv.y*0.5))),1), v.uv, u);
        }
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float2 mediaUV = (v.uv-0.5)*u.media.xy+0.5+u.framing.xy;
        if (any(mediaUV < 0.0) || any(mediaUV > 1.0)) return float4(0);
        return styled(image.sample(sample, mediaUV), v.uv, u);
    }
    """
}

/// Leases are exclusive until GPU completion. Cached and in-flight textures both
/// count toward the cap, including old sizes retained during a window resize.
private final class GroupTexturePool {
    struct Lease {
        let textures: [MTLTexture]
        let bytes: Int
        let width: Int
        let height: Int
    }
    private let lock = NSLock()
    private var free: [Lease] = []
    private var bytes = 0
    private var disposed = false
    var allocatedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
    func acquire(device: MTLDevice, size: CGSize, count: Int) -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard !disposed else { return nil }
        if count == 0 { return Lease(textures: [], bytes: 0, width: 0, height: 0) }
        guard var extent = SceneBudget.groupTargetSize(width: size.width, height: size.height, count: count) else { return nil }
        let spec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: extent.width, height: extent.height, mipmapped: false)
        spec.storageMode = .private
        spec.usage = [.renderTarget, .shaderRead]
        // Tile layout and alignment are device-specific; pixel bytes alone can
        // underestimate the actual allocation, especially near the budget edge.
        var estimate = device.heapTextureSizeAndAlign(descriptor: spec).size
        while estimate > SceneBudget.intermediateTextureBytes / (2 * count) {
            guard extent.width > 1 || extent.height > 1 else { return nil }
            extent = (max(1, Int(Double(extent.width) * 0.95)), max(1, Int(Double(extent.height) * 0.95)))
            spec.width = extent.width
            spec.height = extent.height
            estimate = device.heapTextureSizeAndAlign(descriptor: spec).size
        }
        if let index = free.firstIndex(where: { $0.width == extent.width && $0.height == extent.height && $0.textures.count == count }) {
            return free.remove(at: index)
        }
        // Drop only idle targets; a previous frame may still be using its lease.
        bytes -= free.reduce(0) { $0 + $1.bytes }
        free.removeAll()
        guard estimate <= (SceneBudget.intermediateTextureBytes - bytes) / count else { return nil }
        var textures: [MTLTexture] = []
        var allocated = 0
        for _ in 0..<count {
            guard let texture = device.makeTexture(descriptor: spec) else { return nil }
            allocated += max(texture.allocatedSize, estimate)
            guard allocated <= SceneBudget.intermediateTextureBytes - bytes else { return nil }
            textures.append(texture)
        }
        bytes += allocated
        return Lease(textures: textures, bytes: allocated, width: extent.width, height: extent.height)
    }
    func recycle(_ lease: Lease) {
        guard !lease.textures.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if disposed { bytes -= lease.bytes } else { free.append(lease) }
    }
    func dispose() {
        lock.lock(); defer { lock.unlock() }
        disposed = true
        bytes -= free.reduce(0) { $0 + $1.bytes }
        free.removeAll()
    }
}


extension MetalSceneRenderer {
    /// Static authored content is rasterized once, never on the animation timer.
    private static func rasterize(_ node: SceneNode, pixelLimit: Int) throws -> CGImage {
        let width = node.typography?.width ?? node.shape?.width ?? 1024
        let height = node.typography?.height ?? node.shape?.height ?? 512
        let scale = min(1, sqrt(Double(pixelLimit) / Double(width * height)))
        let pixelsWide = max(1, Int(Double(width) * scale))
        let pixelsHigh = max(1, Int(Double(height) * scale))
        guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: pixelsWide * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SceneError.invalid("Could not allocate the text or shape texture.")
        }
        context.scaleBy(x: scale, y: scale)
        func color(_ hex: String) -> CGColor {
            let digits = hex.dropFirst(), value = UInt64(digits, radix: 16) ?? 0
            let rgb = digits.count == 8 ? value >> 8 : value
            return CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255,
                alpha: digits.count == 8 ? CGFloat(value & 255) / 255 : 1)
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let text = node.typography {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = text.alignment == .left ? .left : text.alignment == .right ? .right : .center
            paragraph.lineSpacing = text.lineSpacing
            let attributes: [NSAttributedString.Key: Any] = [
                .font: CTFontCreateWithName(text.font as CFString, text.size, nil),
                .foregroundColor: NSColor(cgColor: color(text.fill))!,
                .paragraphStyle: paragraph]
            let string = NSAttributedString(string: text.resolved(at: Date()), attributes: attributes)
            let setter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                CGPath(rect: rect.insetBy(dx: 4, dy: 4), transform: nil), nil)
            CTFrameDraw(frame, context)
        } else if let shape = node.shape {
            context.setFillColor(color(shape.fill)); context.setStrokeColor(color(shape.fill))
            switch shape.primitive {
            case .rectangle: context.fill(rect)
            case .ellipse: context.fillEllipse(in: rect)
            case .roundedRectangle:
                let radius = min(shape.cornerRadius, Double(min(width, height)) / 2)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            case .line:
                context.setLineWidth(min(shape.lineWidth, Double(height)))
                context.move(to: CGPoint(x: 0, y: height / 2))
                context.addLine(to: CGPoint(x: width, y: height / 2)); context.strokePath()
            }
        }
        guard let image = context.makeImage() else { throw SceneError.invalid("Could not finish the text or shape texture.") }
        return image
    }
}
