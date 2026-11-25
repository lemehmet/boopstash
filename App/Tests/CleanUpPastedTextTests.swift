import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Edit ▸ Clean Up Pasted Text (#244) in a real editor: the whole note or
/// the selection, one undoable edit, and nothing touched when there is
/// nothing to clean. What the passes do is tested in Core.
@MainActor
@Suite(.serialized)
struct CleanUpPastedTextTests {
    static let table = "  ┌───┬───┐  \n  │ a │ b │\n  │ c │ d │\n  └───┴───┘\n"
    static let cleaned = "| a | b |\n| --- | --- |\n| c | d |\n"

    func host(_ text: String) -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text, syntax: .plain)
        return (window, view)
    }

    @Test func theWholeNoteIsCleanedAndUndoesInOneStep() async {
        let source = "  Counts:  \n" + Self.table
        let (window, view) = host(source)
        #expect(view.undoManager?.canUndo == false)
        await view.run(.cleanUpPastedText).value
        #expect(view.string == "Counts:\n" + Self.cleaned)
        #expect(view.undoManager?.undoActionName == "Clean Up Pasted Text")
        view.undoManager?.undo()
        #expect(view.string == source)
        #expect(view.undoManager?.canUndo == false, "it was one step")
        window.close()
    }

    @Test func onlyTheSelectionChanges() async {
        let before = "  kept as it is  \n\n"
        let after = "\n  and this too  \n"
        let source = before + Self.table + after
        let (window, view) = host(source)
        view.setSelectedRange(NSRange(location: (before as NSString).length, length: (Self.table as NSString).length))
        await view.run(.cleanUpPastedText).value
        #expect(view.string == before + Self.cleaned + after)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == Self.cleaned, "the result stays selected")
        view.undoManager?.undo()
        #expect(view.string == source)
        window.close()
    }

    /// A table selected inside a code fence is as safe as it is when the
    /// whole note is cleaned.
    @Test func aSelectionInsideACodeFenceKeepsItsTable() async {
        let before = "```text\n"
        let table = "┌───┬───┐\n│ a │ b │\n│ c │ d │\n└───┴───┘\n"
        let source = before + table + "```\n"
        let (window, view) = host(source)
        var message: String?
        view.showMessage = { message = $0 }
        view.setSelectedRange(NSRange(location: (before as NSString).length, length: (table as NSString).length))
        await view.run(.cleanUpPastedText).value
        #expect(view.string == source)
        #expect(message == "Nothing to clean up.")
        window.close()
    }

    @Test func aNoteWithNothingToCleanIsUntouchedAndSaysSo() async {
        let source = "# Title\n\nClean already.\n\n" + Self.cleaned
        let (window, view) = host(source)
        var message: String?
        view.showMessage = { message = $0 }
        await view.run(.cleanUpPastedText).value
        #expect(view.string == source)
        #expect(view.undoManager?.canUndo == false, "nothing joined the undo stack")
        #expect(message == "Nothing to clean up.")
        // The same with a selection that is clean, in a note that is not.
        view.load("  indented\n" + source, syntax: .plain)
        message = nil
        view.setSelectedRange(NSRange(location: ("  indented\n" as NSString).length, length: (source as NSString).length))
        await view.run(.cleanUpPastedText).value
        #expect(view.string == "  indented\n" + source)
        #expect(view.undoManager?.canUndo == false)
        #expect(message == "Nothing to clean up.")
        window.close()
    }

    /// The picker's entry runs the same command, without the script
    /// service.
    @Test func thePickerOffersItAndRunsItNatively() async throws {
        let entry = try #require(ScriptLibrary.all(userFolder: nil).scripts.first { $0.name == "Clean Up Pasted Text" })
        #expect(entry.builtIn == .cleanUpPastedText)
        let (window, view) = host(Self.table)
        await view.run(entry, with: LiveScriptRunner())
        #expect(view.string == Self.cleaned)
        #expect(view.undoManager?.undoActionName == "Clean Up Pasted Text")
        window.close()
    }

    @Test func theMenuItemNeedsAnEditableNote() async {
        let (window, view) = host(Self.table)
        let item = NSMenuItem(title: "Clean Up Pasted Text", action: #selector(BoopTextView.cleanUpPastedText(_:)), keyEquivalent: "")
        #expect(view.validateUserInterfaceItem(item))
        view.isEditable = false
        #expect(!view.validateUserInterfaceItem(item))
        await view.run(.cleanUpPastedText).value
        #expect(view.string == Self.table)
        window.close()
    }

    /// An edit made while the clean-up runs wins.
    @Test func anEditMeanwhileIsKept() async {
        let (window, view) = host(Self.table)
        var message: String?
        view.showMessage = { message = $0 }
        let running = view.run(.cleanUpPastedText)
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        await running.value
        #expect(view.string == "x" + Self.table)
        #expect(message == "The note changed while Clean Up Pasted Text ran, so it was left as it is.")
        window.close()
    }
}
