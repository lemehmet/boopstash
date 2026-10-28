// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings

// External Swift packages for the Tuist project, resolved by `tuist install`.
// None yet. GRDB arrives with the store in milestone 2. Each dependency is
// argued for in its PR; if the SDK can do it, it should.
let packageSettings = PackageSettings(productTypes: [:])
#endif

let package = Package(
    name: "BoopstashDependencies",
    dependencies: []
)
