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
