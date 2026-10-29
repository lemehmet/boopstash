import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Text in images (#53): Vision on a synthetic image, and the model's
/// pipeline from a new image to a search that finds it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ImageTextTests {
    /// A PNG of `text`, drawn here: synthetic, never a real screenshot.
    static func picture(of text: String) -> Data {
        let size = NSSize(width: 900, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 24, y: 48), withAttributes: [.font: NSFont.systemFont(ofSize: 56, weight: .semibold), .foregroundColor: NSColor.black])
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    @Test func visionReadsTextOnDevice() async throws {
        let text = try #require(await LiveTextRecognizer.text(in: Self.picture(of: "BOOPSTASH 4217")))
        #expect(text.contains("4217"), "read \(text)")
        #expect(await LiveTextRecognizer.text(in: Data([1, 2, 3])) == nil, "not an image")
    }

    @Test func aNewImageBecomesSearchable() async throws {
        let model = AppModel(store: try .inMemory())
        model.recognizeText = { _ in "Invoice 4217" }
        var note = Note(title: "shot", body: "", createdAt: Date())
        let image = try model.store.addAttachment(Data([1]), contentType: "public.png", noteID: note.id)
        note.body = AttachmentReference.markdown(for: image.id)
        try model.store.save(note)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, (try? model.store.notes(matching: NoteQuery(text: "invoice")).isEmpty) != false {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try model.store.notes(matching: NoteQuery(text: "invoice")).map(\.id) == [note.id])
        #expect(!NoteQuery(text: "invoice").matchesWithoutImages(note), "the list marks it as found in an image")
    }
}
