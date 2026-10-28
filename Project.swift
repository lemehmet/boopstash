import ProjectDescription

// Boopstash — persistent scratch buffers for macOS, with an iOS companion.
//
// Layout:
//   - `BoopstashCore`  Foundation plus GRDB, macOS + iOS. Everything that can be
//                      logic without a device framework lives here, with unit
//                      tests: the note model, search queries, title rules,
//                      keymap presets, paste conversion, script-API semantics.
//   - `Boopstash`      the macOS app. Thin `Live*` adapters are the only code
//                      that imports AppKit, CloudKit, Vision or JavaScriptCore.
//   - The iOS app target arrives with sync in milestone 5.
//   - Swift packages are integrated through Xcode's native package support
//     (`packages:` below), not Tuist's generated targets: the spike found
//     Tuist's resource-bundle targets keep a package's old deployment target,
//     which current Xcode refuses (ADR 0006).
//
// Conventions (see docs/adr/):
//   - Deployment floor macOS 26 / iOS 26 (ADR 0001).
//   - The app is sandboxed in every build, Homebrew and App Store alike
//     (ADR 0004). A new entitlement needs an ADR.
//   - Bundle ID family `com.lemehmet.boopstash.*`.
//   - Signing is not pinned here, so `tuist generate` works with no Apple team.
//     Release signing is injected by the release workflow in milestone 3.

let appBundleId = "com.lemehmet.boopstash"

let macDeployment: DeploymentTargets = .macOS("26.0")
let coreDeployment: DeploymentTargets = .multiplatform(iOS: "26.0", macOS: "26.0")
let coreDestinations: Destinations = [.mac, .iPhone, .iPad]

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    // Version is driven by build settings so the release workflow can set both
    // from the tag.
    "MARKETING_VERSION": "0.0.1",
    "CURRENT_PROJECT_VERSION": "1",
]

let project = Project(
    name: "Boopstash",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    packages: [
        // SQLite toolkit for the store and its FTS5 index (ADR 0002).
        .remote(url: "https://github.com/groue/GRDB.swift", requirement: .exact("7.11.1")),
    ],
    settings: .settings(
        base: baseSettings,
        configurations: [
            .debug(name: "Debug"),
            .release(name: "Release"),
        ]
    ),
    targets: [
        .target(
            name: "BoopstashCore",
            destinations: coreDestinations,
            product: .framework,
            bundleId: "\(appBundleId).core",
            deploymentTargets: coreDeployment,
            infoPlist: .default,
            sources: ["Core/Sources/**"],
            dependencies: [.package(product: "GRDB")]
        ),
        // Tests run on macOS: no simulator to boot, and Core is pure Foundation
        // so the platform does not change what is being tested. CI separately
        // compiles Core for iOS to keep it honest.
        .target(
            name: "BoopstashCoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(appBundleId).core.tests",
            deploymentTargets: macDeployment,
            infoPlist: .default,
            sources: ["Core/Tests/**"],
            dependencies: [.target(name: "BoopstashCore")]
        ),
        .target(
            name: "Boopstash",
            destinations: .macOS,
            product: .app,
            bundleId: appBundleId,
            deploymentTargets: macDeployment,
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Boopstash",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "NSHumanReadableCopyright": "Copyright © 2026 boopstash contributors. Apache-2.0.",
            ]),
            sources: ["App/Sources/**"],
            entitlements: .file(path: "App/Boopstash.entitlements"),
            dependencies: [.target(name: "BoopstashCore")]
        ),
        // Hosted by the app: the editor needs a window, a responder chain
        // and AppKit's pasteboard and key machinery, which Core tests avoid.
        .target(
            name: "BoopstashTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(appBundleId).tests",
            deploymentTargets: macDeployment,
            infoPlist: .default,
            sources: ["App/Tests/**"],
            dependencies: [.target(name: "Boopstash")]
        ),
    ]
)
