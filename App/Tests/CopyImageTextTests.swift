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
        view.attachmentURL = { [store = model.store] id in (try? store.attachment(id: id)).map { store.fileURL(for: $0) } }
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
}
