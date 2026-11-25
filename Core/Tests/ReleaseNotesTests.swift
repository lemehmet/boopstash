import Foundation
import Testing
@testable import BoopstashCore

/// What's New (#253): parsing the store, ordering versions, deciding what
/// a launch shows, and the text Copy, Save as Note and the App Store get.
@Suite struct ReleaseNotesTests {
    private func notes(_ json: String) -> ReleaseNotes {
        ReleaseNotes(json: Data(json.utf8))
    }

    private func version(_ text: String) -> ReleaseVersion {
        ReleaseVersion(text)!
    }

    /// Three releases: 1.2.0 for both platforms, 1.1.0 for the Mac alone,
    /// 1.0.0 for both.
    private var sample: ReleaseNotes {
        notes("""
            { "appStoreSince": { "mac": "1.0.0", "ios": "1.1.0" },
              "unreleased": [ { "on": "ios", "text": "On its way." } ],
              "releases": [
                { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "The first release." } ] },
                { "version": "1.2.0", "date": "2026-01-05", "notes": [
                    { "on": "mac", "text": "A Mac line." }, { "on": "ios", "text": "An iOS line." }, { "on": "both", "text": "A line for both." } ] },
                { "version": "1.1.0", "date": "2026-01-02", "notes": [ { "on": "mac", "text": "Mac only." } ] }
              ] }
            """)
    }

    // MARK: Versions

