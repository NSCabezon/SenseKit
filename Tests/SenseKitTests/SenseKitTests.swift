import Testing
import simd
@testable import SenseKit

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool {
    simd_length(a - b) <= eps
}
private func close(_ a: simd_quatf, _ b: simd_quatf, _ eps: Float = 1e-5) -> Bool {
    // q and -q are the same rotation.
    min(simd_length(a.vector - b.vector), simd_length(a.vector + b.vector)) <= eps
}

@Suite struct SenseKitTests {
    @Test func buttonBitsAreDistinct() {
        let all: [SenseButtons] = [.cross, .circle, .square, .triangle, .options,
                                   .create, .ps, .stickClick, .trigger, .grip]
        var seen: UInt32 = 0
        for b in all {
            #expect(b.rawValue != 0)
            #expect(seen & b.rawValue == 0)
            seen |= b.rawValue
        }
    }

    @Test func defaults() {
        let c = SenseConfiguration()
        #expect(c.haptics.gain == 0.25)
        #expect(c.haptics.sharpness == 1.0)
        #expect(c.haptics.mode == .continuous)
        #expect(c.haptics.minPulseMs == 32)
        #expect(c.haptics.enabled)
        #expect(c.predictionCapMs == 50)
        #expect(c.velocityGate == SenseVelocityGate(linear: 0, angular: 0))
        #expect(c.velocityInAccessoryFrame)
        let g = c.gripCorrection
        #expect(g.tiltDegrees == 5.037)
        #expect(g.pitchDegrees == -37)
        #expect(g.yawDegrees == 0 && g.rollDegrees == 0)
        #expect(g.position == SIMD3<Float>(-0.005, 0.02, -0.02))
        #expect(g.pivot == .zero)
        #expect(g.mirrorLeft)
    }

    @Test func freshControllersAreDisconnected() {
        let s = SenseControllers()
        for hand in SenseHand.allCases {
            let st = s.state(hand, at: 0)
            #expect(!st.connected)
            #expect(st.pose == nil)
            #expect(s.ghostSample(hand, at: 0) == nil)
        }
        #expect(!s.controllersChanged())
    }

    // MARK: - Hand assignment

    @Test func handFromVendorName() {
        #expect(SenseHand.forVendorName("PlayStation VR2 Sense Controller (L)") == .left)
        #expect(SenseHand.forVendorName("PlayStation VR2 Sense Controller (R)") == .right)
        #expect(SenseHand.forVendorName(nil) == .right)
        #expect(SenseHand.forVendorName("Something") == .right)
    }

    // MARK: - Button mapping

    @Test func faceButtonsFollowTheHand() {
        let ab: (String) -> Bool = { $0 == "Button A" || $0 == "Button B" }
        #expect(SenseButtons.pressed(hand: .left, ab) == [.square, .triangle])
        #expect(SenseButtons.pressed(hand: .right, ab) == [.cross, .circle])
        #expect(SenseButtons.pressed(hand: .left, { $0 == "Button A" }) == .square)
        #expect(SenseButtons.pressed(hand: .right, { $0 == "Button B" }) == .circle)
    }

    @Test func menuButtons() {
        // The Sense reports Create (L) and Options (R) both as "Button Menu".
        #expect(SenseButtons.pressed(hand: .left, { $0 == "Button Menu" }) == .create)
        #expect(SenseButtons.pressed(hand: .right, { $0 == "Button Menu" }) == .options)
        // Other spatial controllers' names are Options on either hand, never Create.
        for n in ["Button Share", "Button Options"] {
            #expect(SenseButtons.pressed(hand: .left, { $0 == n }) == .options)
            #expect(SenseButtons.pressed(hand: .right, { $0 == n }) == .options)
        }
        for n in ["Button Home", "Button PS", "Button PS Button"] {
            #expect(SenseButtons.pressed(hand: .left, { $0 == n }) == .ps)
        }
    }

