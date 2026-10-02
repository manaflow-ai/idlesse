import Foundation

public struct SceneTimeline: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable { case once, loop, pingPong }
    var duration: Double
    var mode: Mode
    var rate: Double = 1
    var videosFollowScene: Bool = false
    enum CodingKeys: String, CodingKey { case duration, mode, rate, videosFollowScene }
    init(duration: Double, mode: Mode, rate: Double = 1, videosFollowScene: Bool = false) {
        self.duration = duration; self.mode = mode; self.rate = rate; self.videosFollowScene = videosFollowScene
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        duration = try values.decode(Double.self, forKey: .duration)
        mode = try values.decode(Mode.self, forKey: .mode)
        rate = try values.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        videosFollowScene = try values.decodeIfPresent(Bool.self, forKey: .videosFollowScene) ?? false
    }
    func validate() throws {
        guard !videosFollowScene || mode != .pingPong else {
            throw SceneError.invalid("Video transport supports Once and Loop. Disable video following to use Ping-pong.")
        }
        guard duration.isFinite, (0.01...86400).contains(duration),
              rate.isFinite, (0.1...4).contains(rate) else {
            throw SceneError.invalid("Use a duration of 0.01–86400 seconds and speed of 0.1–4.")
        }
    }
}


/// Which part of an over-sized frame survives the crop when a scene's aspect does
/// not match the display's. Unit coordinates from the top-left, so `(0.5, 0.5)` is
/// the centre and matches what AVFoundation's own fill does on its own.
///
/// Exports are 16:9 and displays are not, so something is always cropped. Art is
/// rarely centred: a subject sits to one side and a low-detail bleed margin runs
/// off the other, precisely so a crop has somewhere to go. A centred crop spends
/// the subject and the bleed equally, which is the one split that is never right.
struct SceneFocus: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    static let centre = SceneFocus(x: 0.5, y: 0.5)
    /// Clamped rather than rejected: a focus slightly outside the frame is a
    /// harmless authoring slip, and refusing to draw a wallpaper over it is worse.
    var clamped: SceneFocus { SceneFocus(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }

    /// Where to put `content` so it covers `bounds` with this point kept in view,
    /// and with any declared `bleed` margin kept off screen.
    ///
    /// Without bleed this is AVFoundation's own cover scale and only the offset
    /// differs. Bleed adds a floor to the scale — enough that the region inside
    /// the margin can cover the display on its own — and clamps the offset so the
    /// margin stays outside. Where the natural cover already crops more than the
    /// margin, as a narrow display does to a wide frame, both are inert and the
    /// result is unchanged.
    ///
    /// Layer geometry runs bottom-up while a focus is quoted from the top, hence
    /// the flip on y. Degenerate sizes fall back to the bounds, which renders as
    /// the centred fill rather than as nothing.
    func filledFrame(content: CGSize, in bounds: CGRect, bleed: SceneBleed? = nil) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let point = clamped
        let margin = (bleed ?? SceneBleed()).clamped
        let safe = CGSize(width: content.width * max(1 - margin.left - margin.right, 0.05),
                          height: content.height * max(1 - margin.top - margin.bottom, 0.05))
        let scale = max(bounds.width / content.width, bounds.height / content.height,
                        bounds.width / safe.width, bounds.height / safe.height)
        let filled = CGSize(width: content.width * scale, height: content.height * scale)
        // `lead` is the margin nearest the axis origin in layer terms, `trail` the
        // far one; `t` slides the content from showing its lead edge to its trail.
        func offset(span: CGFloat, across: CGFloat, lead: Double, trail: Double, t: Double) -> CGFloat {
            let value = -(span - across) * CGFloat(t)
            let atLeast = across - span * CGFloat(1 - trail)
            let atMost = -span * CGFloat(lead)
            // When the margins exactly determine the position the interval is a
            // single point, and rounding can make it look empty by a hair; when
            // they genuinely overlap it is empty for real. Splitting the limits
            // covers both without a cliff between them.
            guard atLeast <= atMost else { return (atLeast + atMost) / 2 }
            return min(max(value, atLeast), atMost)
        }
        return CGRect(x: bounds.minX + offset(span: filled.width, across: bounds.width,
                                              lead: margin.left, trail: margin.right, t: point.x),
                      y: bounds.minY + offset(span: filled.height, across: bounds.height,
                                              lead: margin.bottom, trail: margin.top, t: 1 - point.y),
                      width: filled.width, height: filled.height)
    }

    /// The part of the frame a display of `display` size actually shows, in unit
    /// coordinates from the top-left: `filledFrame` read backwards, so an editor
    /// can outline each display over the whole frame instead of guessing.
    func visibleRegion(content: CGSize, display: CGSize, bleed: SceneBleed? = nil) -> CGRect {
        let bounds = CGRect(origin: .zero, size: display)
        let frame = filledFrame(content: content, in: bounds, bleed: bleed)
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let width = bounds.width / frame.width, height = bounds.height / frame.height
        // Layer y runs bottom-up: the top of the display sits at maxY.
        return CGRect(x: (bounds.minX - frame.minX) / frame.width,
                      y: (frame.maxY - bounds.maxY) / frame.height,
                      width: width, height: height)
    }
}

/// Margin the artist painted past the intended composition so that a crop has
/// somewhere to go, as unit fractions of each edge. Declaring it lets every
/// display crop at least that much: a panel matching the export's aspect crops
/// nothing on its own and would otherwise show the margin, while a narrower one
/// already crops more and is left alone.
///
/// This is not matte. Matte is the renderer's background showing through a frame
/// the camera failed to cover, and is a defect to fix in the recipe.
struct SceneBleed: Codable, Sendable, Equatable {
    var top: Double = 0
    var left: Double = 0
    var bottom: Double = 0
    var right: Double = 0
    var isEmpty: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
    init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    /// Every edge is optional. A synthesized decoder would demand all four, so
    /// `{"right": 0.05}` — the shape anyone would actually write for a margin on
    /// one side — would throw, and a swallowed throw means framing just vanishes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
        left = try c.decodeIfPresent(Double.self, forKey: .left) ?? 0
        bottom = try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
        right = try c.decodeIfPresent(Double.self, forKey: .right) ?? 0
    }
    /// Clamped so a slip cannot ask for more margin than there is frame.
    var clamped: SceneBleed {
        let unit = { (v: Double) in min(max(v, 0), 0.45) }
        return SceneBleed(top: unit(top), left: unit(left), bottom: unit(bottom), right: unit(right))
    }
}

