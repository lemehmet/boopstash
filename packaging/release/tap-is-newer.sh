#!/usr/bin/env bash
# Usage: tap-is-newer.sh <tap checkout> <version being released>
# Exit 0 when the tap already carries a newer version than the one being
# released (so the release must leave it alone), 1 otherwise. A tap with no
# cask yet, the first release, counts as older.
set -euo pipefail

tap="$1"
version="$2"

# `git show` fails when the cask does not exist yet. Under pipefail that
# failure would end the script, so it is allowed to fail and leave
# `current` empty (#34).
current="$( { git -C "$tap" show HEAD:Casks/boopstash.rb 2>/dev/null || true; } | sed -n 's/^  version "\(.*\)"$/\1/p')"

[ -n "$current" ] || exit 1
[ "$current" != "$version" ] || exit 1

# Semver precedence: compare MAJOR.MINOR.PATCH first; when equal, a release
# outranks its prereleases (1.0.0 > 1.0.0-rc1), which `sort -V` alone gets
# backwards. Two prereleases of one version compare with `sort -V`.
core_current="${current%%-*}"
core_version="${version%%-*}"
if [ "$core_current" != "$core_version" ]; then
  [ "$(printf '%s\n%s\n' "$core_current" "$core_version" | sort -V | tail -1)" = "$core_current" ] || exit 1
elif [ "$current" = "$core_current" ]; then
  :  # the tap has the release; the one being released is its prerelease
elif [ "$version" = "$core_version" ]; then
  exit 1  # the tap has a prerelease of the release being published
else
  [ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" = "$current" ] || exit 1
fi
echo "$current"
