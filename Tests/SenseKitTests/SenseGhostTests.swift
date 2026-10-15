import Foundation
import Testing
import simd
@testable import SenseKit

/// A sample at rest at `p`, position-tracked, not held by the platform.
private func resting(_ p: SIMD3<Float> = SIMD3(0, 1, -0.5), speed: Float = 0,
                     angularSpeed: Float = 0, heldByPlatform: Bool = false,
                     positionTracked: Bool = true) -> SenseGhostSample {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(p.x, p.y, p.z, 1)
    return SenseGhostSample(originFromGrip: m, positionTracked: positionTracked,
                            heldByPlatform: heldByPlatform, speed: speed, angularSpeed: angularSpeed)
}

private let origin = SIMD3<Float>(0, 1, -0.5)
private let farPalm = SIMD3<Float>(1, 1, -0.5)        // 1 m away
private let nearPalm = SIMD3<Float>(0.05, 1, -0.5)    // 5 cm away

@Suite struct SenseGhostStateTests {
    /// Runs `update` and returns what it logged.
    private func step(_ s: inout SenseGhostHandState, _ sample: SenseGhostSample?,
                      palms: [SIMD3<Float>] = [], seesHands: Bool = false,
                      lastInput: TimeInterval = -100, now: TimeInterval, dt: Float = 0,
                      cfg: SenseGhostConfiguration = SenseGhostConfiguration(),
                      hand: SenseHand = .left) -> [String] {
        var lines: [String] = []
        s.update(hand: hand, sample: sample, palms: palms, handTrackingSeesHands: seesHands,
                 lastInput: lastInput, now: now, dt: dt, configuration: cfg,
                 log: { lines.append($0) })
        return lines
    }

    @Test func defaults() {
        let c = SenseGhostConfiguration()
        #expect(c.inputWindow == 2.0)
        #expect(c.showAfter == 2.5)
        #expect(c.usePlatformHeld)
        #expect(c.nearIn == 0.09 && c.nearOut == 0.12)
        #expect(c.motionSpeed == 0.08 && c.motionAngularSpeed == 0.9 && c.motionDistance == 0.025)
        #expect(c.motionWindow == 0.6)
        #expect(c.handAwayWait == 1.0)
        #expect(c.fadeSeconds == 0.2)
        #expect(c.fit == matrix_identity_float4x4)
        #expect(c.bodyColor == SIMD4<Float>(0.80, 0.81, 0.84, 1))
        #expect(c.rimColor == SIMD4<Float>(0.10, 0.11, 0.13, 0.85))
        #expect(c.rimWidth == 0.0025)
    }

    @Test func restingControllerShowsAtOnce() {
        var s = SenseGhostHandState()
        let lines = step(&s, resting(), now: 100)
        #expect(s.visible)
        #expect(s.lastReason == "resting (still 2.5 s)")
        #expect(lines == ["left: SHOWN — resting (still 2.5 s)"])
        #expect(s.pose.columns.3 == SIMD4(0, 1, -0.5, 1))
    }

    @Test func inputWithinWindowHides() {
        var s = SenseGhostHandState()
        var lines = step(&s, resting(), lastInput: 99, now: 100)          // 1 s ago
        #expect(!s.visible)
        #expect(s.lastReason == "held (input)")
        #expect(lines.isEmpty)                                            // hidden -> hidden: silent
        // Input 2.5 s old is outside the 2 s window, but the ghost only shows
        // once the held evidence is older than showAfter (no hands tracked).
        lines = step(&s, resting(), lastInput: 99, now: 101.5)
        #expect(!s.visible && s.lastReason == "settling")
        lines = step(&s, resting(), lastInput: 99, now: 102.6)            // 2.6 s after the last held tick
        #expect(s.visible)
        #expect(lines == ["left: SHOWN — resting (still 2.5 s)"])
        // ...and input hides it again, with the line.
        lines = step(&s, resting(), lastInput: 102.9, now: 103, hand: .right)
        #expect(!s.visible)
        #expect(lines == ["right: hidden — held (input)"])
    }

    @Test func platformHeldHides() {
        var s = SenseGhostHandState()
        let lines = step(&s, resting(heldByPlatform: true), now: 100)
        #expect(!s.visible)
        #expect(s.lastReason == "held (platform)")
        #expect(lines == ["left: platform heldChirality SET"])
        let cleared = step(&s, resting(heldByPlatform: false), now: 100.1)
        #expect(cleared == ["left: platform heldChirality cleared"])
        #expect(!s.visible && s.lastReason == "settling")
    }

