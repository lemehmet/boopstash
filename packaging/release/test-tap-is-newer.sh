#!/usr/bin/env bash
# Tests for tap-is-newer.sh against real git repositories, run the way the
# release workflow runs its steps (bash -eo pipefail). CI runs this.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

tap() { # tap <name> [version]: a tap repository, with a cask when a version is given
  local dir="$work/$1"
  git init -q -b main "$dir"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  if [ -n "${2:-}" ]; then
    mkdir -p "$dir/Casks"
    printf 'cask "boopstash" do\n  version "%s"\nend\n' "$2" > "$dir/Casks/boopstash.rb"
    git -C "$dir" add Casks && git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m cask
  fi
  echo "$dir"
}

expect() { # expect <skip|write> <tap dir> <version> <label>
  local outcome
  if "$here/tap-is-newer.sh" "$2" "$3" >/dev/null; then outcome=skip; else outcome=write; fi
  if [ "$outcome" = "$1" ]; then echo "ok   $4"; else echo "FAIL $4: expected $1, got $outcome"; failures=$((failures + 1)); fi
}

expect write "$(tap empty)" 0.1.0 "first release into an empty tap"
expect write "$(tap older 0.1.0)" 0.2.0 "newer release"
expect write "$(tap same 0.1.0)" 0.1.0 "rerun of the same release"
expect skip "$(tap newer 0.2.0)" 0.1.0 "older release does not downgrade"
expect skip "$(tap tens 0.10.0)" 0.9.0 "0.10.0 is newer than 0.9.0"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
