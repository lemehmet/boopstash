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

// Syntax highlighting (ADR 0006): SwiftTreeSitter and one package per
// grammar, each pinned exactly. Some pins are deliberately behind the latest
// tag: the 0.25-era grammar manifests add scanner.c only if
// `FileManager.fileExists("src/scanner.c")` is true at manifest evaluation,
// which SwiftPM runs from another directory, so the scanner is silently left
// out and linking fails. Swift's grammar publishes its generated parser only
// on the with-generated-files branch, so it is pinned to a commit there.
// Grammars depend on SwiftTreeSitter under two URLs (ChimeHQ's and
// tree-sitter's), but only in their test targets, which SwiftPM does not
// resolve for dependencies.
let grammars: [(url: String, requirement: Package.Requirement, products: [String])] = [
    ("https://github.com/tree-sitter/tree-sitter-json", .exact("0.24.8"), ["TreeSitterJSON"]),
    ("https://github.com/tree-sitter-grammars/tree-sitter-yaml", .exact("0.7.0"), ["TreeSitterYAML"]),
    ("https://github.com/tree-sitter-grammars/tree-sitter-toml", .exact("0.7.0"), ["TreeSitterTOML"]),
    ("https://github.com/tree-sitter-grammars/tree-sitter-xml", .exact("0.7.0"), ["TreeSitterXML"]),
    ("https://github.com/tree-sitter-grammars/tree-sitter-markdown", .exact("0.5.4"), ["TreeSitterMarkdown"]),
    ("https://github.com/tree-sitter/tree-sitter-html", .exact("0.23.2"), ["TreeSitterHTML"]),
    ("https://github.com/tree-sitter/tree-sitter-css", .exact("0.23.2"), ["TreeSitterCSS"]),
    ("https://github.com/tree-sitter/tree-sitter-javascript", .exact("0.23.1"), ["TreeSitterJavaScript"]),
    ("https://github.com/tree-sitter/tree-sitter-typescript", .exact("0.23.2"), ["TreeSitterTypeScript"]),
    ("https://github.com/tree-sitter/tree-sitter-python", .exact("0.23.6"), ["TreeSitterPython"]),
    ("https://github.com/tree-sitter/tree-sitter-bash", .exact("0.25.1"), ["TreeSitterBash"]),
    ("https://github.com/tree-sitter/tree-sitter-go", .exact("0.23.4"), ["TreeSitterGo"]),
    ("https://github.com/tree-sitter/tree-sitter-rust", .exact("0.24.2"), ["TreeSitterRust"]),
    ("https://github.com/tree-sitter/tree-sitter-c", .exact("0.24.2"), ["TreeSitterC"]),
    ("https://github.com/tree-sitter/tree-sitter-java", .exact("0.23.5"), ["TreeSitterJava"]),
    ("https://github.com/alex-pinkus/tree-sitter-swift", .revision("82bb3a533e0801fd2bbaa11dc49676e10bf41948"), ["TreeSitterSwift"]),
    ("https://github.com/the-mikedavis/tree-sitter-diff", .exact("0.2.0"), ["TreeSitterDiff"]),
]
let syntaxPackages: [Package] =
    [.remote(url: "https://github.com/tree-sitter/swift-tree-sitter", requirement: .exact("0.10.0"))]
    + grammars.map { .remote(url: $0.url, requirement: $0.requirement) }
let syntaxProducts = ["SwiftTreeSitter"] + grammars.flatMap(\.products)

let project = Project(
    name: "Boopstash",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    packages: [
        // SQLite toolkit for the store and its FTS5 index (ADR 0002).
        .remote(url: "https://github.com/groue/GRDB.swift", requirement: .exact("7.11.1")),
    ] + syntaxPackages,
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
            dependencies: [.package(product: "GRDB")] + syntaxProducts.map { .package(product: $0) }
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
                // Services ▸ Save to Boopstash (ServicesProvider.saveSelection).
                "NSServices": [
                    [
                        "NSMenuItem": ["default": "Save to Boopstash"],
                        "NSMessage": "saveSelection",
                        "NSPortName": "Boopstash",
                        "NSSendTypes": ["public.utf8-plain-text", "NSStringPboardType"],
                        "NSRequiredContext": [:],
                    ],
                ],
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