    @Test func stickTriggerGrip() {
        #expect(SenseButtons.pressed(hand: .left, { $0 == "Thumbstick Button" }) == .stickClick)
        #expect(SenseButtons.pressed(hand: .right, { $0 == "Trigger" }) == .trigger)
        #expect(SenseButtons.pressed(hand: .right, { $0 == "Grip" }) == .grip)
        #expect(SenseButtons.pressed(hand: .right, { _ in false }) == [])
        // Unknown names map to nothing.
        #expect(SenseButtons.pressed(hand: .right, { $0 == "Button X" }) == [])
    }

    @Test func touches() {
        let all: (String) -> Bool = { _ in true }
        #expect(SenseButtons.touched(hand: .left, all) == [.square, .triangle, .trigger, .stickClick])
        #expect(SenseButtons.touched(hand: .right, all) == [.cross, .circle, .trigger, .stickClick])
        // Grip and menu have no capacitive reading.
        #expect(SenseButtons.touched(hand: .right, { $0 == "Grip" || $0 == "Button Menu" }) == [])
    }

    // MARK: - Grip correction

    @Test func eulerRoundTrip() {
        let d = SIMD3<Float>(-31.963, 12, -7)
        let q = SenseMath.eulerXYZ(d)
        #expect(close(SenseMath.eulerDegrees(of: simd_float4x4(q)), d, 1e-3))
    }

    @Test func identityCorrectionIsIdentity() {
        let c = SenseGripCorrection(tiltDegrees: 0, pitchDegrees: 0, position: .zero)
        let raw = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        let o = SIMD3<Float>(0.1, 1.2, -0.3)
        for hand in SenseHand.allCases {
            let (p, q) = c.apply(raw: raw, origin: o, hand: hand)
            #expect(close(p, o))
            #expect(close(q, raw))
        }
    }

    @Test func defaultCorrectionMatchesKlepton() {
        // The pose Klepton computed before the move, written out by hand:
        // q = raw * Rx(5.037 - 37), p = origin + raw.act(pos), X of pos
        // mirrored for the left hand.
        let c = SenseGripCorrection()
        let raw = simd_quatf(angle: 1.1, axis: simd_normalize(SIMD3<Float>(-1, 0.5, 2)))
        let o = SIMD3<Float>(0.3, 1.0, -0.4)
        let rot = simd_quatf(angle: (5.037 - 37) * .pi / 180, axis: [1, 0, 0])
        let right = c.apply(raw: raw, origin: o, hand: .right)
        #expect(close(right.orientation, simd_normalize(raw * rot)))
        #expect(close(right.position, o + raw.act(SIMD3<Float>(-0.005, 0.02, -0.02))))
        let left = c.apply(raw: raw, origin: o, hand: .left)
        #expect(close(left.orientation, simd_normalize(raw * rot)))      // pitch is not mirrored
        #expect(close(left.position, o + raw.act(SIMD3<Float>(0.005, 0.02, -0.02))))
    }

    @Test func mirrorNegatesYawRollAndX() {
        var c = SenseGripCorrection(tiltDegrees: 0, pitchDegrees: 10, yawDegrees: 20, rollDegrees: 30,
                                    position: SIMD3<Float>(0.01, 0.02, 0.03))
        let raw = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let left = c.apply(raw: raw, origin: .zero, hand: .left)
        #expect(close(left.orientation, SenseMath.eulerXYZ(SIMD3<Float>(10, -20, -30))))
        #expect(close(left.position, SIMD3<Float>(-0.01, 0.02, 0.03)))
        let right = c.apply(raw: raw, origin: .zero, hand: .right)
        #expect(close(right.orientation, SenseMath.eulerXYZ(SIMD3<Float>(10, 20, 30))))
        #expect(close(right.position, SIMD3<Float>(0.01, 0.02, 0.03)))
        c.mirrorLeft = false
        let unmirrored = c.apply(raw: raw, origin: .zero, hand: .left)
        #expect(close(unmirrored.orientation, right.orientation))
        #expect(close(unmirrored.position, right.position))
    }

