import Foundation

// What's New (#253): the curated notes in `ReleaseNotes.json`, bundled with
// both apps. Nothing is fetched (ADR 0001).
//
// This file imports Foundation only and uses nothing else of Core: the
// release guard (`packaging/release/release-notes.sh`) compiles it as it
// is, so the guard accepts exactly what the app accepts.

/// A released version, `MAJOR.MINOR.PATCH`, ordered by number: 0.4.10 is
/// after 0.4.9.
public struct ReleaseVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Exactly three runs of ASCII digits; anything else is not a version.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // Nine digits at most, so the number always fits.
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// The version a build reports, which may carry a pre-release or build
    /// suffix (`0.5.0-rc.1`): the notes are those of the version before the
    /// suffix.
    public static func running(_ string: String) -> ReleaseVersion? {
        let end = string.firstIndex { $0 == "-" || $0 == "+" } ?? string.endIndex
        return ReleaseVersion(String(string[..<end]))
    }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// The store: an entry per released version, newest first. A malformed
/// entry is left out and named in `problems`, never fatal: the app shows
/// what it can read, and the checks fail on any problem.
public struct ReleaseNotes: Equatable, Sendable {
    public enum Platform: String, CaseIterable, Sendable {
        case mac, ios

        public var displayName: String { self == .mac ? "Mac" : "iOS" }
    }

    /// One plain sentence, for the Mac, iOS or both.
    public struct Line: Equatable, Sendable {
        public var text: String
        public var platforms: Set<Platform>

        public init(text: String, platforms: Set<Platform> = Set(Platform.allCases)) {
            self.text = text
            self.platforms = platforms
        }
    }

    public struct Release: Equatable, Sendable, Identifiable {
        public var version: ReleaseVersion
        /// `YYYY-MM-DD`, a real day.
        public var date: String
        public var lines: [Line]

        public var id: ReleaseVersion { version }

        public init(version: ReleaseVersion, date: String, lines: [Line]) {
            self.version = version
            self.date = date
            self.lines = lines
        }