/// Metadata only: resolving a scene never retains decoded pixels or a player.
public struct SceneDescriptor: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case image, video, gradient, group, particles, text, shape, shader }
    enum Canvas: String, Codable, Sendable { case perDisplay, desktopSpan }
    var canvas: Canvas? = nil
    /// Absent means centred, which is exactly the previous behaviour.
    var focus: SceneFocus? = nil
    /// Margin every display should crop away before filling. Absent means none.
    var bleed: SceneBleed? = nil
    var metadata: SceneMetadata? = nil
    var components: [String: SceneComponent]? = nil
    public let title: String
    let nodes: [SceneNode]
    var parameters: [String: SceneParameter] = [:]
    var bindings: [SceneParameterBinding] = []
    public var timeline: SceneTimeline? = nil
    var variants: [SceneVariant] = []
    var assetURL: URL? { nodes.first?.assetURL }
    var kind: Kind { nodes.first?.kind ?? .image }
    var allNodes: [SceneNode] { nodes.flatMap { $0.descendants } }
    var assetNodes: [SceneNode] { allNodes + (components?.values.flatMap { $0.node.descendants } ?? []) }
    var usesSmoothing: Bool { bindings.contains { $0.smoothing > 0 } }
    var usesTracks: Bool { bindings.contains { $0.keyframes != nil } }
    var usesSignals: Bool { usesTracks || bindings.contains { $0.signal != nil } }
    var usesDrivers: Bool { bindings.contains { !$0.modifiers.isEmpty } }
    var usesAudio: Bool { bindings.contains { $0.signal?.rawValue.hasPrefix("audio.") == true } }
    var usesPointer: Bool { bindings.contains { $0.signal == .pointerX || $0.signal == .pointerY } }
    var usesTime: Bool { usesTracks || bindings.contains { $0.signal == .time || $0.signal == .sine } }
    var requiresMetal: Bool { parameters.values.contains { !$0.targets.isEmpty } || canvas == .desktopSpan || timeline != nil || usesDrivers || usesSignals || allNodes.contains { $0.style != .plain || [.particles, .text, .shape, .shader].contains($0.kind) || $0.needsComposition } || bindings.contains { [.exposure, .saturation, .vignette].contains($0.target.property) } }
    var animated: Bool {
        if usesSignals || nodes.contains(where: { $0.animated }) { return true }
        let referenced = Set(allNodes.compactMap { $0.maskNodeID })
        return allNodes.filter { referenced.contains($0.id) }.flatMap { $0.descendants }.contains {
            $0.hasAnimatedEffects || [.video, .gradient, .particles, .shader].contains($0.kind)
        }
    }
    init(title: String, assetURL: URL, kind: Kind) {
        self.title = title
        self.nodes = [SceneNode(content: kind == .video ? .video(assetURL) : .image(assetURL))]
    }
    init(title: String, nodes: [SceneNode], parameters: [String: SceneParameter] = [:], bindings: [SceneParameterBinding] = [], timeline: SceneTimeline? = nil, canvas: Canvas? = nil, metadata: SceneMetadata? = nil, components: [String: SceneComponent]? = nil, variants: [SceneVariant] = [], focus: SceneFocus? = nil, bleed: SceneBleed? = nil) {
        self.title = title; self.nodes = nodes; self.parameters = parameters; self.bindings = bindings; self.timeline = timeline; self.canvas = canvas; self.metadata = metadata; self.components = components; self.variants = variants; self.focus = focus; self.bleed = bleed
    }
    enum CodingKeys: String, CodingKey { case canvas, metadata, components, title, nodes, parameters, bindings, timeline, variants, focus, bleed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focus = try c.decodeIfPresent(SceneFocus.self, forKey: .focus)
        bleed = try c.decodeIfPresent(SceneBleed.self, forKey: .bleed)
        canvas = try c.decodeIfPresent(Canvas.self, forKey: .canvas)
        metadata = try c.decodeIfPresent(SceneMetadata.self, forKey: .metadata)
        components = try c.decodeIfPresent([String: SceneComponent].self, forKey: .components)
        title = try c.decode(String.self, forKey: .title)
        nodes = try c.decode([SceneNode].self, forKey: .nodes)
        parameters = try c.decodeIfPresent([String: SceneParameter].self, forKey: .parameters) ?? [:]
        bindings = try c.decodeIfPresent([SceneParameterBinding].self, forKey: .bindings) ?? []
        timeline = try c.decodeIfPresent(SceneTimeline.self, forKey: .timeline)
        variants = try c.decodeIfPresent([SceneVariant].self, forKey: .variants) ?? []
    }
    func replacingNodes(_ nodes: [SceneNode]) -> SceneDescriptor {
        let ids = Set(nodes.flatMap { $0.descendants }.map(\.id))
        var controls = parameters
        for key in controls.keys { controls[key]?.targets.removeAll { !ids.contains($0.nodeID) } }
        return SceneDescriptor(title: title, nodes: nodes, parameters: controls, bindings: bindings.filter { ids.contains($0.target.nodeID) && (try? $0.target.value(in: nodes)) != nil }, timeline: timeline, canvas: canvas, metadata: metadata, components: components, variants: variants, focus: focus, bleed: bleed)
    }
    func duplicatingBindings(from source: SceneNode, to copy: SceneNode) -> SceneDescriptor {
        let pairs = zip(source.descendants, copy.descendants)
        var result = self
        for (old, new) in pairs {
            for key in parameters.keys {
                for target in parameters[key]!.targets where target.nodeID == old.id {
                    result.parameters[key]?.targets.append(.init(nodeID: new.id, property: target.property))
                }
            }
            let effectMap = Dictionary(uniqueKeysWithValues: zip(old.style.effects.compactMap(\.id), new.style.effects.compactMap(\.id)))
            for binding in bindings where binding.target.nodeID == old.id {
                var cloned = binding
                cloned.target = ScenePropertyAddress(nodeID: new.id, property: binding.target.property,
                    effectID: binding.target.effectID.flatMap { effectMap[$0] })
                result.bindings.append(cloned)
            }
        }
        return result
    }
    func evaluated(signals: SceneSignals = .init(), validating: Bool = true, smooth: ((ScenePropertyAddress, Double, Double) -> Double)? = nil) throws -> SceneDescriptor {
        if let focus, !focus.x.isFinite || !focus.y.isFinite { throw SceneError.invalid("Focus coordinates must be finite.") }
        if validating {
            try metadata?.validate()
            guard (components?.count ?? 0) <= 8 else { throw SceneError.invalid("Use at most eight package-local presets.") }
            for (id, component) in components ?? [:] {
                guard UUID(uuidString: id) != nil else { throw SceneError.invalid("Preset identities must be UUIDs.") }
                try component.validate()
            }
            guard allNodes.allSatisfy({ $0.componentID == nil || components?[$0.componentID!] != nil }) else { throw SceneError.invalid("A layer references a missing local preset.") }
            try timeline?.validate()
            guard parameters.count <= 16, bindings.count <= 64 else { throw SceneError.invalid("Use at most 16 parameters and 64 bindings.") }
            for (id, parameter) in parameters {
                guard !id.isEmpty, id.utf8.count <= 64, !parameter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, parameter.name.count <= 80,
                      parameter.isValid else {
                    throw SceneError.invalid("Parameters need a name and a valid typed default within their limits.")
                }
            }
            try SceneVariant.validate(variants)
        }
        var result = nodes
        var controlTargets = Set<SceneControlTarget>()
        for parameter in parameters.values {
            guard parameter.targets.count <= 16 else { throw SceneError.invalid("Use at most 16 targets per control.") }
            for target in parameter.targets {
                guard controlTargets.insert(target).inserted else { throw SceneError.invalid("Each content property can have only one control.") }
                try target.apply(parameter, to: &result)
            }
        }
        var targets = Set<ScenePropertyAddress>()
        for binding in bindings {
            guard binding.scale.isFinite, binding.offset.isFinite,
                  (!validating || targets.insert(binding.target).inserted) else {
                throw SceneError.invalid("Bindings need an existing parameter and a unique property target.")
            }
            guard binding.smoothing.isFinite, (0...5).contains(binding.smoothing),
                  binding.smoothing == 0 || binding.signal != nil || binding.keyframes != nil else {
                throw SceneError.invalid("Smoothing needs a signal or keyframe source and a duration of 0–5 seconds.")
            }
            let source: Double
            if let track = binding.keyframes {
                guard binding.signal == nil, binding.parameter.isEmpty else { throw SceneError.invalid("A keyframe track cannot also have a signal or parameter source.") }
                source = try track.sample(at: signals.time, validating: validating)
            } else if let signal = binding.signal {
                guard binding.parameter.isEmpty, binding.period.isFinite, (0.1...86400).contains(binding.period) else {
                    throw SceneError.invalid("Signal bindings need a period of 0.1–86400 seconds and no parameter source.")
                }
                switch signal {
                case .time: source = signals.time
                case .sine: source = sin(signals.time.truncatingRemainder(dividingBy: binding.period) / binding.period * 2 * .pi)
                case .pointerX: source = signals.pointerX
                case .pointerY: source = signals.pointerY
                case .audioLevel: source = signals.audio.level
                case .audioBass: source = signals.audio.bass
                case .audioMid: source = signals.audio.mid
                case .audioTreble: source = signals.audio.treble
                }
            } else {
                guard let parameter = parameters[binding.parameter], parameter.type == .number else { throw SceneError.invalid("Motion bindings require a numeric parameter.") }
                source = parameter.value
            }
            var raw = source * binding.scale + binding.offset
            guard binding.modifiers.count <= 8 else { throw SceneError.invalid("Use at most eight modifiers per binding.") }
            for modifier in binding.modifiers {
                guard raw.isFinite else { throw SceneError.invalid("The binding result is not finite.") }
                let operand: Double
                if let key = modifier.parameter {
                    guard modifier.value == nil, let parameter = parameters[key], parameter.type == .number else {
                        throw SceneError.invalid("A modifier needs one existing parameter or constant.")
                    }
                    operand = parameter.value
                } else {
                    guard let value = modifier.value else { throw SceneError.invalid("A modifier needs an operand.") }
                    operand = value
                }
                guard operand.isFinite else { throw SceneError.invalid("Modifier operands must be finite.") }
                switch modifier.operation {
                case .multiply: raw *= operand
                case .add: raw += operand
                }
            }
            guard raw.isFinite else { throw SceneError.invalid("The binding result is not finite.") }
            if binding.smoothing > 0, let smooth { raw = smooth(binding.target, raw, binding.smoothing) }
            let range = try binding.target.range(in: nodes)
            try binding.target.set(Swift.min(range.upperBound, Swift.max(range.lowerBound, raw)), in: &result)
        }
        if validating { try SceneBudget.validate(result) }
        for id in result.flatMap({ $0.descendants }).map(\.id) {
            _ = SceneTree.edit(id, in: &result) { siblings, index in siblings[index].componentID = nil }
        }
        return SceneDescriptor(title: title, nodes: result, canvas: canvas, focus: focus, bleed: bleed)
    }
}

/// Package-local reusable snapshots. Insertion expands to ordinary nodes and independent
/// controls; later edits do not silently propagate to another instance.
struct SceneComponent: Codable, Sendable {
    var name: String
    var node: SceneNode
    var parameters: [String: SceneParameter]
    var bindings: [SceneParameterBinding]
    var scene: SceneDescriptor { .init(title: name, nodes: [node], parameters: parameters, bindings: bindings) }
    func validate() throws {
        guard !name.isEmpty, name.count <= 120, node.descendants.allSatisfy({ $0.componentID == nil }) else {
            throw SceneError.invalid("Presets need a name and cannot contain other preset references.")
        }
        _ = try scene.evaluated()
    }
    static func capture(_ node: SceneNode, from scene: SceneDescriptor) throws -> SceneComponent {
        let ids = Set(node.descendants.map(\.id))
        guard node.descendants.allSatisfy({ $0.maskNodeID.map(ids.contains) ?? true }) else {
            throw SceneError.invalid("Include the mask layer in the selected group before creating a preset.")
        }
        func strip(_ node: SceneNode) -> SceneNode {
            var result = node; result.componentID = nil
            if node.kind == .group { result.content = .group(node.children.map(strip)) }
            return result
        }
        let bindings = scene.bindings.filter { ids.contains($0.target.nodeID) }
        let keys = Set(bindings.map(\.parameter) + bindings.flatMap { $0.modifiers.compactMap(\.parameter) })
        var parameters = scene.parameters.filter { keys.contains($0.key) || $0.value.targets.contains { ids.contains($0.nodeID) } }
        for key in parameters.keys { parameters[key]?.targets.removeAll { !ids.contains($0.nodeID) } }
        let component = SceneComponent(name: node.displayName, node: strip(node), parameters: parameters, bindings: bindings)
        try component.validate(); return component
    }
    func inserting(into scene: SceneDescriptor, id: String) throws -> SceneDescriptor {
        try validate()
        guard scene.components?[id] != nil else { throw SceneError.invalid("This preset is not in the current package.") }
        var root = node.duplicated(); root.componentID = id
        let instanceNumber = scene.allNodes.filter { $0.componentID == id }.count + 1
        root.name = String("\(name) \(instanceNumber)".prefix(120))
        let pairs = Array(zip(node.descendants, root.descendants))
        let nodes = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1.id) })
        let effects = Dictionary(uniqueKeysWithValues: pairs.flatMap { Array(zip($0.0.style.effects.compactMap(\.id), $0.1.style.effects.compactMap(\.id))) })
        let keys = Dictionary(uniqueKeysWithValues: parameters.keys.map { ($0, UUID().uuidString) })
        var next = scene.replacingNodes(scene.nodes + [root])
        for (key, parameter) in parameters {
            var cloned = parameter
            cloned.name = String("\(root.displayName) · \(parameter.name)".prefix(80))
            cloned.targets = parameter.targets.map { .init(nodeID: nodes[$0.nodeID]!, property: $0.property) }
            next.parameters[keys[key]!] = cloned
        }
        for binding in bindings {
            var cloned = binding
            cloned.target = .init(nodeID: nodes[binding.target.nodeID]!, property: binding.target.property,
                effectID: binding.target.effectID.flatMap { effects[$0] })
            if !binding.parameter.isEmpty { cloned.parameter = keys[binding.parameter]! }
            for index in cloned.modifiers.indices {
                cloned.modifiers[index].parameter = binding.modifiers[index].parameter.flatMap { keys[$0] }
            }
            next.bindings.append(cloned)
        }
        _ = try next.evaluated() // Expanded instances share the existing scene budgets.
        return next
    }
}

