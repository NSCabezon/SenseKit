import simd
import Foundation

/// A tracked controller pose with velocities, in tracking space.
public struct SensePose: Sendable {
    public var position: SIMD3<Float>
    public var orientation: simd_quatf
    /// m/s.
    public var linearVelocity: SIMD3<Float>
    /// rad/s.
    public var angularVelocity: SIMD3<Float>

    public init(position: SIMD3<Float> = .zero,
                orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                linearVelocity: SIMD3<Float> = .zero,
                angularVelocity: SIMD3<Float> = .zero) {
        self.position = position
        self.orientation = orientation
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
    }
}

/// Snapshot of one controller: connection, pose, buttons, touches and analog values.
public struct SenseHandState: Sendable {
    /// A Sense controller for this hand is attached (GameController). Only an
    /// attached controller's input fields mean anything; a detached hand reads
    /// all released.
    public var connected: Bool
    /// nil = no pose this frame (no anchor yet, or no provider).
    public var pose: SensePose?
    public var buttons: SenseButtons
    /// The capacitive readings (face buttons, trigger, stick). A pressed
    /// button is not folded in.
    public var touches: SenseButtons
    /// Always empty on visionOS 26: the Sense reports no proximity separate
    /// from touch. Kept so a consumer's mapping has a place for it.
    public var nearTouches: SenseButtons
    /// Index trigger, 0...1 (the analog value).
    public var trigger: Float
    /// Grip, 0 or 1 (the Sense grip is digital).
    public var grip: Float
    public var stick: SIMD2<Float>
    /// `CACurrentMediaTime()` of the last poll that showed input on this
    /// controller (any button or touch, trigger or grip above 0.05, stick past
    /// 0.2); -100 before any.
    public var lastActivity: TimeInterval

    public init(connected: Bool = false,
                pose: SensePose? = nil,
                buttons: SenseButtons = [],
                touches: SenseButtons = [],
                nearTouches: SenseButtons = [],
                trigger: Float = 0,
                grip: Float = 0,
                stick: SIMD2<Float> = .zero,
                lastActivity: TimeInterval = -100) {
        self.connected = connected
        self.pose = pose
        self.buttons = buttons
        self.touches = touches
        self.nearTouches = nearTouches
        self.trigger = trigger
        self.grip = grip
        self.stick = stick
        self.lastActivity = lastActivity
    }
}

/// The physical controller for drawing a ghost model: the `.grip` frame with
/// the platform's RENDERED correction (the one meant for drawing content
/// aligned with the device) and none of the consumer's calibration.
public struct SenseGhostSample: Sendable {
    /// ARKit origin from `.grip` (rendered correction), or the anchor's own
    /// transform for an accessory that publishes no grip.
    public var originFromGrip: simd_float4x4
    /// false: untracked, or orientation only.
    public var positionTracked: Bool
    /// `AccessoryAnchor.heldChirality != nil`.
    public var heldByPlatform: Bool
    /// m/s.
    public var speed: Float
    /// rad/s.
    public var angularSpeed: Float

    public init(originFromGrip: simd_float4x4 = matrix_identity_float4x4,
                positionTracked: Bool = false,
                heldByPlatform: Bool = false,
                speed: Float = 0,
                angularSpeed: Float = 0) {
        self.originFromGrip = originFromGrip
        self.positionTracked = positionTracked
        self.heldByPlatform = heldByPlatform
        self.speed = speed
        self.angularSpeed = angularSpeed
    }
}
