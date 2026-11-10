# SenseKit

Swift package: PS VR2 Sense controllers on visionOS (discovery, pose, input, haptics, ghost
controller) and macOS (discovery, input, haptics; no pose). Extracted from Klepton. User-facing
docs live in `README.md`; keep it in sync when the public API changes.

## Git

- **Everything goes on `main`.** No feature branches; commit straight to `main`.
- Push only when asked.

## Platforms

- Targets visionOS 26+ and macOS 26+. Every change must build on **both**.
- ARKit pose/tracking types (`HandAnchor`, `AccessoryTrackingProvider`, `GCSpatialAccessory`…)
  are visionOS-only: wrap them in `#if os(visionOS)` and give macOS a stub that returns nil
  (see `ghostSample`, `pose`, `aimRay` in `SenseControllers.swift`).
- The package never reads environment variables.

## Verify before committing

```sh
swift build && swift test                                                          # macOS
xcodebuild -scheme SenseKit -destination 'generic/platform=visionOS Simulator' build -quiet   # visionOS
```

Tests use Swift Testing (`Tests/SenseKitTests`). Swift language mode 5.

## Layout

- `SenseControllers.swift` — discovery, pose, input polling, haptics pump (main entry point).
- `SenseInputHub.swift`, `StickArbiter.swift`, `GamepadProfile.swift`, `GamepadState.swift` —
  multi-source input (Sense + classic/N64 pads).
- `SenseGhost*.swift` — ghost controller: state machine, mesh, Metal renderer.
- `ShakeDetector.swift`, `SenseMath.swift`, `SenseButtons.swift`, `SenseHaptics.swift`,
  `SenseState.swift`, `SenseHand.swift`, `SenseConfiguration.swift` — supporting types.