struct SceneMetadata: Codable, Sendable, Equatable {
    var author: String? = nil
    var description: String? = nil
    var tags: [String]? = nil
    var license: String? = nil
    var createdWith: String? = nil
    var previewTime: Double? = nil
    func validate() throws {
        guard (author?.utf8.count ?? 0) <= 160, (description?.utf8.count ?? 0) <= 4096,
              (license?.utf8.count ?? 0) <= 1024, (createdWith?.utf8.count ?? 0) <= 160,
              (tags?.count ?? 0) <= 32, tags?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              previewTime.map({ $0.isFinite && (0...86400).contains($0) }) ?? true else {
            throw SceneError.invalid("Scene metadata exceeds its limits or has an invalid preview time.")
        }
    }
}

/// Revision 21 freezes the container; feature names describe subsequent additions.
/// Legacy revisions retain their explicit decode gates below and normalize to SceneDescriptor.
enum SceneFormat {
    static let revision = 21
    static let supported: Set<String> = ["groups", "particles", "effects", "composition", "desktop-span", "motion", "typed-controls", "text", "shapes", "local-presets", "dynamic-text", "shaders", "variants", "focus"]
    static func features(_ scene: SceneDescriptor) -> Set<String> {
        var result = Set<String>()
        if scene.focus != nil { result.insert("focus") }
        if scene.allNodes.contains(where: { $0.kind == .group }) { result.insert("groups") }
        if scene.allNodes.contains(where: { $0.kind == .particles }) { result.insert("particles") }
        if scene.allNodes.contains(where: { $0.style != .plain }) { result.insert("effects") }
        if scene.allNodes.contains(where: { $0.needsComposition || $0.sprite != nil }) { result.insert("composition") }
        if scene.canvas == .desktopSpan { result.insert("desktop-span") }
        if !scene.bindings.isEmpty || scene.timeline != nil { result.insert("motion") }
        if scene.parameters.values.contains(where: { $0.type != .number || !$0.targets.isEmpty }) { result.insert("typed-controls") }
        if !scene.variants.isEmpty { result.insert("variants") }
        if scene.allNodes.contains(where: { $0.kind == .text }) { result.insert("text") }
        if scene.allNodes.contains(where: { $0.typography?.liveSource != nil }) { result.insert("dynamic-text") }
        if scene.allNodes.contains(where: { $0.kind == .shape }) { result.insert("shapes") }
        if scene.allNodes.contains(where: { $0.kind == .shader }) { result.insert("shaders") }
        if !(scene.components?.isEmpty ?? true) { result.insert("local-presets") }
        for component in scene.components?.values ?? Dictionary<String, SceneComponent>().values {
            result.formUnion(features(component.scene))
        }
        return result
    }
}

struct SceneControlTarget: Codable, Sendable, Hashable {
    enum Property: String, Codable, Sendable { case visible, blend, text, fill }
    var nodeID: UUID
    var property: Property
    func apply(_ parameter: SceneParameter, to nodes: inout [SceneNode]) throws {
        guard let node = nodes.flatMap({ $0.descendants }).first(where: { $0.id == nodeID }) else { throw SceneError.invalid("A control target is missing.") }
        var replacement = node
        switch property {
        case .visible:
            guard parameter.type == .boolean else { throw SceneError.invalid("Visibility needs a toggle control.") }
            replacement.visible = parameter.boolean
        case .blend:
            guard parameter.type == .choice, parameter.choices.allSatisfy({ SceneNode.Blend(rawValue: $0) != nil }),
                  let blend = SceneNode.Blend(rawValue: parameter.text) else { throw SceneError.invalid("Blend choices must be normal, add, multiply or screen.") }
            replacement.blend = blend
        case .text:
            guard parameter.type == .string, var text = node.typography else { throw SceneError.invalid("Text controls need a text layer.") }
            text.text = parameter.text; replacement.content = .text(text)
        case .fill:
            guard parameter.type == .color else { throw SceneError.invalid("Fill needs a color control.") }
            if var text = node.typography { text.fill = parameter.text; replacement.content = .text(text) }
            else if var shape = node.shape { shape.fill = parameter.text; replacement.content = .shape(shape) }
            else { throw SceneError.invalid("Fill controls need a text or shape layer.") }
        }
        _ = SceneTree.edit(nodeID, in: &nodes) { siblings, index in siblings[index] = replacement }
    }
}

struct SceneParameter: Codable, Sendable, Equatable {
    enum ValueType: String, Codable, Sendable { case number, boolean, color, choice, string }
    var name: String
    var value: Double
    var min: Double
    var max: Double
    var type: ValueType = .number
    var text: String = ""
    var boolean: Bool = false
    var choices: [String] = []
    var targets: [SceneControlTarget] = []
    init(name: String, value: Double, min: Double, max: Double) {
        self.name = name; self.value = value; self.min = min; self.max = max
    }
    init(name: String, type: ValueType, text: String = "", boolean: Bool = false, choices: [String] = []) {
        self.init(name: name, value: 0, min: 0, max: 1)
        self.type = type; self.text = text; self.boolean = boolean; self.choices = choices
    }
    var isValid: Bool {
        switch type {
        case .number: return [value, min, max, max - min].allSatisfy(\.isFinite) && min < max && (min...max).contains(value)
        case .boolean: return choices.isEmpty
        case .color: return text.range(of: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$", options: .regularExpression) != nil && choices.isEmpty
        case .string: return text.utf8.count <= 4096 && choices.isEmpty
        case .choice: return (1...32).contains(choices.count) && Set(choices).count == choices.count && choices.allSatisfy { !$0.isEmpty && $0.utf8.count <= 120 } && choices.contains(text)
        }
    }
    enum CodingKeys: String, CodingKey { case name, value = "default", min, max, type, choices, targets }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(ValueType.self, forKey: .type) ?? .number
        value = 0; min = 0; max = 1
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        targets = try c.decodeIfPresent([SceneControlTarget].self, forKey: .targets) ?? []
        switch type {
        case .number:
            value = try c.decode(Double.self, forKey: .value)
            min = try c.decode(Double.self, forKey: .min); max = try c.decode(Double.self, forKey: .max)
        case .boolean: boolean = try c.decode(Bool.self, forKey: .value)
        case .color, .choice, .string: text = try c.decode(String.self, forKey: .value)
        }
        guard isValid else { throw SceneError.invalid("Invalid typed parameter default or limits.") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !targets.isEmpty { try c.encode(targets, forKey: .targets) }
        // Keep the original numeric encoding readable by older scene versions.
        if type != .number { try c.encode(type, forKey: .type) }
        switch type {
        case .number:
            try c.encode(value, forKey: .value); try c.encode(min, forKey: .min); try c.encode(max, forKey: .max)
        case .boolean: try c.encode(boolean, forKey: .value)
        case .color, .choice, .string: try c.encode(text, forKey: .value)
        }
        if type == .choice { try c.encode(choices, forKey: .choices) }
    }
}


enum SceneControlValue: Codable, Sendable, Equatable {
    case number(Double)
    case boolean(Bool)
    case text(String)

    init(_ parameter: SceneParameter) {
        switch parameter.type {
        case .number: self = .number(parameter.value)
        case .boolean: self = .boolean(parameter.boolean)
        case .color, .choice, .string: self = .text(parameter.text)
        }
    }

    var structurallyValid: Bool {
        switch self {
        case .number(let value): return value.isFinite
        case .boolean: return true
        case .text(let value): return value.utf8.count <= 4096
        }
    }

    func applying(to parameter: SceneParameter) -> SceneParameter? {
        var result = parameter
        switch (self, parameter.type) {
        case (.number(let value), .number):
            guard value.isFinite, (parameter.min...parameter.max).contains(value) else { return nil }
            result.value = value
        case (.boolean(let value), .boolean):
            result.boolean = value
        case (.text(let value), .color), (.text(let value), .choice), (.text(let value), .string):
            result.text = value
        default:
            return nil
        }
        return result.isValid ? result : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .text(value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Variant control values must be JSON scalars.") }
        guard structurallyValid else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Variant control value exceeds its limits.")
        }
    }

    func encode(to encoder: Encoder) throws {
        guard structurallyValid else { throw SceneError.invalid("Variant control value exceeds its limits.") }
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let value): try c.encode(value)
        case .boolean(let value): try c.encode(value)
        case .text(let value): try c.encode(value)
        }
    }
}

struct SceneVariant: Codable, Sendable, Equatable {
    static let maximumCount = 16
    static let maximumOverrides = 16
    static let maximumEncodedBytes = 16 * 1024

    var id: UUID
    var name: String
    var values: [String: SceneControlValue]

    static func validate(_ variants: [SceneVariant]) throws {
        guard variants.count <= maximumCount else { throw SceneError.invalid("Use at most 16 scene variants.") }
        guard Set(variants.map(\.id)).count == variants.count else { throw SceneError.invalid("Scene variant identities must be unique.") }
        var names = Set<String>()
        for variant in variants {
            let trimmed = variant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, variant.name.count <= 80,
                  names.insert(trimmed.lowercased()).inserted else {
                throw SceneError.invalid("Scene variants need unique names of 1–80 characters.")
            }
            guard variant.values.count <= maximumOverrides else { throw SceneError.invalid("Use at most 16 overrides per scene variant.") }
            for (key, value) in variant.values {
                guard !key.isEmpty, key.utf8.count <= 64, value.structurallyValid else {
                    throw SceneError.invalid("Scene variant overrides exceed their control/value limits.")
                }
            }
        }
        let encoded = try JSONEncoder().encode(variants)
        guard encoded.count <= maximumEncodedBytes else { throw SceneError.invalid("Scene variant data exceeds 16 KiB.") }
    }
}

struct SceneVariantDiagnostic: Sendable, Equatable {
    enum Reason: String, Sendable { case variantUnavailable, missingControl, incompatibleValue }
    let variantID: UUID?
    let controlID: String?
    let reason: Reason
}

struct SceneVariantApplication: Sendable {
    let scene: SceneDescriptor
    let selectedVariantID: UUID?
    let diagnostics: [SceneVariantDiagnostic]
}

