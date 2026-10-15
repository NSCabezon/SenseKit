import Testing
import simd
@testable import SenseKit

@Suite struct GamepadButtonsTests {
    @Test func bitsAreDistinct() {
        let all: [GamepadButtons] = [.a, .b, .x, .y, .l, .r, .zl, .zr, .start, .select, .home, .capture,
                                     .leftStickClick, .rightStickClick,
                                     .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .cUp, .cDown, .cLeft, .cRight]
        var seen: UInt32 = 0
        for b in all {
            #expect(b.rawValue != 0)
            #expect(seen & b.rawValue == 0)
            seen |= b.rawValue
        }
    }

    @Test func edges() {
        let before: GamepadButtons = [.a, .l]
        let after: GamepadButtons = [.a, .zl]
        let e = after.changes(since: before)
        #expect(e.pressed == .zl)
        #expect(e.released == .l)
        #expect(after.changes(since: after).pressed == [])
    }

    @Test func dpadVector() {
        #expect(GamepadButtons([.dpadUp, .dpadRight]).dpadVector == SIMD2(1, 1))
        #expect(GamepadButtons([.dpadDown]).dpadVector == SIMD2(0, -1))
        #expect(GamepadButtons([.dpadLeft, .dpadRight]).dpadVector == .zero)
    }
}

/// The N64 reader through its closure seam: no hardware, element names only.
@Suite struct N64MappingTests {
    private func n64(_ names: Set<String>, pads: [String: SIMD2<Float>] = [:],
                     axes: [String: Float] = [:]) -> GamepadState {
        GamepadProfile.read(kind: .n64, pressed: { names.contains($0) },
                            pad: { pads[$0] }, axis: { axes[$0] })
    }

    @Test func faceAndMenu() {
        #expect(n64(["Button A"]).buttons == .a)
        #expect(n64(["Button B"]).buttons == .b)
        #expect(n64(["Button Menu"]).buttons == .start)
        #expect(n64(["Button Share"]).buttons == .select)
        #expect(n64(["Button Home"]).buttons == .home)
        #expect(n64([]).buttons == [])
        #expect(n64(["Button Nope"]).buttons == [])
        #expect(n64([]).connected)
        #expect(n64([]).kind == .n64)
    }

    @Test func zIsLeftTrigger() {
        // The N64's Z arrives as "Left Trigger" and is reported as zl, digital 1.
        let z = n64(["Left Trigger"])
        #expect(z.buttons == .zl)
        #expect(z.leftTrigger == 1)
        #expect(z.rightTrigger == 0)
        #expect(n64(["Left Shoulder"]).buttons == .l)
        #expect(n64(["Right Shoulder"]).buttons == .r)
        let rt = n64(["Right Trigger"])
        #expect(rt.buttons == .zr)
        #expect(rt.rightTrigger == 1)
    }

    @Test func dpadByButtonsAndByAxes() {
        #expect(n64(["Direction Pad Up", "Direction Pad Left"]).buttons == [.dpadUp, .dpadLeft])
        #expect(n64([], pads: ["Direction Pad": SIMD2(1, 0)]).buttons == .dpadRight)
        #expect(n64([], pads: ["Direction Pad": SIMD2(0, -1)]).buttons == .dpadDown)
        // A dpad resting at centre presses nothing.
        #expect(n64([], pads: ["Direction Pad": .zero]).buttons == [])
    }

    @Test func controlStick() {
        let s = n64([], pads: ["Left Thumbstick": SIMD2(0.4, -0.7)])
        #expect(s.leftStick == SIMD2(0.4, -0.7))
        #expect(s.buttons == [])
        // Without the pad element the axes are used.
        let ax = n64([], axes: ["Left Thumbstick X Axis": 0.25, "Left Thumbstick Y Axis": 0.5])
        #expect(ax.leftStick == SIMD2(0.25, 0.5))
        #expect(n64([]).leftStick == .zero)
    }

    @Test func cButtons() {
        let c = n64(["Right Thumbstick Up", "Right Thumbstick Left"])
        #expect(c.buttons == [.cUp, .cLeft])
        #expect(c.rightStick == SIMD2(-1, 1))
        let byAxis = n64([], pads: ["Right Thumbstick": SIMD2(1, 0)])
        #expect(byAxis.buttons == .cRight)
        #expect(byAxis.rightStick == SIMD2(1, 0))
        #expect(n64(["Right Thumbstick Down"]).buttons == .cDown)
        // An unknown pad's right thumbstick is a stick, not C buttons.
        let u = GamepadProfile.read(kind: .unknown, pressed: { _ in false },
                                    pad: { $0 == "Right Thumbstick" ? SIMD2(0.3, 0.2) : nil }, axis: { _ in nil })
        #expect(u.buttons == [])
        #expect(u.rightStick == SIMD2(0.3, 0.2))
        #expect(u.kind == .unknown)
    }

    @Test func activity() {
        #expect(!GamepadProfile.showsActivity(GamepadState(connected: true)))
        #expect(GamepadProfile.showsActivity(GamepadState(buttons: .a)))
        #expect(GamepadProfile.showsActivity(GamepadState(leftStick: SIMD2(0.21, 0))))
        #expect(!GamepadProfile.showsActivity(GamepadState(leftStick: SIMD2(0.2, 0))))
        #expect(GamepadProfile.showsActivity(GamepadState(rightTrigger: 0.06)))
    }
}

