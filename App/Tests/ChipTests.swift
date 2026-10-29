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
