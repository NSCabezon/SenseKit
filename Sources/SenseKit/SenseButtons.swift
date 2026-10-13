/// Physical Sense controller buttons, named after the hardware (not OVR or OpenXR).
public struct SenseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let cross      = SenseButtons(rawValue: 1 << 0)
    public static let circle     = SenseButtons(rawValue: 1 << 1)
    public static let square     = SenseButtons(rawValue: 1 << 2)
    public static let triangle   = SenseButtons(rawValue: 1 << 3)
    public static let options    = SenseButtons(rawValue: 1 << 4)
    public static let create     = SenseButtons(rawValue: 1 << 5)
    public static let ps         = SenseButtons(rawValue: 1 << 6)
    public static let stickClick = SenseButtons(rawValue: 1 << 7)
    public static let trigger    = SenseButtons(rawValue: 1 << 8)
    public static let grip       = SenseButtons(rawValue: 1 << 9)
}
