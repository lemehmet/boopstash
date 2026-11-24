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

/// The recognition worker both apps run (#53, #136).
@Suite struct RecognitionWorkerTests {
    @Test func everyWaitingImageIsReadOnce() async throws {
        let store = try NoteStore.inMemory()
        let first = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        let second = try store.addAttachment(Data([2]), contentType: "public.png", noteID: nil)
        await store.recognizePendingImages { data in data == Data([1]) ? "invoice" : nil }
        #expect(try store.attachment(id: first.id)?.recognizedText == "invoice")
        #expect(try store.attachment(id: second.id)?.recognizedText == "", "unreadable counts as no text")
        #expect(try store.attachmentsAwaitingRecognition().isEmpty)
    }
}

/// The text a "copy the image's text" command gets (#243); both apps'
/// models call this with their recogniser, so this is the iOS copy path
/// too.
@Suite struct ImageTextCopyTests {
    actor Calls {
        var count = 0
        func add() { count += 1 }
    }

    let store: NoteStore
    let calls = Calls()

    init() throws {
        store = try .inMemory()
    }

    @Test func storedTextIsReturnedWithoutReadingAgain() async throws {
        let image = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        try store.setRecognizedText("Name\tQty\nBolt\t12", for: image.id)
        let read = await store.recognizedText(of: image.id) { [calls] _ in await calls.add(); return "read again" }
        #expect(read == .text("Name\tQty\nBolt\t12"))
        #expect(await calls.count == 0)
    }

    @Test func anImageNotReadYetIsReadOnceAndStored() async throws {
        let image = try store.addAttachment(Data([7]), contentType: "public.png", noteID: nil)
        let recognize: @Sendable (Data) async -> String? = { [calls] data in await calls.add(); return data == Data([7]) ? "Invoice 4217" : nil }
        let first = await store.recognizedText(of: image.id, recognizing: recognize)
        #expect(first == .text("Invoice 4217"))
        #expect(try store.attachment(id: image.id)?.recognizedText == "Invoice 4217")
        let second = await store.recognizedText(of: image.id, recognizing: recognize)
        #expect(second == .text("Invoice 4217"))
        #expect(await calls.count == 1, "the second command uses what the first stored")
    }

    @Test func anImageWithNoTextSaysSo() async throws {
        let read = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        try store.setRecognizedText("", for: read.id)
        let stored = await store.recognizedText(of: read.id) { [calls] _ in await calls.add(); return "text" }
        #expect(stored == .noText)
        #expect(await calls.count == 0, "read before and found empty: not read again")

        let blank = try store.addAttachment(Data([2]), contentType: "public.png", noteID: nil)
        let blankRead = await store.recognizedText(of: blank.id) { _ in " \n" }
        #expect(blankRead == .noText)
        let unreadable = try store.addAttachment(Data([3]), contentType: "public.png", noteID: nil)
        let unreadableRead = await store.recognizedText(of: unreadable.id) { _ in nil }
        #expect(unreadableRead == .noText)
        #expect(try store.attachment(id: unreadable.id)?.recognizedText == "", "recorded, so the worker does not try again")
        #expect(ImageTextRead.noText.message != nil && ImageTextRead.text("a").message == nil)
    }

    @Test func aMissingFileOrImageIsMissing() async throws {
        let image = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        try store.setRecognizedText("stored", for: image.id)
        try FileManager.default.removeItem(at: store.fileURL(for: image))
        #expect(!store.hasFile(for: image))
        let noFile = await store.recognizedText(of: image.id) { [calls] _ in await calls.add(); return "text" }
        #expect(noFile == .missing)
        let noImage = await store.recognizedText(of: UUID()) { [calls] _ in await calls.add(); return "text" }
        #expect(noImage == .missing)
        #expect(await calls.count == 0)
        #expect(ImageTextRead.missing.message != nil)
    }

    /// The background worker stores its reading while the command's own is
    /// under way: the stored text stands and is not written twice.
    @Test func textStoredMeanwhileStands() async throws {
        let image = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        let read = await store.recognizedText(of: image.id) { [store] _ in
            try? store.setRecognizedText("the worker's", for: image.id)
            return "the command's"
        }
        #expect(read == .text("the worker's"))
        #expect(try store.attachment(id: image.id)?.recognizedText == "the worker's")
    }

    @Test func anImageDeletedWhileItIsReadIsMissing() async throws {
        let image = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        let read = await store.recognizedText(of: image.id) { [store] _ in
            try? store.deleteAttachment(id: image.id)
            return "text"
        }
        #expect(read == .missing)
    }
}