    @Test func platformHeldIgnoredWhenConfigured() {
        var cfg = SenseGhostConfiguration()
        cfg.usePlatformHeld = false
        var s = SenseGhostHandState()
        let lines = step(&s, resting(heldByPlatform: true), now: 100, cfg: cfg)
        #expect(s.visible)
        #expect(s.lastReason == "resting (still 2.5 s)")
        // The flag's own change is still logged: it is the thing to compare
        // with reality.
        #expect(lines == ["left: SHOWN — resting (still 2.5 s)", "left: platform heldChirality SET"])
    }

    @Test func movingWithPalmNearHides() {
        var s = SenseGhostHandState()
        let lines = step(&s, resting(speed: 0.1), palms: [nearPalm], seesHands: true, now: 100)
        #expect(!s.visible)
        #expect(s.lastReason == "held (hand near + moving)")
        #expect(lines.isEmpty)
        #expect(s.palmNear)
    }

    @Test func movingWithNoHandsTrackedHides() {
        var s = SenseGhostHandState()
        _ = step(&s, resting(angularSpeed: 1.0), palms: [], seesHands: false, now: 100)
        #expect(!s.visible)
        #expect(s.lastReason == "held (moving, no hands tracked)")
        // Moved by distance, too: 3 cm from where it rested.
        var t = SenseGhostHandState()
        _ = step(&t, resting(origin), now: 100)
        #expect(t.visible)
        _ = step(&t, resting(origin + SIMD3(0.03, 0, 0)), now: 100.1)
        #expect(!t.visible && t.lastReason == "held (moving, no hands tracked)")
        #expect(t.restPos == origin + SIMD3(0.03, 0, 0))
    }

    @Test func stillWithPalmNearStaysVisible() {
        // A hand reaching for a controller that is not moving.
        var s = SenseGhostHandState()
        _ = step(&s, resting(), palms: [nearPalm], seesHands: true, now: 100)
        #expect(s.visible)
        #expect(s.palmNear)
        #expect(s.lastReason == "resting (still 2.5 s)")   // near: hand not "away"
    }

    @Test func movingWithTrackedHandAwayStaysVisible() {
        var s = SenseGhostHandState()
        _ = step(&s, resting(speed: 0.5), palms: [farPalm], seesHands: true, now: 100)
        #expect(s.visible)
        #expect(s.lastReason == "resting (hand away)")
    }

    @Test func nearHysteresis() {
        var s = SenseGhostHandState()
        // 10 cm: outside nearIn (9 cm) -> not near.
        _ = step(&s, resting(), palms: [origin + SIMD3(0.10, 0, 0)], seesHands: true, now: 100)
        #expect(!s.palmNear)
        // 8 cm: in.
        _ = step(&s, resting(), palms: [origin + SIMD3(0.08, 0, 0)], seesHands: true, now: 100.1)
        #expect(s.palmNear)
        // 11 cm: still near (nearOut is 12 cm).
        _ = step(&s, resting(), palms: [origin + SIMD3(0.11, 0, 0)], seesHands: true, now: 100.2)
        #expect(s.palmNear)
        // 13 cm: out.
        _ = step(&s, resting(), palms: [origin + SIMD3(0.13, 0, 0)], seesHands: true, now: 100.3)
        #expect(!s.palmNear)
    }

    @Test func restsAfterHandAwayWaitWithATrackedHandAway() {
        var s = SenseGhostHandState()
        _ = step(&s, resting(), lastInput: 100, now: 100)                   // held (input)
        #expect(!s.visible)
        _ = step(&s, resting(), lastInput: 100, now: 101.5)                 // still inside the window
        #expect(!s.visible && s.lastReason == "held (input)")
        _ = step(&s, resting(), palms: [farPalm], seesHands: true, lastInput: 100, now: 102.3)
        #expect(!s.visible && s.lastReason == "settling")                   // 0.8 s since held
        let lines = step(&s, resting(), palms: [farPalm], seesHands: true, lastInput: 100, now: 102.6)
        #expect(s.visible)                                                  // 1.1 s > handAwayWait
        #expect(lines == ["left: SHOWN — resting (hand away)"])
    }

