import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// Deleting a note removes the images only it showed, judged against every
/// note's text, unsaved edits included.
@MainActor
@Suite(.serialized)
struct AttachmentDeletionTests {
    let model: AppModel

    init() throws {
        model = AppModel(store: try .inMemory())
    }

    @Test func anUnsavedReferenceElsewhereKeepsTheImage() throws {
        let owner = Note(body: "", createdAt: Date())
        let other = Note(body: "", createdAt: Date())
        try model.store.save(owner)
        try model.store.save(other)
        let image = try model.store.addAttachment(Data([1, 2, 3]), contentType: "public.png", noteID: owner.id)
        // A pending edit, not yet saved: the store cannot see it.
        model.updateBody(other.id, to: "copied " + AttachmentReference.markdown(for: image.id))

        model.delete(owner.id)
        #expect(try model.store.attachment(id: image.id) != nil)
        #expect(try model.store.note(id: other.id)?.body.contains(image.id.uuidString.lowercased()) == true,
                "the other note's edit was saved before deleting")
    }

    @Test func anImageOnlyTheDeletedNoteShowedGoes() throws {
        let owner = Note(body: "", createdAt: Date())
        try model.store.save(owner)
        let image = try model.store.addAttachment(Data([1, 2, 3]), contentType: "public.png", noteID: owner.id)
        model.delete(owner.id)
        #expect(try model.store.attachment(id: image.id) == nil)
    }
}
