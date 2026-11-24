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

    /// A PNG of a table, one string per cell, drawn here: synthetic.
    static func picture(ofGrid rows: [[String]]) -> Data {
        let size = NSSize(width: 1500, height: CGFloat(rows.count) * 140 + 60)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (row, cells) in rows.enumerated() {
            for (column, cell) in cells.enumerated() {
                // The first row at the top: AppKit's y runs upwards.
                let point = NSPoint(x: 40 + CGFloat(column) * 480, y: size.height - CGFloat(row + 1) * 140)
                (cell as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: 56, weight: .semibold), .foregroundColor: NSColor.black])
            }
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    /// Vision's boxes end to end (#243): the first row drawn is the first
    /// line read, and cells on a row are a tab apart, left to right.
    @Test func aTableIsReadRowByRow() async throws {
        let text = try #require(await LiveTextRecognizer.text(in: Self.picture(ofGrid: [["ALPHA", "1001", "BRAVO"], ["DELTA", "2002", "HOTEL"]])))
        // The layout exactly; the letters only where a misreading is
        // unlikely, as above.
        let rows = text.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        #expect(rows.map(\.count) == [3, 3], "read \(text.debugDescription)")
        #expect(rows.first?.dropFirst().first?.contains("1001") == true, "read \(text.debugDescription)")
        #expect(rows.last?.dropFirst().first?.contains("2002") == true, "read \(text.debugDescription)")
    }

    @Test func aPicturesSizeIsReadFromItsData() {
        let size = LiveTextRecognizer.pixelSize(of: Self.picture(of: "size"))
        #expect(size.map { $0.width > $0.height } == true)
        #expect(LiveTextRecognizer.pixelSize(of: Data([1, 2, 3])) == nil)
    }

    /// A request that arrives while the worker is busy is not lost.
    /// An image added after the worker's last look, while it finishes, is
    /// read by the rerun the request sets up (#91). Without the rerun it
    /// would wait for the next change or launch.
    @Test func aRequestAsTheWorkerFinishesIsRunAfterIt() async throws {
        // The model's first list delivery also asks for recognition; let it
        // come and go first, so the hook below is the only request left.
        // (Attachments do not touch the observed note table, so adding them
        // causes no further delivery.)
        let store = try NoteStore.inMemory()
        try store.save(Note(body: "seen", createdAt: Date()))
        let model = AppModel(store: store)
        model.recognizeText = { _ in "text" }
        let settled = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < settled, model.notes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.notes.count == 1)
        try await Task.sleep(for: .milliseconds(200))
        let first = try model.store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        var second: NoteAttachment?
        model.recognitionWillFinish = {
            guard second == nil else { return }
            second = try? model.store.addAttachment(Data([2]), contentType: "public.png", noteID: nil)
            model.recognizePendingImages()
        }
        model.recognizePendingImages()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, second == nil || (try? model.store.attachmentsAwaitingRecognition().isEmpty) != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try model.store.attachment(id: first.id)?.recognizedText != nil)
        let added = try #require(second)
        #expect(try model.store.attachment(id: added.id)?.recognizedText != nil)
    }

    actor Gate {
        var isOpen = false
        func wait() async { while !isOpen { try? await Task.sleep(for: .milliseconds(10)) } }
        func open() { isOpen = true }
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
