import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Find and replace in the editor, VS Code's way: the widget, its
/// keyboard, and the edits it makes.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FindTests {
    typealias Host = BoopTextViewTests.Host

    /// Searches run off the main thread; wait for the count.
    func matches(of host: Host, _ count: Int) async throws -> Bool {
        try await eventually { host.view.find.matches.count == count }
    }

    init() {
        FindController.lastQuery = FindQuery()
        FindController.lastReplacement = ""
    }

    @Test func findOpensSeededFromTheSelectionAndFocusesTheQuery() async throws {
        let host = Host("alpha beta alpha gamma")
        host.view.setSelectedRange(NSRange(location: 6, length: 4))
        host.view.perform(.find)
        let find = host.view.find
        #expect(find.isShown)
        #expect(find.query.text == "beta")
        #expect(find.panel?.hasFocus == true)
        #expect(try await matches(of: host, 1))
        #expect(host.view.selectedRange() == NSRange(location: 6, length: 4), "the selection is the current match")
        #expect(find.panel?.count.stringValue == "1 of 1")
        host.close()
    }

    @Test func findSeedsFromTheWordAtTheCaret() async throws {
        let host = Host("one two\nthree")
        host.view.setSelectedRange(NSRange(location: 5, length: 0))
        host.view.perform(.find)
        #expect(host.view.find.query.text == "two")
        host.close()
    }

    @Test func punctuationAtTheCaretSeedsNothing() async throws {
        let host = Host("the end.")
        host.view.setSelectedRange(NSRange(location: 8, length: 0))
        host.view.perform(.find)
        #expect(host.view.find.query.text == "")
        host.close()
    }

    @Test func typingSelectsTheFirstMatchAfterTheCaret() async throws {
        let host = Host("x1 x2 x3")
        host.view.setSelectedRange(NSRange(location: 3, length: 0))
        host.view.find.show(replace: false)
        host.view.find.setQueryText("x")
        #expect(try await matches(of: host, 3))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 3, length: 1) })
        host.close()
    }

    @Test func nextAndPreviousWrapAround() async throws {
        let host = Host("ab ab ab")
        host.view.setSelectedRange(NSRange(location: 0, length: 0))
        host.view.find.show(replace: false)
        host.view.find.setQueryText("ab")
        #expect(try await matches(of: host, 3))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 0, length: 2) })
        host.view.perform(.findNext)
        #expect(host.view.selectedRange() == NSRange(location: 3, length: 2))
        host.view.perform(.findNext)
        host.view.perform(.findNext)
        #expect(host.view.selectedRange() == NSRange(location: 0, length: 2), "wrapped")
        host.view.perform(.findPrevious)
        #expect(host.view.selectedRange() == NSRange(location: 6, length: 2), "wrapped back")
        #expect(host.view.find.panel?.count.stringValue == "3 of 3")
        host.close()
    }

    @Test func findNextWithTheWidgetClosedOpensItWithoutFocus() async throws {
        let host = Host("k k k")
        host.view.setSelectedRange(NSRange(location: 0, length: 1))
        host.view.perform(.findNext)
        let find = host.view.find
        #expect(find.isShown)
        #expect(find.query.text == "k")
        #expect(find.panel?.hasFocus == false)
        #expect(host.window.firstResponder === host.view)
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 2, length: 1) })
        host.close()
    }

    @Test func optionsChangeTheMatches() async throws {
        let host = Host("Cat cat concat")
        host.view.find.show(replace: false)
        host.view.find.setQueryText("cat")
        #expect(try await matches(of: host, 3))
        host.view.perform(.toggleMatchCase)
        #expect(try await matches(of: host, 2))
        host.view.perform(.toggleWholeWord)
        #expect(try await matches(of: host, 1))
        host.view.perform(.toggleRegex)
        host.view.find.setQueryText("c(")
        #expect(try await eventually { host.view.find.error != nil })
        #expect(host.view.find.panel?.count.stringValue == "Invalid regular expression")
        host.close()
    }

    @Test func replaceReplacesTheCurrentMatchAndMovesOn() async throws {
        let host = Host("red red red")
        host.view.setSelectedRange(NSRange(location: 0, length: 0))
        host.view.find.show(replace: true)
        host.view.find.setQueryText("red")
        host.view.find.setReplacement("blue")
        #expect(try await matches(of: host, 3))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 0, length: 3) })
        host.view.find.replaceCurrent()
        #expect(host.view.string == "blue red red")
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 5, length: 3) }, "the next match is selected")
        #expect(host.view.undoManager?.undoActionName == "Replace")
        host.view.undoManager?.undo()
        #expect(host.view.string == "red red red")
        host.view.undoManager?.redo()
        #expect(host.view.string == "blue red red")
        host.view.setSelectedRange(NSRange(location: 5, length: 3))
        host.view.find.replaceCurrent()
        #expect(host.view.string == "blue blue red")
        host.close()
    }

    @Test func replaceOffAMatchOnlyFindsOne() async throws {
        let host = Host("a b a")
        host.view.setSelectedRange(NSRange(location: 2, length: 1))
        host.view.find.show(replace: true)
        host.view.find.setQueryText("a")
        host.view.find.setReplacement("z")
        #expect(try await matches(of: host, 2))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 4, length: 1) })
        host.view.setSelectedRange(NSRange(location: 2, length: 1))
        host.view.find.replaceCurrent()
        #expect(host.view.string == "a b a", "nothing was replaced unseen")
        #expect(host.view.selectedRange() == NSRange(location: 4, length: 1))
        host.close()
    }

    @Test func replaceAllIsOneUndoStepAndKeepsTheCaret() async throws {
        let host = Host("2026-11-05 and 1999-01-02")
        host.view.setSelectedRange(NSRange(location: 14, length: 0)) // after the first date and " and"
        host.view.find.show(replace: true)
        host.view.perform(.toggleRegex)
        host.view.find.setQueryText(#"(\d+)-(\d+)-(\d+)"#)
        host.view.find.setReplacement("$3/$2/$1")
        #expect(try await matches(of: host, 2))
        host.view.setSelectedRange(NSRange(location: 14, length: 0))
        host.view.find.replaceAll()
        #expect(try await eventually { host.view.string == "05/11/2026 and 02/01/1999" })
        #expect(host.view.selectedRange() == NSRange(location: 14, length: 0))
        #expect(host.view.undoManager?.undoActionName == "Replace All")
        host.view.undoManager?.undo()
        #expect(host.view.string == "2026-11-05 and 1999-01-02")
        host.close()
    }

    @Test func escapeClosesAndReturnsTheKeyboardToTheEditor() async throws {
        let host = Host("find me")
        host.view.setSelectedRange(NSRange(location: 0, length: 4))
        host.view.perform(.find)
        #expect(host.view.find.panel?.hasFocus == true)
        host.view.find.hide()
        #expect(!host.view.find.isShown)
        #expect(host.view.find.panel?.isHidden == true)
        #expect(host.window.firstResponder === host.view)
        #expect(host.view.selectedRange() == NSRange(location: 0, length: 4), "the selection stays on the match")
        host.close()
    }

    @Test func menuItemsDriveTheWidget() async throws {
        let host = Host("menu menu")
        host.view.setSelectedRange(NSRange(location: 5, length: 4))
        let item = NSMenuItem()
        item.action = #selector(NSResponder.performTextFinderAction(_:))
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(host.view.validateUserInterfaceItem(item))
        host.view.performTextFinderAction(item)
        #expect(host.view.find.isShown)
        #expect(host.view.find.query.text == "menu")
        item.tag = NSTextFinder.Action.nextMatch.rawValue
        #expect(try await matches(of: host, 2))
        host.view.performTextFinderAction(item)
        #expect(host.view.selectedRange() == NSRange(location: 0, length: 4))
        item.tag = NSTextFinder.Action.hideFindInterface.rawValue
        host.view.performTextFinderAction(item)
        #expect(!host.view.find.isShown)
        #expect(!host.view.usesFindBar, "AppKit's bar is replaced, not doubled")
        host.close()
    }

    @Test func aMatchInAFoldIsRevealed() async throws {
        let host = Host("# Heading\nhidden needle\n\n# Other\n")
        host.view.load(host.view.string, syntax: .language(.markdown))
        #expect(try await eventually { !host.view.folding.regions.isEmpty })
        host.view.setSelectedRange(NSRange(location: 0, length: 0))
        host.view.folding.foldAll()
        #expect(host.view.folding.isHidden(1))
        host.view.find.show(replace: false)
        host.view.find.setQueryText("needle")
        #expect(try await matches(of: host, 1))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 17, length: 6) })
        #expect(!host.view.folding.isHidden(1))
        host.close()
    }

    // MARK: Round 1 of the review (#236)

    @Test func replaceAllIsDroppedWhenAnotherNoteLoadsWithTheSameText() async throws {
        let host = Host("same same")
        host.view.find.show(replace: true)
        host.view.find.setQueryText("same")
        host.view.find.setReplacement("other")
        #expect(try await matches(of: host, 2))
        host.view.find.replaceAll()
        // Another note, with the very same text, before the worker returns.
        host.view.load("same same")
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.string == "same same")
        host.close()
    }

    @Test func inSelectionActionsAreRefused() {
        let host = Host("a a")
        host.view.setSelectedRange(NSRange(location: 0, length: 1))
        let item = NSMenuItem()
        item.action = #selector(NSResponder.performTextFinderAction(_:))
        item.tag = NSTextFinder.Action.replaceAllInSelection.rawValue
        #expect(!host.view.validateUserInterfaceItem(item))
        item.tag = NSTextFinder.Action.replaceAll.rawValue
        #expect(host.view.validateUserInterfaceItem(item))
        host.close()
    }

    @Test func findPreviousWithTheWidgetClosedStepsBack() async throws {
        let host = Host("k k k")
        host.view.setSelectedRange(NSRange(location: 4, length: 1))
        host.view.perform(.findPrevious)
        #expect(host.view.find.isShown)
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 2, length: 1) })
        host.close()
    }

    @Test func replaceAllAndTheTogglesNeedTheWidget() async throws {
        let first = Host("a a")
        first.view.find.show(replace: true)
        first.view.find.setQueryText("a")
        first.view.find.setReplacement("b")
        first.close()
        // The next editor inherits the query, out of sight.
        let host = Host("a a")
        #expect(host.view.find.query.text == "a")
        host.view.perform(.replaceAll)
        host.view.perform(.toggleMatchCase)
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.string == "a a")
        #expect(!host.view.find.query.matchCase)
        host.close()
    }

    @Test func matchesUnderAttachmentChipsAreSkipped() async throws {
        let host = Host()
        host.view.attachmentURL = { _ in nil }
        host.view.load("x " + AttachmentReference.markdown(for: UUID(), alt: "x inside") + " x")
        #expect(!host.view.chipRanges.isEmpty)
        host.view.find.show(replace: false)
        host.view.find.setQueryText("x")
        #expect(try await matches(of: host, 2))
        #expect(host.view.find.matches.allSatisfy { match in !host.view.chipRanges.contains { NSIntersectionRange($0, match).length > 0 } })
        host.close()
    }

    @Test func steppingRightAfterAnEditWaitsForTheNewMatches() async throws {
        let host = Host("ab ab ab")
        host.view.find.show(replace: false)
        host.view.find.setQueryText("ab")
        #expect(try await matches(of: host, 3))
        host.view.setSelectedRange(NSRange(location: 6, length: 2))
        // The tail goes, with the old third match; Enter at once must not
        // select a range past the end.
        host.view.insertText("", replacementRange: NSRange(location: 5, length: 3))
        host.view.perform(.findNext)
        #expect(NSMaxRange(host.view.selectedRange()) <= (host.view.string as NSString).length)
        #expect(try await matches(of: host, 2))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 0, length: 2) }, "wrapped to the first match of the new text")
        host.close()
    }

    @Test func aFocusedWidgetFieldCountsAsTheEditor() {
        let host = Host("focus")
        host.view.perform(.find)
        #expect(host.view.find.panel?.hasFocus == true)
        #expect(BoopTextView.editor(for: host.window.firstResponder) === host.view)
        host.view.find.hide()
        #expect(BoopTextView.editor(for: host.window.firstResponder) === host.view)
        host.close()
    }

    // MARK: Round 2 of the review (#236)

    @Test func replaceAdvancesPastAZeroLengthMatch() async throws {
        let host = Host("one\ntwo")
        host.view.setSelectedRange(NSRange(location: 0, length: 0))
        host.view.find.show(replace: true)
        host.view.perform(.toggleRegex)
        host.view.find.setQueryText("$")
        host.view.find.setReplacement("-")
        #expect(try await matches(of: host, 2))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 3, length: 0) })
        host.view.find.replaceCurrent()
        #expect(host.view.string == "one-\ntwo")
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 8, length: 0) }, "the next line's end, not the same one again")
        host.view.find.replaceCurrent()
        #expect(host.view.string == "one-\ntwo-")
        host.close()
    }

    @Test func openingReplaceKeepsAnActiveRegexQuery() async throws {
        let host = Host("id 123 and 45")
        host.view.find.show(replace: false)
        host.view.perform(.toggleRegex)
        host.view.find.setQueryText(#"\d+"#)
        #expect(try await matches(of: host, 2))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 3, length: 3) })
        host.view.perform(.findAndReplace)
        #expect(host.view.find.query.text == #"\d+"#)
        #expect(host.view.find.replaceShown)
        // From the editor, on something other than the match, ⌘F seeds.
        host.window.makeFirstResponder(host.view)
        host.view.setSelectedRange(NSRange(location: 0, length: 2))
        host.view.perform(.find)
        #expect(host.view.find.query.text == "id")
        host.close()
    }

    @Test func replaceAllCountsOnlyWhatChanged() async throws {
        let host = Host("a a")
        var messages: [String] = []
        host.view.showMessage = { messages.append($0) }
        host.view.find.show(replace: true)
        host.view.find.setQueryText("a")
        host.view.find.setReplacement("a")
        #expect(try await matches(of: host, 2))
        host.view.find.replaceAll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.string == "a a")
        #expect(messages.isEmpty, "nothing was replaced, so nothing is announced")
        #expect(host.view.undoManager?.canUndo == false)
        host.close()
    }

    @Test func aLineBreakInTheQueryFieldStepsBack() async throws {
        let host = Host("q q q")
        host.view.setSelectedRange(NSRange(location: 2, length: 1))
        host.view.find.show(replace: false)
        host.view.find.setQueryText("q")
        #expect(try await matches(of: host, 3))
        #expect(try await eventually { host.view.selectedRange() == NSRange(location: 2, length: 1) })
        let panel = try #require(host.view.find.panel)
        let editor = try #require(host.window.firstResponder as? NSTextView)
        #expect(panel.control(panel.queryField, textView: editor, doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
        #expect(host.view.selectedRange() == NSRange(location: 0, length: 1))
        #expect(host.view.find.query.text == "q", "no line break entered the query")
        host.close()
    }

    @Test func theQueryCarriesOverToTheNextEditor() async throws {
        let first = Host("carry")
        first.view.find.show(replace: false)
        first.view.find.setQueryText("carry")
        first.view.find.setReplacement("over")
        first.close()
        let second = Host("carry on")
        second.view.setSelectedRange(NSRange(location: 8, length: 0))
        // Without the keyboard, nothing is seeded from the caret's word.
        second.view.find.show(replace: true, focus: false)
        #expect(second.view.find.query.text == "carry")
        #expect(second.view.find.replacement == "over")
        second.close()
    }
}
