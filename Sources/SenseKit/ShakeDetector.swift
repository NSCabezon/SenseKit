import Foundation
import simd

/// A shake of one controller, as a held pulse: the Wii Remote's "spin" for a
/// game that maps it to a Sense controller.
///
/// A sample moving faster than `linearThreshold` OR turning faster than
/// `angularThreshold` starts a pulse that reads true for `holdTicks` updates
/// (counting the one that started it), so a consumer polling slower than the
/// feed cannot miss it. A new pulse cannot start until `refractory` seconds
/// after the last one began, so one motion is one shake.
///
/// The defaults come from GalaxyPad (Super Mario Galaxy's spin) and are tuned
/// for that Wii-style shake: a wrist flick turns fast and moves little, hence
/// the angular test. **Not yet validated on a headset**; treat them as a
/// starting point. `holdTicks` 5 is ~40 ms at a 120 Hz poll, more than one
/// 60 Hz game frame.
///
/// Pure value type, one instance per controller; feed it every poll.
public struct ShakeDetector: Sendable, Equatable {
    /// Speed past which a sample is a shake, m/s.
    public var linearThreshold: Float
    /// Angular speed past which a sample is a shake, rad/s.
    public var angularThreshold: Float
    /// Seconds after a shake begins during which no new one can start.
    public var refractory: TimeInterval
    /// Updates the pulse reads true for, including the one that started it.
    public var holdTicks: Int

    /// When the last shake began, or -infinity before any.
    public private(set) var lastShake: TimeInterval = -.infinity
    /// Updates left in the current pulse.
    private var remaining = 0

    public init(linearThreshold: Float = 1.6,
                angularThreshold: Float = 12,
                refractory: TimeInterval = 0.25,
                holdTicks: Int = 5) {
        self.linearThreshold = linearThreshold
        self.angularThreshold = angularThreshold
        self.refractory = refractory
        self.holdTicks = holdTicks
    }

    /// One sample: the controller's velocities (tracking space or its own
    /// frame, only the magnitudes are read) at `time` (any monotonic clock in
    /// seconds, e.g. `CACurrentMediaTime()`). Returns whether the pulse is on.
    public mutating func update(linearVelocity: SIMD3<Float>, angularVelocity: SIMD3<Float>,
                                at time: TimeInterval) -> Bool {
        if time - lastShake >= refractory,
           simd_length(linearVelocity) > linearThreshold
               || simd_length(angularVelocity) > angularThreshold {
            lastShake = time
            remaining = holdTicks
        }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }

    /// The same, from a pose; nil (no pose this poll) cannot start a pulse but
    /// lets one already running finish.
    public mutating func update(pose: SensePose?, at time: TimeInterval) -> Bool {
        update(linearVelocity: pose?.linearVelocity ?? .zero,
               angularVelocity: pose?.angularVelocity ?? .zero, at: time)
    }

    /// Drop the pulse and the refractory period (e.g. on a pause).
    public mutating func reset() {
        lastShake = -.infinity
        remaining = 0
    }
}
