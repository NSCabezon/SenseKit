import simd

/// Correction from the platform's `.grip` frame to the grip pose a consumer wants,
/// in the grip's own frame.
///
/// `AccessoryAnchor`'s `.grip` is the platform's own answer to "where does a
/// hand hold this and which way does it point", so it needs no hand-shaped
/// compensation at all. What it may need is the gap between Apple's grip
/// convention and the pose the consuming app was built against (for an
/// OVRPlugin guest, the pose an Oculus Touch controller would have reported),
/// which nothing on this platform can tell us.
///
/// The defaults are the ones Klepton plays with:
///
///   * **`tiltDegrees` 5.037 about X** — ALVR's, from `WorldTracker.swift`
///     (`controllerToAlvrDeviceMotion`). Not a guess: it is the tilt in
///     SteamVR's own PSVR2 controller model JSON, i.e. the offset between the
///     tracked frame and the handle a user perceives.
///   * **`pitchDegrees` -37 about X** — Klepton's hilt pitch, measured by
///     playing and reading the number back off Beat Saber's own in-game
///     controller adjustment. Negative, because the same magnitude positive
///     pitches the hilts backward on device (the game's adjustment is applied
///     in Unity's left-handed frame). Set it to 0 for the plain ALVR pose.
///   * **`position` (-0.005, 0.02, -0.02) m** — an origin nudge in the grip's
///     frame (ALVR's is (0.002, 0, -0.01); this is Klepton's tuned value).
///   * **`pivot` zero** — the point, in the grip's frame, the rotation turns
///     ABOUT. Zero turns about the reported origin. A translation cannot
///     remove an arc: `position` slides the result, it cannot change what the
///     result rotated around, so a rotation that swings the hilt is fixed here.
///   * **`mirrorLeft` true** — the two hands are mirror images, so the same
///     physical displacement is `+x` on one and `-x` on the other. For the
///     LEFT hand the X terms of `position` and `pivot` are negated, and so are
///     yaw and roll (reflecting X negates rotations about Y and Z and leaves
///     pitch alone). Without it a shared value is right on one hand and wrong
///     by twice its own size on the other.
public struct SenseGripCorrection: Sendable, Equatable {
    /// ALVR's PSVR2 comfort tilt, degrees about X.
    public static let psvr2TiltDegrees: Float = 5.037

    public var tiltDegrees: Float
    /// Extra pitch (about X) on top of the tilt, degrees.
    public var pitchDegrees: Float
    /// Yaw (about the grip's Y), degrees. Mirrored for the left hand with `mirrorLeft`.
    public var yawDegrees: Float
    /// Roll (about the grip's Z), degrees. Mirrored for the left hand with `mirrorLeft`.
    public var rollDegrees: Float
    public var position: SIMD3<Float>
    public var pivot: SIMD3<Float>
    public var mirrorLeft: Bool

    public init(tiltDegrees: Float = SenseGripCorrection.psvr2TiltDegrees,
                pitchDegrees: Float = -37,
                yawDegrees: Float = 0,
                rollDegrees: Float = 0,
                position: SIMD3<Float> = SIMD3<Float>(-0.005, 0.02, -0.02),
                pivot: SIMD3<Float> = .zero,
                mirrorLeft: Bool = true) {
        self.tiltDegrees = tiltDegrees
        self.pitchDegrees = pitchDegrees
        self.yawDegrees = yawDegrees
        self.rollDegrees = rollDegrees
        self.position = position
        self.pivot = pivot
        self.mirrorLeft = mirrorLeft
    }

    /// The corrected grip pose for `hand`, from the platform's grip
    /// orientation `raw` and origin `origin` (tracking space).
    ///
    /// `position` slides the corrected pose; `pivot` decides what the
    /// correction turned AROUND. Holding the pivot C still across the rotation
    /// is `+ raw·C - q·C`, which is zero when C is, so a zero pivot is the
    /// plain rotate-about-the-origin behaviour.
    public func apply(raw: simd_quatf, origin: SIMD3<Float>,
                      hand: SenseHand) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let mx: Float = mirrorLeft && hand == .left ? -1 : 1
        let rot = SenseMath.eulerXYZ(SIMD3<Float>(tiltDegrees + pitchDegrees,
                                                  mx * yawDegrees, mx * rollDegrees))
        let tpos   = SIMD3<Float>(mx * position.x, position.y, position.z)
        let tpivot = SIMD3<Float>(mx * pivot.x, pivot.y, pivot.z)
        let q = simd_normalize(raw * rot)
        var p = origin + raw.act(tpos)
        if tpivot != SIMD3<Float>(0, 0, 0) { p += raw.act(tpivot) - q.act(tpivot) }
        return (p, q)
    }
}

