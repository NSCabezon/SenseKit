import ARKit
import Foundation
import simd

/// Everything the ghost-controller decision and look are tuned by.
///
/// A "ghost" is the Sense controller drawn at its real tracked pose while it
/// is NOT in a hand (resting on a table, on the floor) so it can be found in
/// full VR, and hidden the moment it is picked up so only the app's own hands
/// remain. The decision is `SenseGhostHandState`; the model is
/// `SenseGhostMesh`; the drawing is `SenseGhostRenderer`.
///
/// The defaults are the ones Klepton plays with. The package never reads
/// environment variables: a consumer with knobs maps them in here.
public struct SenseGhostConfiguration: Sendable {
    /// Input from the controller (any button, capacitive touch, trigger, grip
    /// or stick off-centre) within this many seconds counts as HELD.
    public var inputWindow: Double
    /// The fallback "show after N s still": how long with no held evidence
    /// before the ghost shows when hand tracking cannot vouch that the hand
    /// is away from it (see `handAwayWait`).
    public var showAfter: Double
    /// Trust the platform's own in-hand flag (`AccessoryAnchor.heldChirality`,
    /// visionOS 26): set means HELD. false ignores it if it proves unreliable.
    public var usePlatformHeld: Bool
    /// A tracked palm within this many metres of the grip point is "near"...
    public var nearIn: Float
    /// ...and stays near until it is this far away, so the decision does not
    /// flicker at the edge.
    public var nearOut: Float
    /// The controller MOVED this frame if its speed is above this, m/s...
    public var motionSpeed: Float
    /// ...or its angular speed is above this, rad/s...
    public var motionAngularSpeed: Float
    /// ...or it is this far, metres, from where it last rested.
    public var motionDistance: Float
    /// A move within this many seconds counts as "moving". Moving while a palm
    /// is near — or while hand tracking has no hand at all, which is the
    /// normal state when the hands are full of controllers: visionOS stops
    /// reporting hands that hold them — is HELD. A palm near a controller that
    /// is NOT moving does not hide it: that is the hand reaching for it, and
    /// that is exactly when it has to stay visible.
    public var motionWindow: Double
    /// How long with no held evidence before the ghost shows when a tracked
    /// hand is visibly away from it.
    public var handAwayWait: Double
    /// The show/hide fade, seconds.
    public var fadeSeconds: Double
    /// The model's fit onto the real plastic: a transform in the grip frame
    /// applied to the mesh before the pose (a rotation about the grip and an
    /// offset, measured in a device session).
    public var fit: simd_float4x4
    /// The body: light grey, lit. Straight alpha.
    public var bodyColor: SIMD4<Float>
    /// The soft outline round the silhouette. Straight alpha.
    public var rimColor: SIMD4<Float>
    /// How far the rim is pushed out along the mesh normals, metres.
    public var rimWidth: Float

    public init(inputWindow: Double = 2.0,
                showAfter: Double = 2.5,
                usePlatformHeld: Bool = true,
                nearIn: Float = 0.09,
                nearOut: Float = 0.12,
                motionSpeed: Float = 0.08,
                motionAngularSpeed: Float = 0.9,
                motionDistance: Float = 0.025,
                motionWindow: Double = 0.6,
                handAwayWait: Double = 1.0,
                fadeSeconds: Double = 0.2,
                fit: simd_float4x4 = matrix_identity_float4x4,
                bodyColor: SIMD4<Float> = SIMD4<Float>(0.80, 0.81, 0.84, 1),
                rimColor: SIMD4<Float> = SIMD4<Float>(0.10, 0.11, 0.13, 0.85),
                rimWidth: Float = 0.0025) {
        self.inputWindow = inputWindow
        self.showAfter = showAfter
        self.usePlatformHeld = usePlatformHeld
        self.nearIn = nearIn
        self.nearOut = nearOut
        self.motionSpeed = motionSpeed
        self.motionAngularSpeed = motionAngularSpeed
        self.motionDistance = motionDistance
        self.motionWindow = motionWindow
        self.handAwayWait = handAwayWait
        self.fadeSeconds = fadeSeconds
        self.fit = fit
        self.bodyColor = bodyColor
        self.rimColor = rimColor
        self.rimWidth = rimWidth
    }
}

