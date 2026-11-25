import BoopstashCore
import Foundation

/// What's New (#253): the bundled `ReleaseNotes.json`, the version this
/// build reports and this device's record of the version last run. Nothing
/// is fetched; the logic is Core's `ReleaseNotes`.
enum LiveReleaseNotes {
    #if os(macOS)
    static let platform = ReleaseNotes.Platform.mac
    #else
    static let platform = ReleaseNotes.Platform.ios
    #endif

    /// Read once. A file that is missing or unreadable is an empty list,
    /// never a failed launch.
    static let notes: ReleaseNotes = {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"), let data = try? Data(contentsOf: url) else {
            return ReleaseNotes()
        }
        return ReleaseNotes(json: data)
    }()

    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Every version with something to say on this platform, newest first.
    static var all: [ReleaseNotes.Release] { notes.releases(for: platform) }

    /// This launch's offer, asked of the store before anything is written:
    /// notes already here mean an update, none a first install. A query
    /// that fails says neither, so there is no offer: nothing is shown or
    /// recorded until a launch can tell.
    static func offer(for store: NoteStore, defaults: UserDefaults = .standard) -> ReleaseNotesOffer? {
        guard let notes = try? store.notes(matching: NoteQuery(limit: 1)) else { return nil }
        return offer(existingInstall: !notes.isEmpty, defaults: defaults)
    }

    /// This launch's offer. `existingInstall` is whether notes were here
    /// before this launch: an update from a version older than What's New
    /// has them, a first install does not.
    static func offer(existingInstall: Bool, defaults: UserDefaults = .standard) -> ReleaseNotesOffer {
        ReleaseNotesOffer(notes: notes, running: runningVersion, ledger: ReleaseNotesLedger(defaults: defaults),
                          existingInstall: existingInstall, platform: platform)
    }
}
