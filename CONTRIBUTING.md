# Contributing to Boopstash

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
