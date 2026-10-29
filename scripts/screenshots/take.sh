#!/bin/bash
# App Store screenshots (#69) from the debug build's demo mode: made-up
# notes in memory (Core/Sources/Demo), never the real store. Writes
# fastlane/screenshots (Mac, 2880 x 1800) and fastlane/screenshots-ios
# (6.9-inch iPhone, 13-inch iPad), all flattened to opaque PNGs.
# Run from the repository root after `mise exec -- tuist generate`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dd=.build/screenshots
mac=fastlane/screenshots/en-US
ios=fastlane/screenshots-ios/en-US
mkdir -p "$mac" "$ios"

xcodebuild build -workspace Boopstash.xcworkspace -scheme Boopstash -destination 'platform=macOS' -derivedDataPath "$dd" -quiet
app="$dd/Build/Products/Debug/BoopStash.app"
# The default font and themes, for this run only: the debug build shares
# the installed app's preferences, which the shots must not show.
defaults_args=(-editorFontFamily "" -editorFontSize 13 -editorLightTheme system -editorDarkTheme system)
shoot_mac() { # note index, preview YES/NO, file, Settings tab or ""
  osascript -e 'tell application id "com.lemehmet.boopstash" to quit' 2>/dev/null || true
  sleep 2
  local settings=()
  [ -n "${4:-}" ] && settings=(-BoopStashDemoSettings YES -settingsTab "$4")
  open -n "$app" --args -BoopStashDemo YES -BoopStashDemoNote "$1" -previewShown "$2" -previewSideBySide YES \
    "${defaults_args[@]}" ${settings[@]+"${settings[@]}"}
  sleep 9
  read -r id _ _ x y < <(swift "$here/window-id.swift" | awk '$2==1440 && $3==900 {print; exit}')
  if [ -n "${4:-}" ]; then
    # The window's area with Settings open over it.
    screencapture -x -R "$x,$y,1440,900" "$mac/$3"
  else
    screencapture -o -x -l "$id" "$mac/$3"
  fi
}
shoot_mac 2 YES 1-preview.png
shoot_mac 0 NO 2-json.png
shoot_mac 4 NO 3-code.png
shoot_mac 0 NO 4-settings-icloud.png general
shoot_mac 0 NO 5-settings-editor.png editor
osascript -e 'tell application id "com.lemehmet.boopstash" to quit' 2>/dev/null || true

shoot_ios() { # device name, file, extra launch arguments
  local name="$1" file="$2"; shift 2
  local udid
  udid="$(xcrun simctl list devices available | grep -F "$name (" | head -1 | grep -oE '[0-9A-F-]{36}')"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcodebuild build -workspace Boopstash.xcworkspace -scheme BoopStashMobile -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$dd" -quiet
  xcrun simctl install "$udid" "$dd/Build/Products/Debug-iphonesimulator/BoopStash.app"
  # Let first-boot notifications pass before the shot.
  sleep 20
  xcrun simctl terminate "$udid" com.lemehmet.boopstash 2>/dev/null || true
  xcrun simctl launch "$udid" com.lemehmet.boopstash -BoopStashDemo YES "$@" >/dev/null
  sleep 6
  xcrun simctl io "$udid" screenshot --type=png "$ios/$file" >/dev/null
}
shoot_ios "iPhone 17 Pro Max" 1-iphone-list.png
shoot_ios "iPhone 17 Pro Max" 2-iphone-note.png -BoopStashDemoNote 0
shoot_ios "iPhone 17 Pro Max" 3-iphone-settings.png -BoopStashDemoSettings YES
shoot_ios "iPad Pro 13-inch (M5)" 4-ipad.png -BoopStashDemoNote 4

swift "$here/flatten.swift" "$mac"/*.png "$ios"/*.png
