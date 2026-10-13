import ARKit
import CoreHaptics
import Foundation
import GameController
import QuartzCore
import simd

/// Entry point: discovers PS VR2 Sense controllers and serves pose, input and
/// haptics.
///
/// Two halves with independent lifecycles feed it. **Poses** come from ARKit's
/// `AccessoryTrackingProvider` — an anchor stream consumed on its own task —
/// and **input** from GameController, polled on the render thread. So the
/// stored anchors and input states really do cross threads and are kept
/// behind a lock; the rest (discovery, binding, `presentHands`) is render
/// thread only, like the poll.
///
/// A frame, from the render thread:
///
/// ```swift
/// if sense.controllersChanged() {        // the paired set changed
///     sense.forgetPoses()
///     // rebuild: sense.makeTrackingProvider() + ARKitSession.run(...)
/// }
/// sense.pollInput()
/// let left = sense.state(.left, at: presentationTime)
/// sense.pumpHaptics()
/// ```
///
/// The hook closures (`logger`, `liveGripCorrection`, `predictionObserver`,
/// `onControllerBound`, `hapticsSource`) are meant to be set once, before the
/// first frame; they are not synchronised.
public final class SenseControllers: @unchecked Sendable {
    private let lock = NSLock()
    private var _configuration: SenseConfiguration

    /// Optional log sink (default off). Lines carry no channel prefix; a
    /// consumer adds its own. Called from the render thread, the anchor task
    /// and the haptics queue.
    public var logger: ((String) -> Void)?

    /// If set, called for every pose instead of reading
    /// `configuration.gripCorrection` — for a live tuning UI that wants a
    /// slider to move the controller while it is dragged, without a write per
    /// frame. Called only when a pose is actually computed.
    public var liveGripCorrection: ((SenseHand) -> SenseGripCorrection)?

    /// Called on every pose computation with how far ahead of now the
    /// requested instant was and the cap in force (both seconds) — the number
    /// that says whether `predictionCapMs` binds at all. A cap of 50 ms over
    /// a 30 ms pipeline is not a mild setting, it is NO setting.
    public var predictionObserver: ((_ aheadSeconds: Double, _ capSeconds: Double) -> Void)?

    /// Called from `pollInput` when a controller is bound for input — at
    /// launch, and again on every (re)connect. Klepton uses it to arm
    /// OVRPlugin's near-touch edge.
    public var onControllerBound: ((SenseHand) -> Void)?

    /// Where `pumpHaptics` reads each hand's haptic LEVEL — what the hand
    /// should be feeling right now — as (amplitude 0...1, seconds). nil: silent.
    /// Called on the render thread from `pumpHaptics`, once per hand.
    public var hapticsSource: ((SenseHand) -> (amplitude: Float, seconds: Float)?)?

    public init(configuration: SenseConfiguration = .init()) {
        _configuration = configuration
        haptics = SenseHapticsDriver()
        haptics.log = { [weak self] in self?.log($0) }
    }

    /// Live tuning.
    public var configuration: SenseConfiguration {
        get { lock.lock(); defer { lock.unlock() }; return _configuration }
        set { lock.lock(); defer { lock.unlock() }; _configuration = newValue }
    }

    private func log(_ s: String) { logger?(s) }

    // MARK: - State

    /// The most recent anchor per hand — **the object, not the pose it carried**.
    ///
    /// The anchor stream is a *sensor* feed: it delivers when the tracker has
    /// something new, which on this platform is far below display rate, so a
    /// render loop reading the last delivered pose repeats each sample for
    /// several frames — 30 Hz motion inside a 90 Hz picture. Keeping the
    /// anchor keeps `AccessoryTrackingProvider.predictAnchor(for:at:)`
    /// available, the platform's own extrapolator: asked for the frame's
    /// presentation time, every frame gets its own pose. Under `lock`.
    private var accessoryAnchor: [Int: AccessoryAnchor] = [:]
    /// Held so the render thread can predict against it. `makeTrackingProvider`
    /// is the only writer, and it runs before the session that feeds it.
    private var accessoryProvider: AccessoryTrackingProvider?

    /// The last polled input per hand (pose always nil). Under `lock`.
    private var input: [SenseHandState] = [SenseHandState(), SenseHandState()]

    /// Whether the last `makeTrackingProvider` found any accessory.
    public private(set) var accessoriesConnected = false
    private var tracked: [GCController] = []
    /// Which hands have a Sense controller connected right now (left, right),
    /// refreshed every frame by `controllersChanged` from the same
    /// GCController poll. Render thread only, like that poll.
    public private(set) var presentHands = [false, false]

