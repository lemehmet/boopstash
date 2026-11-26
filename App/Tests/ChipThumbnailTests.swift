import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// An image chip's thumbnail follows its file (#296): the picture is of
/// the bytes at the URL now, not of those that were there when it was
/// first made. The store is written as sync writes it; sync itself is off.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ChipThumbnailTests {
    let model: AppModel

    init() async throws {
        let store = try NoteStore.inMemory()
        try store.save(Note(body: "seen", createdAt: Date()))
        model = AppModel(store: store)
        model.recognizeText = { _ in "" }
        try #require(try await eventually { model.notes.count == 1 })
    }

    /// A valid PNG of one colour.
    func png(_ color: NSColor, width: Int = 400, height: Int = 200) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The editor as NoteDetail wires it, focused, with the model watching
    /// the attachments unless the test looks again itself.
    func host(_ text: String, watching: Bool = true) -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 2000, height: 300)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text)
        view.attachmentURL = { [store = model.store] id in store.presentFileURL(forAttachment: id) }
        model.keyResponder = { view }
        if watching { model.watchAttachments() }
        view.updateChips()
        return (window, view)
    }

    /// The picture a chip shows, if it shows one and not an icon.
    func picture(_ view: BoopTextView) -> NSImage? {
        view.chipViews.first?.subviews.compactMap { ($0 as? NSImageView)?.image }.first { !$0.isTemplate }
    }

    enum Shade { case red, blue, other }

    /// Whether the chip's picture is mostly red or mostly blue.
    func shade(_ view: BoopTextView) -> Shade? {
        guard let image = picture(view), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let color = NSBitmapImageRep(cgImage: cgImage).colorAt(x: cgImage.width / 2, y: cgImage.height / 2)?
                  .usingColorSpace(.deviceRGB)
        else { return nil }
        if color.redComponent > 0.6, color.blueComponent < 0.4 { return .red }
        if color.blueComponent > 0.6, color.redComponent < 0.4 { return .blue }
        return .other
    }

    /// An image as it comes from another device that has read its text
    /// already (none). One not read yet is read here, which is a change
    /// made here: the store then keeps this device's file until that
    /// change is sent, and a file that arrives meanwhile is not taken
    /// (#121). Whether the reading got in before the next arrival was a
    /// matter of timing, and on CI it did.
    func image() -> NoteAttachment {
        NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 0, recognizedText: "")
    }

    /// An image iCloud brought, unchanged here: the next version of its
    /// record replaces its file.
    func arrive(_ attachment: NoteAttachment, _ data: Data) throws {
        let record = SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused"))
        try model.store.applyServerRecord(record, systemFields: Data(), assetData: data)
    }

    /// The scenario of #296: the chip has its thumbnail, the image's file
    /// is replaced with another image as `applyServerRecord` does it, and
    /// the chip shows the new one. Nothing here reloads the editor or
    /// tells it to look again.
    @Test func aReplacedFileGetsANewThumbnail() async throws {
        let attachment = image()
        try arrive(attachment, try png(.red))
        let (window, view) = host("text " + AttachmentReference.markdown(for: attachment.id, alt: "plot"))
        defer { window.close() }
        #expect(try await eventually { shade(view) == .red }, "the first picture")
        let url = try #require(model.store.presentFileURL(forAttachment: attachment.id))
        let text = view.string
        let before = try #require(FileVersion(of: url))

        try arrive(attachment, try png(.blue))
        // The store took the file, and it is told apart from the first by
        // what the file system says of it, the two being the same size.
        #expect(FileVersion(of: url) != before, "the replaced file is another version")
        #expect(model.store.presentFileURL(forAttachment: attachment.id) == url, "the same URL")
        #expect(try await eventually { shade(view) == .blue }, "the new picture")
        #expect(view.string == text)
        // Small, as before: never the full image (#95).
        let shown = try #require(picture(view))
        #expect(max(shown.size.width, shown.size.height) <= 160)
    }

    /// A file removed and written again with another image underneath the
    /// app, as the store removes and writes one.
    @Test func aFileRemovedAndWrittenAgainGetsANewThumbnail() async throws {
        let attachment = image()
        try arrive(attachment, try png(.red))
        let (window, view) = host("text " + AttachmentReference.markdown(for: attachment.id))
        defer { window.close() }
        #expect(try await eventually { shade(view) == .red })
        let url = try #require(model.store.presentFileURL(forAttachment: attachment.id))

        try FileManager.default.removeItem(at: url)
        #expect(try await eventually { view.chipViews.first?.accessibilityLabel() == "Missing image" })
        try png(.blue).write(to: url, options: .atomic)
        #expect(try await eventually { shade(view) == .blue })
    }

    /// The file is replaced while its first thumbnail is still being made:
    /// whichever decode finishes last, the chip ends on the new picture
    /// and stays there.
    @Test func aDecodeUnderWayForTheOldBytesDoesNotPutTheOldThumbnailBack() async throws {
        let attachment = image()
        // Large, so that its decode is still running when the file changes.
        try arrive(attachment, try png(.red, width: 3000, height: 2000))
        let (window, view) = host("text " + AttachmentReference.markdown(for: attachment.id))
        defer { window.close() }
        let url = try #require(model.store.presentFileURL(forAttachment: attachment.id))
        #expect(BoopTextView.decodes.isDecoding(url), "the first decode is under way")

        try arrive(attachment, try png(.blue))
        view.updateChips()
        #expect(try await eventually { shade(view) == .blue })
        #expect(try await eventually { !BoopTextView.decodes.isDecoding(url) }, "both decodes are done")
        try await Task.sleep(for: .milliseconds(200))
        view.updateChips()
        #expect(shade(view) == .blue, "the old picture did not come back")
        #expect(BoopTextView.thumbnails.object(forKey: url as NSURL)?.version == FileVersion(of: url))
    }

    /// A file that stops being an image loses the picture of the image it
    /// replaced, and asking again does not go round in circles.
    @Test func aFileThatIsNoLongerAnImageLosesItsThumbnail() async throws {
        let attachment = image()
        try arrive(attachment, try png(.red))
        let (window, view) = host("text " + AttachmentReference.markdown(for: attachment.id))
        defer { window.close() }
        #expect(try await eventually { shade(view) == .red })
        let url = try #require(model.store.presentFileURL(forAttachment: attachment.id))

        try arrive(attachment, Data([1, 2, 3]))
        #expect(try await eventually { picture(view) == nil && view.chipViews.first?.accessibilityLabel() == "Image" })
        #expect(try await eventually { !BoopTextView.decodes.isDecoding(url) })
    }

    /// The same, with the cache letting the old picture go while the new
    /// file is looked at, as it may at any time: the chip was drawn with
    /// that picture and still loses it. Nothing but the decode's end draws
    /// the chips again here; the folder is not watched.
    @Test func aFileThatIsNoLongerAnImageLosesAThumbnailTheCacheLetGo() async throws {
        let attachment = image()
        try arrive(attachment, try png(.red))
        let (window, view) = host("text " + AttachmentReference.markdown(for: attachment.id), watching: false)
        defer { window.close() }
        #expect(try await eventually { shade(view) == .red })
        let url = try #require(model.store.presentFileURL(forAttachment: attachment.id))

        try arrive(attachment, Data([1, 2, 3]))
        view.updateChips()
        #expect(shade(view) == .red, "the old picture stays while the file is looked at")
        #expect(BoopTextView.decodes.isDecoding(url))
        BoopTextView.thumbnails.removeObject(forKey: url as NSURL)
        #expect(try await eventually { picture(view) == nil && view.chipViews.first?.accessibilityLabel() == "Image" })
        #expect(try await eventually { !BoopTextView.decodes.isDecoding(url) })
        // Asking again makes no picture and does not go round in circles.
        view.updateChips()
        #expect(try await eventually { !BoopTextView.decodes.isDecoding(url) })
        #expect(picture(view) == nil)
    }
}
