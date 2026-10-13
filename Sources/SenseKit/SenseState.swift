import simd
import Foundation

/// A tracked controller pose with velocities.
public struct SensePose: Sendable {
    public var position: SIMD3<Float>
    public var orientation: simd_quatf
    public var linearVelocity: SIMD3<Float>
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
    public var connected: Bool
    public var pose: SensePose?            // nil = not tracked this frame
    public var buttons: SenseButtons
    public var touches: SenseButtons       // capacitive
    public var nearTouches: SenseButtons
    public var trigger: Float
    public var grip: Float
    public var stick: SIMD2<Float>
    public var lastActivity: TimeInterval

    public init(connected: Bool = false,
                pose: SensePose? = nil,
                buttons: SenseButtons = [],
                touches: SenseButtons = [],
                nearTouches: SenseButtons = [],
                trigger: Float = 0,
                grip: Float = 0,
                stick: SIMD2<Float> = .zero,
                lastActivity: TimeInterval = 0) {
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

/// A pose sample for drawing a ghost controller, flagged when it has a real position.
public struct SenseGhostSample: Sendable {
    public var pose: SensePose
    public var positioned: Bool

    public init(pose: SensePose = SensePose(), positioned: Bool = false) {
        self.pose = pose
        self.positioned = positioned
    }
}
