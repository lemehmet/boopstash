source "https://rubygems.org"

# fastlane drives the App Store and TestFlight lanes (fastlane/Fastfile,
# ADR 0004). Pinned, with a committed Gemfile.lock, so CI builds are
# reproducible: bump deliberately and regenerate with `bundle lock`.
gem "fastlane", "2.235.0"

# representable (through google-apis-core) loads multi_json without
# declaring it, which Bundler 4 refuses.
gem "multi_json"