    private let haptics: SenseHapticsDriver

    // MARK: - Discovery

    /// The spatial controllers paired right now.
    public static func spatialControllers() -> [GCController] {
        GCController.controllers().filter {
            $0.productCategory == GCProductCategorySpatialController
        }
    }

    /// Which hand a controller is, by vendor name (see `SenseHand.forVendorName`).
    public static func hand(of c: GCController) -> SenseHand {
        SenseHand.forVendorName(c.vendorName)
    }

    /// Has the paired set changed since the last time this was asked? Call
    /// per frame; true means rebuild the tracking provider (and run the
    /// ARKit session again with it — not a restart: world and hand tracking
    /// carry on). Also refreshes `presentHands`.
    ///
    /// Polled rather than driven off `GCControllerDidConnect`, because the set
    /// is what the provider is built from and a notification would only send
    /// us back here to read it anyway. Cheap: an array compare of a list that
    /// is almost always empty or two long.
    public func controllersChanged() -> Bool {
        let now = Self.spatialControllers()
        var hands = [false, false]
        for c in now { hands[Self.hand(of: c).rawValue] = true }
        presentHands = hands
        guard now != tracked else { return false }
        tracked = now
        return true
    }

    /// Build the accessory-tracking provider for whatever is paired now; nil
    /// when the platform has no accessory tracking.
    ///
    /// Built **unconditionally** when the capability exists, including with an
    /// empty accessory list. The provider set is fixed when `ARKitSession.run`
    /// is called, so a run that omitted it could never pick a controller up,
    /// which is what made reconnects look like a platform limitation. They are
    /// not — the session is simply re-`run()` with a rebuilt list when the set
    /// changes (`controllersChanged`), without stopping it first.
    public func makeTrackingProvider() async -> AccessoryTrackingProvider? {
        guard AccessoryTrackingProvider.isSupported else { return nil }
        let spatial = Self.spatialControllers()
        tracked = spatial

        var accessories: [Accessory] = []
        for c in spatial {
            // One failure must not take the other controller with it — they are
            // paired independently and a half-working pair is the normal state
            // while one is waking up.
            do { accessories.append(try await Accessory(device: c)) }
            catch { log("accessory init failed for \(c.vendorName ?? "?"): \(error)") }
        }
        accessoriesConnected = !accessories.isEmpty
        log("spatial controllers: \(accessories.map { $0.name })")
        for c in spatial { census(c) }
        let p = AccessoryTrackingProvider(accessories: accessories)
        setProvider(p)
        return p
    }

    private func setProvider(_ p: AccessoryTrackingProvider?) {
        lock.lock(); accessoryProvider = p; lock.unlock()
    }

    /// Every element name a controller carries, once, when it attaches.
    ///
    /// Input is read by element name, and a name this hardware does not
    /// publish is indistinguishable from a button nobody pressed — the lookup
    /// returns nil, `?? false` makes it a release, and the control is silently
    /// dead for the whole run. Three collections, because which one an
    /// element lives in is exactly what was wrong once (the stick is a DPAD).
    private func census(_ c: GCController) {
        let p = c.physicalInputProfile
        log("\(c.vendorName ?? "?") elements: "
            + "buttons \(p.buttons.keys.sorted()) "
            + "axes \(p.axes.keys.sorted()) "
            + "dpads \(p.dpads.keys.sorted())")
    }

    /// Element names seen pressed at least once, across every controller and
    /// every instance — once per process, like the log it feeds.
    nonisolated(unsafe) private static var pressSeen = Set<String>()

    /// Name each button element the first time it is actually pressed. The
    /// census says what exists; this says what the hardware sends when a
    /// person presses it, and only the pair settles a mapping. Bounded by
    /// construction: one line per distinct name, ever.
    private func notePress(_ name: String) {
        if Self.pressSeen.insert(name).inserted {
            log("button element pressed for the first time: \"\(name)\"")
        }
    }

