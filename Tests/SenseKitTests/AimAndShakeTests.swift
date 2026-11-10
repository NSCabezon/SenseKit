import Foundation
import Testing
import simd
@testable import SenseKit

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-5) -> Bool {
    simd_length(a - b) <= eps
}
private func close(_ a: simd_quatf, _ b: simd_quatf, _ eps: Float = 1e-5) -> Bool {
    min(simd_length(a.vector - b.vector), simd_length(a.vector + b.vector)) <= eps
}

@Suite struct AimTests {
    @Test func presetIsThePlatformAimPitch() {
        let c = SenseGripCorrection.aim
        #expect(c == SenseGripCorrection(tiltDegrees: 0, pitchDegrees: -34.81, position: .zero))
        #expect(SenseGripCorrection.aimPitchDegrees == -34.81)
        #expect(c.yawDegrees == 0 && c.rollDegrees == 0 && c.pivot == .zero)
    }

    @Test func presetTurnsGripIntoAim() {
        // The probe reads `.aim` relative to `.grip` as eulerXYZ(-34.81, 0, 0);
        // the preset must produce exactly that frame, on either hand.
        let raw = simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3<Float>(0.3, -1, 0.5)))
        let o = SIMD3<Float>(0.2, 1.1, -0.5)
        let aimFromGrip = SenseMath.eulerXYZ(SIMD3<Float>(-34.81, 0, 0))
        for hand in SenseHand.allCases {
            let (p, q) = SenseGripCorrection.aim.apply(raw: raw, origin: o, hand: hand)
            #expect(close(p, o))
            #expect(close(q, simd_normalize(raw * aimFromGrip)))
            let back = SenseMath.eulerDegrees(of: simd_float4x4(raw.inverse * q))
            #expect(close(back, SIMD3<Float>(-34.81, 0, 0), 1e-3))
        }
    }

    @Test func aimPointsBelowGripForward() {
        // With the grip at identity the ray leaves -Z pitched by -34.81 about
        // X: down and forward (y < 0, z < 0).
        let (p, q) = SenseGripCorrection.aim.apply(raw: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                   origin: .zero, hand: .right)
        let ray = SenseRay(position: p, orientation: q)
        let a = Float(-34.81) * .pi / 180
        #expect(close(ray.direction, SIMD3<Float>(0, sin(a), -cos(a))))
        #expect(ray.direction.y < 0 && ray.direction.z < 0)
    }

    @Test func rayFromFrame() {
        let identity = SenseRay(position: SIMD3(1, 2, 3), orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        #expect(identity.origin == SIMD3(1, 2, 3))
        #expect(close(identity.direction, SIMD3(0, 0, -1)))
        #expect(close(identity.point(at: 2), SIMD3(1, 2, 1)))
        let turned = SenseRay(position: .zero, orientation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        #expect(close(turned.direction, SIMD3(-1, 0, 0)))          // yaw left: -Z turns to -X
        #expect(abs(simd_length(turned.direction) - 1) < 1e-6)
    }

    @Test func noAnchorNoRay() {
        let s = SenseControllers()
        for hand in SenseHand.allCases { #expect(s.aimRay(hand, at: 0) == nil) }
    }
}

@Suite struct ShakeDetectorTests {
    private let still = SIMD3<Float>(0, 0, 0)
    private let fast = SIMD3<Float>(0, 1.7, 0)         // past 1.6 m/s
    private let flick = SIMD3<Float>(12.5, 0, 0)       // past 12 rad/s

    @Test func defaults() {
        let d = ShakeDetector()
        #expect(d.linearThreshold == 1.6)
        #expect(d.angularThreshold == 12)
        #expect(d.refractory == 0.25)
        #expect(d.holdTicks == 5)
    }

    @Test func thresholdsAreStrict() {
        var d = ShakeDetector()
        #expect(d.update(linearVelocity: SIMD3(1.6, 0, 0), angularVelocity: SIMD3(0, 0, 12), at: 0) == false)
        #expect(d.update(linearVelocity: still, angularVelocity: still, at: 0.01) == false)
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: 0.02) == true)
        var w = ShakeDetector()
        #expect(w.update(linearVelocity: still, angularVelocity: flick, at: 0) == true)   // a wrist flick alone
    }

    @Test func pulseIsHeldForHoldTicks() {
        var d = ShakeDetector()
        var t: TimeInterval = 1
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: t) == true)   // tick 1
        for _ in 0..<4 {                                                       // ticks 2...5, still
            t += 1 / 120
            #expect(d.update(linearVelocity: still, angularVelocity: still, at: t) == true)
        }
        t += 1 / 120
        #expect(d.update(linearVelocity: still, angularVelocity: still, at: t) == false)
        var one = ShakeDetector(holdTicks: 1)
        #expect(one.update(linearVelocity: fast, angularVelocity: still, at: 0) == true)
        #expect(one.update(linearVelocity: still, angularVelocity: still, at: 0.01) == false)
    }

    @Test func refractoryMakesOneMotionOneShake() {
        var d = ShakeDetector(holdTicks: 1)
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: 10) == true)
        #expect(d.lastShake == 10)
        // Still moving fast inside the refractory period: no new pulse.
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: 10.1) == false)
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: 10.249) == false)
        #expect(d.lastShake == 10)
        // From the start of the last shake, not from the end of the motion.
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: 10.25) == true)
        #expect(d.lastShake == 10.25)
    }

    @Test func customThresholds() {
        var d = ShakeDetector(linearThreshold: 3, angularThreshold: 20, refractory: 0, holdTicks: 1)
        #expect(d.update(linearVelocity: fast, angularVelocity: flick, at: 0) == false)
        #expect(d.update(linearVelocity: SIMD3(3.1, 0, 0), angularVelocity: still, at: 0.01) == true)
        #expect(d.update(linearVelocity: still, angularVelocity: SIMD3(0, 0, 21), at: 0.02) == true)   // no refractory
    }

    @Test func fromPose() {
        var d = ShakeDetector(holdTicks: 2)
        #expect(d.update(pose: nil, at: 0) == false)
        #expect(d.update(pose: SensePose(linearVelocity: fast), at: 1) == true)
        #expect(d.update(pose: nil, at: 1.01) == true)        // a lost pose lets the pulse finish
        #expect(d.update(pose: nil, at: 1.02) == false)
        #expect(d == {
            var e = ShakeDetector(holdTicks: 2)
            _ = e.update(pose: SensePose(angularVelocity: flick), at: 1)
            _ = e.update(pose: nil, at: 1.01)
            _ = e.update(pose: nil, at: 1.02)
            return e
        }())
    }

    @Test func resetForgetsPulseAndRefractory() {
        var d = ShakeDetector()
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: 5) == true)
        d.reset()
        #expect(d.lastShake == -.infinity)
        #expect(d.update(linearVelocity: still, angularVelocity: still, at: 5.01) == false)
        #expect(d.update(linearVelocity: fast, angularVelocity: still, at: 5.02) == true)  // no refractory left
    }
}
