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
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
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
        let (window, view) = host(AttachmentReference.markdown(for: first) + " old note")
        view.load("short")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteForward(nil)
        #expect(view.string == "hort")
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
}
