import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Reviewing a change before it is applied (#245) in a real editor: the
/// note is untouched while the review is open, Keep is one undoable edit,
/// Discard is nothing, and Keep refuses over a note that changed. What a
/// diff is made of is tested in Core.
@MainActor
@Suite(.serialized)
struct DiffReviewFlowTests {
    static let table = "┌───┬───┐\n│ a │ b │\n│ c │ d │\n└───┴───┘\n"
    static let cleaned = "| a | b |\n| --- | --- |\n| c | d |\n"

    final class Messages {
        var all: [String] = []
    }

    let messages = Messages()

    func host(_ text: String) -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text, syntax: .plain)
        view.showMessage = { [messages] in messages.all.append($0) }
        return (window, view)
    }

    func close(_ window: NSWindow, _ view: BoopTextView) {
        view.discardPendingReview()
        window.close()
    }

    @Test func aPreviewShowsTheChangeAndLeavesTheNoteAlone() async throws {
        let source = "Counts:\n" + Self.table + "after\n"
        let (window, view) = host(source)
        await view.run(.cleanUpPastedText, preview: true).value
        #expect(view.string == source, "nothing is applied yet")
        #expect(view.undoManager?.canUndo == false)
        let review = try #require(view.pendingReview)
        #expect(review.name == "Clean Up Pasted Text")
        #expect(review.sheet != nil)
        #expect(review.content.summary == TextDiff.Summary(removed: 4, added: 3))
        let lines = review.content.parts.flatMap(\.hunks).flatMap(\.lines)
        #expect(lines.first?.text == "Counts:" && lines.first?.kind == .unchanged, "context around the change")
        #expect(lines.last?.text == "after")
        #expect(messages.all.isEmpty)
        close(window, view)
    }

    @Test func keepAppliesTheChangeAsOneUndoStep() async {
        let source = "Counts:\n" + Self.table
        let (window, view) = host(source)
        await view.run(.cleanUpPastedText, preview: true).value
        view.keepPendingReview()
        #expect(view.pendingReview == nil)
        #expect(view.string == "Counts:\n" + Self.cleaned)
        #expect(view.undoManager?.undoActionName == "Clean Up Pasted Text")
        view.undoManager?.undo()
        #expect(view.string == source)
        #expect(view.undoManager?.canUndo == false, "it was one step")
        #expect(window.firstResponder === view, "the editor has the keyboard again")
        close(window, view)
    }

    @Test func discardChangesNothing() async {
        let source = "Counts:\n" + Self.table
        let (window, view) = host(source)
        await view.run(.cleanUpPastedText, preview: true).value
        view.discardPendingReview()
        #expect(view.pendingReview == nil)
        #expect(view.string == source)
        #expect(view.undoManager?.canUndo == false)
        #expect(messages.all.isEmpty)
        view.keepPendingReview()
        #expect(view.string == source, "nothing is left to keep")
        close(window, view)
    }

    @Test func aChangeOfNothingShowsNoSheetAndSaysSo() async {
        let source = "# Title\n\nClean already.\n"
        let (window, view) = host(source)
        await view.run(.cleanUpPastedText, preview: true).value
        #expect(view.pendingReview == nil)
        #expect(view.string == source)
        #expect(messages.all == ["Nothing to clean up."])

        // The same through the review itself, as a script's result comes.
        let whole = NSRange(location: 0, length: (source as NSString).length)
        view.review([(whole, source)], of: source, named: "Sort Lines")
        #expect(view.pendingReview == nil)
        #expect(messages.all.last == "Sort Lines would change nothing.")
        close(window, view)
    }

    @Test func aSelectionIsReviewedAloneAndOnlyItChanges() async throws {
        let before = "  kept as it is  \n\n"
        let after = "\n  and this too  \n"
        let source = before + Self.table + after
        let (window, view) = host(source)
        view.setSelectedRange(NSRange(location: (before as NSString).length, length: (Self.table as NSString).length))
        await view.run(.cleanUpPastedText, preview: true).value
        let review = try #require(view.pendingReview)
        #expect(review.content.parts.count == 1)
        #expect(review.content.parts[0].firstLine == 3, "numbered where the selection sits in the note")
        let texts = review.content.parts.flatMap(\.hunks).flatMap(\.lines).map(\.text)
        #expect(!texts.contains("  kept as it is  ") && !texts.contains("  and this too  "), "no lines from outside the selection")
        view.keepPendingReview()
        #expect(view.string == before + Self.cleaned + after)
        close(window, view)
    }

    @Test func aScriptsResultIsKeptUnderTheScriptsName() throws {
        let source = "b\na\nc\n"
        let (window, view) = host(source)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        view.review([(whole, "a\nb\nc\n")], of: source, named: "Sort Lines")
        #expect(try #require(view.pendingReview).content.summary == TextDiff.Summary(removed: 1, added: 1))
        #expect(view.string == source)
        view.keepPendingReview()
        #expect(view.string == "a\nb\nc\n")
        #expect(view.undoManager?.undoActionName == "Sort Lines")
        close(window, view)
    }

    @Test func keepRefusesOverANoteThatChangedMeanwhile() async {
        let source = "Counts:\n" + Self.table
        let (window, view) = host(source)
        await view.run(.cleanUpPastedText, preview: true).value
        view.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        view.keepPendingReview()
        #expect(view.string == "edited " + source, "the newer text is not written over")
        #expect(view.pendingReview == nil)
        #expect(messages.all == ["The note changed while Clean Up Pasted Text was being reviewed, so nothing was applied."])
        close(window, view)
    }

    @Test func keepRefusesAfterAnotherNoteWasLoaded() async {
        let (window, view) = host("Counts:\n" + Self.table)
        await view.run(.cleanUpPastedText, preview: true).value
        // The same text again is still another load: another note, or a
        // merge from iCloud.
        view.load("Counts:\n" + Self.table, syntax: .plain)
        view.keepPendingReview()
        #expect(view.string == "Counts:\n" + Self.table)
        #expect(messages.all.count == 1)
        close(window, view)
    }

    @Test func aResultForATextTheNoteNoLongerHasIsNotShown() {
        let (window, view) = host("new text\n")
        view.review([(NSRange(location: 0, length: 4), "x")], of: "old text\n", named: "Upcase")
        #expect(view.pendingReview == nil)
        #expect(messages.all == ["Upcase finished after the note changed, so its result was not shown."])
        close(window, view)
    }

    @Test func oneReviewAtATime() async throws {
        let source = "Counts:\n" + Self.table
        let (window, view) = host(source)
        await view.run(.cleanUpPastedText, preview: true).value
        let first = try #require(view.pendingReview)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        view.review([(whole, "other\n")], of: source, named: "Other")
        #expect(view.pendingReview?.name == first.name, "the open review stays")
        #expect(messages.all == ["Other could not show its changes while another sheet is open."])
        close(window, view)
    }

    @Test func anEditorLeavingItsWindowEndsItsReview() async {
        let (window, view) = host("Counts:\n" + Self.table)
        await view.run(.cleanUpPastedText, preview: true).value
        #expect(view.pendingReview != nil)
        window.contentView = NSView()
        #expect(view.pendingReview == nil)
        window.close()
    }

    @Test func thePickerOpenedForAPreviewRunsWithOne() {
        let (window, view) = host("text\n")
        #expect(PickerTarget(editor: view).preview == false)
        #expect(PickerTarget(editor: view, preview: true).preview)
        close(window, view)
    }

    // MARK: How a line looks

    @Test func everyKindOfLineHasAMarkOfItsOwn() {
        #expect(DiffReviewStyle.mark(.removed) == "−")
        #expect(DiffReviewStyle.mark(.added) == "+")
        #expect(DiffReviewStyle.mark(.unchanged) == " ")
    }

    @Test func changedWordsAreUnderlinedSoTheyShowWithoutColour() throws {
        let lines = TextDiff.lines(old: "let count = 1\n", new: "let total = 1\n")
        let added = NSAttributedString(DiffReviewStyle.text(of: lines[1]))
        #expect(added.string == "let total = 1")
        var range = NSRange()
        let underline = added.attribute(.underlineStyle, at: 4, effectiveRange: &range)
        #expect(underline != nil)
        #expect(range == NSRange(location: 4, length: 5), "the word that changed, and only it")
        #expect(added.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
        let unchanged = NSAttributedString(DiffReviewStyle.text(of: TextDiff.Line(kind: .unchanged, text: "", ending: .lf, oldNumber: 1, newNumber: 1)))
        #expect(unchanged.string == " ", "an empty line still has a row's height")
    }
}
