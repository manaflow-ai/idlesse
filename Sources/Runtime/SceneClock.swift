import Foundation

/// One monotonic timeline shared by every surface of an active scene.
/// Video loops are not frame-locked to this clock yet.
public final class SceneClock {
    private let now: () -> TimeInterval
    private var anchor: TimeInterval
    private var accumulated: TimeInterval = 0
    private var authored: SceneTimeline?
    private(set) var revision: UInt64 = 0
    private(set) var playbackRate: Double = 1
    private(set) var loopRange: Range<TimeInterval>?
    public private(set) var isPaused = true
    /// Explicit host opt-in, never granted by a package manifest.
    public var pointerEnabled = false
    public var audioEnabled = false { didSet { audioActivityChanged?(audioEnabled && !isPaused) } }
    var audioActivityChanged: ((Bool) -> Void)?
    public var audioLevels: () -> SceneAudioLevels = { SceneAudioLevels() }
    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        anchor = now()
    }
    private var phase: TimeInterval { accumulated + (isPaused ? 0 : max(0, now() - anchor) * playbackRate) }
    public var time: TimeInterval { wrapped(phase) }
    var isAtEnd: Bool { authored?.mode == .once && phase >= (authored?.duration ?? 0) }
    var effectiveRate: Double {
        if isPaused || isAtEnd { return 0 }
        return playbackRate
    }
    public func configure(timeline: SceneTimeline?) throws {
        try timeline?.validate()
        try configure(time: 0, rate: timeline?.rate ?? 1, loop: nil)
        authored = timeline
    }
    private func wrapped(_ value: TimeInterval) -> TimeInterval {
        // Transport loop ranges win while set; otherwise fall back to the
        // authored scene timeline so clearing the transport loop never leaves
        // the clock ticking past the scene duration (e.g. "10s / 8s").
        if let loopRange {
            let duration = loopRange.upperBound - loopRange.lowerBound
            guard duration > 0 else { return loopRange.lowerBound }
            return loopRange.lowerBound + max(0, value - loopRange.lowerBound).truncatingRemainder(dividingBy: duration)
        }
        if let authored {
            let duration = authored.duration
            switch authored.mode {
            case .once: return min(value, duration)
            case .loop: return value.truncatingRemainder(dividingBy: duration)
            case .pingPong:
                let position = value.truncatingRemainder(dividingBy: duration * 2)
                return position <= duration ? position : duration * 2 - position
            }
        }
        return value
    }
    /// Atomic transport edit. These settings are host-session state, not authored scene data.
    /// Clearing the loop keeps the authored timeline as the wrap basis.
    func configure(time: TimeInterval, rate: Double, loop: Range<TimeInterval>?) throws {
        guard time.isFinite, (0...86400).contains(time), rate.isFinite, (0.1...4).contains(rate) else {
            throw SceneError.invalid("Use a time of 0–86400 seconds and a playback rate of 0.1–4.")
        }
        if let loop {
            guard loop.lowerBound.isFinite, loop.upperBound.isFinite, loop.lowerBound >= 0,
                  loop.upperBound <= 86400, loop.upperBound - loop.lowerBound >= 0.01 else {
                throw SceneError.invalid("Use a loop within 0–86400 seconds, at least 0.01 seconds long.")
            }
        }
        revision &+= 1
        loopRange = loop
        playbackRate = rate
        accumulated = wrapped(time)
        anchor = now()
    }
    func seek(to time: TimeInterval) throws {
        guard time.isFinite, (0...86400).contains(time) else { throw SceneError.invalid("Use a time of 0–86400 seconds.") }
        revision &+= 1
        accumulated = time
        anchor = now()
    }
    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        accumulated = phase
        anchor = now()
        isPaused = paused
        audioActivityChanged?(audioEnabled && !paused)
    }
}
