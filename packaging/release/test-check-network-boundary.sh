#!/usr/bin/env bash
# Tests for check-network-boundary.sh (ADR 0014) against made-up source
# trees: it must pass on the rule, and fail when the app gains a network
# entitlement, when the model helper gains any other, when a network API
# appears outside the helper, and when the helper touches the Keychain.
# CI runs this.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

plist() { # plist <file> <key>...: an entitlements file with those keys true
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
    for key in "$@"; do
      case "$key" in
        *=group) printf '\t<key>%s</key>\n\t<array><string>TEAM.example</string></array>\n' "${key%=group}" ;;
        *=false) printf '\t<key>%s</key>\n\t<false/>\n' "${key%=false}" ;;
        *) printf '\t<key>%s</key>\n\t<true/>\n' "$key" ;;
      esac
    done
    printf '</dict>\n</plist>\n'
  } > "$file"
}

tree() { # tree <name>: a repository that keeps the rule
  local dir="$work/$1"
  mkdir -p "$dir/App/ModelService" "$dir/App/Sources" "$dir/Core/Sources" "$dir/CLI" "$dir/iOS"
  plist "$dir/App/Boopstash.entitlements" com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.application-groups=group
  plist "$dir/App/ScriptService.entitlements" com.apple.security.app-sandbox
  plist "$dir/App/ModelService.entitlements" com.apple.security.app-sandbox com.apple.security.network.client
  plist "$dir/iOS/Share.entitlements" com.apple.security.application-groups=group
  echo 'let session = URLSession(configuration: .ephemeral)' > "$dir/App/ModelService/ModelClient.swift"
  echo 'let name = "notes"' > "$dir/App/Sources/App.swift"
  echo 'let core = 1' > "$dir/Core/Sources/Core.swift"
  echo "$dir"
}

expect() { # expect <pass|fail> <tree> <label> [message]
  local status=0 output
  output="$("$here/check-network-boundary.sh" --root "$2" 2>&1)" || status=$?
  local outcome=pass
  [ "$status" -eq 0 ] || outcome=fail
  if [ "$outcome" != "$1" ]; then
    echo "FAIL: $3: expected $1, got $outcome: $output"
    failures=$((failures + 1))
  elif [ -n "${4:-}" ] && ! echo "$output" | grep -q "$4"; then
    echo "FAIL: $3: the message lacks '$4': $output"
    failures=$((failures + 1))
  else
    echo "ok: $3"
  fi
}

good="$(tree good)"
expect pass "$good" "the rule as it stands passes"

t="$(tree app-network)"
plist "$t/App/Boopstash.entitlements" com.apple.security.app-sandbox com.apple.security.network.client
expect fail "$t" "the app gains the outgoing-network entitlement" "App/Boopstash.entitlements has a network entitlement"

t="$(tree app-server)"
plist "$t/App/Boopstash.entitlements" com.apple.security.app-sandbox com.apple.security.network.server
expect fail "$t" "the app gains the incoming-network entitlement" "has a network entitlement"

t="$(tree scripts-network)"
plist "$t/App/ScriptService.entitlements" com.apple.security.app-sandbox com.apple.security.network.client
expect fail "$t" "the script service gains a network entitlement" "App/ScriptService.entitlements has a network entitlement"

t="$(tree ios-network)"
plist "$t/iOS/Share.entitlements" com.apple.security.network.client
expect fail "$t" "an iOS target gains a network entitlement" "iOS/Share.entitlements has a network entitlement"

t="$(tree helper-group)"
plist "$t/App/ModelService.entitlements" com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.application-groups=group
expect fail "$t" "the model helper gains the App Group" "nothing else"

t="$(tree helper-keychain-group)"
plist "$t/App/ModelService.entitlements" com.apple.security.app-sandbox com.apple.security.network.client keychain-access-groups=group
expect fail "$t" "the model helper gains a keychain access group" "nothing else"

t="$(tree helper-server)"
plist "$t/App/ModelService.entitlements" com.apple.security.app-sandbox com.apple.security.network.client com.apple.security.network.server
expect fail "$t" "the model helper gains the incoming-network entitlement" "nothing else"

t="$(tree helper-unsandboxed)"
plist "$t/App/ModelService.entitlements" com.apple.security.app-sandbox=false com.apple.security.network.client
expect fail "$t" "the model helper loses the sandbox" "nothing else"

t="$(tree helper-missing)"
rm "$t/App/ModelService.entitlements"
expect fail "$t" "the model helper's entitlements are missing" "is missing"

t="$(tree app-request)"
echo 'let (data, _) = try await URLSession.shared.data(from: url)' > "$t/App/Sources/Fetch.swift"
expect fail "$t" "the app makes a request itself" "a network API is used outside App/ModelService"

t="$(tree core-request)"
echo 'import Network' > "$t/Core/Sources/Net.swift"
expect fail "$t" "Core imports Network" "a network API is used outside App/ModelService"

t="$(tree helper-keychain)"
echo 'SecItemCopyMatching(query, &item)' >> "$t/App/ModelService/ModelClient.swift"
expect fail "$t" "the model helper calls the Keychain" "must call no Keychain API"

# The repository itself keeps the rule.
expect pass "$here/../.." "this repository"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
