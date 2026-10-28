// swift-tools-version: 6.0
import PackageDescription

// Deliberately empty. The spike's packages are integrated through Xcode's
// native Swift Package Manager support (`packages:` in Project.swift), not
// Tuist's: Tuist turns each package into a generated Xcode target, and the
// resource-bundle target it makes for tree-sitter-json keeps the package's
// default macOS 10.13 deployment target, which current Xcode refuses. Neither
// `baseSettings` nor `targetSettings` reaches that target. Worth knowing
// before GRDB or a grammar package joins the main project.
let package = Package(name: "EditorSpikeDependencies", dependencies: [])
