#!/usr/bin/env bash
# Tests for release-notes.sh against made-up trees, run the way the release
# workflows run their steps (bash -eo pipefail). CI runs this.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
# Compiled once for every case below.
export RELEASE_NOTES_BUILD="$work/build"

tree() { # tree <name> <changelog version> <changelog date> < store JSON on stdin
  local dir="$work/$1"
  mkdir -p "$dir/fastlane/metadata/en-US" "$dir/fastlane/metadata-ios/en-US"
  cat > "$dir/ReleaseNotes.json"
  printf '# Changelog\n\n## Unreleased\n\n## v%s — %s\n\n- Something.\n' "$2" "$3" > "$dir/CHANGELOG.md"
  echo "$dir"
}

expect() { # expect <pass|fail> <tree> <label> <text the output must hold, or ""> <command...>
  # 0 is a pass and 1 a failed check; anything else is the script itself
  # failing, which must never pass for either.
  local want="$1" dir="$2" label="$3" needle="$4" status=0 output outcome
  shift 4
  output="$(RELEASE_NOTES_ROOT="$dir" "$here/release-notes.sh" "$@" 2>&1)" || status=$?
  case "$status" in
    0) outcome=pass ;;
    1) outcome=fail ;;
    *) outcome="crash (exit $status)" ;;
  esac
  if [ "$outcome" != "$want" ]; then
    echo "FAIL $label: expected $want, got $outcome: $output"; failures=$((failures + 1))
  elif [ -n "$needle" ] && [[ "$output" != *"$needle"* ]]; then
    echo "FAIL $label: output does not name \"$needle\": $output"; failures=$((failures + 1))
  else
    echo "ok   $label"
  fi
}

good="$(tree good 1.2.0 2026-01-05 <<'JSON'
{
  "appStoreSince": { "mac": "1.0.0", "ios": "1.0.0" },
  "unreleased": [ { "on": "both", "text": "Something on its way." } ],
  "releases": [
    { "version": "1.2.0", "date": "2026-01-05", "notes": [
      { "on": "mac", "text": "A Mac line." },
      { "on": "both", "text": "A line for both." } ] },
    { "version": "1.1.0", "date": "2026-01-02", "notes": [ { "on": "ios", "text": "An iOS line." } ] },
    { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "The first release." } ] }
  ]
}
JSON
)"

expect fail "$good" "the App Store files are missing" "release-notes.sh write" verify
expect pass "$good" "write makes the App Store files" "" write
expect pass "$good" "a good tree verifies" "" verify
expect pass "$good" "a released version has an entry" "" check 1.2.0
expect pass "$good" "a pre-release takes its version's entry" "" check 1.2.0-rc.1
expect fail "$good" "a version with no entry fails, by name" "1.3.0" check 1.3.0
expect fail "$good" "a version that is not one fails" "banana" check banana

mac="$(cat "$good/fastlane/metadata/en-US/release_notes.txt")"
ios="$(cat "$good/fastlane/metadata-ios/en-US/release_notes.txt")"
if [ "$mac" = $'• A Mac line.\n• A line for both.' ] && [ "$ios" = $'• A line for both.\n• An iOS line.' ]; then
  echo "ok   the App Store text holds each platform's lines after the baseline, newest first"
else
  echo "FAIL the App Store text: mac [$mac] ios [$ios]"; failures=$((failures + 1))
fi

echo "• Edited by hand." >> "$good/fastlane/metadata/en-US/release_notes.txt"
expect fail "$good" "an App Store file that disagrees with the store" "fastlane/metadata/en-US/release_notes.txt" verify

# The changelog's newest release must be in the store, with the same date.
behind="$(tree behind 1.3.0 2026-02-01 < "$good/ReleaseNotes.json")"
expect pass "$behind" "(write, to isolate the next check)" "" write
expect fail "$behind" "the changelog is ahead of the store" "1.3.0" verify
dated="$(tree dated 1.2.0 2026-01-06 < "$good/ReleaseNotes.json")"
expect pass "$dated" "(write, to isolate the next check)" "" write
expect fail "$dated" "the dates disagree" "2026-01-06" verify

# The App Store lanes build the changelog's newest version: an entry above it
# would send notes for a version not released yet.
ahead="$(tree ahead 1.2.0 2026-01-05 <<'JSON'
{
  "appStoreSince": { "mac": "1.0.0", "ios": "1.0.0" },
  "releases": [
    { "version": "1.3.0", "date": "2026-02-01", "notes": [ { "text": "Not released yet." } ] },
    { "version": "1.2.0", "date": "2026-01-05", "notes": [ { "text": "A line for both." } ] },
    { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "The first release." } ] }
  ]
}
JSON
)"
expect pass "$ahead" "(write, to isolate the next check)" "" write
expect fail "$ahead" "the store is ahead of the changelog" "1.3.0 has an entry" verify

# fastlane would read "## v1.2.0.1" as 1.2.0: the check stops there instead
# of passing on to an older heading.
four="$(tree four 1.1.0 2026-01-02 < "$good/ReleaseNotes.json")"
printf '# Changelog\n\n## v1.2.0.1 — 2026-01-06\n\n## v1.1.0 — 2026-01-02\n' > "$four/CHANGELOG.md"
expect pass "$four" "(write, to isolate the next check)" "" write
expect fail "$four" "a changelog heading with four numbers" "v1.2.0.1" verify
prose="$(tree prose 1.2.0 2026-01-05 < "$good/ReleaseNotes.json")"
printf '# Changelog\n\n## verbose notes\n\n## v1.2.0 — 2026-01-05\n' > "$prose/CHANGELOG.md"
expect pass "$prose" "(write, to isolate the next check)" "" write
expect pass "$prose" "a heading that is not a version is passed over" "" verify

# A malformed entry is absent: the check fails for it as for a missing one.
malformed="$(tree malformed 1.2.0 2026-01-05 <<'JSON'
{
  "releases": [
    { "version": "1.2.0", "notes": [ { "text": "No date." } ] },
    { "version": "1.1.0", "date": "2026-02-30", "notes": [ { "text": "Not a day." } ] },
    { "version": "1.0.1", "date": "2026-01-03", "notes": [ { "on": "watch", "text": "Another platform." } ] },
    { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "The first release." } ] }
  ]
}
JSON
)"
expect fail "$malformed" "an entry with no date is absent" "1.2.0" check 1.2.0
expect fail "$malformed" "an entry with an impossible date is absent" "1.1.0" check 1.1.0
expect fail "$malformed" "an entry for an unknown platform is absent" "1.0.1" check 1.0.1
expect pass "$malformed" "the good entry beside them stands" "" check 1.0.0
expect fail "$malformed" "verify names what is malformed" "1.2.0 has no YYYY-MM-DD date" verify
expect fail "$malformed" "write refuses a malformed store" "" write

broken="$(tree broken 1.0.0 2026-01-01 <<'JSON'
{ "releases": [
JSON
)"
expect fail "$broken" "a file that is not JSON has no entries" "1.0.0" check 1.0.0

if [ "$failures" -gt 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
