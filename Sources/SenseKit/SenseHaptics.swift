import CoreHaptics
import Foundation
import GameController

//  Plays per-hand haptic LEVELS on the Sense controllers.
//
//  The engine comes from ALVR (`GCController.haptics` →
//  `createEngine(withLocality:)`), the *driving* does not, and the difference
//  was forced by a headset. ALVR's source is discrete events from a server —
//  one amplitude, one duration — so it plays each as its own short
//  `.hapticContinuous`. A game's envelope is continuous (e.g. OVRPlugin's
//  320 Hz buffered haptics), and playing that as a run of short events is a
//  restart per frame: a held buzz survives it, a note cut comes out as a blip
//  with no decay.
//
//  So: **one long-lived looping player per hand, and the envelope is sent to
//  it as a dynamic intensity parameter each frame.** No restarts, no gaps,
//  and the shape of the clip is what reaches the hand. The player is paused
//  after a second of silence and resumed on demand, so an idle run is not
//  holding an actuator open. `.pulse` mode restores the discrete shape — the
//  A/B if the continuous player ever misbehaves on hardware, and the
//  automatic per-hand fallback if the advanced player cannot be made.
final class SenseHapticsDriver: @unchecked Sendable {
    var log: (String) -> Void = { _ in }

    /// Guards the engine/player maps and the run state that `dropEngine`
    /// resets, because `stoppedHandler` fires on CoreHaptics's own queue.
    private let lock = NSLock()
    /// One engine and one player per hand, created on that hand's first pulse.
    private var engines: [Int: CHHapticEngine] = [:]
    private var players: [Int: CHHapticAdvancedPatternPlayer] = [:]
    /// Per hand: is the player started, when did it last go silent, and the
    /// burst being logged.
    private var running = [false, false]
    private var silentSince: [TimeInterval] = [0, 0]
    private var burstPeak: [Float] = [0, 0]
    private var burstStart: [TimeInterval] = [0, 0]
    private var bursts = [0, 0]
    private var pulseFallback = [false, false]     // fell back to discrete?
    private var noted = Set<String>()

    /// Where the haptics calls run, and whether a batch is still in flight.
    private let queue = DispatchQueue(label: "sensekit.haptics", qos: .userInitiated)
    private let gate = NSLock()
    private var busy = false
    private var skipped = 0

    /// Play one frame's levels (index = hand) off the caller's thread.
    func play(_ levels: [(level: Float, seconds: Float)], at now: TimeInterval,
              configuration cfg: SenseHapticsConfiguration) {
        gate.lock()
        let wasBusy = busy
        if wasBusy { skipped += 1 } else { busy = true }
        gate.unlock()
        if wasBusy { return }

        let minOn = Float(cfg.minPulseMs) / 1000
        queue.async { [self] in
            for hand in 0...1 {
                let (level, seconds) = levels[hand]
                traceBurst(hand: hand, level: level, at: now)
                if cfg.mode == .pulse || pulseFallback[hand] {
                    if level > 0 { playPulse(hand: hand, level: level, seconds: seconds, cfg, minOn) }
                } else {
                    drive(hand: hand, level: level, at: now, cfg, minOn)
                }
            }
            let took = ProcessInfo.processInfo.systemUptime - now
            gate.lock()
            let dropped = skipped
            skipped = 0
            busy = false
            gate.unlock()
            if took > 0.25 {
                log("haptics: the haptics service took \(String(format: "%.2f", took)) s to answer — "
                    + "\(dropped) frame(s) of haptics dropped, the render loop did not wait")
            }
        }
    }

    /// The continuous path: hold one looping player per hand and move its
    /// intensity. Starting it costs a `start`; every frame after that is one
    /// `sendParameters`, which is what keeps the envelope unbroken.
    private func drive(hand: Int, level: Float, at now: TimeInterval,
                       _ cfg: SenseHapticsConfiguration, _ minOn: Float) {
        if level <= 0 {
            guard running[hand] else { return }
            // Silence first, then pause once it has been quiet a while: pausing
            // immediately would make every gap between two clips a stop/start
            // pair, which is the restart this design exists to avoid.
            send(hand: hand, level: 0)
            if silentSince[hand] == 0 { silentSince[hand] = now }
            if now - silentSince[hand] > 1.0 {
                try? players[hand]?.pause(atTime: CHHapticTimeImmediate)
                running[hand] = false
                silentSince[hand] = 0
            }
            return
        }
        silentSince[hand] = 0
        if !running[hand] {
            guard let player = player(for: hand, cfg) else { return }
            do { try player.start(atTime: CHHapticTimeImmediate) }
            catch {
                log("haptics: hand \(hand) player would not start: \(error)"
                    + " — falling back to discrete pulses")
                pulseFallback[hand] = true
                playPulse(hand: hand, level: level, seconds: minOn, cfg, minOn)
                return
            }
            running[hand] = true
        }
        send(hand: hand, level: level)
    }

