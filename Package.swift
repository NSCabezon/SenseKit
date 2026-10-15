// swift-tools-version:6.2
//
// SenseKit — PS VR2 Sense controllers on visionOS: discovery, pose, input, haptics, and
// the "ghost" controller (the Sense model drawn at a resting controller's real pose so it can
// be found in full VR: state machine, mesh and Metal renderer).
// Extracted from Klepton's KleptonControllers.swift and KleptonHUD.swift so any visionOS app
// can use them. GameController + ARKit + CoreHaptics + Metal only; the package never reads
// environment variables.
import PackageDescription

let package = Package(
    name: "SenseKit",
    platforms: [.visionOS(.v26)],
    products: [
        .library(name: "SenseKit", targets: ["SenseKit"]),
    ],
    targets: [
        .target(name: "SenseKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SenseKitTests", dependencies: ["SenseKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
