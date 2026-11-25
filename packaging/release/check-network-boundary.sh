#!/usr/bin/env bash
# The network boundary of ADR 0014, checked in the sources and, with
# --app, in a built app:
#   - no entitlements file has a network key, except the model helper's,
#     which has the sandbox and the outgoing-network key and nothing else
#     (no App Group, no keychain access group);
#   - no code outside App/ModelService names a networking API
#     (URLSession, Network, CFNetwork and their kin), and the model helper
#     calls no Keychain API. This is a search of the text, a second line
#     behind the entitlements: it does not see a load through a URL value
#     (`Data(contentsOf: url)`), which the missing entitlement is what
#     stops;
#   - in a built app, the app, the script service and the boopstash
#     command are signed without a network key, and the model helper with
#     exactly its two.
# CI runs it on the sources; the release and App Store lanes also check
# the signed products against their full lists.
#
#   check-network-boundary.sh [--root <repository>] [--app <BoopStash.app>]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
app=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    *) echo "usage: $0 [--root <repository>] [--app <BoopStash.app>]" >&2; exit 2 ;;
  esac
done

failures=0
fail() { echo "network boundary: $1" >&2; failures=$((failures + 1)); }

model_entitlements="App/ModelService.entitlements"

# The keys of a plist, one per line; "name=value" for true/false values.
keys() {
  python3 - "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    for key, value in sorted(plistlib.load(f).items()):
        print(f"{key}={str(value).lower()}" if isinstance(value, bool) else key)
PY
}

expected_model="$(printf 'com.apple.security.app-sandbox=true\ncom.apple.security.network.client=true')"

check_model() { # check_model <plist> <what>
  local actual
  actual="$(keys "$1")" || { fail "$2 could not be read"; return; }
  [ "$actual" = "$expected_model" ] \
    || fail "$2 must be the sandbox and com.apple.security.network.client and nothing else, but is: $(echo "$actual" | tr '\n' ' ')"
}

check_no_network() { # check_no_network <plist> <what>
  local actual
  actual="$(keys "$1")" || { fail "$2 could not be read"; return; }
  if echo "$actual" | grep -q '^com\.apple\.security\.network\.'; then
    fail "$2 has a network entitlement; only the model helper may (ADR 0014)"
  fi
}

# Sources: every entitlements file in the repository.
[ -f "$root/$model_entitlements" ] || fail "$model_entitlements is missing"
while IFS= read -r file; do
  relative="${file#"$root"/}"
  if [ "$relative" = "$model_entitlements" ]; then
    check_model "$file" "$relative"
  else
    check_no_network "$file" "$relative"
  fi
done < <(find "$root/App" "$root/iOS" "$root/CLI" -name '*.entitlements' 2>/dev/null | sort)

# Sources: network APIs only in the model helper; no Keychain there.
network_apis='URLSession|NSURLConnection|NWConnection|NWListener|nw_connection_|nw_listener_|CFNetwork|CFStream|CFSocket|import Network|WKWebView|URLDownload|getaddrinfo|Data\(contentsOf: *URL\(string|String\(contentsOf: *URL\(string'
outside="$(grep -rnE "$network_apis" --include='*.swift' --include='*.m' --include='*.c' \
  "$root/App" "$root/Core/Sources" "$root/CLI" "$root/iOS" 2>/dev/null | grep -v "^$root/App/ModelService/" || true)"
[ -z "$outside" ] || fail "a network API is used outside App/ModelService:
$outside"
keychain="$(grep -rnE 'SecItem|SecKeychain|import Security|kSecClass' "$root/App/ModelService" 2>/dev/null || true)"
[ -z "$keychain" ] || fail "the model helper must call no Keychain API:
$keychain"

# A built app: what each product is signed with.
if [ -n "$app" ]; then
  signed() { # signed <path> -> a plist file of its entitlements
    local out
    out="$(mktemp)"
    codesign -d --entitlements - --xml "$1" 2>/dev/null > "$out" || true
    [ -s "$out" ] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$out"
    # Xcode adds get-task-allow to a Debug build so a debugger can attach.
    # It is not ours and not in a release, whose exact list the release
    # and App Store lanes compare; here it is set aside so the check also
    # runs on a local build.
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$out" >/dev/null 2>&1 || true
    echo "$out"
  }
  helper="$app/Contents/XPCServices/BoopStashModel.xpc"
  [ -d "$helper" ] || fail "the model helper is missing from $app"
  [ ! -d "$helper" ] || check_model "$(signed "$helper")" "the signed model helper"
  for product in "$app" "$app/Contents/XPCServices/BoopStashScripts.xpc" "$app/Contents/Helpers/boopstash"; do
    [ -e "$product" ] || { fail "$product is missing"; continue; }
    check_no_network "$(signed "$product")" "the signed ${product#"$app"/}"
  done
  # Plain HTTP for local addresses only, and only in the helper.
  ats="$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity' "$helper/Contents/Info.plist" 2>/dev/null || true)"
  echo "$ats" | grep -q 'NSAllowsLocalNetworking = true' || fail "the model helper's Info.plist lacks NSAllowsLocalNetworking"
  if echo "$ats" | grep -Eq 'NSAllowsArbitraryLoads|NSExceptionDomains'; then
    fail "the model helper's Info.plist allows more than local plain HTTP"
  fi
  if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity' "$app/Contents/Info.plist" >/dev/null 2>&1; then
    fail "the app's Info.plist has App Transport Security exceptions; the app makes no request"
  fi
fi

[ "$failures" -eq 0 ] || exit 1
echo "network boundary: only the model helper has a network entitlement or names a networking API"
