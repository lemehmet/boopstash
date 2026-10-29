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
        didSet {
            guard query != oldValue else { return }
            if query.text != oldValue.text, !query.text.isEmpty { similarTo = nil }
            observe()
        }
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
        // Notes the share extension wrote meanwhile: neither observation in
        // this process saw them (#138).
        syncEngine?.takeChangesFromElsewhere()
        recognizePendingImages()
    }

    // MARK: Sync

    /// Settings ▸ iCloud; off until the user turns it on (ADR 0008).
    static let syncKey = "syncWithICloud"
    private(set) var syncAccountProblem: String?
    private(set) var syncProblem: String?
    var lastSynced: Date?
    /// Counts changes from iCloud per note, so an open editor reloads.
    private(set) var remoteRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var syncEngine: LiveSyncEngine?

    var isSyncing: Bool { syncEngine != nil }
    /// Screenshots' demo mode (debug builds) shows sync on, without an engine.
    @ObservationIgnored var demoSync = false
    /// Whether Settings offers sync, and shows it running.
    var canSync: Bool { LiveSyncEngine.isAvailable || demoSync }
    var showsSyncing: Bool { isSyncing || demoSync }

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
            model.demoSync = true
            model.lastSynced = Date().addingTimeInterval(-120)
            let index = UserDefaults.standard.integer(forKey: "BoopStashDemoNote")
            model.initialSelection = UserDefaults.standard.object(forKey: "BoopStashDemoNote") == nil
                ? nil : try model.store.notes(matching: NoteQuery()).dropFirst(index).first?.id
            return model
        }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let own = support.appendingPathComponent("Boopstash", isDirectory: true)
        // In the App Group, where the share extension writes too (#66); the
        // store there moves once from the app's own container, and stays
        // there if the move cannot happen. A build without the group (the
        // simulator, unsigned) keeps it at home.
        var folder = own, shared = false, merged = 0
        if let group = SharedStore.folder {
            (folder, shared, merged) = try NoteStore.sharedStoreFolder(own: own, group: group)
        }
        let store = try NoteStore.open(at: folder.appendingPathComponent(SharedStore.fileName), shared: shared)
        // Images nothing refers to, after a day's grace, as on the Mac: also
        // the clean-up a delete leaves when a draft would not save.
        _ = try? store.removeUnreferencedAttachments()
        let model = NotesModel(store: store)
        if merged > 0 {
            model.banner = "\(merged) notes from an earlier copy of BoopStash on this device were added to your notes."
        } else if SharedStore.folder != nil, !shared {
            model.banner = "Sharing to BoopStash is off: its notes could not be moved where the share extension can reach them."
        }
        if UserDefaults.standard.bool(forKey: syncKey) { model.setSyncEnabled(true) }
        return model
    }

    // MARK: Semantic search (#157), as on the Mac

    /// Notes close in meaning to the search that its words did not find.
    private(set) var related: [Note] = []
    /// The note whose similar notes the list shows, instead of a search.
    var similarTo: UUID? {
        didSet { if similarTo != oldValue { findRelated() } }
    }
    @ObservationIgnored var embed: Embedder = { LiveEmbedder.shared.embed($0) }
    @ObservationIgnored private var embedding: Task<Void, Never>?
    @ObservationIgnored private var embeddingRequested = false
    @ObservationIgnored private var relating: Task<Void, Never>?

    func embedPendingNotes() {
        guard embedding == nil else {
            embeddingRequested = true
            return
        }
        embeddingRequested = false
        let store = self.store, embed = self.embed
        embedding = Task { [weak self] in
            await Task.detached(priority: .utility) { await store.embedPendingNotes(with: embed) }.value
            guard let self else { return }
            self.embedding = nil
            if self.embeddingRequested { self.embedPendingNotes() } else { self.findRelated() }
        }
    }

    func findRelated() {
        relating?.cancel()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard similarTo != nil || text.count >= 3 else {
            related = []
            return
        }
        let store = self.store, embed = self.embed, query = self.query, similarTo = self.similarTo
        let shown = similarTo.map { Set([$0]) } ?? Set(notes.map(\.id))
        relating = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { () -> [Note] in
                let vector: [Float]?
                if let similarTo { vector = try? store.embedding(of: similarTo) } else { vector = await embed(text) }
                guard let vector else { return [] }
                return (try? store.notesSimilar(to: vector, within: similarTo == nil ? query : NoteQuery(), excluding: shown, limit: similarTo == nil ? 10 : 20))?.map(\.note) ?? []
            }.value
            guard let self, !Task.isCancelled else { return }
            self.related = found
        }
    }

    func showSimilar(to id: UUID) {
        drafts.flush(id)
        query.text = ""
        similarTo = id
    }

    // MARK: Image text

    /// Reads an image's text on device (#53), as on the Mac; images shared
    /// from other apps arrive without it (#66).
    @ObservationIgnored var recognizeText: @Sendable (Data) async -> String? = { await LiveTextRecognizer.text(in: $0) }
    @ObservationIgnored private var recognition: Task<Void, Never>?
    @ObservationIgnored private var recognitionRequested = false

    /// Starts reading the text of images still waiting, unless that is
    /// under way; a request while it is runs it once more afterwards.
    func recognizePendingImages() {
        guard recognition == nil else {
            recognitionRequested = true
            return
        }
        recognitionRequested = false
        let store = self.store
        let recognize = recognizeText
        recognition = Task { [weak self] in
            await Task.detached(priority: .utility) {
                await store.recognizePendingImages(with: recognize)
            }.value
            guard let self else { return }
            self.recognition = nil
            if self.recognitionRequested { self.recognizePendingImages() }
        }
    }

    private func observe() {
        observation?.cancel()
        let values = store.results(query)
        observation = Task { [weak self] in
            do {
                for try await notes in values {
                    self?.notes = notes
                    // A change may have brought an image to read.
                    self?.recognizePendingImages()
                    self?.embedPendingNotes()
                    self?.findRelated()
                }
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
