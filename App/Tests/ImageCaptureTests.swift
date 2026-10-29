import AppKit
import BoopstashCore
import Testing
import UniformTypeIdentifiers
@testable import Boopstash

/// Images captured by paste, the clipboard capture and drops (#51), from
/// private pasteboards only.
@MainActor
@Suite(.serialized)
struct ImageCaptureTests {
    let model: AppModel
    /// A real (tiny) PNG, made here rather than read from anywhere.
    let png: Data = {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()

    init() throws {
        model = AppModel(store: try .inMemory())
        model.dropSource = { nil }
    }

    func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        write(pasteboard)
        return pasteboard
    }

    func onlyNote() throws -> Note {
        let notes = try model.store.notes(matching: NoteQuery())
        try #require(notes.count == 1, "\(notes.count) notes")
        return notes[0]
    }

    func storedImage(in note: Note) throws -> Data {
        let attachment = try #require(try model.store.attachments(referencedBy: note.body).first)
        #expect(attachment.noteID == note.id)
        return try model.store.data(for: attachment)
    }

    @Test func anImageOnlyClipboardBecomesAnImageNote() throws {
        let board = pasteboard { $0.setData(png, forType: .png) }
        #expect(model.capture(from: board, origin: .menu) == nil)
        let note = try onlyNote()
        #expect(note.title == "Image")
        #expect(try storedImage(in: note) == png)
    }

    @Test func textWinsOverAnImage() throws {
        let board = pasteboard {
            $0.setString("caption", forType: .string)
            $0.setData(png, forType: .png)
        }
        model.capture(from: board, origin: .menu)
        let note = try onlyNote()
        #expect(note.body == "caption")
    }

    @Test func aPasswordManagersImageIsRefused() throws {
        let board = pasteboard {
            $0.setData(png, forType: .png)
            $0.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        model.capture(from: board, origin: .menu)
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
    }

    @Test func oversizedImagesAreRefusedWithTheReason() throws {
        let board = pasteboard { $0.setData(Data(count: ImageImport.sizeLimit + 1), forType: .png) }
        model.capture(from: board, origin: .menu)
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
        #expect(model.banner?.contains("the limit for images is 20 MB") == true)
    }

    @Test func pastingAnImageInsertsItsReference() throws {
        let note = Note(body: "", createdAt: Date())
        try model.store.save(note)
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.string = "before "
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.storeImage = { data, type in model.addImage(data, type: type, to: note.id) }
        view.pastePlainText(from: pasteboard { $0.setData(png, forType: .png) })
        let ids = AttachmentReference.ids(in: view.string)
        #expect(ids.count == 1 && view.string.hasPrefix("before ![](attachment:"))
        let id = try #require(ids.first)
        let attachment = try #require(try model.store.attachment(id: id))
        #expect(attachment.noteID == note.id && attachment.contentType == UTType.png.identifier)
    }

    /// Some apps put an empty string beside an image: that is no text, and
    /// must neither block the image nor erase the selection.
    @Test func anEmptyStringBesideAnImageStillPastesTheImage() throws {
        let note = Note(body: "", createdAt: Date())
        try model.store.save(note)
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.string = "keep this"
        view.setSelectedRange(NSRange(location: 5, length: 4))
        view.storeImage = { data, type in model.addImage(data, type: type, to: note.id) }
        view.pastePlainText(from: pasteboard {
            $0.setString("", forType: .string)
            $0.setData(png, forType: .png)
        })
        #expect(view.string.hasPrefix("keep ![](attachment:"), "got \(view.string)")
    }

    func editorWithSelection(_ text: String, _ selection: NSRange) throws -> BoopTextView {
        let note = Note(body: "", createdAt: Date())
        try model.store.save(note)
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.string = text
        view.setSelectedRange(selection)
        view.storeImage = { data, type in model.addImage(data, type: type, to: note.id) }
        return view
    }

    /// A refused image must not let blank text replace the selection (#89).
    @Test func aRefusedImageLeavesTheSelectionAlone() throws {
        let view = try editorWithSelection("keep this", NSRange(location: 5, length: 4))
        view.pastePlainText(from: pasteboard {
            $0.setString("", forType: .string)
            $0.setData(Data(count: ImageImport.sizeLimit + 1), forType: .png)
        })
        #expect(view.string == "keep this")
        #expect(model.banner?.contains("the limit for images is 20 MB") == true)
    }

    /// An image type BoopStash does not keep is still an image: blank
    /// text beside it does not replace the selection, and the reason shows.
    @Test func anUnsupportedImageIsRefusedWithItsReason() throws {
        let view = try editorWithSelection("keep this", NSRange(location: 5, length: 4))
        var message: String?
        view.showMessage = { message = $0 }
        view.pastePlainText(from: pasteboard {
            $0.setString("", forType: .string)
            // SVG: an image type the pasteboard does not translate to TIFF
            // (BMP it would, and that is then kept as a TIFF).
            $0.setData(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8), forType: NSPasteboard.PasteboardType("public.svg-image"))
        })
        #expect(view.string == "keep this")
        #expect(message?.contains("which BoopStash does not keep") == true, "got \(message ?? "nil")")
    }

    @Test func anUnreadableImageFileSaysSo() throws {
        let view = try editorWithSelection("", NSRange(location: 0, length: 0))
        var message: String?
        view.showMessage = { message = $0 }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).png")
        let board = pasteboard { $0.writeObjects([missing as NSURL]) }
        #expect(view.insertImage(from: board) == .refused)
        #expect(message == "Could not read \(missing.lastPathComponent).")
    }

    /// Whitespace beside an image is no text, as for clipboard capture (#90).
    @Test func whitespaceBesideAnImagePastesTheImage() throws {
        let view = try editorWithSelection("", NSRange(location: 0, length: 0))
        view.pastePlainText(from: pasteboard {
            $0.setString(" \n", forType: .string)
            $0.setData(png, forType: .png)
        })
        #expect(view.string.hasPrefix("![](attachment:"), "got \(view.string)")
    }

    @Test func imageNotesAreNeverSentForAModelTitle() async throws {
        var asked = 0
        model.modelTitlesEnabled = { true }
        model.modelTitlesAvailable = { true }
        model.modelTitler = { _, _ in asked += 1; return "Model title" }
        let image = Note(body: AttachmentReference.markdown(for: UUID()) + "\n", createdAt: Date())
        model.requestModelTitle(for: image)
        let mixed = Note(body: AttachmentReference.markdown(for: UUID()) + "\nmeeting notes", createdAt: Date())
        try model.store.save(mixed)
        model.requestModelTitle(for: mixed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked == 1, "only the note with text was sent")
    }

    /// When the note cannot be written, its image is removed at once.
    @Test func aFailedNoteWriteRemovesItsImage() throws {
        struct DiskFull: Error {}
        model.writeNote = { _ in throw DiskFull() }
        let board = pasteboard { $0.setData(png, forType: .png) }
        #expect(model.capture(from: board, origin: .menu) != nil)
        #expect(try model.store.removeUnreferencedAttachments(olderThan: 0) == 0, "nothing was left to sweep")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: model.store.attachmentsDirectory.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test func aDroppedImageFileBecomesANoteTitledByItsName() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)-chart.png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = try #require(NSItemProvider(contentsOf: url))
        #expect(DropCapture.handle([provider], model: model))
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, (try? model.store.notes(matching: NoteQuery()).count) != 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let note = try onlyNote()
        #expect(note.title.hasSuffix("chart") && note.titleIsUserSet)
        #expect(try storedImage(in: note) == png)
    }
}