    @Test func pivotStaysPut() {
        // Rotating about a pivot leaves the pivot's world position unchanged.
        let pivot = SIMD3<Float>(0, -0.04, -0.06)
        let c = SenseGripCorrection(tiltDegrees: 0, pitchDegrees: -40, position: .zero, pivot: pivot)
        let raw = simd_quatf(angle: 0.4, axis: [0, 1, 0])
        let o = SIMD3<Float>(1, 1, 1)
        let (p, q) = c.apply(raw: raw, origin: o, hand: .right)
        #expect(close(p + q.act(pivot), o + raw.act(pivot)))
        // ...while a zero pivot turns about the origin.
        let c0 = SenseGripCorrection(tiltDegrees: 0, pitchDegrees: -40, position: .zero)
        #expect(close(c0.apply(raw: raw, origin: o, hand: .right).position, o))
    }

    // MARK: - Velocity gate

    @Test func velocityGate() {
        let v = SIMD3<Float>(0.03, 0.04, 0)                 // |v| = 0.05
        #expect(SenseVelocityGate.gate(v, 0) == v)          // off
        #expect(SenseVelocityGate.gate(v, -1) == v)
        #expect(SenseVelocityGate.gate(v, 0.06) == .zero)   // below
        #expect(SenseVelocityGate.gate(v, 0.05) == .zero)   // at
        let fast = SIMD3<Float>(0, 3, 4)                    // |v| = 5
        let g = SenseVelocityGate.gate(fast, 0.06)
        #expect(abs(simd_length(g) - 4.94) < 1e-5)          // minus the threshold
        #expect(close(simd_normalize(g), simd_normalize(fast)))   // same direction
        #expect(SenseVelocityGate.gate(.zero, 0.06) == .zero)
    }

    // MARK: - Prediction cap

    @Test func predictionCap() {
        let now: Double = 100
        #expect(SenseMath.predictionTarget(now: now, time: now + 0.03, capSeconds: 0) == nil)
        #expect(SenseMath.predictionTarget(now: now, time: now + 0.03, capSeconds: -1) == nil)
        #expect(SenseMath.predictionTarget(now: now, time: now + 0.03, capSeconds: 0.05) == now + 0.03)
        #expect(SenseMath.predictionTarget(now: now, time: now + 0.08, capSeconds: 0.05) == now + 0.05)
        #expect(SenseMath.predictionTarget(now: now, time: now - 0.01, capSeconds: 0.05) == now)
    }

    // MARK: - Stick source

    @Test func stickSource() {
        let z = SIMD2<Float>(0, 0)
        let a = SIMD2<Float>(0.5, -0.2)
        let b = SIMD2<Float>(-0.3, 0.9)
        #expect(SenseMath.pickStick(dpad: a, sideDpad: b, axes: b, buttons: b) == a)
        #expect(SenseMath.pickStick(dpad: z, sideDpad: b, axes: a, buttons: a) == b)   // flat dpad skipped
        #expect(SenseMath.pickStick(dpad: nil, sideDpad: nil, axes: a, buttons: b) == a)
        #expect(SenseMath.pickStick(dpad: z, sideDpad: z, axes: z, buttons: SIMD2(1, 0)) == SIMD2(1, 0))
        #expect(SenseMath.pickStick(dpad: SIMD2(0.01, 0.01), sideDpad: nil, axes: z, buttons: z) == z)
    }

    @Test func activity() {
        #expect(!SenseControllers.showsActivity(SenseHandState(connected: true)))
        #expect(SenseControllers.showsActivity(SenseHandState(touches: .trigger)))
        #expect(SenseControllers.showsActivity(SenseHandState(trigger: 0.06)))
        #expect(!SenseControllers.showsActivity(SenseHandState(trigger: 0.05)))
        #expect(SenseControllers.showsActivity(SenseHandState(stick: SIMD2(0.21, 0))))
        #expect(!SenseControllers.showsActivity(SenseHandState(stick: SIMD2(0.2, 0))))
    }
}
