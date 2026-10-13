// swift-tools-version:6.2
//
// SenseKit — PS VR2 Sense controllers on visionOS: discovery, pose, input and haptics.
// Extracted from Klepton's KleptonControllers.swift so any visionOS app can use them.
// GameController + ARKit + CoreHaptics only; the package never reads environment variables.
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
