import Foundation
import simd

/// Classic gamepad buttons, in physical-ish names shared by every pad the
/// hub reads (an N64 pad, a DualSense, an Xbox or Switch Pro controller).
///
/// Face buttons are POSITIONAL, after `GCExtendedGamepad`: `a` south, `b`
/// east, `x` west, `y` north. On a Nintendo pad those are the labels printed
/// on the plastic; on a PlayStation pad `a` is Cross and `b` is Circle.
/// `zl`/`zr` are the triggers (analog in `GamepadState`), `l`/`r` the
/// shoulders. The `c*` four exist only on the N64 pad.
public struct GamepadButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let a               = GamepadButtons(rawValue: 1 << 0)
    public static let b               = GamepadButtons(rawValue: 1 << 1)
    public static let x               = GamepadButtons(rawValue: 1 << 2)
    public static let y               = GamepadButtons(rawValue: 1 << 3)
    public static let l               = GamepadButtons(rawValue: 1 << 4)
    public static let r               = GamepadButtons(rawValue: 1 << 5)
    /// Left trigger (the N64's Z is reported here, see `GamepadProfile`).
    public static let zl              = GamepadButtons(rawValue: 1 << 6)
    public static let zr              = GamepadButtons(rawValue: 1 << 7)
    public static let start           = GamepadButtons(rawValue: 1 << 8)
    public static let select          = GamepadButtons(rawValue: 1 << 9)
    public static let home            = GamepadButtons(rawValue: 1 << 10)
    /// Capture / Share, where the pad has one separate from `select`.
    public static let capture         = GamepadButtons(rawValue: 1 << 11)
    public static let leftStickClick  = GamepadButtons(rawValue: 1 << 12)
    public static let rightStickClick = GamepadButtons(rawValue: 1 << 13)
    public static let dpadUp          = GamepadButtons(rawValue: 1 << 14)
    public static let dpadDown        = GamepadButtons(rawValue: 1 << 15)
    public static let dpadLeft        = GamepadButtons(rawValue: 1 << 16)
    public static let dpadRight       = GamepadButtons(rawValue: 1 << 17)
    public static let cUp             = GamepadButtons(rawValue: 1 << 18)
    public static let cDown           = GamepadButtons(rawValue: 1 << 19)
    public static let cLeft           = GamepadButtons(rawValue: 1 << 20)
    public static let cRight          = GamepadButtons(rawValue: 1 << 21)

    public static let dpad: GamepadButtons = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]
    public static let cButtons: GamepadButtons = [.cUp, .cDown, .cLeft, .cRight]

    /// Edge detection against the previous frame: what went down and what
    /// came up since `previous`. The hub keeps no history for a consumer, so
    /// a caller that wants presses (not levels) keeps last frame's set and
    /// asks this.
    public func changes(since previous: GamepadButtons) -> (pressed: GamepadButtons, released: GamepadButtons) {
        (pressed: subtracting(previous), released: previous.subtracting(self))
    }

    /// The four-way pad as a vector (x right, y up), ±1 per axis.
    public var dpadVector: SIMD2<Float> {
        SIMD2((contains(.dpadRight) ? 1 : 0) - (contains(.dpadLeft) ? 1 : 0),
              (contains(.dpadUp) ? 1 : 0) - (contains(.dpadDown) ? 1 : 0))
    }
}

/// How a gamepad is read, which also says what its elements mean.
public enum GamepadKind: Sendable, Hashable {
    /// Nintendo Switch Online N64 controller: no `extendedGamepad`, read by
    /// element name; its "right stick" is the four C buttons.
    case n64
    /// Anything with a `GCExtendedGamepad` profile (DualSense, Xbox, Switch Pro…).
    case extended
    /// A non-spatial controller with neither — read by the generic element
    /// names, which may or may not be published.
    case unknown
}

/// Snapshot of one classic gamepad, polled by `SenseInputHub.pollInput()`.
public struct GamepadState: Sendable {
    public var connected: Bool
    public var kind: GamepadKind
    public var buttons: GamepadButtons
    /// x right, y up, -1...1.
    public var leftStick: SIMD2<Float>
    /// x right, y up, -1...1. On the N64 pad this is the C buttons as ±1.
    public var rightStick: SIMD2<Float>
    /// 0...1; digital pads report 0 or 1.
    public var leftTrigger: Float
    public var rightTrigger: Float
    /// `CACurrentMediaTime()` of the last poll that showed input on this pad
    /// (any button, a trigger above 0.05, a stick past 0.2); -100 before any.
    public var lastActivity: TimeInterval

    public init(connected: Bool = false,
                kind: GamepadKind = .unknown,
                buttons: GamepadButtons = [],
                leftStick: SIMD2<Float> = .zero,
                rightStick: SIMD2<Float> = .zero,
                leftTrigger: Float = 0,
                rightTrigger: Float = 0,
                lastActivity: TimeInterval = -100) {
        self.connected = connected
        self.kind = kind
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.lastActivity = lastActivity
    }
}