        /// The day, for a formatter.
        public var day: DateComponents {
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return DateComponents() }
            return DateComponents(year: parts[0], month: parts[1], day: parts[2])
        }
    }

    /// Released versions, newest first.
    public var releases: [Release]
    /// Lines for work not released yet; never shown by the app. Cutting a
    /// release moves them into a dated entry.
    public var unreleased: [Line]
    /// Per platform, the newest version whose notes the App Store already
    /// carries: the store's What's New text lists everything after it.
    public var appStoreSince: [Platform: ReleaseVersion]
    /// What was left out, and why.
    public var problems: [String]

    public init(releases: [Release] = [], unreleased: [Line] = [], appStoreSince: [Platform: ReleaseVersion] = [:], problems: [String] = []) {
        self.releases = releases.sorted { $0.version > $1.version }
        self.unreleased = unreleased
        self.appStoreSince = appStoreSince
        self.problems = problems
    }

    // MARK: Parsing

    /// Reads `ReleaseNotes.json`. Unknown fields are ignored; an entry
    /// that is not well formed is skipped, and so is a second entry for a
    /// version.
    public init(json data: Data) {
        self.init()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            problems.append("the file is not a JSON object")
            return
        }
        if let since = root["appStoreSince"] {
            if let since = since as? [String: Any] {
                for (key, value) in since.sorted(by: { $0.key < $1.key }) {
                    guard let platform = Platform(rawValue: key), let version = (value as? String).flatMap(ReleaseVersion.init) else {
                        problems.append("appStoreSince.\(key) is not a platform with a MAJOR.MINOR.PATCH version")
                        continue
                    }
                    appStoreSince[platform] = version
                }
            } else {
                problems.append("appStoreSince is not an object")
            }
        }
        if let pending = root["unreleased"] {
            switch Self.lines(pending) {
            case .success(let parsed):
                unreleased = parsed.lines
                if parsed.blank > 0 { problems.append("unreleased has \(parsed.blank) empty line(s)") }
            case .failure(let problem):
                problems.append("unreleased: \(problem.reason)")
            }
        }
        guard let entries = root["releases"] as? [Any] else {
            problems.append("there is no \"releases\" list")
            return
        }
        var seen: Set<ReleaseVersion> = []
        for (index, entry) in entries.enumerated() {
            let name = "release \(index + 1)"
            guard let entry = entry as? [String: Any] else {
                problems.append("\(name) is not an object")
                continue
            }
            guard let text = entry["version"] as? String, let version = ReleaseVersion(text) else {
                problems.append("\(name) has no MAJOR.MINOR.PATCH version")
                continue
            }
            guard let date = entry["date"] as? String, Self.isDay(date) else {
                problems.append("\(version) has no YYYY-MM-DD date")
                continue
            }
            let lines: [Line]
            switch Self.lines(entry["notes"] as Any) {
            case .success(let parsed) where !parsed.lines.isEmpty:
                lines = parsed.lines
                if parsed.blank > 0 { problems.append("\(version) has \(parsed.blank) empty line(s)") }
            case .success:
                problems.append("\(version) has no lines")
                continue
            case .failure(let problem):
                problems.append("\(version): \(problem.reason)")
                continue
            }
            guard seen.insert(version).inserted else {
                problems.append("\(version) has a second entry")
                continue
            }
            releases.append(Release(version: version, date: date, lines: lines))
        }
        releases.sort { $0.version > $1.version }
    }

    struct LineProblem: Error {
        var reason: String
    }

    /// A list of `{"text": …, "on": "mac" | "ios" | "both"}`; `on` may be
    /// left out for both. An empty text carries nothing and is dropped; a
    /// line that cannot be read, or names another platform, fails the
    /// list, since nothing says who it was meant for.
    static func lines(_ value: Any) -> Result<(lines: [Line], blank: Int), LineProblem> {
        guard let items = value as? [Any] else { return .failure(LineProblem(reason: "\"notes\" is not a list")) }
        var lines: [Line] = []
        var blank = 0
        for (index, item) in items.enumerated() {
            guard let item = item as? [String: Any], let raw = item["text"] as? String else {
                return .failure(LineProblem(reason: "line \(index + 1) has no text"))
            }
            let platforms: Set<Platform>
            switch item["on"] {
            case nil: platforms = Set(Platform.allCases)
            case let on as String where on == "both": platforms = Set(Platform.allCases)
            case let on as String:
                guard let platform = Platform(rawValue: on) else {
                    return .failure(LineProblem(reason: "line \(index + 1) is on \"\(on)\", not mac, ios or both"))
                }
                platforms = [platform]
            default:
                return .failure(LineProblem(reason: "line \(index + 1) is not on mac, ios or both"))
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                blank += 1
                continue
            }
            // One line each: a break would split a bullet in two.
            guard !text.contains(where: \.isNewline) else {
                return .failure(LineProblem(reason: "line \(index + 1) is more than one line"))
            }
            lines.append(Line(text: text, platforms: platforms))
        }
        return .success((lines, blank))
    }

    static func isDay(_ string: String) -> Bool {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return DateComponents(calendar: calendar, year: year, month: month, day: day).isValidDate
    }

    // MARK: Selection

    public func release(_ version: ReleaseVersion) -> Release? {
        releases.first { $0.version == version }
    }

    /// The releases with something to say on a platform, newest first,
    /// holding only that platform's lines.
    public func releases(for platform: Platform) -> [Release] {
        releases.compactMap { release in
            let lines = release.lines.filter { $0.platforms.contains(platform) }
            return lines.isEmpty ? nil : Release(version: release.version, date: release.date, lines: lines)
        }
    }

    public enum Launch: Equatable, Sendable {
        /// Nothing to show and nothing to record.
        case nothing
        /// Nothing to show; this version is now the one last run.
        case record
        /// Show these, and record the version once they are dismissed.
        case show([Release])
    }

    /// What a launch owes the user. `lastSeen` is the version recorded on
    /// this device, nil when none was; `existingInstall` tells an update
    /// from a version older than this feature (notes already here) from a
    /// first install.
    public func launch(running: ReleaseVersion?, lastSeen: ReleaseVersion?, existingInstall: Bool, platform: Platform) -> Launch {
        // A build older than every release is a development build (0.0.1):
        // recording it would make the next real release look many versions
        // away and show them all.
        guard let running, let oldest = releases.last?.version, running >= oldest else { return .nothing }
        let candidates = releases(for: platform)
        let shown: [Release]
        if let lastSeen {
            // The same version, or an older build run after a newer one:
            // the record stays, so coming back shows nothing again.
            guard lastSeen < running else { return .nothing }
            shown = candidates.filter { $0.version > lastSeen && $0.version <= running }
        } else if existingInstall {
            // Nothing says which version they came from: this one only.
            shown = candidates.filter { $0.version == running }
        } else {
            // A first install has nothing to catch up on, and the sheet
            // must not stand between a new user and the app.
            shown = []
        }
        return shown.isEmpty ? .record : .show(shown)
    }

    // MARK: Text

    public static let appName = "BoopStash"

    /// The title of a note holding these releases, named for the newest.
    public static func title(for releases: [Release]) -> String {
        guard let newest = releases.map(\.version).max() else { return "What's New in \(appName)" }
        return "What's New in \(appName) \(newest)"
    }

    /// The releases as Markdown, as shown: what Copy puts on the
    /// pasteboard and Save as Note keeps.
    public static func markdown(_ releases: [Release]) -> String {
        var text = "# What's New in \(appName)\n"
        for release in releases {
            text += "\n## \(release.version) (\(release.date))\n\n"
            text += release.lines.map { "- \($0.text)\n" }.joined()
        }
        return text
    }

    /// App Store Connect's limit for What's New.
    public static let appStoreLimit = 4000

    /// The App Store's What's New for a platform: a bullet per line of
    /// every release after the one the store already carries, newest
    /// first.
    public func appStoreText(for platform: Platform) -> String {
        let since = appStoreSince[platform]
        return releases(for: platform)
            .filter { since == nil || $0.version > since! }
            .flatMap(\.lines)
            .map { "• \($0.text)\n" }
            .joined()
    }
}