extension SceneDescriptor {
    /// Apply only to the canonical authored descriptor. Runtime control edits belong in
    /// a separate layer above this result so switching variants always starts from Default.
    func applyingVariant(id: UUID?) -> SceneVariantApplication {
        guard let id else {
            return SceneVariantApplication(scene: self, selectedVariantID: nil, diagnostics: [])
        }
        guard let variant = variants.first(where: { $0.id == id }) else {
            return SceneVariantApplication(scene: self, selectedVariantID: nil,
                diagnostics: [.init(variantID: id, controlID: nil, reason: .variantUnavailable)])
        }
        var applied = self
        var diagnostics: [SceneVariantDiagnostic] = []
        for key in variant.values.keys.sorted() {
            guard let value = variant.values[key] else { continue }
            guard let parameter = applied.parameters[key] else {
                diagnostics.append(.init(variantID: id, controlID: key, reason: .missingControl))
                continue
            }
            guard let replacement = value.applying(to: parameter) else {
                diagnostics.append(.init(variantID: id, controlID: key, reason: .incompatibleValue))
                continue
            }
            applied.parameters[key] = replacement
        }
        return SceneVariantApplication(scene: applied, selectedVariantID: id, diagnostics: diagnostics)
    }
}

struct SceneKeyframeTrack: Codable, Sendable, Equatable {
    enum Interpolation: String, Codable, Sendable { case hold, linear, easeInOut }
    struct Key: Codable, Sendable, Equatable { var time: Double; var value: Double }
    var interpolation: Interpolation = .linear
    var keys: [Key]
    func movingKey(at index: Int, to time: Double) throws -> SceneKeyframeTrack {
        _ = try sample(at: 0)
        guard keys.indices.contains(index), time.isFinite else { throw SceneError.invalid("Choose an existing key and finite time.") }
        let lower = index == 0 ? 0 : keys[index - 1].time.nextUp
        let upper = index == keys.count - 1 ? 86400 : keys[index + 1].time.nextDown
        var result = self
        result.keys[index].time = min(upper, max(lower, time))
        return result
    }
    func sample(at time: Double, validating: Bool = true) throws -> Double {
        guard !keys.isEmpty, keys.count <= 128, time.isFinite else { throw SceneError.invalid("A track needs 1–128 keys and a finite sample time.") }
        if validating {
            var previous = -1.0
            for key in keys {
                guard key.time.isFinite, (0...86400).contains(key.time), key.time > previous,
                      key.value.isFinite, abs(key.value) <= 1_000_000 else {
                    throw SceneError.invalid("Key times must increase within 0–86400 seconds; values must be finite and within ±1000000.")
                }
                previous = key.time
            }
        }
        guard time > keys[0].time else { return keys[0].value }
        for index in 1..<keys.count where time < keys[index].time {
            let a = keys[index - 1], b = keys[index]
            var t = (time - a.time) / (b.time - a.time)
            switch interpolation {
            case .hold: t = 0
            case .linear: break
            case .easeInOut: t = t * t * (3 - 2 * t)
            }
            return a.value + (b.value - a.value) * t
        }
        return keys[keys.count - 1].value
    }
}

struct SceneParameterBinding: Codable, Sendable {
    struct Modifier: Codable, Sendable {
        enum Operation: String, Codable, Sendable { case multiply, add }
        var operation: Operation
        var parameter: String? = nil
        var value: Double? = nil
    }
    enum Signal: String, Codable, Sendable { case time, sine, pointerX = "pointer.x", pointerY = "pointer.y", audioLevel = "audio.level", audioBass = "audio.bass", audioMid = "audio.mid", audioTreble = "audio.treble" }
    var target: ScenePropertyAddress
    var parameter: String = ""
    var scale: Double = 1
    var offset: Double = 0
    var signal: Signal? = nil
    var period: Double = 8
    var smoothing: Double = 0
    var keyframes: SceneKeyframeTrack? = nil
    var modifiers: [Modifier] = []
    var referencedParameters: [String] { (parameter.isEmpty ? [] : [parameter]) + modifiers.compactMap(\.parameter) }
    enum CodingKeys: String, CodingKey { case target, parameter, scale, offset, signal, period, modifiers, keyframes, smoothing }
    init(target: ScenePropertyAddress, parameter: String = "", scale: Double = 1, offset: Double = 0, signal: Signal? = nil, period: Double = 8, modifiers: [Modifier] = [], keyframes: SceneKeyframeTrack? = nil, smoothing: Double = 0) {
        self.target = target; self.parameter = parameter; self.scale = scale; self.offset = offset; self.signal = signal; self.period = period
        self.modifiers = modifiers; self.keyframes = keyframes; self.smoothing = smoothing
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(ScenePropertyAddress.self, forKey: .target)
        parameter = try values.decodeIfPresent(String.self, forKey: .parameter) ?? ""
        scale = try values.decode(Double.self, forKey: .scale)
        offset = try values.decode(Double.self, forKey: .offset)
        signal = try values.decodeIfPresent(Signal.self, forKey: .signal)
        period = try values.decodeIfPresent(Double.self, forKey: .period) ?? 8
        smoothing = try values.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0
        keyframes = try values.decodeIfPresent(SceneKeyframeTrack.self, forKey: .keyframes)
        modifiers = try values.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []
    }
}

public struct SceneAudioLevels: Sendable {
    public init(level: Double = 0, bass: Double = 0, mid: Double = 0, treble: Double = 0) {
        self.level = level; self.bass = bass; self.mid = mid; self.treble = treble
    }
    public var level: Double = 0
    public var bass: Double = 0
    public var mid: Double = 0
    public var treble: Double = 0
}

struct SceneSignals: Sendable {
    var audio = SceneAudioLevels()
    var time: Double = 0
    var pointerX: Double = 0
    var pointerY: Double = 0
}

struct SceneNode: Codable, Sendable {
    var id = UUID() // Persisted in v6 packages; duplication assigns fresh identities.
    var componentID: String? = nil // Provenance only; instances are independent editable snapshots.
    struct Emitter: Codable, Sendable, Equatable {
        var count: Int = 128
        var lifetime: Double = 6
        var speed: Double = 0.12
        var wind: Double = 0
        var gravity: Double = 0
        var size: Double = 0.008
        var seed: Int = 1234
        func validate() throws {
            guard (1...512).contains(count), (0...65535).contains(seed),
                  lifetime.isFinite, (0.1...60).contains(lifetime),
                  speed.isFinite, (-1...1).contains(speed),
                  wind.isFinite, (-1...1).contains(wind),
                  gravity.isFinite, (-1...1).contains(gravity),
                  size.isFinite, (0.001...0.05).contains(size) else {
                throw SceneError.invalid("Particles need 1–512 instances, lifetime 0.1–60 s, speed/wind/gravity −1…1, size 0.001–0.05, and seed 0–65535.")
            }
        }
    }
    struct Typography: Codable, Sendable, Equatable {
        enum Alignment: String, Codable, Sendable { case left, center, right }
        enum LiveSource: String, Codable, Sendable, CaseIterable {
            case time, timeWithSeconds, date, weekday
            var title: String {
                switch self { case .time: return "Time"; case .timeWithSeconds: return "Time with Seconds"
                case .date: return "Date"; case .weekday: return "Weekday" }
            }
        }
        var liveSource: LiveSource? = nil
        func resolved(at date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            guard let source = liveSource else { return text }
            let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
            switch source {
            case .time: formatter.setLocalizedDateFormatFromTemplate("jmm")
            case .timeWithSeconds: formatter.setLocalizedDateFormatFromTemplate("jmmss")
            case .date: formatter.setLocalizedDateFormatFromTemplate("MMMMd")
            case .weekday: formatter.setLocalizedDateFormatFromTemplate("EEEE")
            }
            return formatter.string(from: date)
        }
        var text: String = "Hello, world"
        var font: String = "HelveticaNeue"
        var size: Double = 96
        var alignment: Alignment = .center
        var fill: String = "#FFFFFF"
        var lineSpacing: Double = 8
        var width: Int = 1024
        var height: Int = 512
        func validate() throws {
            guard text.utf8.count <= 4096, !font.isEmpty, font.utf8.count <= 160,
                  size.isFinite, (4...512).contains(size), lineSpacing.isFinite, (0...256).contains(lineSpacing),
                  (32...4096).contains(width), (32...4096).contains(height),
                  SceneParameter(name: "Fill", type: .color, text: fill).isValid else { throw SceneError.invalid("Invalid text, typography, fill or canvas dimensions.") }
        }
    }
    struct Shape: Codable, Sendable, Equatable {
        enum Primitive: String, Codable, Sendable { case rectangle, ellipse, line, roundedRectangle }
        var primitive: Primitive = .roundedRectangle
        var fill: String = "#FF4FA3"
        var width: Int = 1024
        var height: Int = 512
        var cornerRadius: Double = 64
        var lineWidth: Double = 8
        func validate() throws {
            guard (32...4096).contains(width), (32...4096).contains(height),
                  cornerRadius.isFinite, (0...2048).contains(cornerRadius), lineWidth.isFinite, (1...512).contains(lineWidth),
                  SceneParameter(name: "Fill", type: .color, text: fill).isValid else { throw SceneError.invalid("Invalid shape dimensions, fill or radius.") }
        }
    }
    /// A user Metal fragment snippet. The entry must be
    /// `float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]])`
    /// where `ShaderU` offers time, resolution, pointer, audio, and opacity.
    /// `V` (position, uv, fade, canvasUV) matches the scene vertex output.
    struct Shader: Codable, Sendable, Equatable {
        var source: String = Shader.plasma
        var speed: Double = 1
        func validate() throws {
            guard !source.isEmpty, source.utf8.count <= 32768,
                  speed.isFinite, (0.01...10).contains(speed) else {
                throw SceneError.invalid("Shaders need 1–32768 characters of Metal code and speed 0.01–10.")
            }
        }
        static let plasma = """
        fragment float4 shaderMain(V in [[stage_in]], constant ShaderU &u [[buffer(1)]]) {
            float2 p = (in.uv - 0.5) * u.resolution / min(u.resolution.x, u.resolution.y);
            float t = u.time;
            float v = sin(p.x * 6.0 + t) + sin(p.y * 8.0 - t * 1.3) + sin((p.x + p.y) * 5.0 + t * 0.7);
            v /= 3.0;
            float3 col = 0.5 + 0.5 * cos(t * 0.4 + v * 3.14159 + float3(0.0, 2.1, 4.2));
            return float4(col * u.opacity, u.opacity);
        }
        """
    }
    indirect enum Content: Codable, Sendable { case image(URL), video(URL), gradient, particles(Emitter), group([SceneNode]), text(Typography), shape(Shape), shader(Shader) }
    struct Transform: Codable, Sendable {
        let x: Double?
        let y: Double?
        let scale: Double?
        let rotation: Double?
        static let identity = Transform(x: nil, y: nil, scale: nil, rotation: nil)
    }
    struct Style: Codable, Sendable, Equatable {
        struct Effect: Codable, Sendable, Equatable {
            enum Kind: String, Codable, Sendable { case blur, bloom, exposure, saturation, vignette, displacement }
            var id: UUID? = UUID()
            var type: Kind
            var amount: Double
            var range: ClosedRange<Double> {
                switch type {
                case .displacement: return 0...0.1
                case .blur: return 0...24
                case .bloom, .saturation: return 0...2
                case .exposure: return -2...2
                case .vignette: return 0...1
                }
            }
        }
        var effects: [Effect] = []
        enum Mask: String, Codable, Sendable { case ellipse }
        var mask: Mask? = nil
        var exposure: Double = 0
        var saturation: Double = 1
        var vignette: Double = 0
        static let plain = Style()
        init(mask: Mask? = nil, exposure: Double = 0, saturation: Double = 1, vignette: Double = 0) {
            self.mask = mask; self.exposure = exposure; self.saturation = saturation; self.vignette = vignette
        }
        enum CodingKeys: String, CodingKey { case mask, exposure, saturation, vignette, effects }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mask = try values.decodeIfPresent(Mask.self, forKey: .mask)
            exposure = try values.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
            saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
            vignette = try values.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
            effects = try values.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        }
    }
    enum Blend: String, Codable, Sendable { case normal, add, multiply, screen }
    enum MaskChannel: String, Codable, Sendable { case alpha, luma }
    var blend: Blend? = nil
    var maskAsset: URL? = nil
    var maskNodeID: UUID? = nil
    var maskChannel: MaskChannel? = nil
    var sprite: URL? = nil
    var needsComposition: Bool { blend != nil && blend != .normal || maskAsset != nil || maskNodeID != nil }
    var assets: [URL] { [assetURL, maskAsset, sprite].compactMap { $0 } }
    var style: Style = .plain
    var name: String? = nil
    var displayName: String {
        if let name { return name }
        if let assetURL { return assetURL.deletingPathExtension().lastPathComponent }
        if let typography {
            let title = typography.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return title.isEmpty ? "Text" : String(title.prefix(48))
        }
        if let shape {
            switch shape.primitive {
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .line: return "Line"
            case .roundedRectangle: return "Rounded Rectangle"
            }
        }
        return kind == .group ? "Group" : kind == .particles ? "Particles" : kind == .shader ? "Shader" : "Gradient"
    }
    var content: Content
    var visible = true
    var locked = false
    var opacity: Double = 1
    var transform: Transform = .identity
    var kind: SceneDescriptor.Kind {
        switch content { case .image: return .image; case .video: return .video; case .gradient: return .gradient; case .group: return .group; case .particles: return .particles; case .text: return .text; case .shape: return .shape; case .shader: return .shader }
    }
    var typography: Typography? { if case .text(let value) = content { return value }; return nil }
    var shape: Shape? { if case .shape(let value) = content { return value }; return nil }
    var emitter: Emitter? { if case .particles(let emitter) = content { return emitter }; return nil }
    var shader: Shader? { if case .shader(let shader) = content { return shader }; return nil }
    var children: [SceneNode] { if case .group(let nodes) = content { return nodes }; return [] }
    var descendants: [SceneNode] { [self] + children.flatMap { $0.descendants } }
    var hasAnimatedEffects: Bool { style.effects.contains { $0.type == .displacement && $0.amount > 0 } }
    var animated: Bool { visible && (hasAnimatedEffects || (kind == .group ? children.contains { $0.animated } : [.video, .gradient, .particles, .shader].contains(kind))) }
    func duplicated() -> SceneNode {
        let identities = Dictionary(uniqueKeysWithValues: descendants.map { ($0.id, UUID()) })
        func copy(_ node: SceneNode) -> SceneNode {
            var result = node
            result.id = identities[node.id]!
            if let mask = node.maskNodeID { result.maskNodeID = identities[mask] ?? mask }
            for index in result.style.effects.indices { result.style.effects[index].id = UUID() }
            if node.kind == .group { result.content = .group(node.children.map(copy)) }
            return result
        }
        return copy(self)
    }
    var assetURL: URL? {
        switch content { case .image(let url), .video(let url): return url; case .gradient, .group, .particles, .text, .shape, .shader: return nil }
    }
}