    private func send(hand: Int, level: Float) {
        guard let player = players[hand] else { return }
        do {
            try player.sendParameters([CHHapticDynamicParameter(
                parameterID: .hapticIntensityControl, value: level, relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
        } catch {
            log("haptics: hand \(hand) parameter send failed: \(error)"
                + " — dropping the engine")
            dropEngine(hand)
        }
    }

    /// ALVR's shape, kept as the fallback and the A/B: one short continuous
    /// event per frame, never shorter than the floor.
    private func playPulse(hand: Int, level: Float, seconds: Float,
                           _ cfg: SenseHapticsConfiguration, _ minOn: Float) {
        guard let engine = engine(for: hand) else { return }
        do {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: level),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: cfg.sharpness),
            ], relativeTime: 0, duration: Double(max(seconds, minOn)))
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // Dropped rather than retried: every failure mode here (the engine
            // stopped, the device went away, the pattern was rejected) repeats
            // on the next frame, so keeping it would be one caught error per
            // frame for the rest of the run. A rebuild is one lazy `createEngine`.
            log("haptics: hand \(hand) pulse failed: \(error) — dropping the engine")
            dropEngine(hand)
        }
    }

    /// One line per BURST rather than per frame: at 90 Hz a held buzz would
    /// otherwise be ninety log lines a second, and what is worth reading is the
    /// shape — how loud it got and how long it lasted. The first burst per hand
    /// is the only evidence the whole chain reached an actuator.
    private func traceBurst(hand: Int, level: Float, at now: TimeInterval) {
        if level > 0 {
            if burstStart[hand] == 0 { burstStart[hand] = now; burstPeak[hand] = 0 }
            burstPeak[hand] = max(burstPeak[hand], level)
            return
        }
        guard burstStart[hand] != 0 else { return }
        let ms = (now - burstStart[hand]) * 1000
        bursts[hand] += 1
        if bursts[hand] <= 3 || bursts[hand] % 100 == 0 {
            log(String(format: "haptics: hand %d burst %d — peak %.2f over %.0f ms",
                       hand, bursts[hand], burstPeak[hand], ms))
        }
        burstStart[hand] = 0
    }

    private func player(for hand: Int, _ cfg: SenseHapticsConfiguration) -> CHHapticAdvancedPatternPlayer? {
        if let existing = players[hand] { return existing }
        guard let engine = engine(for: hand) else { return nil }
        do {
            // Intensity 1.0 in the pattern, because the dynamic parameter
            // SCALES it — an event authored quieter would cap everything below.
            // The event's own duration is irrelevant: the player loops.
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: cfg.sharpness),
            ], relativeTime: 0, duration: 1.0)
            let player = try engine.makeAdvancedPlayer(
                with: CHHapticPattern(events: [event], parameters: []))
            player.loopEnabled = true
            players[hand] = player
            return player
        } catch {
            log("haptics: hand \(hand) has no continuous player (\(error))"
                + " — falling back to discrete pulses")
            pulseFallback[hand] = true
            return nil
        }
    }

    private func engine(for hand: Int) -> CHHapticEngine? {
        lock.lock(); let existing = engines[hand]; lock.unlock()
        if let existing { return existing }
        guard let device = SenseControllers.spatialControllers()
            .first(where: { SenseControllers.hand(of: $0).rawValue == hand })
        else { return nil }
        guard let haptics = device.haptics else {
            note("haptics: \(device.vendorName ?? "controller") reports none")
            return nil
        }
        // One controller per hand, so the whole device is the locality. ALVR
        // asks for `.leftHandle`/`.rightHandle` first because its reference
        // device is one gamepad with two grips; a Sense controller *is* the
        // hand, and asking it for a handle it does not have returns nil.
        var made = haptics.createEngine(withLocality: .default)
        if made == nil { made = haptics.createEngine(withLocality: .all) }
        if made == nil, let any = haptics.supportedLocalities.first {
            made = haptics.createEngine(withLocality: any)
        }
        guard let engine = made else {
            note("haptics: no engine for hand \(hand); "
                 + "localities \(haptics.supportedLocalities)")
            return nil
        }
        engine.stoppedHandler = { [weak self] reason in
            self?.log("haptics: hand \(hand) engine stopped (reason \(reason.rawValue))")
            self?.dropEngine(hand)
        }
        // A reset is the media server having gone away and come back: every
        // CoreHaptics object in the process is invalid and the engine has to be
        // started again. Weak on the engine as well as on self — the handler is
        // held BY the engine, so capturing it strongly is a cycle that outlives
        // the controller.
        engine.resetHandler = { [weak self, weak engine] in
            self?.log("haptics: hand \(hand) engine reset — restarting")
            do { try engine?.start() } catch { self?.dropEngine(hand) }
        }
        do { try engine.start() } catch {
            note("haptics: hand \(hand) engine would not start: \(error)")
            return nil
        }
        log("haptics: hand \(hand) engine up on \(device.vendorName ?? "?")")
        lock.lock(); engines[hand] = engine; lock.unlock()
        return engine
    }

    private func dropEngine(_ hand: Int) {
        lock.lock()
        let engine = engines.removeValue(forKey: hand)
        // The player belongs to the engine; keeping it past one would be a
        // player on a dead engine, which throws on every frame's parameter send.
        players.removeValue(forKey: hand)
        running[hand] = false
        silentSince[hand] = 0
        lock.unlock()
        engine?.stop()
    }

    /// Every engine, for a disconnect or teardown.
    func releaseAll() {
        lock.lock()
        let all = engines
        engines.removeAll()
        players.removeAll()
        running = [false, false]
        silentSince = [0, 0]
        lock.unlock()
        for (_, e) in all { e.stop() }
    }

    /// Once per distinct message. These are all "this device cannot do
    /// haptics" shapes, which is a fact about the run rather than an event.
    private func note(_ msg: String) {
        lock.lock()
        let fresh = noted.insert(msg).inserted
        lock.unlock()
        if fresh { log(msg) }
    }
}
