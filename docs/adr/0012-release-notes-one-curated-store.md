# ADR 0012 — Release notes: one curated store, bundled, and a release guard

- **Status:** Accepted (2026-11-24)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0004 (distribution), within ADR 0001 (privacy baseline)

## Context

What users are told about a release lived in three hand-kept places:
`CHANGELOG.md`, detailed and for maintainers, and the two fastlane
`release_notes.txt` files for the App Store. None was in the app, and
nothing kept them in step. Homebrew users, the expected audience (ADR 0004),
never see App Store text at all (#253).

There is no auto-updater and no network access beyond the user's iCloud
(ADR 0001, 0004), so the app cannot ask anyone what changed.

## Decision

- **One file, `ReleaseNotes.json`, is the source of user-facing notes.** An
  entry per released version (version, `YYYY-MM-DD` date, a few plain lines
  each marked Mac, iOS or both), keyed by version because releases are cut
  by version tag. Work not yet released sits in `unreleased` and is never
  shown. `CHANGELOG.md` stays the detailed record.
- **Bundled, never fetched.** Both apps carry the file. Which version a
  device last ran is kept in that device's own defaults and is not synced.
- **Parsing, ordering and selection are Core's.** A malformed entry is
  skipped, not fatal: the app shows what it can read.
- **The App Store text is written from the store.** Per platform it is
  every line after `appStoreSince`, newest first; the fastlane files are
  generated and CI fails when they differ from the store or pass 4000
  characters.
- **A release guard.** `packaging/release/release-notes.sh` compiles Core's
  own parser with a small command, so it accepts exactly what the app
  accepts. `check VERSION` runs first in the release workflow, before
  signing; `verify` runs in CI and first in the App Store workflow. A
  version with no well-formed, dated entry is not released.

## Consequences

- Cutting a release has one more step: move `unreleased` into a dated
  entry and regenerate the fastlane files (CONTRIBUTING ▸ Releasing). A tag
  pushed without it fails in its first minute, before any secret is used.
- The guard needs a Swift compiler, which every workflow that runs it
  already has (macOS runners).
- A workflow run by hand against a ref older than the store has nothing to
  check and says so, instead of failing.
- A dry run of a branch has no version and is not checked.
- Notes are English only, like the rest of the app.
