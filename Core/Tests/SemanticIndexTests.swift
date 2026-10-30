import Foundation
import Testing
@testable import BoopstashCore

/// Semantic search's storage and ranking (#157), with a stand-in embedder:
/// each text is a unit vector along the axis its first word names.
@Suite struct SemanticIndexTests {
    let store: NoteStore

    init() throws {
        store = try .inMemory()
    }

    static let axes = ["money", "code", "travel"]
    static let embed: Embedder = { text in
        let word = text.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
        guard let axis = axes.firstIndex(of: word) else { return [] }
        var vector = [Float](repeating: 0, count: axes.count)
        vector[axis] = 1
        return vector
    }

    @discardableResult
    func note(_ title: String, _ body: String = "", daysAgo: Double = 0) throws -> Note {
        let date = Date().addingTimeInterval(-daysAgo * 86400)
        let note = Note(title: title, titleIsUserSet: true, body: body, createdAt: date, updatedAt: date)
        try store.save(note)
        return note
    }

    @Test func everyNoteIsEmbeddedOnceUntilItChanges() async throws {
        var invoice = try note("money invoice")
        try note("code review")
        await store.embedPendingNotes(with: Self.embed)
        #expect(try store.notesAwaitingEmbedding().isEmpty)
        invoice.title = "travel plans"
        try store.save(invoice)
        #expect(try store.notesAwaitingEmbedding().map(\.id) == [invoice.id])
    }

    @Test func similarNotesRankByMeaning() async throws {
        let bill = try note("money bill for March")
        try note("code review")
        await store.embedPendingNotes(with: Self.embed)
        let found = try store.notesSimilar(to: [1, 0, 0])
        #expect(found.map(\.note.id) == [bill.id])
        #expect(try store.notesSimilar(to: [1, 0, 0], excluding: [bill.id]).isEmpty)
    }

    @Test func theAgeFilterApplies() async throws {
        try note("money old", daysAgo: 30)
        let recent = try note("money new")
        await store.embedPendingNotes(with: Self.embed)
        #expect(try store.notesSimilar(to: [1, 0, 0], within: NoteQuery(days: 7)).map(\.note.id) == [recent.id])
    }

    /// A failing model records nothing: the notes are tried again later.
    @Test func aFailingEmbedderLeavesNotesPending() async throws {
        try note("money one")
        try note("money two")
        await store.embedPendingNotes(with: { _ in nil })
        #expect(try store.notesAwaitingEmbedding().count == 2)
        await store.embedPendingNotes(with: Self.embed)
        #expect(try store.notesAwaitingEmbedding().isEmpty)
    }

    /// An embedding made from text that changed meanwhile is not stored.
    @Test func aStaleEmbeddingIsDropped() async throws {
        var changing = try note("money first")
        let pending = try #require(try store.notesAwaitingEmbedding().first)
        changing.title = "code second"
        try store.save(changing)
        try store.setEmbedding([1, 0, 0], for: changing.id, sourceHash: pending.hash)
        #expect(try store.notesAwaitingEmbedding().map(\.id) == [changing.id])
    }

    @Test func thePendingCountFollowsChanges() async throws {
        var counts = store.pendingEmbeddings().makeAsyncIterator()
        #expect(try await counts.next() == 0)
        try note("money new")
        #expect(try await counts.next() == 1)
        await store.embedPendingNotes(with: Self.embed)
        #expect(try await counts.next() == 0)
    }

    /// Text with nothing to embed is not tried again, and is never found.
    @Test func unembeddableTextIsRecordedAsNone() async throws {
        let odd = try note("zzz nothing")
        await store.embedPendingNotes(with: Self.embed)
        #expect(try store.notesAwaitingEmbedding().isEmpty)
        #expect(try store.embedding(of: odd.id) == nil)
    }

    @Test func embeddingsGoWithTheirNote() async throws {
        let gone = try note("money gone")
        await store.embedPendingNotes(with: Self.embed)
        try store.delete(id: gone.id)
        #expect(try store.notesSimilar(to: [1, 0, 0]).isEmpty)
    }

    @Test func imageReferencesAreNotEmbedded() {
        let text = NoteStore.embeddingText(title: "t", body: "see " + AttachmentReference.markdown(for: UUID()), imageText: "total 42")
        #expect(!text.contains("attachment:") && text.contains("total 42"))
    }
}
