import AppKit
import BoopstashCore
import Observation

@MainActor
@Observable
final class AppModel {
    let store: NoteStore
    private(set) var notes: [Note] = []
    var selection: UUID?
    var query = NoteQuery() {
        didSet { if query != oldValue { observe() } }
    }
    /// A one-line message for the window, such as why a capture was refused.
    var banner: String?

    @ObservationIgnored private let sources = SourceAppTracker()
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var drafts: [UUID: Note] = [:]
    @ObservationIgnored private var dayObserver: NSObjectProtocol?

    /// Edits are saved after typing pauses for this long, and immediately
    /// when the selection changes or the app quits.
    static let saveDelay: Duration = .milliseconds(400)

    init(store: NoteStore) {
        self.store = store
        observe()
        // The store re-evaluates "last N days" on every fetch, but with no
        // edits nothing fetches; at midnight, start over so "Today" is today.
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.observe() }
        }
    }

    isolated deinit {
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
    }

    static func live() throws -> AppModel {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AppModel(store: try NoteStore.open(at: support.appendingPathComponent("Boopstash/notes.sqlite")))
    }

    private func observe() {
        observation?.cancel()
        let values = store.results(query)
        observation = Task { [weak self] in
            do {
                for try await notes in values {
                    self?.notes = notes
                }
            } catch {
                self?.banner = "Could not read notes: \(error.localizedDescription)"
            }
        }
    }

    /// The current version of a note: the unsaved draft if there is one,
    /// otherwise the store. Not the observed list, which lags a save by a
    /// delivery and would hand back the previous version as the base for the
    /// next edit.
    func note(id: UUID) -> Note? {
        if let draft = drafts[id] { return draft }
        return (try? store.note(id: id)) ?? notes.first { $0.id == id }
    }

    // MARK: Creating

    func newNote() {
        let note = Note(title: "", body: "", createdAt: Date())
        insert(note)
    }

    func captureClipboard() {
        switch ClipboardCapture.read() {
        case .text(let text):
            let source = sources.lastOtherApp
            var note = Note(body: text, createdAt: Date(), sourceBundleID: source?.bundleID, sourceAppName: source?.name)
            note.title = RuleTitler.title(for: text, kind: ContentKind.detect(text))
            insert(note)
        case .refused(.refuseConcealed):
            banner = "Not saved: the clipboard holds a password manager item."
        case .refused:
            banner = "Not saved: the app that copied this marked it as not to be kept."
        case .empty:
            banner = "The clipboard has no text to save."
        }
    }

    private func insert(_ note: Note) {
        do {
            try store.save(note)
            // A filter that would hide the new note is cleared, so the
            // capture is visible where the user expects it: at the top.
            if !query.text.isEmpty || query.days != nil {
                query.text = ""
                query.days = nil
            }
            selection = note.id
        } catch {
            banner = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Editing

    /// Called on every keystroke, so it only records the text; the title
    /// is regenerated once typing pauses, when the draft is saved.
    func updateBody(_ id: UUID, to body: String) {
        guard var note = note(id: id), note.body != body else { return }
        note.body = body
        scheduleSave(note)
    }

    /// An empty title hands naming back to the generator.
    func rename(_ id: UUID, to title: String) {
        guard var note = note(id: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.titleIsUserSet = !trimmed.isEmpty
        note.title = trimmed.isEmpty ? RuleTitler.title(for: note.body, kind: ContentKind.detect(note.body)) : trimmed
        scheduleSave(note)
    }

    private func scheduleSave(_ note: Note) {
        var note = note
        note.updatedAt = Date()
        drafts[note.id] = note
        pendingSaves[note.id]?.cancel()
        pendingSaves[note.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush(note.id)
        }
    }

    /// Saves a note's pending edits. The draft is dropped only once the
    /// write succeeds: on a failed write (disk full, say) it stays, so the
    /// next edit, selection change or quit tries again.
    func flush(_ id: UUID) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        guard var draft = drafts[id] else { return }
        if !draft.titleIsUserSet {
            draft.title = RuleTitler.title(for: draft.body, kind: ContentKind.detect(draft.body))
        }
        do {
            try store.save(draft)
            drafts[id] = nil
        } catch {
            drafts[id] = draft
            banner = "Could not save: \(error.localizedDescription)"
        }
    }

    func flushAll() {
        for id in Array(drafts.keys) { flush(id) }
    }

    /// The draft and selection go only once the row is gone, so a failed
    /// delete leaves the note exactly as it was, unsaved edits included.
    func delete(_ id: UUID) {
        do {
            try store.delete(id: id)
        } catch {
            banner = "Could not delete: \(error.localizedDescription)"
            return
        }
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        drafts[id] = nil
        if selection == id { selection = nil }
    }
}
