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
[ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" = "$current" ] || exit 1
echo "$current"