    /// Drop everything tied to the controllers that are going away: the
    /// stored anchors and the provider, the input states, the input bindings
    /// and the haptics engines. Call when `controllersChanged` says so, before
    /// rebuilding the provider, so a disconnect cannot leave a consumer holding
    /// the last pose (or a pressed trigger) forever.
    public func forgetPoses() {
        // The haptics engines belong to the GCControllers that are going away.
        // Kept past a disconnect they are engines on a dead device, and the
        // next `makePlayer` throws rather than returning nil — which is a
        // caught error per frame for the rest of the run.
        haptics.releaseAll()
        // ...and the input half re-binds from scratch on the next poll: every
        // controller's input queue is configured again and logged, after the
        // accessory provider that is about to wrap the same GCControllers.
        buttonBinding.removeAll()
        lock.lock()
        accessoryAnchor.removeAll()
        // The provider goes too: predicting against a provider whose session is
        // being torn down and rebuilt is the one way a stale anchor could still
        // produce a fresh-looking pose after the controller is gone.
        accessoryProvider = nil
        for i in 0...1 { input[i] = SenseHandState(lastActivity: input[i].lastActivity) }
        lock.unlock()
    }

    // MARK: - Anchors

    /// Consume the accessory anchor stream. Runs for the life of the provider
    /// (the stream ends when the provider is replaced).
    public func consumeAnchors(from provider: AccessoryTrackingProvider) async {
        for await update in provider.anchorUpdates {
            let anchor = update.anchor
            // An unspecified chirality is a controller that has not decided
            // which hand it is in. Treated as the right hand, which is the one
            // a single controller is overwhelmingly likely to be, and is what
            // ALVR does.
            let hand: Int
            switch anchor.accessory.inherentChirality {
            case .left:  hand = 0
            case .right: hand = 1
            default:     hand = 1
            }
            // The anchor itself is stored, not the pose read off it: the pose
            // a frame wants is the *predicted* one, and only the anchor can be
            // predicted.
            //
            // Through a non-async helper: the critical section must not span a
            // suspension point, and a synchronous function guarantees that.
            store(hand: hand, removed: update.event == .removed, anchor: anchor)
        }
    }

    private func store(hand: Int, removed: Bool, anchor: AccessoryAnchor) {
        if !removed { probeFrames(hand: hand, anchor) }
        lock.lock()
        defer { lock.unlock() }
        accessoryAnchor[hand] = removed ? nil : anchor
    }

    /// Which hands have already described themselves. Written from the anchor
    /// stream only, which is one task, so no lock.
    private var framesProbed: [Bool] = [false, false]

    /// Every frame this controller publishes, relative to its own `.grip`
    /// frame — once per hand, the first time it arrives.
    ///
    /// A SteamVR render model states exactly where an Oculus Touch's tracked
    /// pose, `openxr_grip` and `openxr_aim` sit relative to one another (on a
    /// Touch those are 10.2 cm and 20.6 degrees apart); whether Apple's
    /// `.grip` means what OpenXR's grip means is not answerable off-device, so
    /// this measures it. Rows are in the render model's units and euler order
    /// (`SenseMath.eulerDegrees`), with the Touch's own rows underneath to
    /// compare against. `.none` and `.rendered` are both printed because the
    /// gap between them is Apple's own comfort correction, and the pose path
    /// takes `.rendered`.
    private func probeFrames(hand: Int, _ a: AccessoryAnchor) {
        if framesProbed[hand] { return }
        framesProbed[hand] = true
        guard logger != nil else { return }
        let side = hand == 0 ? "left" : "right"
        guard a.accessory.locations.contains(.grip) else {
            log("sense frames (\(side)): \(a.accessory.name) publishes no .grip")
            return
        }
        let grip = a.coordinateSpace(for: .grip, correction: .none)
            .ancestorFromSpaceTransformFloat().matrix
        var rows: [(String, simd_float4x4)] = [("tracked", a.originFromAnchorTransform)]
        if a.accessory.locations.contains(.aim) {
            rows.append(("aim", a.coordinateSpace(for: .aim, correction: .none)
                .ancestorFromSpaceTransformFloat().matrix))
        }
        if a.accessory.locations.contains(.gripSurface) {
            rows.append(("gripSurface", a.coordinateSpace(for: .gripSurface, correction: .none)
                .ancestorFromSpaceTransformFloat().matrix))
        }
        rows.append(("grip .rendered", a.coordinateSpace(for: .grip, correction: .rendered)
            .ancestorFromSpaceTransformFloat().matrix))

        log("sense frames (\(side)): \(a.accessory.name), relative to .grip")
        let gi = grip.inverse
        for (name, m) in rows {
            let r = gi * m
            let o = SIMD3<Float>(r.columns.3.x, r.columns.3.y, r.columns.3.z)
            let e = SenseMath.eulerDegrees(of: r)
            log(String(format: "  %@ (%9.6f, %9.6f, %9.6f)  (%+7.2f, %+6.2f, %+7.2f)  %.4f",
                       name.padding(toLength: 14, withPad: " ", startingAt: 0),
                       o.x, o.y, o.z, e.x, e.y, e.z, simd_length(o)))
        }
        // The same two rows for an Oculus Touch, straight out of the render
        // model, so the comparison is in the log rather than in a notebook.
        log("  Touch tracked  ( 0.007000, -0.034157, -0.096073)  ( -20.60,  +0.00,   -0.00)  0.1022")
        log("  Touch aim      ( 0.000000, -0.067273, -0.073480)  ( -60.00,  +0.00,   -0.00)  0.0996")
    }

