import simd

/// Where an input came from, for the arbiter and for a consumer that wants
/// to know whose stick it is holding.
public enum InputSource: Sendable, Hashable {
    case sense(SenseHand)
    case gamepad(GamepadKind)
}

/// Which stick axis the arbiter is deciding.
public enum StickAxis: Sendable, Hashable, CaseIterable {
    case left, right
}

/// Decides which of several sources owns ONE stick axis, so a pad nobody is
/// touching never fights the one being used.
///
/// The bug this exists for: an app wrote the Sense left stick's (0, 0) to the
/// game every frame while the N64 stick was being used, and the two
/// alternated — jitter. The rule:
///
/// * An axis is **owned** by the source that most recently moved it past the
///   deadzone (the crossing is the event: a stick already held out does not
///   re-claim every frame, a stick pushed out just now does, even while the
///   owner is still deflected).
/// * While the owner is deflected its value wins.
/// * When the owner returns to centre, **ownership stays with it** until
///   another source deflects — so the parked sticks' zeros are never
///   reported over the live one's.
/// * A source that stops being offered (disconnected, or filtered out by the
///   caller) loses ownership and the axis reads zero until someone deflects.
///
/// Pure value type, one instance per axis; feed it every frame.
public struct StickArbiter: Sendable, Equatable {
    /// Magnitude past which a source counts as deflected.
    public var deadzone: Float
    /// The source whose value is reported, or nil before anyone has moved.
    public private(set) var owner: InputSource?
    /// Which sources were past the deadzone last frame (for the crossing).
    private var deflected: Set<InputSource> = []

    public init(deadzone: Float = 0.2) {
        self.deadzone = deadzone
    }

    /// One frame's candidates, in any order. Returns the arbitrated value:
    /// the owner's raw reading (no deadzone is applied to the value itself —
    /// that is the consumer's business), or zero with no owner.
    public mutating func resolve(_ candidates: [(source: InputSource, value: SIMD2<Float>)]) -> SIMD2<Float> {
        var now = Set<InputSource>()
        var newOwner: (source: InputSource, magnitude: Float)?
        for c in candidates where simd_length(c.value) > deadzone {
            now.insert(c.source)
            // A crossing: inside last frame (or not offered), outside now.
            // Among several in one frame the strongest wins; the next frame
            // neither is a crossing any more, so it sticks.
            if !deflected.contains(c.source) {
                let m = simd_length(c.value)
                if newOwner == nil || m > newOwner!.magnitude { newOwner = (c.source, m) }
            }
        }
        deflected = now
        if let newOwner { owner = newOwner.source }
        else if let o = owner, !candidates.contains(where: { $0.source == o }) { owner = nil }
        // No owner yet but someone is out: the first frame of a stick already
        // held when the arbiter was made (its crossing was never seen).
        if owner == nil, let first = candidates.first(where: { now.contains($0.source) }) {
            owner = first.source
        }
        guard let o = owner, let v = candidates.first(where: { $0.source == o })?.value else { return .zero }
        return v
    }

    /// Forget the owner and the crossings (e.g. when every controller went away).
    public mutating func reset() {
        owner = nil
        deflected = []
    }
}
