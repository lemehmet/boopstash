# ADR 0004 — Distribution: one sandboxed build, Homebrew cask and Mac App Store

- **Status:** Accepted (2026-10-28)
- **Deciders:** boopstash maintainers

## Context

The expected audience installs through Homebrew. The Mac App Store matters
less for this app, but establishing the know-how is a goal in itself.

Homebrew 5 set 2026-09-01 as the date after which casks failing its
code-signing and notarization audit would be dropped from the official tap, and
the `--no-quarantine` flag is gone. A personal tap is not audited the same way,
but an un-notarized app still meets Gatekeeper on first launch.

## Decision

- **One code path for both channels, sandboxed from day one.** The App Store
  requires the App Sandbox; building the Homebrew release sandboxed too means
  there is never an App Store-only bug. It rules out calling external tools
  (formatters are bundled, see ADR 0005), Accessibility-based tricks, and a
  bundled auto-updater.
- **No auto-updater.** Homebrew users get `brew upgrade`, App Store users get
  the App Store. This also keeps the "no network except iCloud" promise of
  ADR 0001.
- **Homebrew: a cask in a personal tap, `lemehmet/homebrew-boopstash`.** Release
  shape follows mdlook: a `v*` tag builds, signs with Developer ID, notarizes
  with `notarytool`, staples, publishes a GitHub release, then renders
  `packaging/homebrew/boopstash.rb` into the tap's `Casks/` and pushes it with a
  deploy key that can write to that repository only. A `workflow_dispatch` run
  is a dry run that never reaches the tap.
- **Developer ID signing from repository secrets.** The release workflow
  imports a `.p12` of the Developer ID Application identity into a throwaway
  keychain, archives a universal build with the hardened runtime, exports it
  with Developer ID, checks the signature, architectures and entitlements,
  notarizes with `notarytool` (App Store Connect API key) and staples. A
  `.p12` secret was chosen over `fastlane match` for this one identity: the
  certificate already exists and is exported once, and the release job needs
  no Ruby toolchain.
- **Mac App Store and TestFlight through fastlane,** with signing material
  through `fastlane match` on S3 and an App Store Connect API key, as in
  proswatch.
- **Bundle ID `com.lemehmet.boopstash`** for both channels, so both share one
  iCloud container. Developer ID builds can use CloudKit with a Developer ID
  provisioning profile.
- **Universal binary.** It costs nothing for a Swift app. AI features are
  unavailable on Intel and fall back to rules.

## Consequences

- Release needs secrets: Developer ID certificate, notarization credentials
  (the App Store Connect API key), the tap deploy key. The release workflow
  fails with a named, actionable error when one is missing, as mdlook's does.
- The first release (milestone 3) is cut early, while the app is small, so the
  signing and notarization path is learned before it carries much.
