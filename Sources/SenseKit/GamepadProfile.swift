import Foundation
import GameController
import simd

/// Reads a classic `GCController` into a `GamepadState`, by polling — the
/// same way `SenseControllers.pollInput()` reads the Sense — so a consumer
/// has one frame-synchronous picture of every pad and no handler queues to
/// reconcile.
///
/// Two readers:
///
/// * **`extendedGamepad`** (DualSense, Xbox, Switch Pro…): the profile's own
///   positional elements. `buttonA`→`a` (south), `buttonB`→`b` (east),
///   `buttonX`→`x` (west), `buttonY`→`y` (north), shoulders→`l`/`r`,
///   triggers→`zl`/`zr` with their analog values, `buttonMenu`→`start`,
///   `buttonOptions`→`select`, `buttonHome`→`home`, "Button Share"→`capture`,
///   dpad, both sticks and their clicks.
///
/// * **Element names** (the Switch Online **N64** pad, which visionOS exposes
///   as `productCategory == "Switch N64 Controller"` with no
///   `extendedGamepad`; also any unknown non-spatial pad). As seen on device:
///
///   | Element                           | N64        | `GamepadState`              |
///   |-----------------------------------|------------|-----------------------------|
///   | "Button A" / "Button B"           | A / B      | `a` / `b`                   |
///   | "Left Trigger"                    | **Z**      | `zl` (+ `leftTrigger` 1)    |
///   | "Left Shoulder" / "Right Shoulder"| L / R      | `l` / `r`                   |
///   | "Right Trigger"                   | (unknown)  | `zr` (+ `rightTrigger` 1)   |
///   | "Button Menu"                     | Start      | `start`                     |
///   | "Button Share"                    | (Share)    | `select`                    |
///   | "Button Home"                     | (Home)     | `home`                      |
///   | "Direction Pad" (+ Up/Down/…)     | D-pad      | `dpadUp`…`dpadRight`        |
///   | "Left Thumbstick" (dpad element)  | stick      | `leftStick`                 |
///   | "Right Thumbstick Up/Down/Left/Right" | C buttons | `cUp`…`cRight`, and `rightStick` as ±1 |
///
///   **Z is reported as `zl`**: GameController names the N64's Z "Left
///   Trigger", and the generic name is kept so one mapping (`zl` →
///   Z-target) serves the N64 and an extended pad alike. A `.unknown` pad
///   gets the same names minus the C buttons (its "Right Thumbstick" is a
///   stick).
///
/// Spatial controllers (the Sense) are not gamepads: `read` returns nil for
/// them, and `SenseControllers` reads them.
public enum GamepadProfile {
    /// What `c` is to the hub, or nil for a spatial controller.
    public static func kind(of c: GCController) -> GamepadKind? {
        if c.productCategory == GCProductCategorySpatialController { return nil }
        if c.productCategory.localizedCaseInsensitiveContains("N64") { return .n64 }
        if c.extendedGamepad != nil { return .extended }
        return .unknown
    }

    /// This instant's state of `c`, or nil for a spatial controller.
    /// `lastActivity` is left at its default; the hub fills it in.
    public static func read(_ c: GCController) -> GamepadState? {
        guard let kind = kind(of: c) else { return nil }
        switch kind {
        case .extended:
            guard let pad = c.extendedGamepad else { return nil }
            let share = c.physicalInputProfile.buttons["Button Share"]?.isPressed ?? false
            // Live elements, not `capture()`: on visionOS 27 the snapshot of a controller
            // without an extended profile (the N64) never reflected any press, while the live
            // elements (and their handlers) did.
            return read(extended: pad, capture: share)
        case .n64, .unknown:
            let p = c.physicalInputProfile
            return read(kind: kind,
                        pressed: { p.buttons[$0]?.isPressed ?? false },
                        pad: { p.dpads[$0].map { SIMD2($0.xAxis.value, $0.yAxis.value) } },
                        axis: { p.axes[$0]?.value })
        }
    }

