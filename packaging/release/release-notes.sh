#!/usr/bin/env bash
# The release-notes guard (#253): ReleaseNotes.json is the one source of
# what users are told about a release, shown in the app and sent to the App
# Store. CI and the release workflows run this first.
#
#   release-notes.sh check VERSION     the version has a well-formed, dated entry
#   release-notes.sh verify            the whole store is well formed, the changelog's
#                                      newest release has an entry and is the store's
#                                      newest, and fastlane's release_notes.txt files
#                                      match the store
#   release-notes.sh write             regenerate fastlane's release_notes.txt files
#   release-notes.sh app-store mac|ios print a platform's App Store text
#
# The checks are Core's own parser (Core/Sources/ReleaseNotes), compiled
# here with a small command, so this accepts exactly what the app accepts.
# RELEASE_NOTES_ROOT points it at another tree (the tests' fixtures);
# RELEASE_NOTES_BUILD keeps the compiled command between runs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
root="${RELEASE_NOTES_ROOT:-$repo}"

if [ -n "${RELEASE_NOTES_BUILD:-}" ]; then
  build="$RELEASE_NOTES_BUILD"
  mkdir -p "$build"
else
  build="$(mktemp -d)"
  trap 'rm -rf "$build"' EXIT
fi

tool="$build/release-notes"
if [ ! -x "$tool" ]; then
  # The parser always comes from this repository, whatever tree is checked.
  # Exit 3, so a command that does not compile is never taken for a failed
  # check (1) by anything that reads the status.
  xcrun swiftc -o "$tool" "$repo"/Core/Sources/ReleaseNotes/*.swift "$here/release-notes-tool/main.swift" >&2 || {
    echo "release notes: the checking command did not compile" >&2; exit 3; }
fi

"$tool" "$root" "$@"
