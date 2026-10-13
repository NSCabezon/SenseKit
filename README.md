# SenseKit

PS VR2 Sense controllers on visionOS: discovery, pose, input and haptics.

## Status

Extracted from Klepton's `KleptonControllers.swift` (behaviour unchanged); Klepton consumes it as a
submodule. GameController + ARKit + CoreHaptics only: no environment variables, no C.

## What it does

- **Discovery**: spatial `GCController`s, left/right by vendor name, hot-plug (`controllersChanged()`
  per frame → rebuild the `AccessoryTrackingProvider` with `makeTrackingProvider()`), `presentHands`.
- **Pose**: the accessory anchor stream (`consumeAnchors(from:)`), predicted to the frame's presentation
  time with a horizon cap, the `.grip` frame with a grip correction (PSVR2 tilt, pitch/yaw/roll, offset,
  pivot, left-hand mirror), velocities rotated and noise-gated, and a ghost sample for drawing the device.
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

## Requirements

visionOS 26+.

## Adding it

Add it as a git submodule and reference it as a local Swift package:

```
git submodule add https://github.com/NSCabezon/SenseKit
```

## Licence

MIT, see `LICENSE`. Third-party notices are in `THIRD_PARTY_NOTICES.md`.