/// (Adapted from avp-play, MIT, github.com/myMartek/avp-play.)
/// A NOISE GATE on the published velocity, not a low-pass.
///
/// visionOS's accessory velocity is a few cm/s of noise when the hand is
/// still, invisible in the pose but turned into jitter once a consumer (e.g.
/// SteamVR) extrapolates a render pose from it. A low-pass killed the jitter
/// but also lagged the pose (it starves the consumer's prediction) and blunted
/// the flick (a short flick IS a short velocity spike). A gate instead leaves
/// fast motion ALONE — above the threshold the real velocity passes (minus the
/// threshold, a few-percent trim on a flick), below it goes to zero — so a
/// still hand is steady while a flick keeps the full signal.
///
/// 0 disables a gate (the default). Klepton turns it on for Steam Link only
/// (0.06 m/s, 0.35 rad/s). Values are deliberately small.
public struct SenseVelocityGate: Sendable, Equatable {
    /// Linear threshold, m/s.
    public var linear: Float
    /// Angular threshold, rad/s.
    public var angular: Float

    public init(linear: Float = 0, angular: Float = 0) {
        self.linear = linear
        self.angular = angular
    }

    /// Soft magnitude gate: zero below `t`, and above it subtract `t` while
    /// keeping direction — continuous at the threshold (no pop) and only a
    /// small constant trim on a large, deliberate motion. `t <= 0` passes `x`.
    public static func gate(_ x: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        if t <= 0 { return x }
        let m = simd_length(x)
        return m <= t || m == 0 ? .zero : x * ((m - t) / m)
    }
}

/// Haptics tuning.
///
/// The engine comes from ALVR (`GCController.haptics` →
/// `createEngine(withLocality:)`); the driving does not. A consumer that hands
/// over a continuous envelope (a level per frame) is played through **one
/// long-lived looping player per hand, with the envelope sent as a dynamic
/// intensity parameter each frame** — no restarts, no gaps. `.pulse` restores
/// ALVR's discrete shape (one short `.hapticContinuous` event per frame, never
/// shorter than `minPulseMs`), and is what a hand falls back to on its own if
/// the continuous player cannot be made or started.
public struct SenseHapticsConfiguration: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case continuous, pulse }

    /// false: the source is still drained every frame, but nothing is played.
    public var enabled: Bool
    /// Scales every level. 0.25 is ALVR's own PSVR2 scale (0.7 for anything
    /// else): the Sense actuators are strong enough that 1.0 at full intensity
    /// is not what a game meant by it.
    public var gain: Float
    /// CoreHaptics's sharpness axis. 1.0 is ALVR's constant: crisp.
    public var sharpness: Float
    public var mode: Mode
    /// The floor a discrete event is never shorter than — ALVR's "controllers
    /// can't do 10ms vibrations".
    public var minPulseMs: Double

    public init(enabled: Bool = true,
                gain: Float = 0.25,
                sharpness: Float = 1.0,
                mode: Mode = .continuous,
                minPulseMs: Double = 32) {
        self.enabled = enabled
        self.gain = gain
        self.sharpness = sharpness
        self.mode = mode
        self.minPulseMs = minPulseMs
    }
}

/// All live-tunable settings of `SenseControllers`.
public struct SenseConfiguration: Sendable, Equatable {
    public var gripCorrection: SenseGripCorrection
    /// How far into the future a pose may be predicted, ms. 0 is the measured
    /// pose. **A time cap, not a fraction of the interval**: a tracker's
    /// extrapolation error is a function of how far AHEAD it reaches, so the
    /// same setting means the same horizon at any frame rate. The default 50
    /// is the horizon Klepton clamps the head to. A consumer that predicts
    /// again downstream (Steam Link: SteamVR predicts to the PC's photon
    /// time) wants 0 here, or the prediction is applied twice.
    public var predictionCapMs: Double
    public var velocityGate: SenseVelocityGate
    /// true (the default, ALVR's reading): `AccessoryAnchor.velocity` and
    /// `.angularVelocity` are in the accessory's own frame and are rotated
    /// into tracking space by the UNCORRECTED grip orientation. false: they
    /// are taken as already being in tracking space. Apple documents neither;
    /// the two differ only in direction.
    public var velocityInAccessoryFrame: Bool
    public var haptics: SenseHapticsConfiguration

    public init(gripCorrection: SenseGripCorrection = SenseGripCorrection(),
                predictionCapMs: Double = 50,
                velocityGate: SenseVelocityGate = SenseVelocityGate(),
                velocityInAccessoryFrame: Bool = true,
                haptics: SenseHapticsConfiguration = SenseHapticsConfiguration()) {
        self.gripCorrection = gripCorrection
        self.predictionCapMs = predictionCapMs
        self.velocityGate = velocityGate
        self.velocityInAccessoryFrame = velocityInAccessoryFrame
        self.haptics = haptics
    }
}
