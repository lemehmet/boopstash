import Foundation
import Testing
@testable import BoopstashCore

@Suite struct LineEditingTests {
    /// Applies an edit the way the text view does and returns the new text.
    func apply(_ edit: LineEditing.Edit?, to text: String) -> String? {
        guard let edit else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func lines(_ text: String, containing substring: String) -> NSRange {
        let ns = text as NSString
        return ns.lineRange(for: ns.range(of: substring))
    }

    @Test func mapLinesKeepsTheTrailingNewline() {
        #expect(LineEditing.mapLines("a\nb\n") { "> " + $0 } == "> a\n> b\n")
        #expect(LineEditing.mapLines("a\nb") { "> " + $0 } == "> a\n> b")
    }

    @Test func mapLinesKeepsEachLinesTerminator() {
        #expect(LineEditing.mapLines("a\r\nb\rc\u{2028}d") { "> " + $0 } == "> a\r\n> b\r> c\u{2028}> d")
        #expect(LineEditing.mapLines("") { "> " + $0 } == "")
    }

    @Test func spanningLinesUsesNSStringLineBreaks() {
        #expect(LineEditing.spansLines("a\rb", NSRange(location: 0, length: 3)))
        #expect(LineEditing.spansLines("a\u{2028}b", NSRange(location: 0, length: 3)))
        #expect(!LineEditing.spansLines("abc\ndef", NSRange(location: 1, length: 2)))
        // Selecting a line including its newline still counts as one line
        // being extended into the next, as in VS Code.
        #expect(LineEditing.spansLines("abc\ndef", NSRange(location: 0, length: 4)))
    }

    @Test func swapUpAndDownInTheMiddle() {
        let text = "one\ntwo\nthree\n"
        #expect(apply(LineEditing.swap(text, lines: lines(text, containing: "two"), up: true), to: text) == "two\none\nthree\n")
        #expect(apply(LineEditing.swap(text, lines: lines(text, containing: "two"), up: false), to: text) == "one\nthree\ntwo\n")
    }

    @Test func swappingTheUnterminatedLastLineKeepsLinesTerminated() {
        let text = "one\ntwo"
        #expect(apply(LineEditing.swap(text, lines: lines(text, containing: "two"), up: true), to: text) == "two\none")
        #expect(apply(LineEditing.swap(text, lines: lines(text, containing: "one"), up: false), to: text) == "two\none")
    }

    @Test func noSwapPastTheEnds() {
        let text = "one\ntwo"
        #expect(LineEditing.swap(text, lines: lines(text, containing: "one"), up: true) == nil)
        #expect(LineEditing.swap(text, lines: lines(text, containing: "two"), up: false) == nil)
    }

    @Test func caretShiftFollowsTheMovedLines() throws {
        let text = "alpha\nbe\ngamma\n"
        let up = try #require(LineEditing.swap(text, lines: lines(text, containing: "gamma"), up: true))
        #expect(up.caretShift == -3) // "be\n"
        let down = try #require(LineEditing.swap(text, lines: lines(text, containing: "alpha"), up: false))
        #expect(down.caretShift == 3)
    }

    @Test func multiLineBlocksMoveTogether() {
        let text = "a\nb\nc\nd\n"
        let block = NSRange(location: 2, length: 4) // "b\nc\n"
        #expect(apply(LineEditing.swap(text, lines: block, up: true), to: text) == "b\nc\na\nd\n")
        #expect(apply(LineEditing.swap(text, lines: block, up: false), to: text) == "a\nd\nb\nc\n")
    }

    @Test func utf16RangesHandleEmoji() {
        let text = "🙂 smile\nplain\n"
        #expect(apply(LineEditing.swap(text, lines: lines(text, containing: "plain"), up: true), to: text) == "plain\n🙂 smile\n")
    }

    // MARK: Terminators other than LF (#22)

    @Test(arguments: ["\r\n", "\r", "\u{2028}", "\u{2029}"])
    func swapKeepsEveryTerminator(_ t: String) throws {
        let text = "one\(t)two\(t)three"
        let up = try #require(LineEditing.swap(text, lines: lines(text, containing: "two"), up: true))
        #expect(apply(up, to: text) == "two\(t)one\(t)three")
        let down = try #require(LineEditing.swap(text, lines: lines(text, containing: "two"), up: false))
        #expect(apply(down, to: text) == "one\(t)three\(t)two", "the last line stays unterminated")
        #expect(down.caretShift == ("three" + t as NSString).length)
    }

    @Test func mixedTerminatorsStayInPlace() throws {
        let text = "a\r\nb\nc"
        let edit = try #require(LineEditing.swap(text, lines: lines(text, containing: "b"), up: true))
        #expect(apply(edit, to: text) == "b\r\na\nc")
    }

    @Test(arguments: ["\n", "\r\n", "\r", "\u{2028}"])
    func duplicateKeepsTheTerminator(_ t: String) {
        let text = "one\(t)two\(t)"
        #expect(apply(LineEditing.duplicate(text, lines: lines(text, containing: "one"), above: false), to: text) == "one\(t)one\(t)two\(t)")
        #expect(apply(LineEditing.duplicate(text, lines: lines(text, containing: "two"), above: true), to: text) == "one\(t)two\(t)two\(t)")
        let last = "one\(t)two"
        #expect(apply(LineEditing.duplicate(last, lines: lines(last, containing: "two"), above: false), to: last) == "one\(t)two\(t)two",
                "an unterminated last line borrows the line above's terminator")
    }

    @Test func duplicateMovesTheCaretOntoTheCopyBelow() {
        let text = "ab\ncd"
        let edit = LineEditing.duplicate(text, lines: lines(text, containing: "cd"), above: false)
        #expect(apply(edit, to: text) == "ab\ncd\ncd")
        #expect(edit.caretShift == 3) // "\ncd"
        #expect(LineEditing.duplicate("solo", lines: NSRange(location: 0, length: 4), above: false).replacement == "\nsolo")
    }
}
