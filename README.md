# SenseKit

PS VR2 Sense controllers on visionOS (discovery, pose, input and haptics) and macOS (discovery,
input and haptics; no pose).

## Status

Extracted from Klepton's `KleptonControllers.swift` (behaviour unchanged); Klepton consumes it as a
submodule. GameController + ARKit + CoreHaptics only: no environment variables, no C.

## What it does

- **Discovery**: spatial `GCController`s, left/right by vendor name, hot-plug (`controllersChanged()`
  per frame → rebuild the `AccessoryTrackingProvider` with `makeTrackingProvider()`), `presentHands`.
- **Pose**: the accessory anchor stream (`consumeAnchors(from:)`), predicted to the frame's presentation
  time with a horizon cap, the `.grip` frame with a grip correction (PSVR2 tilt, pitch/yaw/roll, offset,
  pivot, left-hand mirror), velocities rotated and noise-gated, and a ghost sample for drawing the device.
- **Pointing**: `aimRay(_:at:)`, a world-space ray from the platform's `.aim` frame, predicted like the
  pose (see [Pointing](#pointing)).
- **Shake**: `ShakeDetector`, a pure per-controller shake pulse (Wii-style spin) fed the pose's velocities.
- **Input**: buttons, capacitive touches, trigger, grip and stick per hand, in physical names
  (`SenseButtons`); rebinding on every connect, cleared by attachment, queue or `capture()`.
- **Haptics**: one `CHHapticEngine` per hand, a continuous looping player driven by a per-frame level
  (or ALVR's discrete pulses), gain and minimum pulse, played off the render thread.

## Use

```swift
let sense = SenseControllers(configuration: SenseConfiguration())
sense.logger = { print("[sense]", $0) }
sense.hapticsSource = { hand in myLevel(hand) }      // (amplitude, seconds) or nil

// ARKit: add `await sense.makeTrackingProvider()` to the session's providers, then
// Task { await sense.consumeAnchors(from: provider) }

// Every frame, on the render thread:
if sense.controllersChanged() { sense.forgetPoses(); /* rebuild the provider, re-run the session */ }
sense.pollInput()
let right = sense.state(.right, at: presentationTime)  // input + predicted pose
sense.pumpHaptics()
```

## Pointing

The default grip correction is Klepton's Beat Saber hilt (-37° pitch plus tilt and position nudges)
and is the wrong frame for a pointer: as a ray, it and the uncorrected `.grip` both run about 35° off
where the controller points. The platform publishes a pointer of its own, the `.aim` frame; on device
(visionOS 27.2, PS VR2 Sense L and R) the "sense frames" probe measures it relative to `.grip` as
pitched -34.81° about X and offset about (±0.0013, -0.0144, -0.0779) m. Its -Z is the direction.

```swift
// Every frame: the right controller's ray, predicted like `state(.right, at:)`.
if let ray = sense.aimRay(.right, at: presentationTime) {
    cursor = myQuad.intersection(origin: ray.origin, direction: ray.direction)
}
```

`aimRay` reads `.aim` when the accessory publishes it and otherwise turns `.grip` by
`SenseGripCorrection.aim` (tilt 0, pitch -34.81, no position nudge). It ignores `gripCorrection`, so a
game can keep a hilt for the held object and still point. A consumer that wants the pose itself to be
the pointer sets `SenseConfiguration(gripCorrection: .aim)`.

**Pointing at a 2D surface**: intersect the ray with your quad in the same space. The anchors are in
the ARKit world origin, which is the one CompositorServices renders from and is shared across the
app, so a quad placed in that space needs no other transform.

## Shake

`ShakeDetector` (pure, one per controller) turns velocities into a held pulse: speed above
`linearThreshold` (1.6 m/s) or angular speed above `angularThreshold` (12 rad/s) starts a pulse that
reads true for `holdTicks` (5) updates, and no new one starts for `refractory` (0.25 s) after it began.
The defaults come from GalaxyPad and are tuned for Wii-style spin shakes (a wrist flick turns fast and
moves little); they are not yet validated on a headset.

```swift
var shake = [ShakeDetector(), ShakeDetector()]
// Every poll:
let spin = shake[hand.rawValue].update(pose: sense.pose(hand, at: now), at: now)
```

## Gamepads and the input hub

`SenseInputHub` makes SenseKit the one input layer of a game: the Sense controllers plus every
classic gamepad visionOS exposes as a `GCController`, polled together once a frame, with the
sticks **arbitrated** so two controllers never fight over one axis (the bug it exists for: a
parked Sense stick writing (0, 0) every frame over the N64 stick in use → jitter).

- `GamepadProfile.read(_:)` reads a pad into a `GamepadState` (`GamepadButtons` + sticks +
  triggers + `kind`): `extendedGamepad` pads (DualSense, Xbox, Switch Pro…) positionally —
  `a` south, `b` east, `x` west, `y` north, `l`/`r` shoulders, `zl`/`zr` triggers, `start` =
  menu, `select` = options — and the Nintendo Switch Online **N64 controller** (no
  `extendedGamepad`; `productCategory` "Switch N64 Controller") by element name:

  | N64            | Element name(s)                              | `GamepadButtons` / state   |
  |----------------|----------------------------------------------|----------------------------|
  | A, B           | "Button A", "Button B"                       | `.a`, `.b`                 |
  | Z              | "Left Trigger"                               | `.zl` (`leftTrigger` = 1)  |
  | L, R           | "Left Shoulder", "Right Shoulder"            | `.l`, `.r`                 |
  | Start          | "Button Menu"                                | `.start`                   |
  | Share, Home    | "Button Share", "Button Home"                | `.select`, `.home`         |
  | D-pad          | "Direction Pad" (+ "… Up/Down/Left/Right")   | `.dpadUp` … `.dpadRight`   |
  | Control Stick  | "Left Thumbstick" (a `GCControllerDirectionPad`) | `leftStick`            |
  | C buttons      | "Right Thumbstick Up/Down/Left/Right"        | `.cUp` … `.cRight` (and `rightStick` as ±1) |
  | (right trigger)| "Right Trigger"                              | `.zr`                      |

  Z is reported as `zl` on purpose: it is the generic name GameController gives it, so one
  mapping serves the N64 and an extended pad.
- `StickArbiter` (pure, one per axis): an axis is owned by the source that most recently moved
  it past the deadzone (0.2); while the owner is deflected its value wins; when it returns to
  centre it keeps the axis until another source deflects, so parked zeros never win.
- `SenseInputHub.pollInput()` runs `sense.controllersChanged()` + `sense.pollInput()`, reads the
  pads, logs bind/unbind through `logger`, and `arbitrated()` gives the frame: both sticks with
  their owners, the OR of every pad's buttons, and both Sense hands.

```swift
let hub = SenseInputHub()                           // or SenseInputHub(sense: mySense)
hub.logger = { print("[input]", $0) }
var lastButtons: GamepadButtons = []

// Every frame, on the render thread:
if hub.pollInput() { hub.sense.forgetPoses(); /* rebuild the tracking provider */ }
let input = hub.arbitrated()
game.move(input.leftStick)                          // whoever is actually using it
if input.buttons.contains(.zl) || input.senseLeft.trigger > 0.5 { game.zTarget() }
let presses = input.buttons.changes(since: lastButtons).pressed
lastButtons = input.buttons
// Keep a source off an axis (a cursor, the N64 C buttons): hub.pollInput { src, axis in ... }
```

## Requirements

visionOS 26+ or macOS 26+.

## macOS

The package builds for macOS too: the Sense controllers paired to the Mac over Bluetooth, and
every classic pad, through GameController alone. Measured on macOS 27 with both Sense
controllers paired: each is its own `GCController` ("PlayStation VR2 Sense Controller (L)" /
"(R)", `productCategory` "Spatial Controller", no `extendedGamepad`), with the same element names
as on visionOS ("Button A", "Button B", "Button Menu", "Grip", "Thumbstick Button", the
"Thumbstick" DPAD, "Trigger") and `haptics`. They appear asynchronously, a second or two after
launch, delivered on the main run loop, so the process must run one (a Cocoa/SDL event loop, or
`RunLoop.main.run()` in a CLI). No Info.plist is needed, even for a command-line binary; set
`GCController.shouldMonitorBackgroundEvents = true` to get input while another app is
frontmost (a CLI in Terminal always is).

What is not there on macOS (ARKit accessory tracking and `GCSpatialAccessory` are visionOS
only): `makeTrackingProvider()` and `consumeAnchors(from:)` do not exist; `pose(_:at:)`,
`aimRay(_:at:)` and `ghostSample(_:at:)` always return nil, so `state(_:at:)` is the input with
`pose == nil`. Everything else (`pollInput`, `inputState`, `SenseButtons`, `pumpHaptics`,
`SenseInputHub`, `StickArbiter`, `GamepadProfile`, `ShakeDetector` fed by your own velocities)
behaves as on visionOS. No capacitive touches were seen in the element lists on macOS
(`touches` stays empty).

## App setup

What an app needs before the controllers show up at all:

- **Deployment target visionOS 26** (or macOS 26 for input + haptics only) (`AccessoryTrackingProvider`, spatial `GCController`s).
- **`GCSupportedGameControllers`** must list the profile `SpatialGamepad`, or GameController never
  offers the Sense controllers to the app; add `ExtendedGamepad` too for classic pads.
- **`NSAccessoryTrackingUsageDescription`** is required. Requesting accessory tracking without it is
  not a refusal: the system kills the process (a TCC crash report), on device only, since the
  Simulator does not enforce TCC. `makeTrackingProvider()` builds a provider even with no controller
  paired, so the request can come with nothing connected.

```xml
<key>GCSupportedGameControllers</key>
<array>
    <dict><key>ProfileName</key><string>SpatialGamepad</string></dict>
    <dict><key>ProfileName</key><string>ExtendedGamepad</string></dict>
</array>
<key>NSAccessoryTrackingUsageDescription</key>
<string>Tracks your PlayStation VR2 Sense controllers.</string>
```

**SDL-based engines**: an engine with SDL's gamepad support (e.g. Aurora's SDL3, through its MFi
joystick driver) also enumerates the Sense controllers and every pad as SDL gamepads. When SenseKit
owns input, disable the engine's SDL gamepad path, or each pad is read twice.

## Adding it

Add it as a git submodule and reference it as a local Swift package:

```
git submodule add https://github.com/NSCabezon/SenseKit
```

## Licence

MIT, see `LICENSE`. Third-party notices are in `THIRD_PARTY_NOTICES.md`.