/// The version this device last ran, in its own defaults: per device,
/// never synced.
public struct ReleaseNotesLedger {
    public static let key = "releaseNotesSeenVersion"

    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var lastSeen: ReleaseVersion? {
        defaults.string(forKey: Self.key).flatMap(ReleaseVersion.init)
    }

    /// Never lowers the record: an older build run once does not bring
    /// the newer one's notes back.
    public func record(_ version: ReleaseVersion) {
        if let lastSeen, lastSeen >= version { return }
        defaults.set(version.description, forKey: Self.key)
    }
}

/// One launch's offer of the notes: decided once, taken once, recorded
/// when the user has dismissed them.
public struct ReleaseNotesOffer {
    public let running: ReleaseVersion?
    let ledger: ReleaseNotesLedger
    private var pending: [ReleaseNotes.Release]
    /// Set only when there were notes to show: a launch that offered
    /// nothing has nothing to record on dismissal.
    private let shownVersion: ReleaseVersion?

    /// `suppressed` is demo mode, screenshots and tests: nothing is shown
    /// and nothing is recorded.
    public init(notes: ReleaseNotes, running: String, ledger: ReleaseNotesLedger, existingInstall: Bool,
                suppressed: Bool = false, platform: ReleaseNotes.Platform) {
        let version = ReleaseVersion.running(running)
        self.running = version
        self.ledger = ledger
        guard !suppressed, let version else {
            pending = []
            shownVersion = nil
            return
        }
        switch notes.launch(running: version, lastSeen: ledger.lastSeen, existingInstall: existingInstall, platform: platform) {
        case .nothing:
            pending = []
            shownVersion = nil
        case .record:
            ledger.record(version)
            pending = []
            shownVersion = nil
        case .show(let releases):
            pending = releases
            shownVersion = version
        }
    }

    /// The notes to show now, once. When they cannot be shown (another
    /// sheet or alert is up, there is no window) the offer is dropped
    /// without a record, so the next launch offers them again.
    public mutating func take(canPresent: Bool) -> [ReleaseNotes.Release] {
        defer { pending = [] }
        return canPresent ? pending : []
    }

    /// The sheet was dismissed: this version is the one last run.
    public func dismissed() {
        if let shownVersion { ledger.record(shownVersion) }
    }
}
