import Foundation

// The release-notes checks (#253), compiled by release-notes.sh together
// with Core's ReleaseNotes.swift: what this accepts is what the app shows.
// Exit 0 is a pass, 1 a failed check, 2 a wrong invocation.

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("release notes: \(message)\n".utf8))
    exit(status)
}

func usage() -> Never {
    fail("""
        usage: release-notes.sh check VERSION    the version has a well-formed entry with a date
               release-notes.sh verify           every entry is well formed, the changelog's newest release has one,
                                                 and fastlane's release_notes.txt files say what the store says
               release-notes.sh write            rewrite fastlane's release_notes.txt files from the store
               release-notes.sh app-store mac|ios  print the App Store's What's New for a platform
        """, status: 2)
}

let storeName = "ReleaseNotes.json"
let appStoreFiles: [(platform: ReleaseNotes.Platform, path: String)] = [
    (.mac, "fastlane/metadata/en-US/release_notes.txt"),
    (.ios, "fastlane/metadata-ios/en-US/release_notes.txt"),
]

func load(root: URL) -> ReleaseNotes {
    let url = root.appendingPathComponent(storeName)
    guard let data = try? Data(contentsOf: url) else { fail("cannot read \(storeName)") }
    return ReleaseNotes(json: data)
}

/// The version being released by the App Store lanes: the changelog's
/// newest `## vX.Y.Z`, as fastlane/Fastfile reads it, with its date.
func newestInChangelog(root: URL) -> (version: String, date: String?) {
    guard let text = try? String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8) else {
        fail("cannot read CHANGELOG.md")
    }
    for line in text.split(separator: "\n") where line.hasPrefix("## v") {
        let heading = line.dropFirst("## v".count)
        let version = String(heading.prefix { $0.isASCII && ($0.isNumber || $0 == ".") })
        guard ReleaseVersion(version) != nil else { continue }
        // "## v0.4.6 — 2026-11-10": the date is the heading's last word.
        let date = heading.split(separator: " ").last.map(String.init).flatMap { $0 == version ? nil : $0 }
        return (version, date)
    }
    fail("CHANGELOG.md has no released version (## vX.Y.Z)")
}

func check(_ notes: ReleaseNotes, version text: String) {
    guard let version = ReleaseVersion.running(text) else { fail("\(text) is not a MAJOR.MINOR.PATCH version") }
    guard notes.release(version) != nil else {
        let reasons = notes.problems.isEmpty ? "" : " (\(notes.problems.joined(separator: "; ")))"
        fail("no well-formed entry for \(version) in \(storeName): add one with its date and lines\(reasons)")
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage() }
let root = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
let command = arguments.removeFirst()

switch (command, arguments.count) {
case ("check", 1):
    check(load(root: root), version: arguments[0])
    print("release notes: \(arguments[0]) has an entry")

case ("verify", 0):
    let notes = load(root: root)
    var failures = notes.problems.map { "\(storeName): \($0)" }
    let newest = newestInChangelog(root: root)
    if let version = ReleaseVersion(newest.version), let release = notes.release(version) {
        if let date = newest.date, date != release.date {
            failures.append("\(version) is dated \(release.date) in \(storeName) and \(date) in CHANGELOG.md")
        }
    } else {
        failures.append("no well-formed entry for \(newest.version), the changelog's newest release, in \(storeName)")
    }
    for (platform, path) in appStoreFiles {
        let expected = notes.appStoreText(for: platform)
        if expected.count > ReleaseNotes.appStoreLimit {
            failures.append("the \(platform.displayName) App Store text is \(expected.count) characters; App Store Connect allows \(ReleaseNotes.appStoreLimit). Move appStoreSince.\(platform.rawValue) forward or shorten lines")
        }
        let actual = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        if actual != expected {
            failures.append("\(path) is not what \(storeName) says: run packaging/release/release-notes.sh write")
        }
    }
    guard failures.isEmpty else { fail(failures.joined(separator: "\nrelease notes: ")) }
    print("release notes: \(notes.releases.count) releases, newest \(newest.version); the App Store texts match")

case ("write", 0):
    let notes = load(root: root)
    guard notes.problems.isEmpty else { fail(notes.problems.joined(separator: "\nrelease notes: ")) }
    for (platform, path) in appStoreFiles {
        do {
            try notes.appStoreText(for: platform).write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write \(path): \(error.localizedDescription)")
        }
        print("wrote \(path)")
    }

case ("app-store", 1):
    guard let platform = ReleaseNotes.Platform(rawValue: arguments[0]) else { usage() }
    print(load(root: root).appStoreText(for: platform), terminator: "")

default:
    usage()
}
