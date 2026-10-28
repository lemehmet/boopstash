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
    /// Requests in flight, so leaving and re-entering a note does not ask
    /// twice. What was titled is persisted on the note (`modelTitledHash`).
    @ObservationIgnored private var modelTitleRequests: Set<UUID> = []

    /// Settings ▸ "Name notes with Apple Intelligence"; on by default where
    /// the on-device model is available.
    static let modelTitlesKey = "modelTitles"
    private var usesModelTitles: Bool {
        UserDefaults.standard.object(forKey: Self.modelTitlesKey) as? Bool ?? true
    }

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

    /// Where a capture came from, which decides how loudly to report it.
    enum CaptureOrigin {
        /// File ▸ New Note from Clipboard, with Boopstash in front.
        case menu
        /// The global shortcut or a service, with another app in front:
        /// the window may not be visible, so success is a sound.
        case hotKey, service
    }

    func captureClipboard(origin: CaptureOrigin = .menu) {
        capture(from: .general, origin: origin)
    }

    /// Returns why nothing was saved, or nil on success.
    @discardableResult
    func capture(from pasteboard: NSPasteboard, origin: CaptureOrigin) -> String? {
        let message: String
        switch ClipboardCapture.read(from: pasteboard) {
        case .text(let text):
            let source = sources.lastOtherApp
            var note = Note(body: text, createdAt: Date(), sourceBundleID: source?.bundleID, sourceAppName: source?.name)
            note.title = RuleTitler.title(for: text, kind: ContentKind.detect(text))
            // With another app in front the sound is the only feedback, so it
            // must not say "saved" when the write failed.
            guard insert(note) else {
                if origin != .menu { NSSound.beep() }
                return banner
            }
            requestModelTitle(for: note)
            if origin != .menu { NSSound(named: "Pop")?.play() }
            return nil
        case .refused(.refuseConcealed):
            message = "Not saved: the clipboard holds a password manager item."
        case .refused:
            message = "Not saved: the app that copied this marked it as not to be kept."
        case .empty:
            message = origin == .service ? "The selection has no text to save." : "The clipboard has no text to save."
        }
        banner = message
        if origin == .hotKey {
            // A beep alone does not say why. The capture was the user's own
            // action, so bringing the window forward to show the reason is
            // fair; the Services menu reports through its error instead.
            NSSound.beep()
            NSApp.activate()
        }
        return message
    }

    /// False when the note could not be saved; the banner says why.
    @discardableResult
    private func insert(_ note: Note) -> Bool {
        do {
            try store.save(note)
            // A filter that would hide the new note is cleared, so the
            // capture is visible where the user expects it: at the top.
            if !query.text.isEmpty || query.days != nil {
                query.text = ""
                query.days = nil
            }
            selection = note.id
            return true
        } catch {
            banner = "Could not save: \(error.localizedDescription)"
            return false
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
        // A model title for this exact text beats the rule-based one.
        if !draft.titleIsUserSet, !draft.hasCurrentModelTitle {
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

    // MARK: Model titles

    /// Asks the on-device model for a better title. The rule-based one is
    /// already showing; this replaces it only if, when the answer arrives,
    /// the user has not named the note and its text is what was titled.
    func requestModelTitle(for note: Note) {
        guard usesModelTitles, LiveModelTitler.isAvailable, !note.titleIsUserSet,
              !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !note.hasCurrentModelTitle, !modelTitleRequests.contains(note.id)
        else { return }
        modelTitleRequests.insert(note.id)
        let body = note.body
        Task { [weak self] in
            let title = await LiveModelTitler().title(for: body, kind: ContentKind.detect(body))
            self?.modelTitleRequests.remove(note.id)
            self?.applyModelTitle(title, to: note.id, body: body)
        }
    }

    /// Reads only the draft or the store, never the observed list: a note
    /// deleted or re-saved since the request must not be written back.
    private func applyModelTitle(_ title: String, to id: UUID, body: String) {
        guard var current = drafts[id] ?? (try? store.note(id: id)),
              !current.titleIsUserSet, current.body == body
        else { return }
        current.title = title
        current.modelTitledHash = Note.contentHash(body)
        if drafts[id] != nil {
            drafts[id] = current
        } else {
            // Not an edit: keep updatedAt so the note does not jump to the top.
            do { try store.save(current) } catch { banner = "Could not save: \(error.localizedDescription)" }
        }
    }

    /// Saves every pending draft; false if any write failed (the failed
    /// drafts are kept, see `flush`).
    @discardableResult
    func flushAll() -> Bool {
        for id in Array(drafts.keys) { flush(id) }
        return drafts.isEmpty
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
        modelTitleRequests.remove(id)
        if selection == id { selection = nil }
    }
}