/// Picture adjustments for a video, read from the same sidecar as framing.
///
/// Some lobby art is painted bright -- Seia's sunlit bedroom averages 224 of
/// 255 and plays back exactly as rendered -- and reads as overexposed on a
/// desktop that is otherwise dim. These correct it at playback without touching
/// the file, so deleting the sidecar restores the original. Every field is
/// optional and neutral at 0, so `{"soften": 0.3}` still means what it did.
struct SceneTone: Codable, Sendable, Equatable {
    /// Rolls highlights off, 0...1; shadows and midtones are left alone.
    var soften: Double = 0
    /// Stops of exposure, -2...2, applied to linear light like a camera would.
    var exposure: Double = 0
    /// -1...1 around mid-grey.
    var contrast: Double = 0
    /// -1 is greyscale, 1 doubles saturation.
    var saturation: Double = 0
    enum CodingKeys: String, CodingKey { case soften, exposure, contrast, saturation }

    init(soften: Double = 0, exposure: Double = 0, contrast: Double = 0, saturation: Double = 0) {
        self.soften = soften; self.exposure = exposure; self.contrast = contrast; self.saturation = saturation
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        soften = try container.decodeIfPresent(Double.self, forKey: .soften) ?? 0
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
    }
    /// Neutral fields are left out, so a sidecar only says what was changed.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let value = clamped
        if value.soften != 0 { try container.encode(value.soften, forKey: .soften) }
        if value.exposure != 0 { try container.encode(value.exposure, forKey: .exposure) }
        if value.contrast != 0 { try container.encode(value.contrast, forKey: .contrast) }
        if value.saturation != 0 { try container.encode(value.saturation, forKey: .saturation) }
    }

    var clamped: SceneTone {
        func unit(_ v: Double, _ low: Double, _ high: Double) -> Double { v.isFinite ? min(max(v, low), high) : 0 }
        return SceneTone(soften: unit(soften, 0, 1), exposure: unit(exposure, -2, 2),
                         contrast: unit(contrast, -1, 1), saturation: unit(saturation, -1, 1))
    }
    var isNeutral: Bool { clamped == SceneTone() }

    /// Points for a tone curve over sRGB-encoded values. Shadows and midtones
    /// stay where they are; the curve bends only above the middle, so the
    /// picture keeps its contrast and loses its glare.
    var curve: [CGPoint] {
        let amount = CGFloat(clamped.soften)
        return [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5 - 0.02 * amount),
                CGPoint(x: 0.75, y: 0.75 - 0.08 * amount), CGPoint(x: 1, y: 1 - 0.18 * amount)]
    }
}

/// Framing for a plain media file, read from `<name>.framing.json` beside it.
///
/// An imported picture or video has nowhere to keep a focus or a bleed margin:
/// a `.idlesse` package carries them in its scene, but a bare `.mp4` is just
/// the media, and the Library stores a bookmark rather than a scene. A sidecar
/// keeps originals where they already live, stays editable by hand, and reads
/// the same whether the file is reached through the Library, the wallpaper or
/// the screen saver.
///
/// Missing or malformed is not an error: framing is an optional refinement, and
/// a wallpaper that refuses to play because a preferences file has a typo in it
/// is worse than one that plays centred.
struct SceneFraming: Decodable {
    var focus: SceneFocus?
    var bleed: SceneBleed?
    var tone: SceneTone?

    static func url(for media: URL) -> URL {
        media.deletingPathExtension().appendingPathExtension("framing.json")
    }
    static func beside(_ media: URL) throws -> SceneFraming? {
        let path = url(for: media)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard data.count <= 4096 else { throw SceneError.invalid("Framing sidecar is too large.") }
        return try JSONDecoder().decode(SceneFraming.self, from: data)
    }

    /// Writes this framing beside `media`, leaving any keys it does not own in
    /// place. Values that change nothing -- a centred focus, an empty margin, no
    /// softening -- are dropped rather than written, and a sidecar left with
    /// nothing in it is removed, so resetting a file really does restore it.
    func write(beside media: URL) throws {
        let path = SceneFraming.url(for: media)
        var contents: [String: Any] = [:]
        if let data = try? Data(contentsOf: path), data.count <= 4096,
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { contents = existing }
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        let margin = bleed?.clamped
        contents["focus"] = try focus.map(\.clamped).flatMap { $0 == .centre ? nil : try object($0) }
        contents["bleed"] = try margin.flatMap { $0.isEmpty ? nil : try object($0) }
        contents["tone"] = try tone.map(\.clamped).flatMap { $0.isNeutral ? nil : try object($0) }
        if contents.isEmpty {
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            return
        }
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }
}

protocol SceneSource {
    func resolve(_ url: URL) async throws -> SceneDescriptor
}

enum SceneError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct LocalSceneSource: SceneSource {
    public init() {}
    private struct Manifest: Decodable {
        let version: Int
        let title: String
        let capabilities: [String]
        let features: [String]?
        let metadata: SceneMetadata?
    }
    private struct Scene: Decodable {
        let canvas: SceneDescriptor.Canvas?
        let focus: SceneFocus?
        let bleed: SceneBleed?
        let parameters: [String: SceneParameter]?
        let bindings: [SceneParameterBinding]?
        let timeline: SceneTimeline?
        let variants: [SceneVariant]?
        let layers: [Node]?
        let nodes: [Node]?
        let components: [String: Component]?
        struct Component: Decodable {
            let name: String
            let node: Node
            let parameters: [String: SceneParameter]
            let bindings: [SceneParameterBinding]
        }
        struct Node: Decodable {
            let id: UUID?
            let componentID: String?
            let blend: SceneNode.Blend?
            let maskAsset: String?
            let maskNodeID: UUID?
            let maskChannel: SceneNode.MaskChannel?
            let sprite: String?
            let style: SceneNode.Style?
            let children: [Node]?
            let name: String?
            let emitter: SceneNode.Emitter?
            let typography: SceneNode.Typography?
            let shape: SceneNode.Shape?
            let shader: SceneNode.Shader?
            let type: SceneDescriptor.Kind
            let asset: String?
            let visible: Bool?
            let locked: Bool?
            let opacity: Double?
            let transform: SceneNode.Transform?
        }
    }