    /// The extended profile, positionally. `capture` is the pad's separate
    /// Share / Capture button where it has one ("Button Share" in the
    /// physical profile; absent on a DualSense, whose Create is `buttonOptions`).
    public static func read(extended pad: GCExtendedGamepad, capture: Bool = false) -> GamepadState {
        var st = GamepadState(connected: true, kind: .extended)
        var b: GamepadButtons = []
        if pad.buttonA.isPressed { b.insert(.a) }
        if pad.buttonB.isPressed { b.insert(.b) }
        if pad.buttonX.isPressed { b.insert(.x) }
        if pad.buttonY.isPressed { b.insert(.y) }
        if pad.leftShoulder.isPressed { b.insert(.l) }
        if pad.rightShoulder.isPressed { b.insert(.r) }
        if pad.leftTrigger.isPressed { b.insert(.zl) }
        if pad.rightTrigger.isPressed { b.insert(.zr) }
        if pad.buttonMenu.isPressed { b.insert(.start) }
        if pad.buttonOptions?.isPressed ?? false { b.insert(.select) }
        if pad.buttonHome?.isPressed ?? false { b.insert(.home) }
        if capture { b.insert(.capture) }
        if pad.leftThumbstickButton?.isPressed ?? false { b.insert(.leftStickClick) }
        if pad.rightThumbstickButton?.isPressed ?? false { b.insert(.rightStickClick) }
        if pad.dpad.up.isPressed { b.insert(.dpadUp) }
        if pad.dpad.down.isPressed { b.insert(.dpadDown) }
        if pad.dpad.left.isPressed { b.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { b.insert(.dpadRight) }
        st.buttons = b
        st.leftStick = SIMD2(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
        st.rightStick = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        st.leftTrigger = pad.leftTrigger.value
        st.rightTrigger = pad.rightTrigger.value
        return st
    }

    /// The element-name reader, as closures so it can be driven without
    /// hardware (mirrors `SenseButtons.pressed(hand:_:)`).
    ///
    /// - Parameters:
    ///   - kind: `.n64` reads "Right Thumbstick Up/Down/Left/Right" as the C
    ///     buttons; `.unknown` (or any other) reads it as a plain stick.
    ///   - pressed: a button element's `isPressed`, false when absent.
    ///   - pad: a direction-pad element's (x, y), nil when absent.
    ///   - axis: an axis element's value, nil when absent.
    ///
    /// Directions are read BOTH as their own button elements and off the pad
    /// element's axes (past 0.5), because which of the two a given pad
    /// publishes is exactly what cannot be known off-device.
    public static func read(kind: GamepadKind,
                            pressed: (String) -> Bool,
                            pad: (String) -> SIMD2<Float>?,
                            axis: (String) -> Float?) -> GamepadState {
        var st = GamepadState(connected: true, kind: kind)
        var b: GamepadButtons = []
        if pressed("Button A") { b.insert(.a) }
        if pressed("Button B") { b.insert(.b) }
        if pressed("Button X") { b.insert(.x) }
        if pressed("Button Y") { b.insert(.y) }
        if pressed("Left Shoulder") { b.insert(.l) }
        if pressed("Right Shoulder") { b.insert(.r) }
        if pressed("Left Trigger") { b.insert(.zl) }
        if pressed("Right Trigger") { b.insert(.zr) }
        if pressed("Button Menu") { b.insert(.start) }
        if pressed("Button Share") || pressed("Button Options") { b.insert(.select) }
        if pressed("Button Home") { b.insert(.home) }
        if pressed("Left Thumbstick Button") { b.insert(.leftStickClick) }
        if pressed("Right Thumbstick Button") { b.insert(.rightStickClick) }

        func stick(_ name: String) -> SIMD2<Float> {
            if let v = pad(name) { return v }
            return SIMD2(axis("\(name) X Axis") ?? 0, axis("\(name) Y Axis") ?? 0)
        }
        /// (right, left, up, down) of a four-way element, by button or by axis.
        func four(_ name: String) -> (Bool, Bool, Bool, Bool) {
            let v = pad(name) ?? .zero
            return (pressed("\(name) Right") || v.x > 0.5,
                    pressed("\(name) Left") || v.x < -0.5,
                    pressed("\(name) Up") || v.y > 0.5,
                    pressed("\(name) Down") || v.y < -0.5)
        }

        let d = four("Direction Pad")
        if d.0 { b.insert(.dpadRight) }
        if d.1 { b.insert(.dpadLeft) }
        if d.2 { b.insert(.dpadUp) }
        if d.3 { b.insert(.dpadDown) }

        st.leftStick = stick("Left Thumbstick")
        if kind == .n64 {
            let c = four("Right Thumbstick")
            if c.0 { b.insert(.cRight) }
            if c.1 { b.insert(.cLeft) }
            if c.2 { b.insert(.cUp) }
            if c.3 { b.insert(.cDown) }
            st.rightStick = SIMD2((c.0 ? 1 : 0) - (c.1 ? 1 : 0), (c.2 ? 1 : 0) - (c.3 ? 1 : 0))
        } else {
            st.rightStick = stick("Right Thumbstick")
        }
        st.buttons = b
        st.leftTrigger = b.contains(.zl) ? 1 : 0
        st.rightTrigger = b.contains(.zr) ? 1 : 0
        return st
    }

    /// Any sign of a hand on the pad: a button, a trigger, a stick off-centre.
    public static func showsActivity(_ st: GamepadState) -> Bool {
        !st.buttons.isEmpty || st.leftTrigger > 0.05 || st.rightTrigger > 0.05
            || simd_length(st.leftStick) > 0.2 || simd_length(st.rightStick) > 0.2
    }
}
