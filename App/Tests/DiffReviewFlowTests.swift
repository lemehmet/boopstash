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
        await view.review([(whole, source)], of: source, named: "Sort Lines").value
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

    @Test func aScriptsResultIsKeptUnderTheScriptsName() async throws {
        let source = "b\na\nc\n"
        let (window, view) = host(source)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        await view.review([(whole, "a\nb\nc\n")], of: source, named: "Sort Lines").value
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

    /// A script that only changes how a character is encoded (a
    /// combining accent to a precomposed letter) changes the note: it is
    /// reviewed, and Keep applies it.
    @Test func aCanonicallyEquivalentResultIsReviewedAndKept() async throws {
        let source = "cafe\u{301}\n"
        let result = "caf\u{E9}\n"
        let (window, view) = host(source)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        await view.review([(whole, result)], of: source, named: "Normalise").value
        #expect(try #require(view.pendingReview).content.summary == TextDiff.Summary(removed: 1, added: 1))
        view.keepPendingReview()
        #expect(Array(view.string.utf16) == Array(result.utf16), "the code units are the script's")
        #expect(view.undoManager?.undoActionName == "Normalise")
        close(window, view)
    }

    // MARK: A note that became a canonically equal text (#266)

    /// The note's "e" with a combining accent becomes the precomposed
    /// letter: the same text to Swift's `==`, one UTF-16 unit shorter. A
    /// result made for the longer text has ranges this one does not.
    func recompose(_ view: BoopTextView, at location: Int) {
        view.insertText("\u{E9}", replacementRange: NSRange(location: location, length: 2))
    }

    @Test func keepRefusesOverANoteThatBecameACanonicallyEqualText() async throws {
        let source = "cafe\u{301}\n"
        let (window, view) = host(source)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        await view.review([(whole, "CAFE\u{301}\n")], of: source, named: "Upcase").value
        #expect(view.pendingReview != nil)
        recompose(view, at: 3)
        #expect(view.string == source, "equal to Swift, which is why the check is on code units")
        view.keepPendingReview()
        #expect(Array(view.string.utf16) == Array("caf\u{E9}\n".utf16), "nothing was applied")
        #expect(view.pendingReview == nil)
        #expect(messages.all == ["The note changed while Upcase was being reviewed, so nothing was applied."])
        close(window, view)
    }

    @Test func aResultForACanonicallyEqualTextIsNotShown() async {
        let (window, view) = host("caf\u{E9}\n")
        let snapshot = "cafe\u{301}\n"
        let whole = NSRange(location: 0, length: (snapshot as NSString).length)
        await view.review([(whole, "CAFE\u{301}\n")], of: snapshot, named: "Upcase").value
        #expect(view.pendingReview == nil)
        #expect(Array(view.string.utf16) == Array("caf\u{E9}\n".utf16))
        #expect(messages.all == ["Upcase finished after the note changed, so its result was not shown."])
        close(window, view)
    }

    @Test func aNoteRecomposedWhileTheDiffIsWorkedOutIsNotReviewed() async {
        let source = "cafe\u{301}\n"
        let (window, view) = host(source)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        let review = view.review([(whole, "CAFE\u{301}\n")], of: source, named: "Upcase")
        recompose(view, at: 3)
        await review.value
        #expect(view.pendingReview == nil)
        #expect(messages.all == ["Upcase finished after the note changed, so its result was not shown."])
        close(window, view)
    }

    /// The built-in command, applied at once: the selection is put back
    /// where it was, so only the text's code units tell the two apart.
    @Test func aBuiltInCommandLeavesANoteRecomposedMeanwhileAlone() async {
        let source = "e\u{301}\n" + Self.table
        let (window, view) = host(source)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let running = view.run(.cleanUpPastedText)
        recompose(view, at: 0)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        await running.value
        #expect(Array(view.string.utf16) == Array(("\u{E9}\n" + Self.table).utf16), "nothing was applied")
        #expect(messages.all == ["The note changed while Clean Up Pasted Text ran, so it was left as it is."])
        close(window, view)
    }

    /// A script in the service, applied at once. The script is slow on
    /// purpose, so the note changes while it runs.
    @Test func aScriptLeavesANoteRecomposedMeanwhileAlone() async throws {
        let slow = """
        /**
        {"api":1,"name":"Slow Upcase"}
        **/
        function main(state) {
            var end = Date.now() + 1000
            while (Date.now() < end) {}
            state.text = state.text.toUpperCase()
        }
        """
        let script = try BoopScript.parse(slow, id: "user/SlowUpcase.js", bundled: false).get()
        let (window, view) = host("cafe\u{301}\n")
        let running = Task { await view.run(script, with: LiveScriptRunner()) }
        // The run has read the note and is waiting on the service.
        try await Task.sleep(for: .milliseconds(100))
        recompose(view, at: 3)
        await running.value
        #expect(Array(view.string.utf16) == Array("caf\u{E9}\n".utf16), "nothing was applied")
        #expect(messages.all == ["Slow Upcase finished after the note changed, so its result was not applied."])
        close(window, view)
    }

    /// A script runs in the service for a moment. Another note loaded
    /// meanwhile is another note even when its text is the same, so the
    /// result made for the first is not shown over it.
    @Test func aResultMadeBeforeAnotherNoteWasLoadedIsNotShown() async {
        let source = "b\na\n"
        let (window, view) = host(source)
        let started = view.documentGeneration
        view.load(source, syntax: .plain)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        await view.review([(whole, "a\nb\n")], of: source, named: "Sort Lines", generation: started).value
        #expect(view.pendingReview == nil)
        #expect(messages.all == ["Sort Lines finished after the note changed, so its result was not shown."])
        close(window, view)
    }

    @Test func aResultForATextTheNoteNoLongerHasIsNotShown() async {
        let (window, view) = host("new text\n")
        await view.review([(NSRange(location: 0, length: 4), "x")], of: "old text\n", named: "Upcase").value
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
        await view.review([(whole, "other\n")], of: source, named: "Other").value
        #expect(view.pendingReview?.name == first.name, "the open review stays")
        #expect(messages.all == ["Other could not show its changes while another sheet is open."])
        close(window, view)
    }

    /// The script picker is a sheet on the same window and is still
    /// closing when a fast script's result arrives: the review waits for
    /// it and is shown, not refused.
    @Test func aReviewWaitsForASheetThatIsClosing() async throws {
        let source = "b\na\n"
        let (window, view) = host(source)
        let picker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        picker.isReleasedWhenClosed = false
        window.beginSheet(picker, completionHandler: nil)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        let review = view.review([(whole, "a\nb\n")], of: source, named: "Sort Lines")
        #expect(view.pendingReview == nil, "not over the picker")
        window.endSheet(picker)
        await review.value
        #expect(try #require(view.pendingReview).name == "Sort Lines")
        #expect(messages.all.isEmpty)
        view.keepPendingReview()
        #expect(view.string == "a\nb\n")
        close(window, view)
    }

    @Test func aReviewGivesUpOnASheetThatStays() async {
        let source = "b\na\n"
        let (window, view) = host(source)
        view.reviewSheetWait = .milliseconds(150)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        window.beginSheet(other, completionHandler: nil)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        await view.review([(whole, "a\nb\n")], of: source, named: "Sort Lines").value
        #expect(view.pendingReview == nil)
        #expect(view.string == source)
        #expect(messages.all == ["Sort Lines could not show its changes while another sheet is open."])
        window.endSheet(other)
        close(window, view)
    }

    @Test func aNoteThatChangesWhileTheDiffIsWorkedOutIsNotReviewed() async {
        let source = "b\na\n"
        let (window, view) = host(source)
        let whole = NSRange(location: 0, length: (source as NSString).length)
        let review = view.review([(whole, "a\nb\n")], of: source, named: "Sort Lines")
        view.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        await review.value
        #expect(view.pendingReview == nil)
        #expect(messages.all == ["Sort Lines finished after the note changed, so its result was not shown."])
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