    // MARK: - Pose

    /// This hand's controller, predicted to `time` and corrected: grip pose
    /// plus the motion that goes with it, all in tracking space. nil when
    /// there is no anchor for that hand (or no provider).
    ///
    /// `time` is a `CACurrentMediaTime()`-domain instant — the frame's
    /// presentation time, the one `queryDeviceAnchor(atTimestamp:)` gets for
    /// the head, so the hands and the head describe one instant. Prediction is
    /// capped by `predictionCapMs` (see `SenseMath.predictionTarget`). Falling
    /// back to the raw anchor if prediction refuses keeps a controller that
    /// has just appeared (or one the tracker has lost) visible.
    public func pose(_ hand: SenseHand, at time: TimeInterval) -> SensePose? {
        lock.lock()
        let stored = accessoryAnchor[hand.rawValue]
        let provider = accessoryProvider
        let cfg = _configuration
        lock.unlock()
        guard let stored, let provider else { return nil }
        let now = CACurrentMediaTime()
        let capS = cfg.predictionCapMs / 1000.0
        predictionObserver?(time - now, capS)
        let a = SenseMath.predictionTarget(now: now, time: time, capSeconds: capS)
            .flatMap { provider.predictAnchor(for: stored, at: $0) } ?? stored

        // `.grip` is the location the platform defines for "where a hand holds
        // this" — the anchor's own transform is the middle of the plastic. A
        // controller that publishes no grip (a stylus) falls back to its base.
        let m = a.accessory.locations.contains(.grip)
            ? a.coordinateSpace(for: .grip, correction: .rendered)
                .ancestorFromSpaceTransformFloat().matrix
            : a.originFromAnchorTransform
        let raw = simd_quatf(m)
        let correction = liveGripCorrection?(hand) ?? cfg.gripCorrection
        let (p, q) = correction.apply(raw: raw,
                                      origin: SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                                      hand: hand)

        // Motion, rotated out of the accessory's own frame if that is what it
        // is in — by the UNCORRECTED orientation, because the correction above
        // is a change of convention applied to the pose we report, not a claim
        // about the frame the tracker measured in.
        var v = a.velocity, w = a.angularVelocity
        if cfg.velocityInAccessoryFrame { v = raw.act(v); w = raw.act(w) }
        v = SenseVelocityGate.gate(v, cfg.velocityGate.linear)
        w = SenseVelocityGate.gate(w, cfg.velocityGate.angular)
        return SensePose(position: p, orientation: q, linearVelocity: v, angularVelocity: w)
    }

    /// How far ahead a ghost sample may be predicted, seconds — fixed, it is
    /// for drawing the device, not for a consumer that re-predicts.
    public static let ghostPredictionCap: Double = 0.05

    /// The physical controller for a ghost model: the `.grip` frame with the
    /// platform's RENDERED correction and none of the consumer's calibration,
    /// predicted to `time` (capped at `ghostPredictionCap`). nil when there is
    /// no anchor for that hand.
    public func ghostSample(_ hand: SenseHand, at time: TimeInterval) -> SenseGhostSample? {
        lock.lock()
        let stored = accessoryAnchor[hand.rawValue]
        let provider = accessoryProvider
        lock.unlock()
        guard let stored else { return nil }
        let now = CACurrentMediaTime()
        let a = provider?.predictAnchor(for: stored, at: now + min(max(time - now, 0), Self.ghostPredictionCap)) ?? stored
        let m = a.accessory.locations.contains(.grip)
            ? a.coordinateSpace(for: .grip, correction: .rendered).ancestorFromSpaceTransformFloat().matrix
            : a.originFromAnchorTransform
        let positioned: Bool
        switch a.trackingState {
        case .positionOrientationTracked, .positionOrientationTrackedLowAccuracy: positioned = true
        case .untracked, .orientationTracked: positioned = false
        @unknown default: positioned = a.isTracked
        }
        return SenseGhostSample(originFromGrip: m, positionTracked: positioned && a.isTracked,
                                heldByPlatform: a.heldChirality != nil,
                                speed: simd_length(a.velocity), angularSpeed: simd_length(a.angularVelocity))
    }