/// The in-hand decision for one controller, with hysteresis.
///
/// HELD (ghost hidden) the moment any of these is true:
///   1. the platform says so (`AccessoryAnchor.heldChirality`, visionOS 26),
///      unless `usePlatformHeld` is off;
///   2. input from that controller in the last `inputWindow` s (any button,
///      capacitive touch, trigger, grip or stick off-centre);
///   3. the controller MOVED in the last `motionWindow` s (velocity above
///      `motionSpeed` or `motionAngularSpeed`, or `motionDistance` from where
///      it last rested) while a tracked palm is within `nearIn` of its grip
///      point (`nearOut` to leave, so it does not flicker at the edge) — or
///      while hand tracking has no hand at all, which is the normal state when
///      the hands are full of controllers: visionOS stops reporting hands that
///      hold them.
/// A palm near a controller that is NOT moving does not hide it: that is the
/// hand reaching for it, and that is exactly when it has to stay visible.
///
/// RESTING (ghost shown) again only after none of the above for
/// `handAwayWait` when a tracked hand is visibly away from it, else for
/// `showAfter` — the fallback "show after N s still" when hand tracking cannot
/// vouch. Not tracked (no anchor, untracked, orientation only): hidden.
public struct SenseGhostHandState: Sendable {
    /// The decision this frame.
    public private(set) var visible = false
    /// The faded presence, 0...1, what to draw with.
    public private(set) var alpha: Float = 0
    public private(set) var lastHeldEvidence: TimeInterval = -100
    public private(set) var lastMotion: TimeInterval = -100
    public private(set) var restPos: SIMD3<Float>?
    public private(set) var palmNear = false
    /// The last position-tracked `originFromGrip`, what the model is drawn at.
    public private(set) var pose = matrix_identity_float4x4
    /// Why the decision is what it is ("held (input)", "settling", "no anchor"...).
    public private(set) var lastReason = ""
    public private(set) var platformHeld = false

    public init() {}

    /// One frame. `palms` are the tracked palm centres (`SenseGhostHands.palm`),
    /// `handTrackingSeesHands` whether hand tracking is running and reports at
    /// least one, `lastInput` when this controller last showed input
    /// (`SenseHandState.lastActivity`), `now` the same clock, `dt` the frame
    /// step for the fade. `log` gets "left: SHOWN — held (input)"-style lines
    /// on every change of visibility and of the platform's own held flag.
    public mutating func update(hand: SenseHand, sample: SenseGhostSample?, palms: [SIMD3<Float>],
                                handTrackingSeesHands: Bool, lastInput: TimeInterval,
                                now: TimeInterval, dt: Float,
                                configuration: SenseGhostConfiguration,
                                log: ((String) -> Void)?) {
        let cfg = configuration
        var show = false
        var reason: String
        if let s = sample, s.positionTracked {
            pose = s.originFromGrip
            let p = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            if s.speed > cfg.motionSpeed || s.angularSpeed > cfg.motionAngularSpeed { lastMotion = now }
            if let r = restPos {
                if simd_distance(p, r) > cfg.motionDistance { lastMotion = now; restPos = p }
            } else { restPos = p }
            let d = palms.map { simd_distance($0, p) }.min() ?? .infinity
            palmNear = d < (palmNear ? cfg.nearOut : cfg.nearIn)
            let moved = now - lastMotion < cfg.motionWindow
            let platform = cfg.usePlatformHeld && s.heldByPlatform
            let input = now - lastInput < cfg.inputWindow
            let grabbed = moved && (palmNear || !handTrackingSeesHands)
            if platform || input || grabbed {
                lastHeldEvidence = now
                reason = platform ? "held (platform)" : input ? "held (input)"
                       : palmNear ? "held (hand near + moving)" : "held (moving, no hands tracked)"
            } else {
                let handAway = handTrackingSeesHands && !palmNear
                let wait = handAway ? cfg.handAwayWait : cfg.showAfter
                show = now - lastHeldEvidence > wait
                reason = show ? (handAway ? "resting (hand away)" : "resting (still \(cfg.showAfter) s)")
                              : "settling"
            }
        } else {
            restPos = nil
            palmNear = false
            reason = sample == nil ? "no anchor" : "not position-tracked"
        }
        // Said on every change of visibility, and on every change of the
        // platform's own held flag — the one input this logic cannot check
        // off-device, so the log has to say whether it agrees with reality.
        let side = hand == .left ? "left" : "right"
        if show != visible {
            log?("\(side): \(show ? "SHOWN" : "hidden") — \(reason)")
        } else if reason != lastReason && (reason.hasPrefix("no") || reason.hasPrefix("not")) {
            log?("\(side): \(reason)")
        }
        let ph = sample?.heldByPlatform ?? false
        if ph != platformHeld {
            platformHeld = ph
            log?("\(side): platform heldChirality \(ph ? "SET" : "cleared")")
        }
        visible = show
        lastReason = reason
        // ~200 ms fades.
        let step = dt / Float(cfg.fadeSeconds)
        alpha = visible ? min(1, alpha + step) : max(0, alpha - step)
    }
}