    public func resolve(_ url: URL) async throws -> SceneDescriptor {
        let task = Task.detached(priority: .userInitiated) { try Self.read(url) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }, onCancel: { task.cancel() })
    }

    private static func kind(_ url: URL) throws -> SceneDescriptor.Kind {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic": return .image
        case "mp4", "mov": return .video
        default: throw SceneError.invalid("Choose an image, MP4, MOV, or .idlesse scene.")
        }
    }

    private static func contained(_ path: String, in root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":") else {
            throw SceneError.invalid("Scene assets must use relative paths inside the package.")
        }
        let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw SceneError.invalid("A scene file points outside its package.")
        }
        return resolved
    }

    private static func json<T: Decodable>(_ type: T.Type, name: String, root: URL) throws -> T {
        try Task.checkCancellation()
        let url = try contained(name, in: root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw SceneError.invalid("Scene JSON exceeds 64 KB.") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch DecodingError.keyNotFound(let key, let context) {
            let path = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            throw SceneError.invalid("\(name): missing ‘\(path)’.")
        } catch DecodingError.typeMismatch(_, let context) {
            throw SceneError.invalid("\(name): wrong value type at ‘\(context.codingPath.map(\.stringValue).joined(separator: "."))’.")
        } catch DecodingError.valueNotFound(_, let context) {
            throw SceneError.invalid("\(name): missing value at ‘\(context.codingPath.map(\.stringValue).joined(separator: "."))’.")
        } catch DecodingError.dataCorrupted(let context) {
            throw SceneError.invalid("\(name): invalid JSON or value at ‘\(context.codingPath.map(\.stringValue).joined(separator: "."))’.")
        }
    }

    static func read(_ url: URL) throws -> SceneDescriptor {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SceneError.invalid("Download this scene before opening it.") }
        if url.pathExtension.lowercased() != "idlesse" {
            var scene = SceneDescriptor(title: url.deletingPathExtension().lastPathComponent, assetURL: url, kind: try kind(url))
            if let framing = try? SceneFraming.beside(url) {
                scene.focus = framing.focus
                scene.bleed = framing.bleed
            }
            return scene
        }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try json(Manifest.self, name: "manifest.json", root: root)
        guard (1...SceneFormat.revision).contains(manifest.version) else { throw SceneError.invalid("This scene uses an unsupported version.") }
        if manifest.version == SceneFormat.revision {
            guard let features = manifest.features, features.count <= 32, Set(features).count == features.count else {
                throw SceneError.invalid("Revision 21 needs a unique features list.")
            }
            let unsupported = Set(features).subtracting(SceneFormat.supported)
            guard unsupported.isEmpty else { throw SceneError.invalid("Unsupported scene features: " + unsupported.sorted().joined(separator: ", ")) }
        } else if manifest.features != nil || manifest.metadata != nil {
            throw SceneError.invalid("Feature declarations and metadata require revision 21.")
        }
        guard Set(manifest.capabilities).count == manifest.capabilities.count, manifest.capabilities.allSatisfy({ ($0 == "pointer" && manifest.version >= 8) || ($0 == "audio" && manifest.version >= 14) }) else { throw SceneError.invalid("Unsupported scene capability.") }
        let scene = try json(Scene.self, name: "scene.json", root: root)
        guard (manifest.version == 1 ? scene.nodes == nil : scene.layers == nil),
              let descriptions = manifest.version == 1 ? scene.layers : scene.nodes,
              (1...SceneBudget.maxNodes).contains(descriptions.count) else {
            throw SceneError.invalid("Use 1–16 layers in v1, or nodes in v2 and later.")
        }
        func decode(_ node: Scene.Node, depth: Int) throws -> SceneNode {
            guard depth <= SceneBudget.maxGroupDepth else { throw SceneError.invalid("Groups may nest at most two levels deep.") }
            let opacity = node.opacity ?? 1
            let transform = node.transform ?? .identity
            guard opacity.isFinite, (0...1).contains(opacity),
                  [transform.x ?? 0, transform.y ?? 0, transform.rotation ?? 0, transform.scale ?? 1].allSatisfy({ $0.isFinite }),
                  abs(transform.x ?? 0) <= 2, abs(transform.y ?? 0) <= 2,
                  (0.05...4).contains(transform.scale ?? 1), abs(transform.rotation ?? 0) <= 360 else {
                throw SceneError.invalid("Invalid opacity or transform; use finite values within the scene limits.")
            }
            let content: SceneNode.Content
            if node.type == .group {
                guard manifest.version >= 3, node.asset == nil, let children = node.children, !children.isEmpty else {
                    throw SceneError.invalid("Groups require v3 or later, nonempty children, and no asset.")
                }
                content = .group(try children.map { try decode($0, depth: depth + 1) })
            } else if node.type == .particles {
                guard manifest.version >= 17, node.children == nil, node.asset == nil, let emitter = node.emitter else {
                    throw SceneError.invalid("Particle nodes require v17 and an emitter, without assets or children.")
                }
                try emitter.validate()
                content = .particles(emitter)
            } else if node.type == .text || node.type == .shape {
                guard manifest.version == SceneFormat.revision, node.asset == nil, node.children == nil else { throw SceneError.invalid("Text and shapes require revision 21 and no asset or children.") }
                if node.type == .text, let typography = node.typography {
                    try typography.validate(); content = .text(typography)
                } else if node.type == .shape, let shape = node.shape {
                    try shape.validate(); content = .shape(shape)
                } else { throw SceneError.invalid("Text or shape content is missing.") }
            } else if node.type == .shader {
                guard manifest.version == SceneFormat.revision, node.asset == nil, node.children == nil, let shader = node.shader else {
                    throw SceneError.invalid("Shader nodes require revision 21 Metal source, without assets or children.")
                }
                try shader.validate()
                content = .shader(shader)
            } else if node.type == .gradient {
                guard node.children == nil, manifest.version >= 2, node.asset == nil else { throw SceneError.invalid("Gradient nodes require v2 and no asset.") }
                content = .gradient
            } else {
                guard node.children == nil, let path = node.asset else { throw SceneError.invalid("Media nodes need an asset.") }
                let asset = try contained(path, in: root)
                guard try kind(asset) == node.type else { throw SceneError.invalid("The asset does not match its node type.") }
                guard try asset.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw SceneError.invalid("The scene asset is not a regular file.")
                }
                content = node.type == .video ? .video(asset) : .image(asset)
            }
            guard node.type == .particles || node.emitter == nil else { throw SceneError.invalid("Only particle nodes accept an emitter.") }
            guard node.type == .text || node.typography == nil, node.type == .shape || node.shape == nil,
                  node.type == .shader || node.shader == nil else { throw SceneError.invalid("Content fields must match the node type.") }
            guard node.style == nil || manifest.version >= 4 else { throw SceneError.invalid("Masks and color effects require scene version 4.") }
            guard (node.style?.vignette ?? 0) == 0 || manifest.version >= 5 else { throw SceneError.invalid("Vignette requires scene version 5.") }
            guard manifest.version >= 18 || !(node.style?.effects.contains { $0.type == .displacement } ?? false) else {
                throw SceneError.invalid("Displacement requires scene version 18.")
            }
            guard (node.style?.effects.isEmpty ?? true) || manifest.version >= 15 else { throw SceneError.invalid("Ordered effects require scene version 15.") }
            guard manifest.version < 6 || node.id != nil else { throw SceneError.invalid("Every v6 node needs a UUID id.") }
            var decodedStyle = node.style ?? .plain
            for index in decodedStyle.effects.indices {
                guard manifest.version < 16 || decodedStyle.effects[index].id != nil else {
                    throw SceneError.invalid("Every v16 effect needs a UUID id.")
                }
                if decodedStyle.effects[index].id == nil { decodedStyle.effects[index].id = UUID() }
            }
            var result = SceneNode(id: manifest.version >= 6 ? node.id! : UUID(), style: decodedStyle, name: node.name.map { String($0.prefix(120)) }, content: content, visible: node.visible ?? true, locked: node.locked ?? false, opacity: opacity, transform: transform)
            guard manifest.version == SceneFormat.revision || node.componentID == nil else { throw SceneError.invalid("Local presets require revision 21.") }
            result.componentID = node.componentID
            guard manifest.version >= 20 || (node.blend == nil && node.maskAsset == nil && node.maskNodeID == nil && node.maskChannel == nil && node.sprite == nil) else {
                throw SceneError.invalid("Asset masks, blend modes and sprites require scene version 20.")
            }
            func imageAsset(_ path: String?) throws -> URL? {
                guard let path else { return nil }
                let url = try contained(path, in: root)
                guard try kind(url) == .image, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw SceneError.invalid("Mask and sprite assets must be regular image files.")
                }
                return url
            }
            result.blend = node.blend; result.maskNodeID = node.maskNodeID; result.maskChannel = node.maskChannel
            result.maskAsset = try imageAsset(node.maskAsset); result.sprite = try imageAsset(node.sprite)
            return result
        }
        let nodes = try descriptions.map { try decode($0, depth: 0) }
        try SceneBudget.validate(nodes)
        guard manifest.version >= 7 || (scene.parameters == nil && scene.bindings == nil) else {
            throw SceneError.invalid("Parameters and bindings require scene version 7.")
        }
        var components: [String: SceneComponent]? = nil
        if let definitions = scene.components {
            guard manifest.version == SceneFormat.revision, definitions.count <= 8 else { throw SceneError.invalid("Use at most eight presets in revision 21.") }
            components = try definitions.mapValues { .init(name: $0.name, node: try decode($0.node, depth: 0), parameters: $0.parameters, bindings: $0.bindings) }
        }
        guard manifest.version == SceneFormat.revision || scene.variants == nil else {
            throw SceneError.invalid("Scene variants require revision 21.")
        }
        guard scene.focus == nil || manifest.version == SceneFormat.revision else { throw SceneError.invalid("Focus requires revision 21.") }
        let result = SceneDescriptor(title: manifest.title, nodes: nodes, parameters: scene.parameters ?? [:], bindings: scene.bindings ?? [], timeline: scene.timeline, canvas: scene.canvas, metadata: manifest.metadata, components: components, variants: scene.variants ?? [], focus: scene.focus, bleed: scene.bleed)
        if manifest.version == SceneFormat.revision {
            guard SceneFormat.features(result).isSubset(of: Set(manifest.features ?? [])) else { throw SceneError.invalid("The manifest is missing required scene features.") }
        } else if result.parameters.values.contains(where: { $0.type != .number || !$0.targets.isEmpty }) {
            throw SceneError.invalid("Typed controls require revision 21.")
        }
        guard scene.canvas == nil || manifest.version >= 19 else { throw SceneError.invalid("Canvas modes require scene version 19.") }
        guard scene.timeline == nil || manifest.version >= 11 else { throw SceneError.invalid("Authored playback requires scene version 11.") }
        guard result.timeline?.videosFollowScene != true || manifest.version >= 13 else { throw SceneError.invalid("Video transport requires scene version 13.") }
        guard !result.usesSmoothing || manifest.version >= 12 else { throw SceneError.invalid("Smoothing requires scene version 12.") }
        guard !result.usesTracks || manifest.version >= 10 else { throw SceneError.invalid("Keyframes require scene version 10.") }
        guard !result.usesDrivers || manifest.version >= 9 else { throw SceneError.invalid("Binding modifiers require scene version 9.") }
        guard !result.usesSignals || manifest.version >= 8 else { throw SceneError.invalid("Signal bindings require scene version 8.") }
        guard manifest.version >= 16 || !result.bindings.contains(where: { $0.target.effectID != nil || $0.target.property == .effectAmount }) else {
            throw SceneError.invalid("Effect targets require scene version 16.")
        }
        guard !result.usesAudio || (manifest.version >= 14 && manifest.capabilities.contains("audio")) else { throw SceneError.invalid("Audio bindings require v14 and the audio capability.") }
        guard !result.usesPointer || manifest.capabilities.contains("pointer") else { throw SceneError.invalid("Pointer bindings must declare the pointer capability.") }
        _ = try result.evaluated()
        return result
    }
}

