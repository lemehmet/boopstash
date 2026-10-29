import Foundation
import GRDB
import Testing
@testable import BoopstashCore

@Suite struct AttachmentTests {
    let store: NoteStore
    /// Synthetic bytes; the store never decodes them.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    init() throws {
        store = try .inMemory()
    }

    func note(_ body: String) throws -> Note {
        let note = Note(body: body, createdAt: Date())
        try store.save(note)
        return note
    }

    func exists(_ attachment: NoteAttachment) -> Bool {
        FileManager.default.fileExists(atPath: store.fileURL(for: attachment).path)
    }

    // MARK: References

    @Test func referencesRoundTrip() {
        let id = UUID()
        let markdown = AttachmentReference.markdown(for: id, alt: "chart")
        #expect(markdown == "![chart](attachment:\(id.uuidString.lowercased()))")
        #expect(AttachmentReference.ids(in: "before \(markdown) after") == [id])
    }

    @Test(arguments: ["]", "[x]", #"a\b"#, #"end\"#, "plain"])
    func anyAltTextRoundTrips(_ alt: String) {
        let id = UUID()
        #expect(AttachmentReference.ids(in: AttachmentReference.markdown(for: id, alt: alt)) == [id], "alt \(alt)")
    }

    @Test func referencesAreFoundWhateverTheirAltAndCase() {
        let a = UUID(), b = UUID()
        let body = #"![a \] b](attachment:\#(a.uuidString.uppercased())) and `![](attachment:\#(b.uuidString))`"#
        #expect(AttachmentReference.ids(in: body) == [a, b], "escaped bracket in alt; a reference in code still counts")
        #expect(AttachmentReference.ids(in: "![](attachment:not-a-uuid) [x](attachment:\(a))").isEmpty,
                "a plain link is not an image reference")
    }

    @Test func matchesGiveRangesIDsAndAltText() {
        let a = UUID(), b = UUID()
        let body = "x " + AttachmentReference.markdown(for: a, alt: "a]b") + " y " + AttachmentReference.markdown(for: b)
        let found = AttachmentReference.matches(in: body)
        #expect(found.map(\.id) == [a, b])
        #expect(found.map(\.alt) == ["a]b", ""])
        #expect((body as NSString).substring(with: found[1].range) == AttachmentReference.markdown(for: b))
    }

    @Test func rewritingReplacesOnlyKnownReferences() {
        let known = UUID(), unknown = UUID()
        let body = "\(AttachmentReference.markdown(for: known, alt: "k")) \(AttachmentReference.markdown(for: unknown))"
        let rewritten = AttachmentReference.rewriting(body) { $0 == known ? "attachments/k.png" : nil }
        #expect(rewritten == "![k](attachments/k.png) \(AttachmentReference.markdown(for: unknown))")
    }

    // MARK: Store

    @Test func addingStoresTheFileAndTheRow() throws {
        let owner = try note("x")
        let attachment = try store.addAttachment(png, contentType: "public.png", noteID: owner.id)
        #expect(attachment.fileName == "\(attachment.id.uuidString.lowercased()).png")
        #expect(attachment.byteSize == png.count)
        #expect(try store.attachment(id: attachment.id) == attachment)
        #expect(try store.data(for: attachment) == png)
        let body = "see " + AttachmentReference.markdown(for: attachment.id)
        #expect(try store.attachments(referencedBy: body) == [attachment])
    }

    @Test func deletingANoteRemovesWhatOnlyItShowed() throws {
        let owner = try note("")
        let only = try store.addAttachment(png, contentType: "public.png", noteID: owner.id)
        let shared = try store.addAttachment(png, contentType: "public.jpeg", noteID: owner.id)
        var withRefs = owner
        withRefs.body = AttachmentReference.markdown(for: only.id) + AttachmentReference.markdown(for: shared.id)
        try store.save(withRefs)
        _ = try note("copied " + AttachmentReference.markdown(for: shared.id))

        try store.delete(id: owner.id)
        #expect(try store.attachment(id: only.id) == nil)
        #expect(!exists(only))
        #expect(try store.attachment(id: shared.id) != nil, "another note still shows it")
        #expect(exists(shared))
    }

    @Test func deletingANoteLeavesOtherNotesAttachments() throws {
        let owner = try note("")
        let other = try note("")
        let theirs = try store.addAttachment(png, contentType: "public.png", noteID: other.id)
        try store.delete(id: owner.id)
        #expect(try store.attachment(id: theirs.id) != nil, "unreferenced, but not the deleted note's")
    }

    @Test func sweepingRemovesOnlyOldUnreferencedAttachments() throws {
        let now = Date()
        let old = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let orphan = try store.addAttachment(png, contentType: "public.png", noteID: nil, now: old)
        let recent = try store.addAttachment(png, contentType: "public.png", noteID: nil, now: now)
        let shown = try store.addAttachment(png, contentType: "public.png", noteID: nil, now: old)
        _ = try note("x " + AttachmentReference.markdown(for: shown.id))

        #expect(try store.removeUnreferencedAttachments(now: now) == 1)
        #expect(try store.attachment(id: orphan.id) == nil)
        #expect(!exists(orphan))
        #expect(try store.attachment(id: recent.id) != nil, "within the grace period")
        #expect(try store.attachment(id: shown.id) != nil)
    }

    @Test func theSweepRemovesOldFilesWithoutRows() throws {
        try FileManager.default.createDirectory(at: store.attachmentsDirectory, withIntermediateDirectories: true)
        let old = store.attachmentsDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        let recent = store.attachmentsDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        let unrelated = store.attachmentsDirectory.appendingPathComponent("notes.txt")
        for file in [old, recent, unrelated] { try png.write(to: file) }
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: unrelated.path)
        let kept = try store.addAttachment(png, contentType: "public.png", noteID: nil)
        _ = try note(AttachmentReference.markdown(for: kept.id))
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: store.fileURL(for: kept).path)

        #expect(try store.removeUnreferencedAttachments() == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path), "within the grace period")
        #expect(FileManager.default.fileExists(atPath: unrelated.path), "not an attachment file")
        #expect(exists(kept), "a file with a row stays")
    }

    @Test func deletingWithUnsavedEditsElsewhereKeepsAttachments() throws {
        let owner = try note("")
        let image = try store.addAttachment(png, contentType: "public.png", noteID: owner.id)
        try store.delete(id: owner.id, removingOrphanedAttachments: false)
        #expect(try store.attachment(id: image.id) != nil, "left for the sweep")
    }

    @Test func notesFromBeforeAttachmentsSurviveTheMigration() throws {
        let queue = try DatabaseQueue(configuration: NoteStore.configuration)
        try NoteStore.migrator.migrate(queue, upTo: "v3-syntax-override")
        let existing = Note(title: "kept", body: "from v3", createdAt: Date())
        try queue.write { db in try existing.insert(db) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let migrated = try NoteStore(queue, attachmentsDirectory: folder)
        #expect(try migrated.note(id: existing.id) == existing)
        #expect(try migrated.addAttachment(png, contentType: "public.png", noteID: existing.id).byteSize == png.count)
    }

    // MARK: Export

    @Test func exportLinksImagesIntoItsAttachmentsFolder() throws {
        let attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 3)
        let missing = UUID()
        let body = "![plot](attachment:\(attachment.id.uuidString.lowercased())) \(AttachmentReference.markdown(for: missing))"
        let note = Note(title: "t", body: body, createdAt: Date())
        let file = try #require(NoteExport.files(for: [note], attachments: [attachment.id: attachment]).first)
        #expect(file.contents.contains("![plot](attachments/\(attachment.fileName))"))
        #expect(file.contents.contains(AttachmentReference.markdown(for: missing)), "an unknown reference is left as it is")
    }
}
