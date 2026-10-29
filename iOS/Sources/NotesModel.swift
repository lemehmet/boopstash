import BoopstashCore
import Observation
import UIKit

/// The iOS app's state: the list for the current query, and edits through
/// Core's `NoteDrafts`, as on the Mac.
@MainActor
@Observable
final class NotesModel {
    let store: NoteStore
    @ObservationIgnored let drafts: NoteDrafts
    var query = NoteQuery() {
        didSet { if query != oldValue { observe() } }
    }
    private(set) var notes: [Note] = []
    var banner: String?
    /// The note to open at launch (the screenshots' demo mode only).
    @ObservationIgnored var initialSelection: UUID?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var dayObserver: NSObjectProtocol?

    init(store: NoteStore) {
        self.store = store
        drafts = NoteDrafts(store: store)
        drafts.onError = { [weak self] in self?.banner = $0 }
        observe()
        // "Today" is re-evaluated on every fetch, but nothing fetches when
        // nothing changes: start over when the day does, as on the Mac.
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
    }

    /// Re-reads the list, for a new day or a return to the foreground
    /// (the day may have changed while the app was suspended).
    func refresh() {
        observe()
    }

    // MARK: Sync

    /// Settings ▸ iCloud; off until the user turns it on (ADR 0008).
    static let syncKey = "syncWithICloud"
    private(set) var syncAccountProblem: String?
    private(set) var syncProblem: String?
    private(set) var lastSynced: Date?
    /// Counts changes from iCloud per note, so an open editor reloads.
    private(set) var remoteRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var syncEngine: LiveSyncEngine?

    var isSyncing: Bool { syncEngine != nil }

    /// Starts or stops sync. Starting is the first contact with CloudKit;
    /// stopping keeps everything here and the engine's place.
    func setSyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.syncKey)
        guard enabled, LiveSyncEngine.isAvailable else {
            syncEngine?.stop()
            syncEngine = nil
            syncAccountProblem = nil
            syncProblem = nil
            return
        }
        guard syncEngine == nil else { return }
        do {
            syncEngine = try LiveSyncEngine(store: store, report: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }, applyRemote: { [weak self] work in
                await MainActor.run { self?.applyRemote(work) }
            })
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            syncProblem = "Could not start sync: \(error.localizedDescription)"
        }
    }

    func syncNow() {
        guard let syncEngine else { return }
        Task { await syncEngine.syncNow() }
    }

    /// Applies changes from iCloud between edits, as on the Mac: drafts are
    /// saved first, so a note being edited merges instead of being
    /// overwritten, then the open editor reloads.
    @discardableResult
    func applyRemote(_ work: () -> LiveSyncEngine.RemoteOutcome) -> LiveSyncEngine.RemoteOutcome {
        _ = drafts.flushAll()
        let outcome = work()
        for id in outcome.changed { remoteRevisions[id, default: 0] += 1 }
        return outcome
    }

    private func handle(_ event: LiveSyncEngine.Event) {
        switch event {
        case .fetched(let date, let first):
            lastSynced = date
            if first, drafts.flushAll() { _ = try? store.removeUnreferencedAttachments(includingSynced: true) }
        case .sent(let date, let failed):
            lastSynced = date
            if !failed { syncProblem = nil }
        case .account(let problem):
            syncAccountProblem = problem
        case .problem(let message):
            syncProblem = message
        case .stoppedByServer(let message):
            setSyncEnabled(false)
            banner = message
        }
    }

    static func live() throws -> NotesModel {
        #if DEBUG
        // Screenshots (#69): made-up notes in memory; the real store and
        // sync are never touched.
        if UserDefaults.standard.bool(forKey: "BoopStashDemo") {
            let model = NotesModel(store: try DemoNotes.store())
            let index = UserDefaults.standard.integer(forKey: "BoopStashDemoNote")
            model.initialSelection = UserDefaults.standard.object(forKey: "BoopStashDemoNote") == nil
                ? nil : try model.store.notes(matching: NoteQuery()).dropFirst(index).first?.id
            return model
        }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let own = support.appendingPathComponent("Boopstash", isDirectory: true)
        // In the App Group, where the share extension writes too (#66); the
        // store there moves once from the app's own container. A build
        // without the group (the simulator, unsigned) keeps it at home.
        let folder: URL
        if let group = SharedStore.folder {
            try NoteStore.moveStoreFolder(from: own, to: group)
            folder = group
        } else {
            folder = own
        }
        let store = try NoteStore.open(at: folder.appendingPathComponent(SharedStore.fileName), shared: SharedStore.folder != nil)
        // Images nothing refers to, after a day's grace, as on the Mac: also
        // the clean-up a delete leaves when a draft would not save.
        _ = try? store.removeUnreferencedAttachments()
        let model = NotesModel(store: store)
        if UserDefaults.standard.bool(forKey: syncKey) { model.setSyncEnabled(true) }
        return model
    }

    private func observe() {
        observation?.cancel()
        let values = store.results(query)
        observation = Task { [weak self] in
            do {
                for try await notes in values { self?.notes = notes }
            } catch {
                self?.banner = "Could not read notes: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func newNote(body: String = "", sourceAppName: String? = nil) -> Note? {
        var note = Note(body: body, createdAt: Date(), sourceAppName: sourceAppName)
        note.title = RuleTitler.title(for: body, kind: ContentKind.detect(body))
        do {
            try store.save(note)
            // A filter that would hide the new note is cleared, as on the
            // Mac, so it does not seem to vanish (#101).
            if query.text != "" || query.days != nil { query = NoteQuery(scope: query.scope) }
            return note
        } catch {
            banner = "Could not save: \(error.localizedDescription)"
            return nil
        }
    }

    /// New Note from Clipboard: an explicit tap, so the system's paste
    /// prompt is the user's own doing. Password-manager and transient items
    /// are refused (ADR 0001), as on the Mac.
    func newNoteFromClipboard() -> Note? {
        let pasteboard = UIPasteboard.general
        switch CapturePolicy.decide(types: pasteboard.types) {
        case .refuseConcealed:
            banner = "Not saved: the clipboard holds a password manager item."
            return nil
        case .refuseTransient:
            banner = "Not saved: the app it came from marked it as not to be kept."
            return nil
        case .accept:
            break
        }
        guard let text = pasteboard.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            banner = "The clipboard has no text."
            return nil
        }
        return newNote(body: text)
    }

    /// The draft goes only once the row is gone, so a failed delete leaves
    /// the note exactly as it was, unsaved edits included.
    func delete(_ id: UUID) {
        // Other notes' unsaved edits may refer to this note's images, and
        // the store sees only saved text: save them first, and if any will
        // not save, leave the images to the launch sweep (#99), as the Mac
        // does.
        let othersSaved = drafts.draftIDs.filter { $0 != id }.allSatisfy { drafts.flush($0) }
        do {
            try store.delete(id: id, removingOrphanedAttachments: othersSaved)
        } catch {
            banner = "Could not delete: \(error.localizedDescription)"
            return
        }
        drafts.discard(id)
    }
}
