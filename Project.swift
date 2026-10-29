import ProjectDescription

// BoopStash — persistent scratch buffers for macOS, with an iOS companion.
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
// out and linking fails. Swift's and SQL's grammars publish their generated
// parsers only on a side branch (with-generated-files, gh-pages), so each is
// pinned to a commit there.
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
    ("https://github.com/tree-sitter/tree-sitter-cpp", .exact("0.23.4"), ["TreeSitterCPP"]),
    ("https://github.com/tree-sitter/tree-sitter-ruby", .exact("0.23.1"), ["TreeSitterRuby"]),
    ("https://github.com/tree-sitter/tree-sitter-java", .exact("0.23.5"), ["TreeSitterJava"]),
    ("https://github.com/alex-pinkus/tree-sitter-swift", .revision("82bb3a533e0801fd2bbaa11dc49676e10bf41948"), ["TreeSitterSwift"]),
    ("https://github.com/the-mikedavis/tree-sitter-diff", .exact("0.2.0"), ["TreeSitterDiff"]),
    // SQL publishes its generated parser only on gh-pages; pinned to a commit.
    ("https://github.com/DerekStride/tree-sitter-sql", .revision("e038788e5d4daba82dea35676bf49a216629e141"), ["TreeSitterSql"]),
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
            // The app is BoopStash; the target and Swift module keep the
            // original spelling, which nobody sees.
            productName: "BoopStash",
            bundleId: appBundleId,
            deploymentTargets: macDeployment,
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "BoopStash",
                // Tuist's default plist hard-codes 1.0 and 1; the release sets
                // these build settings from the tag, so the plist must use them
                // (v0.1.0 shipped reporting 1.0).
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "NSHumanReadableCopyright": "Copyright © 2026 boopstash contributors. Apache-2.0.",
                // Services ▸ Save to BoopStash (ServicesProvider.saveSelection).
                "NSServices": [
                    [
                        "NSMenuItem": ["default": "Save to BoopStash"],
                        "NSMessage": "saveSelection",
                        "NSPortName": "BoopStash",
                        "NSSendTypes": ["public.utf8-plain-text", "NSStringPboardType"],
                        "NSRequiredContext": [:],
                    ],
                ],
            ]),
            sources: ["App/Sources/**", "App/Shared/**"],
            resources: [
                "App/Resources/**",
                // Boop's scripts (ADR 0005); the app lists and sends them.
                .folderReference(path: "Vendor/Boop/scripts"),
            ],
            entitlements: .file(path: "App/Boopstash.entitlements"),
            dependencies: [.target(name: "BoopstashCore"), .target(name: "BoopStashScripts")],
            // Notarization requires the hardened runtime; every build has it
            // so what is tested is what ships (ADR 0004).
            settings: .settings(base: [
                "ENABLE_HARDENED_RUNTIME": "YES",
                "PRODUCT_MODULE_NAME": "Boopstash",
                // The icon is App/Resources' AppIcon; there is no accent colour,
                // so the system's applies.
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
            ])
        ),
        // The iOS companion (#65), sharing BoopstashCore. Sync and the share
        // extension arrive with the developer-portal setup (#62).
        .target(
            name: "BoopStashMobile",
            destinations: [.iPhone, .iPad],
            product: .app,
            productName: "BoopStash",
            bundleId: appBundleId,
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "BoopStash",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                // One scene: two editors on one note would each save their own
                // copy over the other's until editors sync live.
                "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false],
            ]),
            sources: ["iOS/Sources/**"],
            dependencies: [.target(name: "BoopstashCore")],
            settings: .settings(base: ["PRODUCT_MODULE_NAME": "BoopStashMobile"])
        ),
        // Runs scripts and JavaScript formatters in its own sandboxed
        // process, so a runaway script can be stopped (ADR 0007).
        .target(
            name: "BoopStashScripts",
            destinations: .macOS,
            product: .xpc,
            bundleId: "\(appBundleId).scripts",
            deploymentTargets: macDeployment,
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "XPCService": ["ServiceType": "Application"],
            ]),
            sources: ["App/ScriptService/**", "App/Shared/**"],
            resources: [.folderReference(path: "Vendor/Boop/lib")],
            entitlements: .file(path: "App/ScriptService.entitlements"),
            dependencies: [.target(name: "BoopstashCore")],
            settings: .settings(base: [
                "ENABLE_HARDENED_RUNTIME": "YES",
                // BoopstashCore is embedded once, in the app's Frameworks.
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../../../../Frameworks",
            ])
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
