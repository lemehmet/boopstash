# Contributing to BoopStash

Thanks for your interest. Contributions and bug reports are both welcome.

## Dev setup

Requirements: Xcode 26 or newer and [mise](https://mise.jdx.dev).

```sh
mise install                              # installs the pinned Tuist
mise exec -- tuist install                # resolves Swift packages
mise exec -- tuist generate               # generates and opens the workspace
mise exec -- tuist test BoopstashCore     # unit tests
```

The `.xcodeproj` and `.xcworkspace` are generated from `Project.swift` and are
never committed. Change the manifest, not the project.

## The checks

CI runs on macOS:

- `tuist generate`
- the `BoopstashCore` unit tests
- a build of the macOS app
- a build of `BoopstashCore` for iOS

## What review will ask about

**Read the ADRs first.** [`docs/adr/`](docs/adr/) records the decisions that
shape everything else: the platform floor and privacy baseline, storage, editor
behaviour, distribution, formatting. A change that contradicts one needs a new
ADR, not a quiet exception.

**Logic lives in `BoopstashCore`, with tests.** Core imports Foundation and
GRDB, and nothing that needs a device or a window. Only thin `Live*` adapters in the app
import AppKit, CloudKit, Vision or JavaScriptCore. If a change adds a decision
to an adapter, expect to be asked to move it into Core.

**Privacy is a hard constraint.** No new network access, no new entitlement and
no background pasteboard read without an ADR. The app reads the pasteboard only
in response to a user action.

**Dependencies are argued for, not added.** If the SDK can do it, it should.

**Comments explain the decision, not the code.** Why this ordering, why this is
refused, what breaks if it changes.

## Pull requests

1. Branch off `main`; do not push to `main` directly.
2. Keep them focused, and include tests for new behaviour.
3. Automated review runs at most three rounds per PR. Comments from the third
   round become follow-up issues rather than more fix commits, and the PR is
   labelled `review-capped`, which stops further rounds.
4. Add a line to `CHANGELOG.md` under **Unreleased** for anything a user would
   notice.

## Releasing

A `v*` tag runs `.github/workflows/release.yml`: a universal build signed with
Developer ID, notarized and stapled, a GitHub release, and the cask rendered
into [lemehmet/homebrew-boopstash](https://github.com/lemehmet/homebrew-boopstash)
(ADR 0004). Running the workflow by hand with a tag or branch is a dry run of
the build, signing and notarization that publishes nothing.

It needs, in this repository's Actions settings:

| Name | Kind | What |
|---|---|---|
| `APPLE_TEAM_ID` | variable | The Apple Developer team ID |
| `DEVELOPER_ID_P12_BASE64` | secret | The Developer ID Application certificate and its private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | secret | The password chosen for that export |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | secrets | An App Store Connect API key (Users and Access ▸ Integrations), used by `notarytool` |
| `ASC_KEY_CONTENT` | secret | That key's `.p8` file, `base64 -i AuthKey_XXXX.p8` |
| `HOMEBREW_TAP_DEPLOY_KEY` | secret | The private half of a write deploy key on the tap repository |
| `MACOS_DEVELOPER_ID_PROFILE_BASE64` | secret | The Developer ID provisioning profile for `com.lemehmet.boopstash`, made after the App ID has iCloud with the container `iCloud.com.lemehmet.boopstash` (ADR 0008), then `base64 -i profile.provisionprofile`. Changing the App ID's capabilities invalidates it: make a new one and replace the secret |

To cut a release: move **Unreleased** in `CHANGELOG.md` under the new version,
merge that, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
