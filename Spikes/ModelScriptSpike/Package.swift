// swift-tools-version: 6.2
import PackageDescription

// A spike (ADR 0013), outside CI and outside the app's Tuist project: can
// Apple's on-device model write a Boop-style script? Run it with
//   swift run -c release --package-path Spikes/ModelScriptSpike ModelScriptSpike
let package = Package(
    name: "ModelScriptSpike",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure: fixtures, prompts, reply extraction, scoring. No model, no JavaScriptCore.
        .target(name: "SpikeKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ModelScriptSpike", dependencies: ["SpikeKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SpikeKitTests", dependencies: ["SpikeKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
