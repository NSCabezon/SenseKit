/// Which controller: left or right.
///
/// The raw values are the hand indices an OVRPlugin / OpenXR-style consumer
/// uses (0 = left, 1 = right), so `SenseHand(rawValue: i)` and `.rawValue`
/// convert straight to and from an index.
public enum SenseHand: Int, Sendable, CaseIterable {
    case left = 0, right = 1

    /// The hand a spatial controller is in, by its vendor name.
    ///
    /// `GCController` does not carry chirality itself — `Accessory` does, and
    /// the two objects are not joined — so the vendor string is the rule:
    /// "PlayStation VR2 Sense Controller (L)" is the left one, anything else
    /// the right (a single controller is overwhelmingly likely to be the
    /// right hand, which is also what ALVR assumes).
    public static func forVendorName(_ name: String?) -> SenseHand {
        (name ?? "").hasSuffix("(L)") ? .left : .right
    }
}