    @Test func restsAfterShowAfterOtherwise() {
        var s = SenseGhostHandState()
        _ = step(&s, resting(), lastInput: 100, now: 100)
        _ = step(&s, resting(), lastInput: 100, now: 101.9)                 // last held tick
        #expect(!s.visible && s.lastReason == "held (input)")
        _ = step(&s, resting(), lastInput: 100, now: 103.1)                 // 1.2 s since held
        #expect(!s.visible && s.lastReason == "settling")
        _ = step(&s, resting(), lastInput: 100, now: 104.3)                 // 2.4 s
        #expect(!s.visible)
        _ = step(&s, resting(), lastInput: 100, now: 104.5)                 // 2.6 s > showAfter
        #expect(s.visible)
        #expect(s.lastReason == "resting (still 2.5 s)")
    }

    @Test func configurableWindows() {
        var cfg = SenseGhostConfiguration()
        cfg.inputWindow = 0.5
        cfg.showAfter = 1.0
        var s = SenseGhostHandState()
        _ = step(&s, resting(), lastInput: 100, now: 100, cfg: cfg)
        #expect(!s.visible)
        _ = step(&s, resting(), lastInput: 100, now: 100.6, cfg: cfg)       // input window shut
        #expect(!s.visible && s.lastReason == "settling")
        _ = step(&s, resting(), lastInput: 100, now: 101.1, cfg: cfg)       // showAfter from the held tick
        #expect(s.visible)
        #expect(s.lastReason == "resting (still 1.0 s)")
    }

    @Test func noSampleHidesAndFades() {
        var s = SenseGhostHandState()
        _ = step(&s, resting(), now: 100, dt: 0.1)
        #expect(s.visible && s.alpha == 0.5)                                // 0.1 / 0.2
        _ = step(&s, resting(), now: 100.1, dt: 0.1)
        #expect(s.alpha == 1)
        _ = step(&s, resting(), now: 100.2, dt: 0.1)
        #expect(s.alpha == 1)                                               // clamped
        var lines = step(&s, nil, now: 100.3, dt: 0.1)
        #expect(!s.visible)
        #expect(s.lastReason == "no anchor")
        #expect(s.alpha == 0.5)
        #expect(lines == ["left: hidden — no anchor"])
        lines = step(&s, nil, now: 100.4, dt: 0.1)
        #expect(s.alpha == 0)
        #expect(lines.isEmpty)                                              // same reason: silent
        lines = step(&s, nil, now: 100.5, dt: 0.1)
        #expect(s.alpha == 0)                                               // clamped
        // Orientation-only is its own reason, said once.
        lines = step(&s, resting(positionTracked: false), now: 100.6, dt: 0.1)
        #expect(lines == ["left: not position-tracked"])
        #expect(s.restPos == nil && !s.palmNear)
    }

    @Test func fadeRateFollowsConfiguration() {
        var cfg = SenseGhostConfiguration()
        cfg.fadeSeconds = 0.5
        var s = SenseGhostHandState()
        _ = step(&s, resting(), now: 100, dt: 0.1, cfg: cfg)
        #expect(abs(s.alpha - 0.2) < 1e-6)
    }

    @Test func ghostsKeepTheClock() {
        let g = SenseGhosts()
        var lines: [String] = []
        g.logger = { lines.append($0) }
        g.update(samples: [resting(), nil], palms: [], handTrackingSeesHands: false,
                 lastInput: [-100, -100], now: 100)
        #expect(g.hands[0].visible && g.hands[0].alpha == 0)                // first tick: dt 0
        #expect(!g.hands[1].visible && g.hands[1].lastReason == "no anchor")
        #expect(lines == ["left: SHOWN — resting (still 2.5 s)", "right: no anchor"])
        g.update(samples: [resting(), nil], palms: [], handTrackingSeesHands: false,
                 lastInput: [-100, -100], now: 100.05)
        #expect(abs(g.hands[0].alpha - 0.25) < 1e-6)                        // 0.05 / 0.2
        // A long gap is capped at 100 ms.
        g.update(samples: [resting(), nil], palms: [], handTrackingSeesHands: false,
                 lastInput: [-100, -100], now: 105)
        #expect(abs(g.hands[0].alpha - 0.75) < 1e-6)
        // Live configuration: a shorter fade applies on the next tick.
        g.configuration.fadeSeconds = 0.1
        g.update(samples: [resting(), nil], palms: [], handTrackingSeesHands: false,
                 lastInput: [-100, -100], now: 105.05)
        #expect(g.hands[0].alpha == 1)
    }