/// Both ghosts: the two per-hand state machines and the frame clock they
/// share. One per app, on the render thread; `update` once a frame, then draw
/// `hands` with a `SenseGhostRenderer` (or your own model from `SenseGhostMesh`).
///
/// `configuration` and `logger` are read on the thread that calls `update`;
/// they are not synchronised.
public final class SenseGhosts {
    /// Live tuning; the renderer reads `fit` and the colours from here too.
    public var configuration: SenseGhostConfiguration
    /// Optional log sink (default off). Lines carry no channel prefix
    /// ("left: SHOWN — held (input)"); a consumer adds its own.
    public var logger: ((String) -> Void)?
    /// The two state machines, indexed by `SenseHand.rawValue`.
    public private(set) var hands = [SenseGhostHandState(), SenseGhostHandState()]
    private var lastTick: TimeInterval = 0

    public init(configuration: SenseGhostConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Once per frame. `samples` and `lastInput` are indexed by hand (left,
    /// right); `palms` are every tracked palm centre; `now` is the sample's
    /// clock (`CACurrentMediaTime()`). The fade step is the time since the
    /// last call, capped at 100 ms, and 0 on the first.
    public func update(samples: [SenseGhostSample?], palms: [SIMD3<Float>],
                       handTrackingSeesHands: Bool, lastInput: [TimeInterval],
                       now: TimeInterval) {
        let dt = lastTick > 0 ? Float(min(now - lastTick, 0.1)) : 0
        lastTick = now
        let cfg = configuration
        let log = logger
        for hand in SenseHand.allCases {
            let h = hand.rawValue
            hands[h].update(hand: hand, sample: h < samples.count ? samples[h] : nil, palms: palms,
                            handTrackingSeesHands: handTrackingSeesHands,
                            lastInput: h < lastInput.count ? lastInput[h] : -100,
                            now: now, dt: dt, configuration: cfg, log: log)
        }
    }
}

/// Hand-tracking helpers for the ghost decision.
public enum SenseGhostHands {
    /// The middle of the palm: halfway between the middle finger's metacarpal
    /// base and its knuckle, where a fist closes around a grip. The anchor's
    /// origin when it carries no skeleton.
    public static func palm(_ a: HandAnchor) -> SIMD3<Float> {
        let o = a.originFromAnchorTransform
        guard let sk = a.handSkeleton else {
            return SIMD3(o.columns.3.x, o.columns.3.y, o.columns.3.z)
        }
        let b = (o * sk.joint(.middleFingerMetacarpal).anchorFromJointTransform).columns.3
        let k = (o * sk.joint(.middleFingerKnuckle).anchorFromJointTransform).columns.3
        return SIMD3((b.x + k.x) / 2, (b.y + k.y) / 2, (b.z + k.z) / 2)
    }
}
