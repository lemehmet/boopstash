import Foundation
import GRDB
import Testing
@testable import BoopstashCore

@Suite struct ImageTextTests {
    let store: NoteStore
    let png = Data([0x89, 0x50, 0x4E, 0x47])

    init() throws {
        store = try .inMemory()
    }

    func titles(_ query: NoteQuery) throws -> [String] {
        try store.notes(matching: query).map(\.title)
    }

    /// A word that is only in a screenshot finds its note, in the scopes
    /// that cover content, and leaves the title scope alone.
    @Test func recognisedTextIsSearchable() throws {
        var note = Note(title: "screenshot", body: "", createdAt: Date())
        let image = try store.addAttachment(png, contentType: "public.png", noteID: note.id)
        note.body = AttachmentReference.markdown(for: image.id)
        try store.save(note)
        #expect(try titles(NoteQuery(text: "invoice")).isEmpty)

        try store.setRecognizedText("Invoice 4217 due Friday", for: image.id)
        #expect(try titles(NoteQuery(text: "invoice")) == ["screenshot"])
        #expect(try titles(NoteQuery(text: "4217", scope: .content)) == ["screenshot"])
        #expect(try titles(NoteQuery(text: "invoice", scope: .title)).isEmpty)
        #expect(try titles(NoteQuery(text: "du")) == ["screenshot"], "short terms scan image text too")
        #expect(try store.imageText(of: note.id) == "Invoice 4217 due Friday")
    }

    @Test func removingTheImageRemovesItsWords() throws {
        var note = Note(title: "t", body: "", createdAt: Date())
        let image = try store.addAttachment(png, contentType: "public.png", noteID: note.id)
        note.body = AttachmentReference.markdown(for: image.id)
        try store.save(note)
        try store.setRecognizedText("quarterly", for: image.id)
        note.body = "no picture now"
        try store.save(note)
        #expect(try titles(NoteQuery(text: "quarterly")).isEmpty)
    }

    /// A draft loaded before recognition finished is saved later: it must
    /// not erase the recognised text.
    @Test func anOlderDraftKeepsTheImageText() throws {
        var note = Note(title: "t", body: "", createdAt: Date())
        let image = try store.addAttachment(png, contentType: "public.png", noteID: note.id)
        note.body = AttachmentReference.markdown(for: image.id)
        try store.save(note)
        let draft = note
        try store.setRecognizedText("receipt", for: image.id)
        try store.save(draft)
        #expect(try titles(NoteQuery(text: "receipt")) == ["t"])
    }

    @Test func emptyRecognitionIsRecordedOnce() throws {
        let image = try store.addAttachment(png, contentType: "public.png", noteID: nil)
        #expect(try store.attachmentsAwaitingRecognition().map(\.id) == [image.id])
        try store.setRecognizedText("", for: image.id)
        #expect(try store.attachmentsAwaitingRecognition().isEmpty, "nothing found is still done")
    }

    @Test func matchesThroughImagesAreTold() {
        let note = Note(title: "screenshot", body: "see image", createdAt: Date())
        #expect(!NoteQuery(text: "invoice").matchesWithoutImages(note))
        #expect(NoteQuery(text: "screen").matchesWithoutImages(note))
        #expect(!NoteQuery(text: "see invoice").matchesWithoutImages(note), "every term must match without images")
    }

    /// Notes from before image text stay searchable after the index is
    /// rebuilt with its new column.
    @Test func theIndexRebuildKeepsOldNotesSearchable() throws {
        let queue = try DatabaseQueue(configuration: NoteStore.configuration)
        try NoteStore.migrator.migrate(queue, upTo: "v4-attachments")
        let old = Note(title: "nginx notes", body: "proxy_pass upstream", createdAt: Date())
        try queue.write { db in try old.insert(db) }
        let migrated = try NoteStore(queue, attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(try migrated.notes(matching: NoteQuery(text: "upstream")).map(\.id) == [old.id])
        #expect(try migrated.notes(matching: NoteQuery(text: "ginx", scope: .title)).map(\.id) == [old.id])
    }
}