@Suite struct StickArbiterTests {
    private let senseL = InputSource.sense(.left)
    private let n64 = InputSource.gamepad(.n64)
    private let pad = InputSource.gamepad(.extended)

    @Test func deadzone() {
        var a = StickArbiter()
        #expect(a.deadzone == 0.2)
        #expect(a.resolve([(senseL, SIMD2(0.19, 0)), (n64, SIMD2(0, 0.1))]) == .zero)
        #expect(a.owner == nil)
        #expect(a.resolve([(senseL, SIMD2(0.21, 0)), (n64, .zero)]) == SIMD2(0.21, 0))
        #expect(a.owner == senseL)
        var tight = StickArbiter(deadzone: 0.5)
        #expect(tight.resolve([(n64, SIMD2(0.4, 0))]) == .zero)
        #expect(tight.resolve([(n64, SIMD2(0.6, 0))]) == SIMD2(0.6, 0))
    }

    @Test func parkedStickDoesNotOverride() {
        // The observed bug: the N64 stick is in use, the Sense left stick
        // sits at (0, 0) and must never win.
        var a = StickArbiter()
        let live = SIMD2<Float>(0.8, 0.1)
        for _ in 0..<5 {
            #expect(a.resolve([(senseL, .zero), (n64, live)]) == live)
            #expect(a.owner == n64)
        }
        // N64 back to centre: its (small) value is still the one reported,
        // and it keeps the axis.
        #expect(a.resolve([(senseL, .zero), (n64, SIMD2(0.05, 0))]) == SIMD2(0.05, 0))
        #expect(a.owner == n64)
        #expect(a.resolve([(senseL, .zero), (n64, .zero)]) == .zero)
        #expect(a.owner == n64)
        // ...and out again without anyone else moving.
        #expect(a.resolve([(senseL, .zero), (n64, live)]) == live)
        #expect(a.owner == n64)
    }

    @Test func handOff() {
        var a = StickArbiter()
        _ = a.resolve([(senseL, SIMD2(0.9, 0)), (n64, .zero)])
        #expect(a.owner == senseL)
        // The N64 crosses the deadzone while the Sense is still held out: the
        // newest mover takes it.
        #expect(a.resolve([(senseL, SIMD2(0.9, 0)), (n64, SIMD2(0, 0.6))]) == SIMD2(0, 0.6))
        #expect(a.owner == n64)
        // Both still held: no new crossing, the N64 keeps it.
        #expect(a.resolve([(senseL, SIMD2(0.9, 0)), (n64, SIMD2(0, 0.7))]) == SIMD2(0, 0.7))
        #expect(a.owner == n64)
        // The Sense goes to centre and back out: that is a crossing, it takes over.
        _ = a.resolve([(senseL, .zero), (n64, SIMD2(0, 0.7))])
        #expect(a.owner == n64)
        #expect(a.resolve([(senseL, SIMD2(-0.5, 0)), (n64, SIMD2(0, 0.7))]) == SIMD2(-0.5, 0))
        #expect(a.owner == senseL)
    }

    @Test func ownerGoesAway() {
        var a = StickArbiter()
        _ = a.resolve([(senseL, SIMD2(0.9, 0)), (pad, .zero)])
        #expect(a.owner == senseL)
        // Disconnected (not offered): the axis is free and reads zero.
        #expect(a.resolve([(pad, .zero)]) == .zero)
        #expect(a.owner == nil)
        // A pad already held out when the axis frees up takes it at once.
        _ = a.resolve([(senseL, SIMD2(0.9, 0)), (pad, SIMD2(0.3, 0.3))])
        #expect(a.owner == senseL)
        #expect(a.resolve([(pad, SIMD2(0.3, 0.3))]) == SIMD2(0.3, 0.3))
        #expect(a.owner == pad)
        a.reset()
        #expect(a.owner == nil)
        #expect(a.resolve([]) == .zero)
    }

    @Test func twoCrossingsInOneFrame() {
        var a = StickArbiter()
        #expect(a.resolve([(senseL, SIMD2(0.3, 0)), (n64, SIMD2(0.9, 0))]) == SIMD2(0.9, 0))
        #expect(a.owner == n64)
    }
}

@Suite struct InputHubTests {
    @Test func freshHubIsEmpty() {
        let hub = SenseInputHub()
        #expect(hub.gamepads.isEmpty)
        #expect(!hub.anyConnected)
        let a = hub.arbitrated()
        #expect(a.leftStick == .zero && a.rightStick == .zero)
        #expect(a.leftStickOwner == nil && a.rightStickOwner == nil)
        #expect(a.buttons == [])
        #expect(!a.senseLeft.connected && !a.senseRight.connected)
        // Polling with nothing paired is a no-op that reports no Sense change.
        #expect(!hub.pollInput())
        #expect(hub.gamepads.isEmpty)
        #expect(!hub.sense(.right).connected)
    }

    @Test func loggerIsShared() {
        let sense = SenseControllers()
        let hub = SenseInputHub(sense: sense)
        #expect(hub.sense === sense)
        hub.logger = { _ in }
        #expect(sense.logger != nil)
    }
}