/// A typed, serializable target shared by future controls and animation tracks.
struct ScenePropertyAddress: Codable, Sendable, Hashable {
    enum Property: String, Codable, Sendable, CaseIterable {
        case x = "transform.x", y = "transform.y", scale = "transform.scale", rotation = "transform.rotation"
        case particleSize = "emitter.size", particleWind = "emitter.wind", particleSpeed = "emitter.speed"
        case effectAmount = "effect.amount"
        case opacity, exposure = "style.exposure", saturation = "style.saturation", vignette = "style.vignette"
        var range: ClosedRange<Double> {
            switch self {
            case .x, .y, .exposure: return -2...2
            case .scale: return 0.05...4
            case .rotation: return -360...360
            case .opacity, .vignette: return 0...1
            case .saturation: return 0...2
            case .effectAmount: return -2...24
            case .particleSize: return 0.001...0.05
            case .particleWind, .particleSpeed: return -1...1
            }
        }
    }
    let nodeID: UUID
    let property: Property
    var effectID: UUID? = nil
    static func targets(for node: SceneNode) -> [Self] {
        Property.allCases.filter { $0 != .effectAmount && (node.emitter != nil || ![.particleSize, .particleWind, .particleSpeed].contains($0)) }.map { Self(nodeID: node.id, property: $0) }
        + node.style.effects.map { Self(nodeID: node.id, property: .effectAmount, effectID: $0.id) }
    }
    func label(in nodes: [SceneNode]) -> String {
        guard let effectID, let node = nodes.flatMap({ $0.descendants }).first(where: { $0.id == nodeID }),
              let index = node.style.effects.firstIndex(where: { $0.id == effectID }) else { return property.rawValue }
        return "Effect \(index + 1) · \(node.style.effects[index].type.rawValue) amount"
    }
    func range(in nodes: [SceneNode]) throws -> ClosedRange<Double> {
        guard (property == .effectAmount) == (effectID != nil) else { throw SceneError.invalid("Effect amount requires an effect ID, and other properties cannot use one.") }
        guard let node = nodes.flatMap({ $0.descendants }).first(where: { $0.id == nodeID }) else { throw SceneError.invalid("The target layer no longer exists.") }
        guard ![Property.particleSize, .particleWind, .particleSpeed].contains(property) || node.emitter != nil else {
            throw SceneError.invalid("Particle properties need a particle node.")
        }
        guard let effectID else { return property.range }
        guard let effect = node.style.effects.first(where: { $0.id == effectID }) else { throw SceneError.invalid("The target effect no longer exists.") }
        return effect.range
    }

    func value(in nodes: [SceneNode]) throws -> Double {
        _ = try range(in: nodes)
        guard let node = nodes.flatMap({ $0.descendants }).first(where: { $0.id == nodeID }) else {
            throw SceneError.invalid("The property target no longer exists.")
        }
        switch property {
        case .x: return node.transform.x ?? 0
        case .y: return node.transform.y ?? 0
        case .scale: return node.transform.scale ?? 1
        case .rotation: return node.transform.rotation ?? 0
        case .opacity: return node.opacity
        case .exposure: return node.style.exposure
        case .saturation: return node.style.saturation
        case .vignette: return node.style.vignette
        case .particleSize: return node.emitter!.size
        case .particleWind: return node.emitter!.wind
        case .particleSpeed: return node.emitter!.speed
        case .effectAmount: return node.style.effects.first { $0.id == effectID }!.amount
        }
    }

    /// Reject invalid values before mutation; bindings must explicitly clamp their output.
    func set(_ value: Double, in nodes: inout [SceneNode]) throws {
        guard value.isFinite, try range(in: nodes).contains(value) else {
            throw SceneError.invalid("The property value is outside its supported range.")
        }
        guard SceneTree.edit(nodeID, in: &nodes, { siblings, index in
            var node = siblings[index]
            let t = node.transform
            switch property {
            case .x: node.transform = .init(x: value, y: t.y, scale: t.scale, rotation: t.rotation)
            case .y: node.transform = .init(x: t.x, y: value, scale: t.scale, rotation: t.rotation)
            case .scale: node.transform = .init(x: t.x, y: t.y, scale: value, rotation: t.rotation)
            case .rotation: node.transform = .init(x: t.x, y: t.y, scale: t.scale, rotation: value)
            case .opacity: node.opacity = value
            case .exposure: node.style.exposure = value
            case .saturation: node.style.saturation = value
            case .vignette: node.style.vignette = value
            case .particleSize, .particleWind, .particleSpeed:
                var emitter = node.emitter!
                if property == .particleSize { emitter.size = value }
                else if property == .particleWind { emitter.wind = value }
                else { emitter.speed = value }
                node.content = .particles(emitter)
            case .effectAmount: node.style.effects[node.style.effects.firstIndex { $0.id == effectID }!].amount = value
            }
            siblings[index] = node
        }) else { throw SceneError.invalid("The property target no longer exists.") }
    }
}

/// Writes a self-contained copy, leaving the source package and its assets untouched.
enum ScenePackageWriter {
    struct Revision: Equatable, Sendable {
        let manifest: Data
        let scene: Data
        let files: [String]
    }
    static func revision(of package: URL) throws -> Revision {
        let files = FileManager.default
        guard let entries = files.enumerator(at: package, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            throw SceneError.invalid("The scene package is no longer available.")
        }
        var records: [String] = []
        for case let url as URL in entries {
            guard records.count < 10_000 else { throw SceneError.invalid("This package contains too many files to edit safely.") }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            records.append("\(url.path.replacingOccurrences(of: package.path, with: ""))|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)|\(values.isSymbolicLink ?? false)")
        }
        func json(_ name: String) throws -> Data {
            let handle = try FileHandle(forReadingFrom: package.appendingPathComponent(name))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw SceneError.invalid("Scene JSON exceeds 64 KB.") }
            return data
        }
        return try Revision(manifest: json("manifest.json"), scene: json("scene.json"), files: records.sorted())
    }
    static func write(_ scene: SceneDescriptor, to destination: URL, replacing expected: Revision? = nil) throws {
        try SceneBudget.validate(scene.nodes)
        _ = try scene.evaluated()
        let files = FileManager.default
        guard destination.isFileURL, destination.pathExtension.lowercased() == "idlesse",
              expected != nil || !files.fileExists(atPath: destination.path) else {
            throw SceneError.invalid("Choose a new .idlesse package name; existing files are never replaced.")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".idlesse-\(UUID().uuidString).idlesse")
        defer { try? files.removeItem(at: staging) }
        if let expected {
            guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try revision(of: destination) == expected else {
                throw SceneError.invalid("The package changed outside Studio. Reopen it or use Save As to keep both versions.")
            }
            try files.copyItem(at: destination, to: staging)
        }
        let assetsDirectory = staging.appendingPathComponent("assets")
        if files.fileExists(atPath: assetsDirectory.path),
           try assetsDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw SceneError.invalid("The package assets folder must be a real directory.")
        }
        try files.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        var retained = Set<String>()
        var copiedAssets: [URL: String] = [:]
        func encode(_ node: SceneNode) throws -> [String: Any] {
            try Task.checkCancellation()
            var json: [String: Any] = ["id": node.id.uuidString, "type": node.kind.rawValue, "opacity": node.opacity, "visible": node.visible, "locked": node.locked,
                "transform": ["x": node.transform.x ?? 0, "y": node.transform.y ?? 0,
                              "scale": node.transform.scale ?? 1, "rotation": node.transform.rotation ?? 0]]
            if let name = node.name { json["name"] = name }
            if let component = node.componentID { json["componentID"] = component }
            if let emitter = node.emitter { json["emitter"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(emitter)) }
            if let text = node.typography { json["typography"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(text)) }
            if let shape = node.shape { json["shape"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shape)) }
            if let shader = node.shader { json["shader"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shader)) }
            if node.style != .plain {
                json["style"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node.style))
            }
            if let blend = node.blend { json["blend"] = blend.rawValue }
            if let id = node.maskNodeID { json["maskNodeID"] = id.uuidString }
            if let channel = node.maskChannel { json["maskChannel"] = channel.rawValue }
            for (key, source) in [("asset", node.assetURL), ("maskAsset", node.maskAsset), ("sprite", node.sprite)] {
                guard let source else { continue }
                let root = destination.resolvingSymlinksInPath().path + "/"
                let path = source.resolvingSymlinksInPath().path
                let relative: String
                let identity = source.resolvingSymlinksInPath().standardizedFileURL
                if let existing = copiedAssets[identity] {
                    relative = existing
                } else if expected != nil, path.hasPrefix(root) {
                    relative = String(path.dropFirst(root.count))
                } else {
                    relative = "assets/\(UUID().uuidString).\(source.pathExtension.lowercased())"
                    try files.copyItem(at: source, to: staging.appendingPathComponent(relative))
                }
                copiedAssets[identity] = relative
                json[key] = relative
                retained.insert(relative)
            }
            if node.kind == .group { json["children"] = try node.children.map(encode) }
            return json
        }
        let nodes = try scene.nodes.map(encode)
        var contents: [String: Any] = ["nodes": nodes]
        if let focus = scene.focus { contents["focus"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(focus)) }
        if let components = scene.components {
            contents["components"] = try components.mapValues { component -> [String: Any] in
                ["name": component.name, "node": try encode(component.node),
                 "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(component.parameters)),
                 "bindings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(component.bindings))]
            }
        }
        if let canvas = scene.canvas { contents["canvas"] = canvas.rawValue }
        if let timeline = scene.timeline {
            try timeline.validate()
            contents["timeline"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline))
        }
        let controlled = !scene.parameters.isEmpty || !scene.bindings.isEmpty
        if controlled {
            contents["parameters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene.parameters))
            contents["bindings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene.bindings))
        }
        if !scene.variants.isEmpty {
            contents["variants"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene.variants))
        }
        var manifest: [String: Any] = ["version": SceneFormat.revision, "title": scene.title,
            "features": SceneFormat.features(scene).sorted(),
            "capabilities": (scene.usesPointer ? ["pointer"] : []) + (scene.usesAudio ? ["audio"] : [])]
        if let metadata = scene.metadata {
            manifest["metadata"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
        }
        for (name, json) in [("manifest.json", manifest), ("scene.json", contents)] {
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent(name), options: .atomic)
        }
        try Task.checkCancellation()
        _ = try LocalSceneSource.read(staging)
        if let expected {
            guard try revision(of: destination) == expected else {
                throw SceneError.invalid("The package changed while saving. Your draft is intact; use Save As or reopen it.")
            }
            // Remove only media referenced by the previous supported scene and deleted
            // by this edit. Preserve ancillary files, previews, and unrelated assets.
            let previous = try LocalSceneSource.read(destination)
            let root = destination.resolvingSymlinksInPath().path + "/"
            for asset in previous.assetNodes.flatMap({ $0.assets }) {
                let path = asset.resolvingSymlinksInPath().path
                if path.hasPrefix(root) {
                    let relative = String(path.dropFirst(root.count))
                    if !retained.contains(relative) { try? files.removeItem(at: staging.appendingPathComponent(relative)) }
                }
            }
            _ = try LocalSceneSource.read(staging)
            let backup = ".idlesse-recovery-\(UUID().uuidString).idlesse"
            do {
                _ = try files.replaceItemAt(destination, withItemAt: staging, backupItemName: backup)
            } catch {
                let recovery = destination.deletingLastPathComponent().appendingPathComponent(backup)
                if files.fileExists(atPath: recovery.path) {
                    throw SceneError.invalid("Save failed. A recovery copy is at \(recovery.path). \(error.localizedDescription)")
                }
                throw error
            }
        } else {
            try files.moveItem(at: staging, to: destination)
        }
    }
}

