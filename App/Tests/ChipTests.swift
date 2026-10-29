import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Image references shown as chips (#52): the text stays the markdown, and
/// editing treats each reference as one unit.
@MainActor
@Suite(.serialized)
struct ChipTests {
    let first = UUID()
    let second = UUID()

    func host(_ text: String, missing: Set<UUID> = []) -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        // Wide enough that no reference wraps: a narrow first segment of a
        // wrapped reference has no label (#96), which these tests do not test.
        scroll.frame = NSRect(x: 0, y: 0, width: 2000, height: 300)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text)
        let dir = FileManager.default.temporaryDirectory
        view.attachmentURL = { missing.contains($0) ? nil : dir.appendingPathComponent("\($0).png") }
        view.updateChips()
        return (window, view)
    }

    var body: String {
        "a " + AttachmentReference.markdown(for: first, alt: "plot") + " b " + AttachmentReference.markdown(for: second) + " c"
    }

    func range(of id: UUID, in text: String) -> NSRange {
        AttachmentReference.matches(in: text).first { $0.id == id }!.range
    }

    @Test func eachReferenceGetsAChipAndTheTextStaysMarkdown() {
        let (window, view) = host(body, missing: [second])
        let labelled = view.chipViews.compactMap { $0.accessibilityLabel() }
        #expect(labelled == ["plot", "Missing image"])
        let (other, missingWithAlt) = host(body, missing: [first])
        #expect(missingWithAlt.chipViews.compactMap { $0.accessibilityLabel() }.first == "plot (missing)")
        other.close()
        #expect(view.string == body, "chips only cover the text")
        window.close()
    }

    @Test func oneBackspaceRemovesAWholeReferenceAndUndoBringsItBack() {
        let (window, view) = host(body)
        let chip = range(of: first, in: body)
        view.setSelectedRange(NSRange(location: NSMaxRange(chip), length: 0))
        view.deleteBackward(nil)
        #expect(view.string == "a  b " + AttachmentReference.markdown(for: second) + " c")
        view.undoManager?.undo()
        #expect(view.string == body)
        window.close()
    }

    /// A second delete straight after the first sees the text as it is
    /// now, not ranges from before the first.
    @Test func rapidDeletesDoNotUseStaleRanges() {
        let text = AttachmentReference.markdown(for: first) + "keep this text intact please, more than a reference long"
        let (window, view) = host(text)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteForward(nil)
        view.deleteForward(nil)
        #expect(view.string == "eep this text intact please, more than a reference long")
        window.close()
    }

    @Test func clickingAChipFocusesTheEditor() throws {
        let (window, view) = host(body)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let chip = try #require(view.chipViews.first)
        chip.onClick()
        #expect(window.firstResponder === view)
        #expect(view.selectedRange() == range(of: first, in: body))
        window.close()
    }

    /// Loading another note replaces the chip ranges at once: a delete
    /// straight after the load acts on the new text (#94).
    @Test func loadingANoteReplacesItsRangesAtOnce() {
        // The old note starts with a long reference; the new one with a
        // different reference: only ranges recomputed for the new text make
        // one Forward Delete remove exactly its reference.
        let (window, view) = host(AttachmentReference.markdown(for: first, alt: "a much longer alt text here") + " old note")
        let next = AttachmentReference.markdown(for: second) + "tail"
        view.load(next)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteForward(nil)
        #expect(view.string == "tail")
        #expect(view.chipViews.isEmpty)
        window.close()
    }

    @Test func aNarrowSegmentHasNoDecoration() {
        let chip = ChipView(frame: NSRect(x: 0, y: 0, width: 8, height: 16), reference: NSRange(location: 0, length: 1),
                            label: "plot", image: nil, missing: false, background: .white, fill: .gray, text: .black)
        #expect(chip.subviews.count == 1, "only the pill")
        #expect(chip.layer?.masksToBounds == true)
    }

    @Test func forwardDeleteRemovesTheReferenceAhead() {
        let (window, view) = host(body)
        let chip = range(of: second, in: body)
        view.setSelectedRange(NSRange(location: chip.location, length: 0))
        view.deleteForward(nil)
        #expect(view.string == "a " + AttachmentReference.markdown(for: first, alt: "plot") + " b  c")
        window.close()
    }

    @Test func theCaretNeverStopsInsideAReference() {
        let (window, view) = host(body)
        let chip = range(of: first, in: body)
        view.setSelectedRange(NSRange(location: chip.location, length: 0))
        view.setSelectedRange(NSRange(location: chip.location + 5, length: 0))
        #expect(view.selectedRange() == NSRange(location: NSMaxRange(chip), length: 0), "moving right lands after it")
        view.setSelectedRange(NSRange(location: chip.location + 5, length: 0))
        #expect(view.selectedRange() == NSRange(location: chip.location, length: 0), "moving left lands before it")
        window.close()
    }

    @Test func aSelectionGrowsToCoverAReference() {
        let (window, view) = host(body)
        let chip = range(of: first, in: body)
        view.setSelectedRange(NSRange(location: 0, length: chip.location + 3))
        #expect(view.selectedRange() == NSRange(location: 0, length: NSMaxRange(chip)))
        window.close()
    }

    @Test func copyingAChipCopiesItsMarkdown() {
        let (window, view) = host(body)
        let chip = range(of: first, in: body)
        view.setSelectedRange(chip)
        let pasteboard = NSPasteboard.withUniqueName()
        // A plain-text view writes the legacy string type, which reads back
        // as `.string`.
        #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == AttachmentReference.markdown(for: first, alt: "plot"))
        window.close()
    }

    @Test func withoutAnAttachmentLookupReferencesStayText() {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.load(body)
        view.updateChips()
        #expect(view.chipViews.isEmpty)
    }

    /// Only references on screen get a chip; all keep their range, so
    /// editing treats an off-screen one as a unit too (#95).
    @Test func onlyVisibleReferencesGetChips() {
        let far = String(repeating: "line\n", count: 2000)
        let text = AttachmentReference.markdown(for: first, alt: "top") + "\n" + far + AttachmentReference.markdown(for: second, alt: "bottom")
        let (window, view) = host(text)
        #expect(view.chipRanges.count == 2)
        #expect(view.chipViews.compactMap { $0.accessibilityLabel() } == ["top"])
        window.close()
    }

    /// A chip's picture is a small thumbnail, never the full image.
    @Test func thumbnailsAreDownsampled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let big = NSImage(size: NSSize(width: 2000, height: 1000), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(big.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
        let (image, cost) = try #require(BoopTextView.downsampled(url, maxPixels: 160))
        #expect(max(image.size.width, image.size.height) <= 160)
        #expect(cost < 160 * 160 * 4 + 1024)
    }

    /// Two editors showing the same image both get its thumbnail, though
    /// only one decode runs.
    @Test func everyWaitingEditorGetsTheThumbnail() async throws {
        let id = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: url)
        BoopTextView.thumbnails.removeObject(forKey: url as NSURL)
        let text = AttachmentReference.markdown(for: id, alt: "shared") + " text"
        let (one, first) = host(text)
        let (two, second) = host(text)
        func hasPicture(_ view: BoopTextView) -> Bool {
            view.chipViews.first?.subviews.contains { ($0 as? NSImageView)?.image?.isTemplate == false } ?? false
        }
        for _ in 0..<100 where !(hasPicture(first) && hasPicture(second)) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(hasPicture(first) && hasPicture(second))
        one.close()
        two.close()
    }
}