    // MARK: - Input binding (connect / disconnect at any time)

    private struct Binding {
        var name: String
        var hand: SenseHand
        var queued: Int
        var captured: Int
        var saidCapture: Bool
    }
    /// The controllers `pollInput` has configured, by object, with how their
    /// input has been arriving. Render thread only, like the poll.
    private var buttonBinding: [ObjectIdentifier: Binding] = [:]

    /// (Re)bind the input path to exactly the spatial controllers present
    /// NOW. Every frame, from the same `GCController.controllers()` read the
    /// poll uses, so a controller that connects or reconnects at any moment —
    /// before the game, mid-game, after a sleep — is configured on the frame
    /// it appears, the same as one paired at launch. The pose half is rebuilt
    /// separately (`controllersChanged` → a new provider); this is the input
    /// half, and it logs each bind/unbind so a headset log shows both.
    private func rebind(_ spatial: [GCController]) {
        var live = Set<ObjectIdentifier>()
        for c in spatial {
            let id = ObjectIdentifier(c)
            live.insert(id)
            if buttonBinding[id] != nil { continue }
            c.input.inputStateQueueDepth = 1
            let hand = Self.hand(of: c)
            let name = c.vendorName ?? "?"
            buttonBinding[id] = Binding(name: name, hand: hand, queued: 0, captured: 0, saidCapture: false)
            log("buttons bound: \(name) -> hand \(hand == .left ? "L" : "R") "
                + "(\(buttonBinding.count) bound)")
            onControllerBound?(hand)
            census(c)
        }
        for (id, v) in buttonBinding where !live.contains(id) {
            buttonBinding[id] = nil
            log("buttons unbound: \(v.name) (hand \(v.hand == .left ? "L" : "R"), "
                + "\(v.queued) queued / \(v.captured) captured reads)")
        }
    }

    /// Count which path a controller's input came through, and say so ONCE if
    /// a press is only visible through `capture()` — the measurement that
    /// tells "the queue stays silent for a late controller" from anything else.
    private func noteInputPath(_ c: GCController, queued: Bool, state: GCControllerInputState) {
        let id = ObjectIdentifier(c)
        guard var v = buttonBinding[id] else { return }
        if queued { v.queued += 1 } else { v.captured += 1 }
        if !queued, v.queued == 0, !v.saidCapture,
           state.buttons.contains(where: { $0.pressedInput.isPressed }) {
            v.saidCapture = true
            log("\(v.name): a press arrived through capture() with the input "
                + "queue silent since bind (\(v.captured) reads) — the late-connect case")
        }
        buttonBinding[id] = v
    }

    // MARK: - Input polling

