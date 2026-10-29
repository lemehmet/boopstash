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
    /// Whether the key window's focus is a note editor; editor-only menu
    /// commands are disabled otherwise (#25). It is worked out from the key
    /// window rather than kept from editor reports: each window keeps its
    /// own first responder, so an editor in a window that is no longer key
    /// still holds focus there.
    private(set) var editorHasFocus = false
    /// The key window's first responder; replaceable for tests.
    @ObservationIgnored var keyResponder: () -> NSResponder? = { NSApp.keyWindow?.firstResponder }

    /// The focused editor's language, for the commands that depend on it.
    /// SwiftUI commands are not validated through the responder chain, so
    /// this is observable state they read.
    private(set) var editorLanguage: SyntaxLanguage?

    var canFormatDocument: Bool { editorHasFocus && DocumentFormatter.canFormat(editorLanguage) }
    var canSortJSONKeys: Bool { editorHasFocus && DocumentFormatter.canFormat(editorLanguage, style: .sortedKeys) }

    func refreshEditorFocus() {
        let editor = keyResponder() as? BoopTextView
        editorHasFocus = editor != nil
        editorLanguage = editor?.syntax.currentLanguage
    }

    /// An editor gained or lost focus, or went away. The window's first
    /// responder settles only after the change, so look on the next turn.
    func editorFocusMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshEditorFocus() }
    }

    @ObservationIgnored private let sources = SourceAppTracker()
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var drafts: [UUID: Note] = [:]
    @ObservationIgnored private var dayObserver: NSObjectProtocol?
    @ObservationIgnored private var keyObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let notifications: NotificationCenter
    /// Requests in flight, so leaving and re-entering a note does not ask
    /// twice. What was titled is persisted on the note (`modelTitledHash`).
    @ObservationIgnored private var modelTitleRequests: Set<UUID> = []

    /// Settings ▸ "Name notes with Apple Intelligence"; on by default where
    /// the on-device model is available.
    static let modelTitlesKey = "modelTitles"
    private var usesModelTitles: Bool {
        modelTitlesEnabled() && modelTitlesAvailable()
    }

    /// The setting, the model's availability and the model itself, behind
    /// closures so tests can stand in for Apple Intelligence.
    @ObservationIgnored var modelTitlesEnabled: () -> Bool = {
        UserDefaults.standard.object(forKey: AppModel.modelTitlesKey) as? Bool ?? true
    }
    @ObservationIgnored var modelTitlesAvailable: () -> Bool = { LiveModelTitler.isAvailable }
    @ObservationIgnored var modelTitler: @MainActor (String, ContentKind) async -> String? = { body, kind in
        await LiveModelTitler().modelTitle(for: body, kind: kind)
    }

    /// Edits are saved after typing pauses for this long, and immediately
    /// when the selection changes or the app quits.
    static let saveDelay: Duration = .milliseconds(400)

    /// `notifications` carries the window-key changes; tests pass their own
    /// so their posts never reach the rest of the app.
    init(store: NoteStore, notifications: NotificationCenter = .default) {
        self.store = store
        self.notifications = notifications
        observe()
        // The store re-evaluates "last N days" on every fetch, but with no
        // edits nothing fetches; at midnight, start over so "Today" is today.
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.observe() }
        }
        // Another window becoming key (another note window, Settings) moves
        // focus without any editor resigning.
        keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEditorFocus() }
            }
        }
    }

    isolated deinit {
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
        keyObservers.forEach(notifications.removeObserver)
    }

    static func live() throws -> AppModel {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try NoteStore.open(at: support.appendingPathComponent("Boopstash/notes.sqlite"))
        // Attachments nothing refers to any more, after a day's grace so an
        // undo can still bring a deleted image back within a session.
        try? store.removeUnreferencedAttachments()
        return AppModel(store: store)
    }

    private func observe() {
        observation?.cancel()
        let values = store.results(query)
        observation = Task { [weak self] in
            do {
                for try await notes in values {
                    self?.notes = notes
                    // A change may have added an image to read.
                    self?.recognizePendingImages()
                }
            } catch {
                self?.banner = "Could not read notes: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Image text

    /// Reads an image's text on device (#53); replaceable for tests.
    @ObservationIgnored var recognizeText: @Sendable (Data) async -> String? = { await LiveTextRecognizer.text(in: $0) }
    @ObservationIgnored private var recognition: Task<Void, Never>?

    /// Reads the text of images not read yet, one at a time at low
    /// priority, so screenshots become searchable. Images from before this
    /// existed are read too. An image deleted meanwhile is skipped.
    func recognizePendingImages() {
        guard recognition == nil else { return }
        let store = self.store
        let recognize = recognizeText
        recognition = Task { [weak self] in
            // Reading a file of up to 20 MB and recognising its text both
            // happen off the main actor; the store is safe from any thread.
            await Task.detached(priority: .utility) {
                while let next = try? store.attachmentsAwaitingRecognition(limit: 1).first {
                    let data = try? store.data(for: next)
                    // Unreadable (a missing file, say): recorded as empty,
                    // so it is not tried on every change.
                    let text = if let data { await recognize(data) ?? "" } else { "" }
                    guard (try? store.attachment(id: next.id)) != nil else { continue }
                    do {
                        try store.setRecognizedText(text, for: next.id)
                    } catch {
                        break
                    }
                }
            }.value
            self?.recognition = nil
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
        /// File ▸ New Note from Clipboard, with BoopStash in front.
        case menu
        /// The global shortcut or a service, with another app in front:
        /// the window may not be visible, so success is a sound.
        case hotKey, service
        /// Dropped on the note list: the window is in view.
        case drop
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
            return save(text, origin: origin, sourceBundleID: source?.bundleID, sourceAppName: source?.name)
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

    /// Where a drop came from: a drag usually starts in the app that is in
    /// front (Finder, a browser); failing that, the last one that was.
    /// Replaceable so tests do not depend on what else is running.
    @ObservationIgnored lazy var dropSource: () -> (bundleID: String?, name: String?)? = { [sources] in
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return (front.bundleIdentifier, front.localizedName)
        }
        return sources.lastOtherApp
    }

    /// Stores a captured text as a new note. Returns why it failed, or nil.
    @discardableResult
    func save(_ text: String, origin: CaptureOrigin, title: String? = nil, sourceBundleID: String? = nil, sourceAppName: String? = nil) -> String? {
        // A drop's source is the one DropCapture saw when it happened (#31),
        // nil included: looking it up again now could name whatever app
        // came forward since.
        var note = Note(body: text, createdAt: Date(), sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
        if let title {
            note.title = title
            note.titleIsUserSet = true
        } else {
            note.title = RuleTitler.title(for: text, kind: ContentKind.detect(text))
        }
        // With another app in front the sound is the only feedback, so it
        // must not say "saved" when the write failed.
        let background = origin == .hotKey || origin == .service
        guard insert(note) else {
            if background { NSSound.beep() }
            // With another app in front the banner is out of sight; the
            // shortcut was the user's own action, so show why (#19). A
            // service reports through its error instead.
            if origin == .hotKey { NSApp.activate() }
            return banner
        }
        if !note.titleIsUserSet { requestModelTitle(for: note) }
        if background { NSSound(named: "Pop")?.play() }
        return nil
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

    /// The note's highlighting setting. Not an edit: saved at once, and the
    /// note keeps its place in the list.
    func setSyntax(_ id: UUID, to choice: SyntaxChoice) {
        if var draft = drafts[id] {
            draft.syntaxChoice = choice
            drafts[id] = draft
            return
        }
        guard var note = try? store.note(id: id), note.syntaxChoice != choice else { return }
        note.syntaxChoice = choice
        do { try store.save(note) } catch { banner = "Could not save: \(error.localizedDescription)" }
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
        guard usesModelTitles, !note.titleIsUserSet,
              !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !note.hasCurrentModelTitle, !modelTitleRequests.contains(note.id)
        else { return }
        modelTitleRequests.insert(note.id)
        let body = note.body
        Task { [weak self] in
            guard let self else { return }
            let title = await self.modelTitler(body, ContentKind.detect(body))
            self.modelTitleRequests.remove(note.id)
            // No reply means no model title: the rule title stays and the
            // text is not marked as titled, so it is asked again later (#15).
            if let title { self.applyModelTitle(title, to: note.id, body: body) }
        }
    }

    /// Reads only the draft or the store, never the observed list: a note
    /// deleted or re-saved since the request must not be written back.
    private func applyModelTitle(_ title: String, to id: UUID, body: String) {
        // Turning the setting off also discards replies already on their way
        // (#16).
        guard usesModelTitles,
              var current = drafts[id] ?? (try? store.note(id: id)),
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
        // Other notes' unsaved edits may refer to this note's images; the
        // store can only see saved bodies. Save them first, and if any will
        // not save, leave the images to the launch sweep's grace period.
        let othersSaved = drafts.keys.filter { $0 != id }.allSatisfy { other in
            flush(other)
            return drafts[other] == nil
        }
        do {
            try store.delete(id: id, removingOrphanedAttachments: othersSaved)
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