    @Test func ghostsPerHandInput() {
        let g = SenseGhosts()
        g.update(samples: [resting(), resting()], palms: [], handTrackingSeesHands: false,
                 lastInput: [-100, 99.5], now: 100)
        #expect(g.hands[0].visible)
        #expect(!g.hands[1].visible && g.hands[1].lastReason == "held (input)")
    }
}

@Suite struct SenseGhostMeshTests {
    private func vertex(_ m: SenseGhostMesh, _ i: Int) -> (p: SIMD3<Float>, n: SIMD3<Float>, uv: SIMD2<Float>) {
        let v = m.vertices
        let o = i * 8
        return (SIMD3(v[o], v[o + 1], v[o + 2]), SIMD3(v[o + 3], v[o + 4], v[o + 5]), SIMD2(v[o + 6], v[o + 7]))
    }

    @Test(arguments: [true, false]) func wellFormed(right: Bool) {
        let m = SenseGhostMesh.sense(right: right)
        #expect(m.vertices.count % 8 == 0)
        #expect(m.vertexCount > 0 && m.vertexCount < 65535)
        #expect(m.indices.count % 3 == 0)
        #expect(m.indices.count > 0)
        #expect(m.indices.allSatisfy { Int($0) < m.vertexCount })
        // The three surfaces: capsule 25x25, ring 49x17, disc 2x25.
        #expect(m.vertexCount == 25 * 25 + 49 * 17 + 2 * 25)
        // Every normal is unit length.
        for i in 0..<m.vertexCount {
            #expect(abs(simd_length(vertex(m, i).n) - 1) < 1e-4)
        }
    }

    @Test(arguments: [true, false]) func windingAgreesWithNormals(right: Bool) {
        let m = SenseGhostMesh.sense(right: right)
        var bad = 0
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let a = vertex(m, Int(m.indices[t])), b = vertex(m, Int(m.indices[t + 1])),
                c = vertex(m, Int(m.indices[t + 2]))
            let fn = simd_cross(b.p - a.p, c.p - a.p)
            #expect(simd_length(fn) >= 1e-12)                               // no degenerate triangle kept
            if simd_dot(fn, a.n + b.n + c.n) < 0 { bad += 1 }
        }
        #expect(bad == 0)
    }

    @Test func leftIsTheMirrorOfRightInX() {
        let r = SenseGhostMesh.sense(right: true), l = SenseGhostMesh.sense(right: false)
        #expect(r.vertexCount == l.vertexCount)
        #expect(r.indices.count == l.indices.count)
        for i in 0..<r.vertexCount {
            let a = vertex(r, i), b = vertex(l, i)
            #expect(a.p.x == -b.p.x && a.p.y == b.p.y && a.p.z == b.p.z)
            #expect(a.n.x == -b.n.x && a.n.y == b.n.y && a.n.z == b.n.z)
            #expect(a.uv == b.uv)
        }
        // The ring is on the back of the hand: +X for the right, -X for the left.
        let rx = (0..<r.vertexCount).map { vertex(r, $0).p.x }
        let lx = (0..<l.vertexCount).map { vertex(l, $0).p.x }
        #expect(rx.max()! > 0.05 && lx.min()! < -0.05)
    }

    @Test func sizeIsASense() {
        // The grip is radius 1.9 cm about Z; the ring (radius 5.5 cm, band
        // 6 mm, centred 3 cm toward the back of the hand and 5 mm down the
        // grip) loops from z = 0.005 - 0.061 to 0.005 + 0.061 and reaches
        // 9.1 cm out to the back of the hand.
        let m = SenseGhostMesh.sense(right: true)
        let ps = (0..<m.vertexCount).map { vertex(m, $0).p }
        #expect(abs(ps.map(\.z).max()! - 0.066) < 1e-4)
        #expect(abs(ps.map(\.z).min()! - -0.056) < 1e-4)
        #expect(abs(ps.map(\.x).max()! - 0.091) < 1e-4)
        #expect(abs(ps.map(\.x).min()! - -0.019) < 1e-5)
        #expect(abs(ps.map(\.y).max()! - 0.019) < 1e-5)
        #expect(m.indices.count == 8064)
    }
}
