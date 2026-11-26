import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Copy Text from Image and Insert Text Below on an image chip (#243).
/// Nothing here touches the general pasteboard: the copy takes the
/// pasteboard as a parameter, and the tests pass a private one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CopyImageTextTests {
    actor Calls {
        var count = 0
        func add() { count += 1 }
    }

    let model: AppModel
    let calls = Calls()
    let messages = Messages()

    final class Messages {
        var all: [String] = []
    }

    init() async throws {
        // The model's first list delivery starts the recognition worker;
        // it comes and goes before any image exists, so the only reading
        // in a test is the command's own. (Attachments do not touch the
        // observed note table: adding one starts no worker.)
        let store = try NoteStore.inMemory()
        try store.save(Note(body: "seen", createdAt: Date()))
        model = AppModel(store: store)
        model.recognizeText = { [calls] _ in await calls.add(); return "Name\tQty\nBolt\t12" }
        let delivered = try await eventually { model.notes.count == 1 }
        try #require(delivered)
        try await Task.sleep(for: .milliseconds(200))
    }

    func image() throws -> NoteAttachment {
        try model.store.addAttachment(Data([1, 2, 3]), contentType: "public.png", noteID: nil)
    }

    func host(_ text: String) -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 2000, height: 300)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text)
        // As NoteDetail wires the editor.
        view.attachmentURL = { [store = model.store] id in store.presentFileURL(forAttachment: id) }
        view.imageText = { [model] in await model.imageText(of: $0) }
        view.showMessage = { [messages] in messages.all.append($0) }
        view.updateChips()
        return (window, view)
    }

    func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    func reference(_ id: UUID, in view: BoopTextView) -> NSRange {
        AttachmentReference.matches(in: view.string).first { $0.id == id }!.range
    }

    @Test func storedTextIsCopiedAsPlainText() async throws {
        let image = try image()
        try model.store.setRecognizedText("Invoice 4217\tdue Friday", for: image.id)
        let (window, view) = host("see " + AttachmentReference.markdown(for: image.id) + " here")
        view.setSelectedRange(reference(image.id, in: view))
        #expect(view.selectedImage == image.id)
        let pasteboard = NSPasteboard.withUniqueName()
        await view.copyImageText(of: image.id, to: pasteboard).value
        #expect(pasteboard.string(forType: .string) == "Invoice 4217\tdue Friday")
        #expect(pasteboard.availableType(from: [.rtf, .html, .fileURL, .png, .tiff]) == nil, "plain text only")
        #expect(await calls.count == 0, "stored text is not read again")
        #expect(messages.all.isEmpty)
        window.close()
    }

    @Test func anImageNotReadYetIsReadOnceStoredAndCopied() async throws {
        let image = try image()
        let (window, view) = host(AttachmentReference.markdown(for: image.id))
        let pasteboard = NSPasteboard.withUniqueName()
        await view.copyImageText(of: image.id, to: pasteboard).value
        #expect(pasteboard.string(forType: .string) == "Name\tQty\nBolt\t12")
        #expect(try model.store.attachment(id: image.id)?.recognizedText == "Name\tQty\nBolt\t12")
        await view.copyImageText(of: image.id, to: pasteboard).value
        #expect(await calls.count == 1, "the second copy uses what the first stored")
        window.close()
    }

    /// The copy does not need the editor, so closing the note while the
    /// image is read still copies its text: the copy runs here with no
    /// editor at all.
    @Test func aCopyNeedsNoEditor() async throws {
        let image = try image()
        let pasteboard = NSPasteboard.withUniqueName()
        await BoopTextView.copyImageText(of: image.id, reading: { [model] in await model.imageText(of: $0) }, to: pasteboard) { _ in }.value
        #expect(pasteboard.string(forType: .string) == "Name\tQty\nBolt\t12")
    }

    @Test func anImageWithNoTextCopiesNothingAndSaysSo() async throws {
        let image = try image()
        try model.store.setRecognizedText("", for: image.id)
        let (window, view) = host(AttachmentReference.markdown(for: image.id))
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("what was there", forType: .string)
        await view.copyImageText(of: image.id, to: pasteboard).value
        #expect(pasteboard.string(forType: .string) == "what was there", "not replaced by an empty string")
        #expect(messages.all == ["This image has no text."])
        await view.insertImageText(of: image.id).value
        #expect(view.string == AttachmentReference.markdown(for: image.id), "nothing to insert")
        window.close()
    }

    /// The items are enabled for a selected image whose file is here, on
    /// the chip's menu and (through the model) in the Edit menu.
    @Test func theCommandsNeedASelectedImageWithItsFile() throws {
        let image = try image()
        let (window, view) = host("text " + AttachmentReference.markdown(for: image.id))
        model.keyResponder = { view }
        let copy = item(#selector(BoopTextView.copyTextFromImage(_:)))
        let insert = item(#selector(BoopTextView.insertImageTextBelow(_:)))

        view.setSelectedRange(NSRange(location: 0, length: 4))
        model.refreshEditorFocus()
        #expect(!view.validateUserInterfaceItem(copy) && !view.validateUserInterfaceItem(insert), "text is not an image")
        #expect(!model.canCopyImageText)

        // A right click selects the chip and offers both commands.
        let menu = try #require(view.chipViews.first).onMenu()
        #expect(menu?.items.map(\.title) == ["Copy Text from Image", "Insert Text Below"])
        #expect(menu?.items.allSatisfy { $0.target === view } == true)
        #expect(view.selectedRange() == reference(image.id, in: view))
        #expect(view.validateUserInterfaceItem(copy) && view.validateUserInterfaceItem(insert))
        // As AppKit validates the menu before showing it.
        menu?.update()
        #expect(menu?.items.allSatisfy(\.isEnabled) == true)
        model.refreshEditorFocus()
        #expect(model.canCopyImageText)

        try FileManager.default.removeItem(at: model.store.fileURL(for: image))
        #expect(!view.validateUserInterfaceItem(copy) && !view.validateUserInterfaceItem(insert), "the file is missing")
        menu?.update()
        #expect(menu?.items.contains(where: \.isEnabled) == false, "shown, and disabled")
        model.refreshEditorFocus()
        #expect(!model.canCopyImageText)
        window.close()
    }

    /// The editor as NoteDetail wires it: focused, and reporting its image
    /// selection to the model, with the model watching the attachments.
    func focus(_ view: BoopTextView) {
        model.keyResponder = { view }
        view.onImageSelectionChange = { [model] in model.editorFocusMayHaveChanged() }
        model.watchAttachments()
    }

    /// The Edit menu's state follows the image's file while the selection
    /// stays where it is (#251): nothing here tells the model to look again.
    @Test func theEditMenuFollowsAFileThatGoesAndComesBack() async throws {
        let image = try image()
        let (window, view) = host("text " + AttachmentReference.markdown(for: image.id))
        focus(view)
        view.setSelectedRange(reference(image.id, in: view))
        #expect(try await eventually { model.canCopyImageText })

        // As the store removes a file, and as it writes one.
        let url = model.store.fileURL(for: image)
        try FileManager.default.removeItem(at: url)
        #expect(try await eventually { !model.canCopyImageText }, "the file went")
        #expect(try await eventually { view.chipViews.first?.accessibilityLabel() == "Missing image" }, "and its chip says so")
        try Data([1, 2, 3]).write(to: url, options: .atomic)
        #expect(try await eventually { model.canCopyImageText }, "the file is back")
        #expect(try await eventually { view.chipViews.first?.accessibilityLabel() == "Image" }, "and so does its chip")

        // The editor's own record followed too: leaving the image is still
        // a change it reports.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(try await eventually { !model.canCopyImageText })
        window.close()
    }

    /// An image whose record iCloud has not brought yet: its chip can be
    /// selected, and the commands come on when the record and its file
    /// arrive, and go off when another device deletes it (#251). The store
    /// is written as sync writes it; sync itself is off.
    @Test func theEditMenuFollowsAnImageThatArrivesAndIsDeletedElsewhere() async throws {
        let attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 3)
        let (window, view) = host("text " + AttachmentReference.markdown(for: attachment.id))
        focus(view)
        view.setSelectedRange(reference(attachment.id, in: view))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.canCopyImageText, "not here yet")
        let revision = model.attachmentsRevision

        let record = SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused"))
        try model.store.applyServerRecord(record, systemFields: Data(), assetData: Data([1, 2, 3]))
        #expect(try await eventually { model.canCopyImageText }, "arrived")
        #expect(model.attachmentsRevision != revision, "the other editors draw their chips again")

        try model.store.applyServerDeletion(kind: .attachment, name: attachment.id.uuidString.lowercased())
        #expect(try await eventually { !model.canCopyImageText }, "deleted on another device")
        window.close()
    }

    /// The Edit menu's state follows the selection, not only the focus.
    @Test func selectingAnImageIsReported() throws {
        let image = try image()
        let (window, view) = host("text " + AttachmentReference.markdown(for: image.id))
        var reports = 0
        view.onImageSelectionChange = { reports += 1 }
        view.setSelectedRange(reference(image.id, in: view))
        #expect(reports == 1)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(reports == 2)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(reports == 2, "still no image")
        window.close()
    }

    @Test func aMissingFileCopiesNothing() async throws {
        let image = try image()
        try model.store.setRecognizedText("stored", for: image.id)
        let (window, view) = host(AttachmentReference.markdown(for: image.id))
        try FileManager.default.removeItem(at: model.store.fileURL(for: image))
        let pasteboard = NSPasteboard.withUniqueName()
        await view.copyImageText(of: image.id, to: pasteboard).value
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(messages.all.count == 1)
        window.close()
    }

    @Test func insertTextBelowIsOneUndoStep() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let original = "before\nsee " + markdown + " here\nafter"
        let (window, view) = host(original)
        view.setSelectedRange(reference(image.id, in: view))
        await view.insertImageText(of: image.id).value
        #expect(view.string == "before\nsee " + markdown + " here\nName\tQty\nBolt\t12\nafter")
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "Name\tQty\nBolt\t12", "the inserted text is selected")
        #expect(await calls.count == 1, "read on demand")
        view.undoManager?.undo()
        #expect(view.string == original)
        window.close()
    }

    /// The image is in the note twice and the command was chosen on the
    /// second reference: the text goes below that one, also when the caret
    /// has moved by the time the image is read.
    @Test func insertGoesBelowTheReferenceItWasChosenOn() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nbetween\n" + markdown + "\nafter")
        let second = try #require(AttachmentReference.matches(in: view.string).last?.range)
        view.setSelectedRange(second)
        let task = view.insertImageText(of: image.id)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        await task.value
        #expect(view.string == markdown + "\nbetween\n" + markdown + "\nName\tQty\nBolt\t12\nafter")
        window.close()
    }

    /// The chosen reference is deleted while the image is read: the text is
    /// not put under the other copy of the image.
    @Test func insertIsDroppedWhenTheChosenReferenceWasDeleted() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nbetween\n" + markdown + "\nafter")
        let first = try #require(AttachmentReference.matches(in: view.string).first?.range)
        view.setSelectedRange(first)
        let task = view.insertImageText(of: image.id)
        view.insertText("", replacementRange: first)
        await task.value
        #expect(view.string == "\nbetween\n" + markdown + "\nafter")
        #expect(messages.all.count == 1)
        window.close()
    }

    /// The same image is added above the chosen reference while the image
    /// is read: the text still goes below the one it was chosen on.
    @Test func insertFollowsTheChosenReferenceThroughEdits() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nafter")
        view.setSelectedRange(try #require(AttachmentReference.matches(in: view.string).first?.range))
        let task = view.insertImageText(of: image.id)
        view.insertText(markdown + "\nabove\n", replacementRange: NSRange(location: 0, length: 0))
        await task.value
        #expect(view.string == markdown + "\nabove\n" + markdown + "\nName\tQty\nBolt\t12\nafter")
        window.close()
    }

    /// The text arrives after a moment; a note loaded meanwhile is not the
    /// one the command was for.
    @Test func insertIsDroppedWhenAnotherNoteWasLoaded() async throws {
        let image = try image()
        let (window, view) = host(AttachmentReference.markdown(for: image.id))
        let task = view.insertImageText(of: image.id)
        view.load("another note")
        await task.value
        #expect(view.string == "another note")
        #expect(messages.all.count == 1)
        window.close()
    }

    /// The open note is reloaded in place (an iCloud merge) while the image
    /// is read: the reference is found again in the merged text (#255).
    @Test func insertSurvivesAReloadOfTheSameNote() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host("mine\n" + markdown + "\nafter")
        view.setSelectedRange(reference(image.id, in: view))
        let task = view.insertImageText(of: image.id)
        view.load("a line from another Mac\nmine\n" + markdown + "\nafter", sameNote: true)
        await task.value
        #expect(view.string == "a line from another Mac\nmine\n" + markdown + "\nName\tQty\nBolt\t12\nafter")
        #expect(messages.all.isEmpty)
        window.close()
    }

    /// Edits made after the reload are followed as before it.
    @Test func insertFollowsEditsMadeAfterAReload() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nafter")
        let task = view.insertImageText(of: image.id)
        view.load("merged\n" + markdown + "\nafter", sameNote: true)
        view.insertText(markdown + "\nabove\n", replacementRange: NSRange(location: 0, length: 0))
        await task.value
        #expect(view.string == markdown + "\nabove\nmerged\n" + markdown + "\nName\tQty\nBolt\t12\nafter")
        #expect(messages.all.isEmpty)
        window.close()
    }

    @Test func insertIsDroppedWhenAReloadRemovedTheReference() async throws {
        let image = try image()
        let (window, view) = host(AttachmentReference.markdown(for: image.id) + "\nafter")
        let task = view.insertImageText(of: image.id)
        view.load("the image was removed on another Mac\nafter", sameNote: true)
        await task.value
        #expect(view.string == "the image was removed on another Mac\nafter")
        #expect(messages.all == ["The image is no longer in this note, so its text was not inserted."])
        window.close()
    }

    /// Which of two references was chosen cannot be told after a reload.
    @Test func insertIsDroppedWhenAReloadHasTheImageTwice() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nafter")
        let task = view.insertImageText(of: image.id)
        let merged = markdown + "\nbetween\n" + markdown + "\nafter"
        view.load(merged, sameNote: true)
        await task.value
        #expect(view.string == merged)
        #expect(messages.all == ["The note changed in iCloud, and the image you chose cannot be told from its other copies, so its text was not inserted."])
        window.close()
    }

    /// The image was in the note twice and the reload kept one: it may be
    /// the other copy, so the text does not go under it.
    @Test func insertIsDroppedWhenAReloadKeptOneOfTwoCopies() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nbetween\n" + markdown + "\nafter")
        view.setSelectedRange(try #require(AttachmentReference.matches(in: view.string).last?.range))
        let task = view.insertImageText(of: image.id)
        let merged = markdown + "\nbetween\nafter"
        view.load(merged, sameNote: true)
        await task.value
        #expect(view.string == merged)
        #expect(messages.all == ["The note changed in iCloud, and the image you chose cannot be told from its other copies, so its text was not inserted."])
        window.close()
    }

    /// A reference deleted before the reload stays lost: the text does not
    /// go under the copy of the image the merged text still has.
    @Test func aReloadDoesNotBringBackADeletedReference() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nbetween\n" + markdown + "\nafter")
        let first = try #require(AttachmentReference.matches(in: view.string).first?.range)
        view.setSelectedRange(first)
        let task = view.insertImageText(of: image.id)
        view.insertText("", replacementRange: first)
        view.load("merged\nbetween\n" + markdown + "\nafter", sameNote: true)
        await task.value
        #expect(view.string == "merged\nbetween\n" + markdown + "\nafter")
        #expect(messages.all == ["The image is no longer in this note, so its text was not inserted."])
        window.close()
    }

    /// Another note loaded after a reload that could not tell the copies
    /// apart: the message is the other note's, the reason that holds now.
    @Test func anotherNoteAfterAnAmbiguousReloadSaysTheImageIsGone() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown + "\nafter")
        let task = view.insertImageText(of: image.id)
        view.load(markdown + "\nbetween\n" + markdown + "\nafter", sameNote: true)
        view.load("another note")
        await task.value
        #expect(view.string == "another note")
        #expect(messages.all == ["The image is no longer in this note, so its text was not inserted."])
        window.close()
    }

    /// A note reloaded and then replaced by another is another note.
    @Test func insertIsDroppedWhenAnotherNoteFollowsAReload() async throws {
        let image = try image()
        let markdown = AttachmentReference.markdown(for: image.id)
        let (window, view) = host(markdown)
        let task = view.insertImageText(of: image.id)
        view.load("merged\n" + markdown, sameNote: true)
        view.load("another note with " + markdown)
        await task.value
        #expect(view.string == "another note with " + markdown)
        #expect(messages.all == ["The image is no longer in this note, so its text was not inserted."])
        window.close()
    }
}
