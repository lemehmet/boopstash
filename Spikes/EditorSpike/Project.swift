import ProjectDescription

let deployment: DeploymentTargets = .macOS("26.0")

let project = Project(
    name: "EditorSpike",
    packages: [
        // ChimeHQ's URL, not tree-sitter/swift-tree-sitter: the grammar
        // packages still depend on the old one, and two URLs for one package
        // collide.
        .remote(url: "https://github.com/ChimeHQ/SwiftTreeSitter", requirement: .exact("0.10.0")),
        .remote(url: "https://github.com/tree-sitter/tree-sitter-json", requirement: .exact("0.24.8")),
    ],
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
    ]),
    targets: [
        .target(
            name: "EditorSpike",
            destinations: .macOS,
            product: .app,
            bundleId: "com.lemehmet.boopstash.editorspike",
            deploymentTargets: deployment,
            infoPlist: .extendingDefault(with: [:]),
            sources: ["Sources/**"],
            entitlements: .file(path: "EditorSpike.entitlements"),
            dependencies: [
                .package(product: "SwiftTreeSitter"),
                .package(product: "TreeSitterJSON"),
            ]
        ),
        // Hosted by the app: the checks need a real window, a responder chain
        // and AppKit's key binding machinery.
        .target(
            name: "EditorSpikeTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.lemehmet.boopstash.editorspike.tests",
            deploymentTargets: deployment,
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [.target(name: "EditorSpike")]
        ),
    ]
)
