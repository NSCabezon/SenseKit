import Foundation
import GameController
import QuartzCore
import simd

/// The one frame's input, with the sticks arbitrated across every source.
public struct ArbitratedInput: Sendable {
    /// The left axis after `StickArbiter` (the Sense left stick and every
    /// gamepad's left stick compete), x right, y up.
    public var leftStick: SIMD2<Float>
    /// The right axis (the Sense right stick and every gamepad's right stick;
    /// on an N64 pad that is the C buttons as ±1 — filter it out with
    /// `pollInput(stickSources:)` if that is not wanted).
    public var rightStick: SIMD2<Float>
    public var leftStickOwner: InputSource?
    public var rightStickOwner: InputSource?
    /// OR of every connected gamepad's buttons (the Sense buttons are in
    /// `senseLeft`/`senseRight`). For presses rather than levels, keep the
    /// previous frame's set and use `GamepadButtons.changes(since:)`.
    public var buttons: GamepadButtons
    /// Max across gamepads, 0...1.
    public var leftTrigger: Float
    public var rightTrigger: Float
    public var senseLeft: SenseHandState
    public var senseRight: SenseHandState

    public init(leftStick: SIMD2<Float> = .zero, rightStick: SIMD2<Float> = .zero,
                leftStickOwner: InputSource? = nil, rightStickOwner: InputSource? = nil,
                buttons: GamepadButtons = [], leftTrigger: Float = 0, rightTrigger: Float = 0,
                senseLeft: SenseHandState = SenseHandState(), senseRight: SenseHandState = SenseHandState()) {
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftStickOwner = leftStickOwner
        self.rightStickOwner = rightStickOwner
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.senseLeft = senseLeft
        self.senseRight = senseRight
    }
}

/// The single input layer for a game: the Sense controllers (through
/// `SenseControllers`) plus every classic gamepad (`GamepadProfile`), polled
/// together once a frame, with the sticks arbitrated (`StickArbiter`) so two
/// controllers never fight over one axis.
///
/// A frame, from the render thread:
///
/// ```swift
/// if hub.pollInput() {                   // the Sense set changed
///     hub.sense.forgetPoses()
///     // rebuild: hub.sense.makeTrackingProvider() + ARKitSession.run(...)
/// }
/// let input = hub.arbitrated()
/// game.stick = input.leftStick           // whoever is using it
/// let presses = input.buttons.changes(since: lastButtons).pressed
/// ```
///
/// Poses and haptics are not duplicated here: use `hub.sense` for
/// `state(_:at:)`, `pumpHaptics()` and the ARKit provider. Like
/// `SenseControllers`, the poll is render-thread only and the read-back
/// (`gamepads`, `arbitrated()`, `sense(_:)`) is lock-protected.
public final class SenseInputHub: @unchecked Sendable {
    /// The Sense half. Injected or made here.
    public let sense: SenseControllers

    /// Optional log sink, shared with `sense.logger` (setting one sets both).
    public var logger: ((String) -> Void)? {
        didSet { sense.logger = logger }
    }

    private let lock = NSLock()
    private var _gamepads: [GamepadState] = []
    private var _arbitrated = ArbitratedInput()
    private var leftArbiter: StickArbiter
    private var rightArbiter: StickArbiter

    private struct Bound {
        var name: String
        var kind: GamepadKind
        var state: GamepadState
    }
    /// The pads seen last poll, by object, with their last state (for
    /// `lastActivity`). Render thread only, like the poll.
    private var bound: [ObjectIdentifier: Bound] = [:]

    /// - Parameters:
    ///   - sense: the Sense controllers to poll; a fresh one by default.
    ///   - stickDeadzone: `StickArbiter.deadzone` for both axes.
    public init(sense: SenseControllers = SenseControllers(), stickDeadzone: Float = 0.2) {
        self.sense = sense
        leftArbiter = StickArbiter(deadzone: stickDeadzone)
        rightArbiter = StickArbiter(deadzone: stickDeadzone)
    }

    private func log(_ s: String) { logger?(s) }

    /// The classic (non-spatial) controllers paired right now.
    public static func gamepadControllers() -> [GCController] {
        GCController.controllers().filter { $0.productCategory != GCProductCategorySpatialController }
    }

