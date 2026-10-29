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
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(store: NoteStore) {
        self.store = store
        drafts = NoteDrafts(store: store)
        drafts.onError = { [weak self] in self?.banner = $0 }
        observe()
    }

    static func live() throws -> NotesModel {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try NoteStore.open(at: support.appendingPathComponent("Boopstash/notes.sqlite"))
        return NotesModel(store: store)
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

    func delete(_ id: UUID) {
        drafts.discard(id)
        do { try store.delete(id: id) } catch { banner = "Could not delete: \(error.localizedDescription)" }
    }
}