/// Returns old resource indices in the new drawing order, only for metadata edits.
func sceneResourceOrder(from old: [SceneNode], to new: [SceneNode]) -> [Int]? {
    guard old.count == new.count, Set(old.map { $0.id }).count == old.count,
          Set(new.map { $0.id }).count == new.count else { return nil }
    var order: [Int] = []
    for node in new {
        guard let index = old.firstIndex(where: { $0.id == node.id }),
              old[index].kind == node.kind, old[index].assets == node.assets,
              old[index].typography == node.typography, old[index].shape == node.shape else { return nil }
        if node.kind == .group, sceneResourceOrder(from: old[index].children, to: node.children) == nil { return nil }
        order.append(index)
    }
    return order
}

/// Per-display retained image allowance; video decoder and drawable memory are separate.
enum SceneBudget {
    static let maxGroups = 4
    static let maxGroupDepth = 2
    static let intermediateTextureBytes = 128 * 1024 * 1024
    static let maxNodes = 16
    static let maxVideos = 2
    static let maxGradients = 4
    static let maxShaders = 4
    static let decodedImagePixels = 32_000_000
    static func validate(_ roots: [SceneNode]) throws {
        func walk(_ nodes: [SceneNode], depth: Int) throws -> [SceneNode] {
            guard depth <= maxGroupDepth else { throw SceneError.invalid("Groups may nest at most two levels deep.") }
            var result: [SceneNode] = []
            for node in nodes {
                try node.emitter?.validate()
                try node.typography?.validate()
                try node.shape?.validate()
                try node.shader?.validate()
                guard node.style.effects.count <= 8, node.style.effects.allSatisfy({ $0.amount.isFinite && $0.range.contains($0.amount) }) else {
                    throw SceneError.invalid("Use at most eight effects per layer, with amounts inside each effect's range.")
                }
                guard node.style.exposure.isFinite, (-2...2).contains(node.style.exposure),
                      node.style.saturation.isFinite, (0...2).contains(node.style.saturation),
                      node.style.vignette.isFinite, (0...1).contains(node.style.vignette) else {
                    throw SceneError.invalid("Use exposure −2…2, saturation 0…2 and vignette 0…1.")
                }
                result.append(node)
                if node.kind == .group {
                    guard !node.children.isEmpty else { throw SceneError.invalid("Groups need at least one child.") }
                    result += try walk(node.children, depth: depth + 1)
                }
            }
            return result
        }
        let nodes = try walk(roots, depth: 0)
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visiting = Set<UUID>(), visited = Set<UUID>()
        func checkReferences(_ node: SceneNode) throws {
            guard !visiting.contains(node.id) else { throw SceneError.invalid("Masks and groups cannot form a reference cycle.") }
            if visited.contains(node.id) { return }
            visiting.insert(node.id)
            guard node.maskAsset == nil || node.maskNodeID == nil else { throw SceneError.invalid("Choose either an image mask or a node mask.") }
            guard node.sprite == nil || node.kind == .particles else { throw SceneError.invalid("Only particles can use a sprite.") }
            if let id = node.maskNodeID {
                guard let mask = byID[id] else { throw SceneError.invalid("The mask layer no longer exists. Remove its mask reference first.") }
                try checkReferences(mask)
            }
            for child in node.children { try checkReferences(child) }
            visiting.remove(node.id); visited.insert(node.id)
        }
        for node in nodes { try checkReferences(node) }
        guard nodes.filter({ $0.kind == .particles }).count <= 4 else { throw SceneError.invalid("A scene supports at most four particle emitters.") }
        let effectIDs = nodes.flatMap { $0.style.effects }.compactMap(\.id)
        guard effectIDs.count == nodes.reduce(0, { $0 + $1.style.effects.count }), Set(effectIDs).count == effectIDs.count else {
            throw SceneError.invalid("Effect identities must exist and be unique across the scene.")
        }
        guard Set(nodes.map { $0.id }).count == nodes.count else { throw SceneError.invalid("Scene layer identities must be unique.") }
        guard nodes.filter({ $0.kind == .group }).count <= maxGroups else { throw SceneError.invalid("A scene supports at most four groups.") }
        guard (1...maxNodes).contains(nodes.count) else { throw SceneError.invalid("A scene supports 1–16 layers.") }
        guard nodes.filter({ $0.kind == .video }).count <= maxVideos else { throw SceneError.invalid("A scene supports at most two video layers, including hidden layers.") }
        guard nodes.filter({ $0.kind == .gradient }).count <= maxGradients else { throw SceneError.invalid("A scene supports at most four gradient layers, including hidden layers.") }
        guard nodes.filter({ $0.kind == .shader }).count <= maxShaders else { throw SceneError.invalid("A scene supports at most four shader layers, including hidden layers.") }
    }
    /// Two in-flight frames share a fixed byte allowance. Larger group surfaces
    /// are reduced uniformly; images/video assets themselves are never rewritten.
    static func groupTargetSize(width: Double, height: Double, count: Int) -> (width: Int, height: Int)? {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, (1...(maxGroups + 4 * maxNodes + 2)).contains(count) else { return nil }
        let pixels = Double(intermediateTextureBytes / (2 * count) - 65_536) / 4
        let scale = min(1, 16384 / max(width, height), sqrt(pixels / width / height))
        return (max(1, Int(floor(width * scale))), max(1, Int(floor(height * scale))))
    }
    static func imagePixels(_ nodes: [SceneNode]) -> Int {
        var count = 0
        for node in nodes.flatMap({ $0.descendants }) {
            if [.image, .text, .shape].contains(node.kind) { count += 1 }
            if node.maskAsset != nil { count += 1 }
            if node.sprite != nil { count += 1 }
        }
        return min(16_000_000, decodedImagePixels / max(1, count))
    }
}

/// Tree edits retain node identity so renderers can keep media resources alive.
enum SceneTree {
    static func siblings(of id: UUID, in nodes: [SceneNode]) -> [SceneNode]? {
        if nodes.contains(where: { $0.id == id }) { return nodes }
        for node in nodes { if let found = siblings(of: id, in: node.children) { return found } }
        return nil
    }
    static func edit(_ id: UUID, in nodes: inout [SceneNode], _ body: (inout [SceneNode], Int) -> Void) -> Bool {
        if let index = nodes.firstIndex(where: { $0.id == id }) { body(&nodes, index); return true }
        for index in nodes.indices where nodes[index].kind == .group {
            var children = nodes[index].children
            if edit(id, in: &children, body) { nodes[index].content = .group(children); return true }
        }
        return false
    }
}

/// Runtime-only filter memory, bounded by the scene's 64 unique binding targets.
final class SceneBindingSmoother {
    private var values: [ScenePropertyAddress: Double] = [:]
    private var lastTime: Double?
    private var revision: UInt64?
    private var delta: Double = 0
    func reset() { values.removeAll(keepingCapacity: true); lastTime = nil; revision = nil }
    func beginFrame(time: Double, revision: UInt64) {
        if self.revision != revision { reset(); self.revision = revision }
        delta = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
    }
    func sample(target: ScenePropertyAddress, value: Double, duration: Double) -> Double {
        guard duration > 0, let previous = values[target] else { values[target] = value; return value }
        let alpha = -expm1(-delta / duration)
        let filtered = previous * (1 - alpha) + value * alpha
        let result = filtered.isFinite ? filtered : value
        values[target] = result
        return result
    }
}