    /// Poll every attached controller's input. Once per frame, on the render
    /// thread, before reading `inputState` / `state`.
    ///
    /// **Hands with NO CONTROLLER ATTACHED are cleared, then the ones that
    /// have one are filled in.** GameController connect/disconnect and ARKit's
    /// anchor stream are independent and either can lead; filling in place
    /// without clearing would leave a hand whose controller has gone away
    /// holding its last frame's input forever — a controller unpaired
    /// mid-press would hold that trigger down for the rest of the run.
    ///
    /// The clear is keyed on ATTACHMENT, not on a new input state having
    /// arrived: `nextInputState()` returns nil when nothing has been queued
    /// since the last call (a controller nobody is moving publishes nothing),
    /// and nil means "unchanged", not "released". It is answered with
    /// `capture()`, the controller's CURRENT state — the same values for a
    /// controller whose queue is merely idle, and the only input at all from
    /// one whose queue never fills (a pair switched on after the app started).
    ///
    /// Poses are deliberately NOT cleared here: they belong to the ARKit
    /// stream, which reports its own `.removed`.
    public func pollInput() {
        let spatial = Self.spatialControllers()
        var attached = [false, false]
        for c in spatial { attached[Self.hand(of: c).rawValue] = true }
        rebind(spatial)

        lock.lock()
        for i in 0...1 where !attached[i] {
            input[i] = SenseHandState(lastActivity: input[i].lastActivity)
        }
        lock.unlock()

        for c in spatial {
            let hand = Self.hand(of: c)
            let queued = c.input.nextInputState()
            let s: GCControllerInputState = queued ?? c.input.capture()
            noteInputPath(c, queued: queued != nil, state: s)
            let b = s.buttons, ax = s.axes, dp = s.dpads

            func pressed(_ n: String) -> Bool { b[n]?.pressedInput.isPressed ?? false }
            func value(_ n: String) -> Float { b[n]?.pressedInput.value ?? 0 }
            func touched(_ n: String) -> Bool { b[n]?.touchedInput?.isTouched ?? false }
            func axis(_ n: String) -> Float { ax[n]?.absoluteInput?.value ?? 0 }

            // Every element name this controller reports pressed, once each —
            // under every alias, since an element is reachable under any of
            // them and the bug being hunted is reading one under a name it
            // does not answer to.
            for el in b where el.pressedInput.isPressed {
                for n in el.aliases { notePress("\(n) [\(hand == .left ? "L" : "R")]") }
            }

            var st = SenseHandState(connected: true)
            st.trigger = value("Trigger")
            st.grip = pressed("Grip") ? 1 : 0
            // **The thumbstick is a DPAD element, not two axes** (`GCInput`
            // models a stick as one `GCDirectionPadElement`); see
            // `SenseMath.pickStick` for why every source is still read.
            func pad(_ n: String) -> SIMD2<Float>? {
                dp[n].map { SIMD2($0.xAxis.value, $0.yAxis.value) }
            }
            st.stick = SenseMath.pickStick(
                dpad: pad("Thumbstick"),
                sideDpad: pad(hand == .left ? "Left Thumbstick" : "Right Thumbstick"),
                axes: SIMD2(axis("Thumbstick X Axis"), axis("Thumbstick Y Axis")),
                buttons: SIMD2(value("Thumbstick Right") - value("Thumbstick Left"),
                               value("Thumbstick Up") - value("Thumbstick Down")))
            st.buttons = SenseButtons.pressed(hand: hand, pressed)
            st.touches = SenseButtons.touched(hand: hand, touched)

            let now = CACurrentMediaTime()
            lock.lock()
            st.lastActivity = Self.showsActivity(st) ? now : input[hand.rawValue].lastActivity
            input[hand.rawValue] = st
            lock.unlock()
        }
    }

    /// Any sign of a hand ON the controller: a button, a capacitive touch,
    /// the trigger or grip, the stick off-centre.
    static func showsActivity(_ st: SenseHandState) -> Bool {
        !st.buttons.isEmpty || !st.touches.isEmpty || st.trigger > 0.05
            || st.grip > 0.05 || simd_length(st.stick) > 0.2
    }

    /// The last polled input for `hand` (`pose` is always nil — see `state`).
    public func inputState(_ hand: SenseHand) -> SenseHandState {
        lock.lock(); defer { lock.unlock() }
        return input[hand.rawValue]
    }

    /// The last polled input for `hand` plus its pose predicted to `time`.
    public func state(_ hand: SenseHand, at time: TimeInterval) -> SenseHandState {
        var st = inputState(hand)
        st.pose = pose(hand, at: time)
        return st
    }

    // MARK: - Haptics

    /// Follow both hands' haptic levels from `hapticsSource`. Once a frame,
    /// from the render thread.
    ///
    /// The source is drained every frame, even with haptics disabled, so a
    /// producer's queue stays in step. **The pull happens here; the playing
    /// does not.** (Adapted from avp-play, MIT, github.com/myMartek/avp-play.)
    /// Everything CoreHaptics does is a synchronous message to a system
    /// service (creating an engine goes through gamecontrollerd), and one was
    /// seen to block for over two seconds under heavy haptics; made from the
    /// render loop that stalls presentation, and visionOS ends an immersive
    /// app that stops presenting. So the levels are handed to a queue of
    /// their own, and while that queue is still busy with an earlier frame
    /// this frame's levels are dropped: a buzz that arrives seconds late is
    /// worse than one that is missed.
    public func pumpHaptics() {
        let now = ProcessInfo.processInfo.systemUptime
        let cfg = configuration.haptics
        var levels: [(level: Float, seconds: Float)] = []
        for hand in SenseHand.allCases {
            if let s = hapticsSource?(hand) {
                levels.append((min(max(s.amplitude * cfg.gain, 0), 1), s.seconds))
            } else {
                levels.append((0, 0))
            }
        }
        guard cfg.enabled else { return }
        haptics.play(levels, at: now, configuration: cfg)
    }

    /// Stop and drop every haptics engine (also done by `forgetPoses`).
    public func releaseHaptics() { haptics.releaseAll() }
}
