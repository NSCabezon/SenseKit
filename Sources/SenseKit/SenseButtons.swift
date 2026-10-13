/// Physical Sense controller buttons, named after the hardware (not OVR or OpenXR).
///
/// The left controller carries Square, Triangle and Create; the right one
/// Cross, Circle and Options. Both have a stick click, a trigger and a grip.
/// The PS button is listed for completeness: visionOS 26 hands it to the
/// system, so it may never be reported (see `SenseButtons.pressed(hand:_:)`).
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

extension SenseButtons {
    /// The lower face button of `hand` (Square on the left, Cross on the right).
    public static func lowerFace(_ hand: SenseHand) -> SenseButtons { hand == .left ? .square : .cross }
    /// The upper face button of `hand` (Triangle on the left, Circle on the right).
    public static func upperFace(_ hand: SenseHand) -> SenseButtons { hand == .left ? .triangle : .circle }

    /// The pressed buttons of one controller, from its GameController element names.
    ///
    /// The PSVR2 Sense publishes the SAME unprefixed names on both controllers
    /// — the hand is the device, not the element — so the hand decides what a
    /// name means:
    ///
    ///   "Button A"            -> lower face (Square L / Cross R)
    ///   "Button B"            -> upper face (Triangle L / Circle R)
    ///   "Button Menu"         -> Create (L) / Options (R) — the one non-game
    ///                            button each Sense controller reports
    ///   "Button Share",
    ///   "Button Options"      -> Options, on either hand (not published by the
    ///                            Sense; read for other spatial controllers)
    ///   "Button Home", "Button PS", "Button PS Button" -> PS
    ///   "Thumbstick Button"   -> stick click
    ///   "Trigger"             -> trigger (its digital press; the analog value
    ///                            is `SenseHandState.trigger`)
    ///   "Grip"                -> grip
    ///
    /// **The real PlayStation button may not reach an app at all.** It is
    /// `GCInputButtonHome`, and visionOS 26 hands it to the system the way it
    /// hands over the Digital Crown; taking it needs
    /// `GCControllerHomeButtonSetting.inAppAction`, which does not exist in
    /// the XROS 26.0 SDK. It is read anyway, so a later OS gets it the moment
    /// the system stops eating it.
    public static func pressed(hand: SenseHand, _ isPressed: (String) -> Bool) -> SenseButtons {
        var b: SenseButtons = []
        if isPressed("Button A") { b.insert(lowerFace(hand)) }
        if isPressed("Button B") { b.insert(upperFace(hand)) }
        if isPressed("Button Menu") { b.insert(hand == .left ? .create : .options) }
        if isPressed("Button Share") || isPressed("Button Options") { b.insert(.options) }
        if isPressed("Button Home") || isPressed("Button PS") || isPressed("Button PS Button") {
            b.insert(.ps)
        }
        if isPressed("Thumbstick Button") { b.insert(.stickClick) }
        if isPressed("Trigger") { b.insert(.trigger) }
        if isPressed("Grip") { b.insert(.grip) }
        return b
    }

    /// The capacitively touched controls of one controller: the two face
    /// buttons, the trigger and the stick. A pressed button is NOT folded in
    /// here — this is the sensor reading alone.
    public static func touched(hand: SenseHand, _ isTouched: (String) -> Bool) -> SenseButtons {
        var t: SenseButtons = []
        if isTouched("Button A") { t.insert(lowerFace(hand)) }
        if isTouched("Button B") { t.insert(upperFace(hand)) }
        if isTouched("Trigger") { t.insert(.trigger) }
        if isTouched("Thumbstick Button") { t.insert(.stickClick) }
        return t
    }
}