    /// Poll everything. Once per frame, on the render thread, before reading
    /// `gamepads`, `arbitrated()` or `sense(_:)`.
    ///
    /// Does `sense.controllersChanged()` and `sense.pollInput()`, then reads
    /// every classic pad into a `GamepadState` and runs the arbiters.
    ///
    /// - Parameter stickSources: which (source, axis) pairs may compete for
    ///   a stick this frame; everything by default. A consumer that is using
    ///   a Sense stick for something else (a cursor) or that maps the N64 C
    ///   buttons itself excludes them here, and the arbiter forgets them as
    ///   owners the same frame.
    /// - Returns: `sense.controllersChanged()` — true means rebuild the
    ///   accessory-tracking provider (see `SenseControllers`).
    @discardableResult
    public func pollInput(stickSources include: (InputSource, StickAxis) -> Bool = { _, _ in true }) -> Bool {
        let senseChanged = sense.controllersChanged()
        sense.pollInput()
        let left = sense.inputState(.left)
        let right = sense.inputState(.right)

        // Gamepads: bind / unbind by object, read each, carry its activity clock.
        let now = CACurrentMediaTime()
        var live = Set<ObjectIdentifier>()
        var states: [GamepadState] = []
        for c in Self.gamepadControllers() {
            guard var st = GamepadProfile.read(c) else { continue }
            let id = ObjectIdentifier(c)
            live.insert(id)
            let previous = bound[id]
            if previous == nil {
                let name = c.vendorName ?? "?"
                log("gamepad bound: \(name) (\(st.kind), category \"\(c.productCategory)\") "
                    + "(\(bound.count + 1) bound)")
                let p = c.physicalInputProfile
                log("\(name) elements: buttons \(p.buttons.keys.sorted()) "
                    + "axes \(p.axes.keys.sorted()) dpads \(p.dpads.keys.sorted())")
            }
            st.lastActivity = GamepadProfile.showsActivity(st) ? now : (previous?.state.lastActivity ?? -100)
            bound[id] = Bound(name: c.vendorName ?? "?", kind: st.kind, state: st)
            states.append(st)
        }
        for (id, b) in bound where !live.contains(id) {
            bound[id] = nil
            log("gamepad unbound: \(b.name) (\(b.kind))")
        }

        // Arbitration.
        var l: [(source: InputSource, value: SIMD2<Float>)] = []
        var r: [(source: InputSource, value: SIMD2<Float>)] = []
        if left.connected, include(.sense(.left), .left) { l.append((.sense(.left), left.stick)) }
        if right.connected, include(.sense(.right), .right) { r.append((.sense(.right), right.stick)) }
        var buttons: GamepadButtons = []
        var lt: Float = 0, rt: Float = 0
        for st in states {
            let src = InputSource.gamepad(st.kind)
            if include(src, .left) { l.append((src, st.leftStick)) }
            if include(src, .right) { r.append((src, st.rightStick)) }
            buttons.formUnion(st.buttons)
            lt = max(lt, st.leftTrigger)
            rt = max(rt, st.rightTrigger)
        }
        let lv = leftArbiter.resolve(l)
        let rv = rightArbiter.resolve(r)
        let arb = ArbitratedInput(leftStick: lv, rightStick: rv,
                                  leftStickOwner: leftArbiter.owner, rightStickOwner: rightArbiter.owner,
                                  buttons: buttons, leftTrigger: lt, rightTrigger: rt,
                                  senseLeft: left, senseRight: right)
        lock.lock()
        _gamepads = states
        _arbitrated = arb
        lock.unlock()
        return senseChanged
    }

    /// Every classic pad as of the last poll.
    public var gamepads: [GamepadState] {
        lock.lock(); defer { lock.unlock() }
        return _gamepads
    }

    /// The last poll's input for a Sense hand (`sense.inputState`).
    public func sense(_ hand: SenseHand) -> SenseHandState {
        sense.inputState(hand)
    }

    /// The last poll, arbitrated.
    public func arbitrated() -> ArbitratedInput {
        lock.lock(); defer { lock.unlock() }
        return _arbitrated
    }

    /// Whether any controller at all (Sense or gamepad) was present at the last poll.
    public var anyConnected: Bool {
        sense.presentHands.contains(true) || !gamepads.isEmpty
    }
}
