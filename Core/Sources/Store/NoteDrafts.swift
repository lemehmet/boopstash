import Foundation

/// Edits not yet written: typing changes a draft, and the draft is saved
/// after a pause, so the store is not written on every key. A draft whose
/// save fails stays, and the next edit or flush tries again. Shared by the
/// Mac and iOS models; only their views differ.
@MainActor
public final class NoteDrafts {
    public let store: NoteStore
    public let saveDelay: Duration
    /// Told when a save fails, with the reason.
    public var onError: (String) -> Void = { _ in }

    private var drafts: [UUID: Note] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]

    public init(store: NoteStore, saveDelay: Duration = .milliseconds(400)) {
        self.store = store
        self.saveDelay = saveDelay
    }

    /// The current version of a note: the draft if there is one, otherwise
    /// the stored one.
    public func note(id: UUID) -> Note? {
        drafts[id] ?? (try? store.note(id: id))
    }

    public var hasUnsavedEdits: Bool { !drafts.isEmpty }

    /// The notes with unsaved edits.
    public var draftIDs: [UUID] { Array(drafts.keys) }

    public func edit(_ id: UUID, body: String, now: Date = Date()) {
        guard var note = note(id: id), note.body != body else { return }
        note.body = body
        note.updatedAt = now
        schedule(note)
    }

    /// An empty title hands naming back to the generator.
    public func rename(_ id: UUID, to title: String, now: Date = Date()) {
        guard var note = note(id: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.titleIsUserSet = !trimmed.isEmpty
        note.title = trimmed.isEmpty ? RuleTitler.title(for: note.body, kind: ContentKind.detect(note.body)) : trimmed
        note.updatedAt = now
        schedule(note)
    }

    /// Changes a note's draft in place, if it has one, without counting as
    /// an edit (no new save delay, no new edit date): for settings and
    /// titles that land while the note is being typed in. Returns whether
    /// there was a draft.
    @discardableResult
    public func amend(_ id: UUID, _ change: (inout Note) -> Void) -> Bool {
        guard var draft = drafts[id] else { return false }
        change(&draft)
        drafts[id] = draft
        return true
    }

    /// Writes a note's draft now. Returns false if it could not be saved.
    @discardableResult
    public func flush(_ id: UUID) -> Bool {
        pending[id]?.cancel()
        pending[id] = nil
        guard var draft = drafts[id] else { return true }
        // A model title for this exact text beats the rule-based one.
        if !draft.titleIsUserSet, !draft.hasCurrentModelTitle {
            draft.title = RuleTitler.title(for: draft.body, kind: ContentKind.detect(draft.body))
        }
        do {
            try store.save(draft)
            drafts[id] = nil
            return true
        } catch {
            drafts[id] = draft
            onError("Could not save: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes every draft. Returns false if any could not be saved.
    @discardableResult
    public func flushAll() -> Bool {
        Array(drafts.keys).map(flush).allSatisfy { $0 }
    }

    /// Forgets a note's draft, for a note that was deleted.
    public func discard(_ id: UUID) {
        pending[id]?.cancel()
        pending[id] = nil
        drafts[id] = nil
    }

    private func schedule(_ note: Note) {
        drafts[note.id] = note
        pending[note.id]?.cancel()
        let delay = saveDelay
        pending[note.id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush(note.id)
        }
    }
}
