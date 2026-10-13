import Foundation
import simd

/// The pure maths behind `SenseControllers`, separate so it can be tested
/// without a controller.
public enum SenseMath {
    /// Degrees to a quaternion, X then Y then Z in the frame being corrected.
    public static func eulerXYZ(_ degrees: SIMD3<Float>) -> simd_quatf {
        let r = degrees * .pi / 180
        return simd_quatf(angle: r.x, axis: [1, 0, 0])
             * simd_quatf(angle: r.y, axis: [0, 1, 0])
             * simd_quatf(angle: r.z, axis: [0, 0, 1])
    }

    /// `eulerXYZ` read back off a transform, in degrees — the same convention
    /// a SteamVR render model's `rotate_xyz` states, so a measured row and a
    /// row out of a model file can be compared term by term.
    public static func eulerDegrees(of m: simd_float4x4) -> SIMD3<Float> {
        let r = 180 / Float.pi
        return SIMD3<Float>(atan2(-m.columns.2.y, m.columns.2.z) * r,
                            asin(max(-1, min(1, m.columns.2.x))) * r,
                            atan2(-m.columns.1.x, m.columns.0.x) * r)
    }

    /// The instant to ask the tracker for, or nil for the measured pose.
    ///
    /// Predicted no further AHEAD than the cap, so a consumer that predicts
    /// again downstream is handed a pose that has not already reached into its
    /// territory. The cap is applied to the target INSTANT and the tracker is
    /// asked for that instant, rather than the pose being scaled after the
    /// fact: a pose is not linear in time and the tracker is the thing that
    /// knows how to move it. A target in the past is clamped to `now`.
    ///
    /// - Parameters:
    ///   - now: `CACurrentMediaTime()`.
    ///   - time: the frame's presentation time, same clock.
    ///   - capSeconds: the horizon; `<= 0` turns prediction off.
    public static func predictionTarget(now: TimeInterval, time: TimeInterval,
                                        capSeconds: Double) -> TimeInterval? {
        capSeconds > 0.0 ? now + min(max(time - now, 0), capSeconds) : nil
    }

    /// The thumbstick, from the first source that is actually deflected.
    ///
    /// The PSVR2 Sense publishes the stick THREE ways at once (dpad
    /// "Thumbstick", axes "Thumbstick X/Y Axis", and discrete buttons
    /// "Thumbstick Left/Right/Up/Down"), and NOT every one carries the live
    /// analog: the dpad element exists but its axes can read a flat 0. So:
    /// the analog dpad, then the per-side dpad a conventional gamepad uses,
    /// then the analog axes, then the discrete direction buttons as a coarse
    /// ±1 so a stick that only reports edges still moves.
    ///
    /// - Parameters:
    ///   - dpad: `dpads["Thumbstick"]` (ALVR's reading), if present.
    ///   - sideDpad: `dpads["Left Thumbstick"]` / `["Right Thumbstick"]`, if present.
    ///   - axes: ("Thumbstick X Axis", "Thumbstick Y Axis"), 0 when absent.
    ///   - buttons: (Right − Left, Up − Down) of the discrete direction buttons.
    public static func pickStick(dpad: SIMD2<Float>?, sideDpad: SIMD2<Float>?,
                                 axes: SIMD2<Float>, buttons: SIMD2<Float>) -> SIMD2<Float> {
        let eps: Float = 0.02
        func live(_ v: SIMD2<Float>) -> Bool { v.x*v.x + v.y*v.y > eps*eps }
        if let v = dpad, live(v) { return v }
        if let v = sideDpad, live(v) { return v }
        if live(axes) { return axes }
        return buttons
    }
}
