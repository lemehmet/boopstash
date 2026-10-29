import Foundation
import Testing
@testable import BoopstashCore

@MainActor
@Suite struct NoteDraftsTests {
    let store: NoteStore
    let drafts: NoteDrafts

    init() throws {
        store = try .inMemory()
        drafts = NoteDrafts(store: store, saveDelay: .milliseconds(20))
    }

    func saved(_ body: String = "") throws -> Note {
        let note = Note(body: body, createdAt: Date(timeIntervalSince1970: 0))
        try store.save(note)
        return note
    }

    @Test func editsAreDraftsUntilFlushed() throws {
        let note = try saved()
        drafts.edit(note.id, body: "{\"a\": 1}")
        #expect(drafts.note(id: note.id)?.body == "{\"a\": 1}")
        #expect(try store.note(id: note.id)?.body == "", "not written yet")
        #expect(drafts.flush(note.id))
        let stored = try #require(try store.note(id: note.id))
        #expect(stored.body == "{\"a\": 1}")
        #expect(stored.title == "JSON {a}", "titled by the rules when written")
        #expect(!drafts.hasUnsavedEdits)
    }

    @Test func aPauseSavesOnItsOwn() async throws {
        let note = try saved()
        drafts.edit(note.id, body: "typed")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try store.note(id: note.id)?.body == "typed")
    }

    @Test func aUserTitleIsKeptAndAnEmptyOneHandsBack() throws {
        let note = try saved("line one\nline two")
        drafts.rename(note.id, to: "  Mine  ")
        drafts.edit(note.id, body: "other text")
        drafts.flushAll()
        #expect(try store.note(id: note.id)?.title == "Mine")
        drafts.rename(note.id, to: "")
        drafts.flushAll()
        let renamed = try #require(try store.note(id: note.id))
        #expect(!renamed.titleIsUserSet && renamed.title == "other text")
    }

    @Test func draftsListTheNotesWithUnsavedEdits() throws {
        let a = try saved(), b = try saved()
        drafts.edit(a.id, body: "x")
        drafts.edit(b.id, body: "y")
        #expect(Set(drafts.draftIDs) == [a.id, b.id])
        drafts.flush(a.id)
        #expect(drafts.draftIDs == [b.id])
    }

    @Test func discardingForgetsTheDraft() throws {
        let note = try saved()
        drafts.edit(note.id, body: "x")
        drafts.discard(note.id)
        #expect(!drafts.hasUnsavedEdits)
        #expect(try store.note(id: note.id)?.body == "")
    }

    /// A setting or title that lands mid-typing changes the draft without
    /// counting as an edit; with no draft there is nothing to amend.
    @Test func amendingChangesOnlyTheDraft() throws {
        let store = try NoteStore.inMemory()
        let drafts = NoteDrafts(store: store, saveDelay: .seconds(60))
        let note = Note(body: "a", createdAt: Date(timeIntervalSince1970: 0))
        try store.save(note)
        #expect(!drafts.amend(note.id) { $0.syntaxOverride = "json" }, "no draft yet")
        drafts.edit(note.id, body: "ab", now: Date(timeIntervalSince1970: 100))
        #expect(drafts.amend(note.id) { $0.syntaxOverride = "json" })
        let draft = try #require(drafts.note(id: note.id))
        #expect(draft.syntaxOverride == "json" && draft.updatedAt == Date(timeIntervalSince1970: 100))
        #expect(try store.note(id: note.id)?.syntaxOverride == nil, "not saved by amending")
        drafts.flush(note.id)
        #expect(try store.note(id: note.id)?.syntaxOverride == "json")
    }
}