    @Test func versionsAreOrderedByNumberNotByString() {
        #expect(version("0.4.10") > version("0.4.9"))
        #expect(version("0.10.0") > version("0.9.9"))
        #expect(version("1.0.0") > version("0.99.99"))
        #expect(version("0.4.06") == version("0.4.6"))
        #expect(version("0.4.6").description == "0.4.6")
    }

    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "1.2.x", "v1.2.3", "1.2.-3", "1..3", " 1.2.3", "1.2.3-rc.1", "1.2.٣", "1.2.1234567890"])
    func whatIsNotThreeNumbersIsNotAVersion(text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func aRunningVersionMayCarryASuffix() {
        #expect(ReleaseVersion.running("0.5.0-rc.1") == version("0.5.0"))
        #expect(ReleaseVersion.running("0.5.0+42") == version("0.5.0"))
        #expect(ReleaseVersion.running("0.5.0") == version("0.5.0"))
        #expect(ReleaseVersion.running("unknown") == nil)
    }

    // MARK: Parsing

    @Test func releasesComeNewestFirstWhateverTheFileOrder() {
        #expect(sample.problems.isEmpty)
        #expect(sample.releases.map(\.version.description) == ["1.2.0", "1.1.0", "1.0.0"])
        #expect(sample.releases[0].date == "2026-01-05")
        #expect(sample.releases[0].day == DateComponents(year: 2026, month: 1, day: 5))
        #expect(sample.releases[2].lines == [ReleaseNotes.Line(text: "The first release.", platforms: [.mac, .ios])])
        #expect(sample.unreleased == [ReleaseNotes.Line(text: "On its way.", platforms: [.ios])])
        #expect(sample.appStoreSince == [.mac: version("1.0.0"), .ios: version("1.1.0")])
    }

    @Test(arguments: [
        (#"{ "date": "2026-01-01", "notes": [ { "text": "x" } ] }"#, "release 2 has no MAJOR.MINOR.PATCH version"),
        (#"{ "version": "2.0", "date": "2026-01-01", "notes": [ { "text": "x" } ] }"#, "release 2 has no MAJOR.MINOR.PATCH version"),
        (#"{ "version": 2, "date": "2026-01-01", "notes": [ { "text": "x" } ] }"#, "release 2 has no MAJOR.MINOR.PATCH version"),
        (#"{ "version": "2.0.0", "notes": [ { "text": "x" } ] }"#, "2.0.0 has no YYYY-MM-DD date"),
        (#"{ "version": "2.0.0", "date": null, "notes": [ { "text": "x" } ] }"#, "2.0.0 has no YYYY-MM-DD date"),
        (#"{ "version": "2.0.0", "date": "", "notes": [ { "text": "x" } ] }"#, "2.0.0 has no YYYY-MM-DD date"),
        (#"{ "version": "2.0.0", "date": "2026-1-1", "notes": [ { "text": "x" } ] }"#, "2.0.0 has no YYYY-MM-DD date"),
        (#"{ "version": "2.0.0", "date": "2026-02-30", "notes": [ { "text": "x" } ] }"#, "2.0.0 has no YYYY-MM-DD date"),
        (#"{ "version": "2.0.0", "date": "2026-13-01", "notes": [ { "text": "x" } ] }"#, "2.0.0 has no YYYY-MM-DD date"),
        (#"{ "version": "2.0.0", "date": "01/02/2026", "notes": [ { "text": "x" } ] }"#, "2.0.0 has no YYYY-MM-DD date"),
        (#"{ "version": "2.0.0", "date": "2026-01-01" }"#, "2.0.0: \"notes\" is not a list"),
        (#"{ "version": "2.0.0", "date": "2026-01-01", "notes": [] }"#, "2.0.0 has no lines"),
        (#"{ "version": "2.0.0", "date": "2026-01-01", "notes": [ { "text": "  " } ] }"#, "2.0.0 has no lines"),
        (#"{ "version": "2.0.0", "date": "2026-01-01", "notes": [ "a bare string" ] }"#, "2.0.0: line 1 has no text"),
        (#"{ "version": "2.0.0", "date": "2026-01-01", "notes": [ { "text": "x" }, { "on": "mac" } ] }"#, "2.0.0: line 2 has no text"),
        (#"{ "version": "2.0.0", "date": "2026-01-01", "notes": [ { "on": "watch", "text": "x" } ] }"#, "2.0.0: line 1 is on \"watch\", not mac, ios or both"),
        (#"{ "version": "2.0.0", "date": "2026-01-01", "notes": [ { "on": ["mac"], "text": "x" } ] }"#, "2.0.0: line 1 is not on mac, ios or both"),
        (#"{ "version": "2.0.0", "date": "2026-01-01", "notes": [ { "text": "one\ntwo" } ] }"#, "2.0.0: line 1 is more than one line"),
        (#""not an object""#, "release 2 is not an object"),
    ])
    func aMalformedEntryIsSkippedAndNamedAndTheRestStand(entry: String, problem: String) {
        let parsed = notes("""
            { "releases": [
                { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "Good." } ] },
                \(entry),
                { "version": "3.0.0", "date": "2026-03-01", "notes": [ { "text": "Also good." } ] }
            ] }
            """)
        #expect(parsed.releases.map(\.version.description) == ["3.0.0", "1.0.0"])
        #expect(parsed.release(version("2.0.0")) == nil)
        #expect(parsed.problems == [problem])
    }

    @Test func aSecondEntryForAVersionIsSkipped() {
        let parsed = notes("""
            { "releases": [
                { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "First." } ] },
                { "version": "1.0.00", "date": "2026-01-09", "notes": [ { "text": "Second." } ] }
            ] }
            """)
        #expect(parsed.releases.count == 1)
        #expect(parsed.releases[0].lines.map(\.text) == ["First."])
        #expect(parsed.problems == ["1.0.0 has a second entry"])
    }

    @Test func unknownFieldsAreIgnored() {
        let parsed = notes("""
            { "schema": 7, "releases": [
                { "version": "1.0.0", "date": "2026-01-01", "build": 12, "notes": [ { "text": "Good.", "since": "ever" } ] }
            ] }
            """)
        #expect(parsed.problems.isEmpty)
        #expect(parsed.releases.map(\.lines) == [[ReleaseNotes.Line(text: "Good.")]])
    }

    @Test func anEmptyLineIsDroppedAndNamedAndTextIsTrimmed() {
        let parsed = notes("""
            { "releases": [
                { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "" }, { "text": "  Kept.  " }, { "on": "mac", "text": " " } ] }
            ] }
            """)
        #expect(parsed.releases[0].lines == [ReleaseNotes.Line(text: "Kept.")])
        #expect(parsed.problems == ["1.0.0 has 2 empty line(s)"])
    }

    @Test(arguments: ["", "not json", "[]", "{}", #"{ "releases": {} }"#])
    func aFileThatCannotBeReadIsAnEmptyStoreWithAProblem(text: String) {
        let parsed = notes(text)
        #expect(parsed.releases.isEmpty)
        #expect(parsed.problems.count == 1)
    }

    @Test func aBadBaselineOrUnreleasedListIsNamedAndLeftOut() {
        let parsed = notes("""
            { "appStoreSince": { "mac": "1.0", "watch": "1.0.0", "ios": "1.0.0" },
              "unreleased": [ { "on": "tv", "text": "x" } ],
              "releases": [ { "version": "1.0.0", "date": "2026-01-01", "notes": [ { "text": "Good." } ] } ] }
            """)
        #expect(parsed.appStoreSince == [.ios: version("1.0.0")])
        #expect(parsed.unreleased.isEmpty)
        #expect(parsed.problems.count == 3)
        #expect(parsed.releases.count == 1)
    }

    // MARK: Platforms

    @Test func aPlatformSeesOnlyItsLinesAndOnlyReleasesThatHaveSome() {
        let ios = sample.releases(for: .ios)
        #expect(ios.map(\.version.description) == ["1.2.0", "1.0.0"])
        #expect(ios[0].lines.map(\.text) == ["An iOS line.", "A line for both."])
        let mac = sample.releases(for: .mac)
        #expect(mac.map(\.version.description) == ["1.2.0", "1.1.0", "1.0.0"])
        #expect(mac[0].lines.map(\.text) == ["A Mac line.", "A line for both."])
    }

    // MARK: Launch

    private func launch(running: String, lastSeen: String?, existing: Bool = true, platform: ReleaseNotes.Platform = .mac) -> ReleaseNotes.Launch {
        sample.launch(running: ReleaseVersion.running(running), lastSeen: lastSeen.map(version), existingInstall: existing, platform: platform)
    }

    private func shown(_ launch: ReleaseNotes.Launch) -> [String]? {
        if case .show(let releases) = launch { return releases.map(\.version.description) }
        return nil
    }

    @Test func aFirstInstallShowsNothingAndRecords() {
        #expect(launch(running: "1.2.0", lastSeen: nil, existing: false) == .record)
    }

    @Test func anExistingUserWithNoRecordSeesThisVersionOnly() {
        #expect(shown(launch(running: "1.2.0", lastSeen: nil)) == ["1.2.0"])
        // On iOS 1.1.0 says nothing, so there is nothing to show.
        #expect(launch(running: "1.1.0", lastSeen: nil, platform: .ios) == .record)
    }

    @Test func theSameVersionShowsNothing() {
        #expect(launch(running: "1.2.0", lastSeen: "1.2.0") == .nothing)
    }

    @Test func oneStepShowsThatVersion() {
        #expect(shown(launch(running: "1.2.0", lastSeen: "1.1.0")) == ["1.2.0"])
    }

    @Test func severalStepsShowEveryVersionSinceNewestFirst() {
        #expect(shown(launch(running: "1.2.0", lastSeen: "1.0.0")) == ["1.2.0", "1.1.0"])
        // Only up to the running version, and only what this platform has.
        #expect(shown(launch(running: "1.1.0", lastSeen: "0.9.0")) == ["1.1.0", "1.0.0"])
        #expect(shown(launch(running: "1.2.0", lastSeen: "1.0.0", platform: .ios)) == ["1.2.0"])
    }

    @Test func aDowngradeShowsNothingAndKeepsTheRecord() {
        #expect(launch(running: "1.0.0", lastSeen: "1.2.0") == .nothing)
    }

    @Test func aRunningVersionWithNoEntryShowsWhatLiesBetweenOrOnlyRecords() {
        #expect(shown(launch(running: "1.3.0", lastSeen: "1.1.0")) == ["1.2.0"])
        #expect(launch(running: "1.3.0", lastSeen: "1.2.0") == .record)
        #expect(launch(running: "1.3.0", lastSeen: nil) == .record)
        #expect(launch(running: "unknown", lastSeen: "1.0.0") == .nothing)
    }

    @Test func aDevelopmentBuildOlderThanEveryReleaseLeavesNoTrace() {
        // Development builds report 0.0.1 and share the installed app's
        // defaults: they neither show notes nor move the record.
        #expect(launch(running: "0.0.1", lastSeen: nil) == .nothing)
        #expect(launch(running: "0.0.1", lastSeen: nil, existing: false) == .nothing)
        #expect(launch(running: "0.0.1", lastSeen: "1.2.0") == .nothing)
        #expect(ReleaseNotes().launch(running: version("1.0.0"), lastSeen: nil, existingInstall: false, platform: .mac) == .nothing)
        let store = defaults()
        var development = offer(running: "0.0.1", in: store, existing: false)
        #expect(development.take(canPresent: true).isEmpty)
        development.dismissed()
        #expect(ReleaseNotesLedger(defaults: store).lastSeen == nil)
    }

    @Test func aPreReleaseBuildShowsItsVersionsNotes() {
        #expect(shown(launch(running: "1.2.0-rc.1", lastSeen: "1.1.0")) == ["1.2.0"])
    }

    // MARK: The ledger and the offer

    private func defaults() -> UserDefaults {
        let name = "ReleaseNotesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func offer(running: String, in defaults: UserDefaults, existing: Bool = true, suppressed: Bool = false) -> ReleaseNotesOffer {
        ReleaseNotesOffer(notes: sample, running: running, ledger: ReleaseNotesLedger(defaults: defaults),
                          existingInstall: existing, suppressed: suppressed, platform: .mac)
    }

    @Test func theLedgerNeverGoesBack() {
        let ledger = ReleaseNotesLedger(defaults: defaults())
        #expect(ledger.lastSeen == nil)
        ledger.record(version("1.2.0"))
        ledger.record(version("1.0.0"))
        #expect(ledger.lastSeen == version("1.2.0"))
        ledger.record(version("1.10.0"))
        #expect(ledger.lastSeen == version("1.10.0"))
    }

    @Test func theNotesAreShownOnceAndRecordedWhenDismissed() {
        let store = defaults()
        store.set("1.0.0", forKey: ReleaseNotesLedger.key)
        var first = offer(running: "1.2.0", in: store)
        #expect(first.take(canPresent: true).map(\.version.description) == ["1.2.0", "1.1.0"])
        // Shown is not seen: only the dismissal records.
        #expect(ReleaseNotesLedger(defaults: store).lastSeen == version("1.0.0"))
        #expect(first.take(canPresent: true).isEmpty)
        first.dismissed()
        #expect(ReleaseNotesLedger(defaults: store).lastSeen == version("1.2.0"))
        var next = offer(running: "1.2.0", in: store)
        #expect(next.take(canPresent: true).isEmpty)
    }

    @Test func notesThatCannotBeShownWaitForTheNextLaunch() {
        let store = defaults()
        store.set("1.1.0", forKey: ReleaseNotesLedger.key)
        var blocked = offer(running: "1.2.0", in: store)
        #expect(blocked.take(canPresent: false).isEmpty)
        // Not later in this launch either, and nothing was recorded.
        #expect(blocked.take(canPresent: true).isEmpty)
        #expect(ReleaseNotesLedger(defaults: store).lastSeen == version("1.1.0"))
        var next = offer(running: "1.2.0", in: store)
        #expect(next.take(canPresent: true).map(\.version.description) == ["1.2.0"])
    }

    @Test func aFirstInstallRecordsAtOnceAndShowsNothing() {
        let store = defaults()
        var first = offer(running: "1.2.0", in: store, existing: false)
        #expect(first.take(canPresent: true).isEmpty)
        #expect(ReleaseNotesLedger(defaults: store).lastSeen == version("1.2.0"))
    }

    @Test func demoModeAndTestsShowNothingAndRecordNothing() {
        let store = defaults()
        store.set("1.0.0", forKey: ReleaseNotesLedger.key)
        var suppressed = offer(running: "1.2.0", in: store, suppressed: true)
        #expect(suppressed.take(canPresent: true).isEmpty)
        #expect(ReleaseNotesLedger(defaults: store).lastSeen == version("1.0.0"))
        let fresh = defaults()
        _ = offer(running: "1.2.0", in: fresh, existing: false, suppressed: true)
        #expect(ReleaseNotesLedger(defaults: fresh).lastSeen == nil)
    }

    @Test func aRecordThatIsNotAVersionCountsAsNone() {
        let store = defaults()
        store.set("banana", forKey: ReleaseNotesLedger.key)
        var existing = offer(running: "1.2.0", in: store)
        #expect(existing.take(canPresent: true).map(\.version.description) == ["1.2.0"])
    }

    // MARK: Text

    @Test func markdownIsWhatIsShown() {
        let shown = Array(sample.releases(for: .mac).prefix(2))
        #expect(ReleaseNotes.markdown(shown) == """
            # What's New in BoopStash

            ## 1.2.0 (2026-01-05)

            - A Mac line.
            - A line for both.

            ## 1.1.0 (2026-01-02)

            - Mac only.

            """)
        #expect(ReleaseNotes.title(for: shown) == "What's New in BoopStash 1.2.0")
        #expect(ReleaseNotes.title(for: []) == "What's New in BoopStash")
    }

    @Test func theAppStoreTextIsEveryLineAfterTheBaselineNewestFirst() {
        #expect(sample.appStoreText(for: .mac) == "• A Mac line.\n• A line for both.\n• Mac only.\n")
        #expect(sample.appStoreText(for: .ios) == "• An iOS line.\n• A line for both.\n")
        var all = sample
        all.appStoreSince = [:]
        #expect(all.appStoreText(for: .ios) == "• An iOS line.\n• A line for both.\n• The first release.\n")
    }
}
