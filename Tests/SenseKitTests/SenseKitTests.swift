import Testing
@testable import SenseKit

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

    @Test func defaultHapticsGain() {
        #expect(SenseConfiguration().haptics.gain == 0.25)
    }

    @Test func freshControllersAreDisconnected() {
        let s = SenseControllers()
        for hand in [SenseHand.left, .right] {
            let st = s.state(hand, at: 0)
            #expect(!st.connected)
            #expect(st.pose == nil)
            #expect(s.ghostSample(hand, at: 0) == nil)
        }
        #expect(!s.controllersChanged())
    }
}
