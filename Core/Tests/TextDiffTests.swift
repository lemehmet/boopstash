import Foundation
import Testing
@testable import BoopstashCore

@Suite struct TextDiffTests {
    /// A diff the way `diff -u` prints it, for compact expectations:
    /// " " kept, "-" removed, "+" added, hunks separated by "@@".
    func unified(_ old: String, _ new: String, context: Int = 3) -> String {
        TextDiff.hunks(old: old, new: new, context: context).map { hunk in
            hunk.lines.map { line in
                let mark = switch line.kind {
                case .unchanged: " "
                case .removed: "-"
                case .added: "+"
                }
                return mark + line.text
            }.joined(separator: "\n")
        }.joined(separator: "\n@@\n")
    }

    func marked(_ line: TextDiff.Line) -> [String] {
        line.changes.map { (line.text as NSString).substring(with: $0) }
    }

    @Test func equalTextsHaveNoHunks() {
        #expect(TextDiff.hunks(old: "a\nb\n", new: "a\nb\n").isEmpty)
        #expect(TextDiff.hunks(old: "", new: "").isEmpty)
        #expect(TextDiff.summary(of: []).description == "No changes")
    }

    @Test func anInsertedLineComesWithItsContext() {
        #expect(unified("a\nb\nc\n", "a\nb\nnew\nc\n") == " a\n b\n+new\n c")
    }

    @Test func aDeletedLine() {
        #expect(unified("a\nb\nc\n", "a\nc\n") == " a\n-b\n c")
    }

    @Test func aReplacedLineShowsTheOldThenTheNew() {
        #expect(unified("a\nb\nc\n", "a\nB\nc\n") == " a\n-b\n+B\n c")
    }

    @Test func aChangedStretchListsItsRemovalsBeforeItsAdditions() {
        #expect(unified("one\ntwo\nthree\n", "uno\ndos\ntres\n") == "-one\n-two\n-three\n+uno\n+dos\n+tres")
    }

    @Test func farApartChangesAreSeparateHunksAndNearOnesShareOne() {
        let old = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let far = old.replacingOccurrences(of: "line 2\n", with: "LINE 2\n").replacingOccurrences(of: "line 25\n", with: "LINE 25\n")
        let hunks = TextDiff.hunks(old: old, new: far, context: 3)
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.first?.text == "line 1")
        #expect(hunks[0].lines.last?.text == "line 5", "three lines of context after the change")
        #expect(hunks[1].lines.first?.text == "line 22")
        #expect(hunks[1].lines.last?.text == "line 28")

        let near = old.replacingOccurrences(of: "line 2\n", with: "LINE 2\n").replacingOccurrences(of: "line 9\n", with: "LINE 9\n")
        #expect(TextDiff.hunks(old: old, new: near, context: 3).count == 1, "six unchanged lines between them: their contexts meet")
        let apart = old.replacingOccurrences(of: "line 2\n", with: "LINE 2\n").replacingOccurrences(of: "line 10\n", with: "LINE 10\n")
        #expect(TextDiff.hunks(old: old, new: apart, context: 3).count == 2, "seven unchanged lines: one is in neither context")
    }

    @Test func noContextGivesOnlyTheChanges() {
        #expect(unified("a\nb\nc\nd\n", "a\nB\nc\nD\n", context: 0) == "-b\n+B\n@@\n-d\n+D")
    }

    @Test func lineNumbersCountFromTheFirstLineAsked() {
        let lines = TextDiff.lines(old: "a\nb\nc\n", new: "a\nx\ny\nc\n", firstLine: 10)
        #expect(lines.map(\.oldNumber) == [10, 11, nil, nil, 12])
        #expect(lines.map(\.newNumber) == [10, nil, 11, 12, 13])
    }

    @Test func aMovedBlockIsRemovedInOnePlaceAndAddedInTheOther() {
        let old = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
        let new = "delta\nepsilon\nalpha\nbeta\ngamma\n"
        let lines = TextDiff.lines(old: old, new: new)
        #expect(lines.filter { $0.kind == .unchanged }.map(\.text) == ["alpha", "beta", "gamma"], "the longer run stays")
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["delta", "epsilon"])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["delta", "epsilon"])
        #expect(TextDiff.lines(old: old, new: new) == lines, "the same answer every time")
    }

    @Test func repeatedLinesDoNotPairWithTheWrongNeighbour() {
        let old = "{\n  a\n}\n{\n  b\n}\n"
        let new = "{\n  a\n}\n{\n  c\n}\n{\n  b\n}\n"
        let lines = TextDiff.lines(old: old, new: new)
        #expect(lines.count(where: { $0.kind == .unchanged }) == 6, "both old blocks stay whole")
        #expect(lines.filter { $0.kind == .added }.map(\.text).sorted() == ["  c", "{", "}"])
        #expect(TextDiff.summary(of: TextDiff.hunks(old: old, new: new)) == TextDiff.Summary(removed: 0, added: 3))
    }

    @Test func emptyBeforeOrAfter() {
        #expect(unified("", "a\nb\n") == "+a\n+b")
        #expect(unified("a\nb\n", "") == "-a\n-b")
    }

    // MARK: Endings

    @Test func aFinalNewlineGainedOrLostIsAChangeOfThatLine() {
        let lines = TextDiff.lines(old: "a\nb", new: "a\nb\n")
        #expect(lines.map(\.kind) == [.unchanged, .removed, .added])
        #expect(lines[1].ending == .none)
        #expect(lines[2].ending == .lf)
        #expect(lines[1].endingChanged && lines[2].endingChanged)
        #expect(lines[1].changes.isEmpty && lines[2].changes.isEmpty, "no word differs")
        #expect(TextDiff.hunks(old: "a\nb", new: "a\nb").isEmpty, "the same missing newline on both sides is no change")
    }

    @Test func carriageReturnLineFeedIsOneEndingAndDiffersFromLineFeed() {
        #expect(TextDiff.split("a\r\nb\r\n") == [.init(text: "a", ending: .crlf), .init(text: "b", ending: .crlf)])
        #expect(TextDiff.hunks(old: "a\r\nb\r\n", new: "a\r\nb\r\n").isEmpty)
        let lines = TextDiff.lines(old: "a\r\nb\r\n", new: "a\nb\r\n")
        #expect(lines.map(\.kind) == [.removed, .added, .unchanged])
        #expect(lines[0].text == "a" && lines[1].text == "a", "the ending is not in the text")
        #expect(lines[0].endingChanged && lines[1].endingChanged)
    }

    @Test func aLoneCarriageReturnStaysInItsLine() {
        #expect(TextDiff.split("a\rb\nc\r") == [.init(text: "a\rb", ending: .lf), .init(text: "c\r", ending: .none)])
    }

    @Test func emptyLinesAreLines() {
        #expect(TextDiff.split("a\n\nb") == [.init(text: "a", ending: .lf), .init(text: "", ending: .lf), .init(text: "b", ending: .none)])
        #expect(TextDiff.split("\n") == [.init(text: "", ending: .lf)])
        #expect(TextDiff.split("").isEmpty)
        #expect(unified("a\nb\n", "a\n\nb\n") == " a\n+\n b")
    }

    // MARK: Words

    @Test func aChangedLineMarksTheWordsThatDiffer() {
        let lines = TextDiff.lines(old: "let count = items.count\n", new: "let total = items.count\n")
        #expect(marked(lines[0]) == ["count"])
        #expect(marked(lines[1]) == ["total"])
    }

    @Test func insertedWordsAreMarkedOnTheNewLineOnly() {
        let lines = TextDiff.lines(old: "#define A 1\n", new: "#define REG_A (1)\n")
        #expect(marked(lines[0]) == ["A"])
        #expect(marked(lines[1]) == ["REG_A", "(", ")"])
    }

    @Test func aWhitespaceOnlyChangeMarksTheWhitespace() {
        let lines = TextDiff.lines(old: "a  b\n", new: "a b\n")
        #expect(lines.map(\.kind) == [.removed, .added])
        #expect(marked(lines[0]) == ["  "])
        #expect(marked(lines[1]) == [" "])
        let trailing = TextDiff.lines(old: "a \n", new: "a\n")
        #expect(marked(trailing[0]) == [" "])
        #expect(trailing[1].changes.isEmpty)
    }

    @Test func linesWithLittleInCommonAreNotMarked() {
        let lines = TextDiff.lines(old: "the quick brown fox\n", new: "return nil\n")
        #expect(lines[0].changes.isEmpty && lines[1].changes.isEmpty)
    }

    @Test func marksAreUTF16RangesAlsoPastAnEmoji() {
        let lines = TextDiff.lines(old: "🙂 old value\n", new: "🙂 new value\n")
        #expect(marked(lines[0]) == ["old"])
        #expect(lines[0].changes == [NSRange(location: 3, length: 3)])
    }

    @Test func unpairedLinesOfAStretchHaveNoMarks() {
        let lines = TextDiff.lines(old: "a = 1\n", new: "a = 2\nb = 3\n")
        #expect(lines.map(\.kind) == [.removed, .added, .added])
        #expect(marked(lines[1]) == ["2"])
        #expect(lines[2].changes.isEmpty)
    }

    // MARK: Code units

    /// Swift's string equality takes a precomposed "é" and "e" with a
    /// combining accent for equal. A change between them is a change of
    /// the text, and shows.
    @Test func canonicallyEquivalentTextIsStillAChange() {
        let composed = "the caf\u{E9} is open\nZ\n"
        let decomposed = "the cafe\u{301} is open\nZ\n"
        #expect(composed == decomposed, "equal to Swift")
        let lines = TextDiff.lines(old: decomposed, new: composed)
        #expect(lines.map(\.kind) == [.removed, .added, .unchanged])
        #expect(!lines[0].changes.isEmpty && !lines[1].changes.isEmpty, "the word that changed is marked")
        #expect(TextDiff.hunks(old: composed, new: composed).isEmpty)
    }

    /// A pair of very long lines is not matched word by word past the
    /// word limit: it is shown as changed whole, with no marks.
    @Test func veryLongLinesAreChangedWholeAndNotMatchedWordByWord() {
        // Words that all differ in the middle of the line, so nothing
        // anchors and trimming the ends leaves the whole middle.
        let old = "start " + (0..<200).map { _ in "a b" }.joined(separator: " ") + " end"
        let new = "start " + (0..<200).map { _ in "b a" }.joined(separator: " ") + " end"
        #expect(TextDiff.tokens(old).count * TextDiff.tokens(new).count > TextDiff.wordExactLimit)
        let (removed, added) = TextDiff.wordChanges(old, new)
        #expect(removed.isEmpty && added.isEmpty)
        // A short pair of the same shape is matched and marked.
        let (shortRemoved, shortAdded) = TextDiff.wordChanges("start a b a b end", "start b a b a end")
        #expect(!shortRemoved.isEmpty && !shortAdded.isEmpty)
    }

    // MARK: Summary

    @Test func theSummaryCountsLines() {
        func summary(_ old: String, _ new: String) -> String {
            TextDiff.summary(of: TextDiff.hunks(old: old, new: new)).description
        }
        #expect(summary("a\n", "a\nb\n") == "1 line added")
        #expect(summary("a\nb\nc\n", "a\n") == "2 lines removed")
        #expect(summary("a\nb\n", "A\nB\nC\n") == "2 lines removed, 3 added")
    }

    // MARK: Size

    /// The work is bounded by construction, which this pins without a
    /// clock: a stretch with no line in common larger than the exact
    /// limit is taken as replaced, not matched cell by cell.
    @Test func aLargeStretchWithNothingInCommonIsTakenAsReplaced() {
        let old = Array(0..<1_200)
        let new = Array(repeating: 5_000, count: 600) + Array(repeating: 5_001, count: 600)
        #expect(old.count * new.count > TextDiff.exactLimit)
        let steps = TextDiff.steps(old, new)
        #expect(steps.count == 2_400)
        #expect(steps.prefix(1_200).allSatisfy { if case .remove = $0 { true } else { false } })
    }

    @Test func fiveThousandLinesWithScatteredEdits() {
        var lines = (0..<5_000).map { "line number \($0) of the fixture" }
        let old = lines.joined(separator: "\n") + "\n"
        for index in stride(from: 10, to: 5_000, by: 250) { lines[index] = "changed \(index)" }
        lines.insert("inserted", at: 2_500)
        lines.remove(at: 4_000)
        let new = lines.joined(separator: "\n") + "\n"
        let summary = TextDiff.summary(of: TextDiff.hunks(old: old, new: new))
        #expect(summary == TextDiff.Summary(removed: 21, added: 21))
        // Every line is unique, so the anchors carry the whole match and
        // nothing is left to the exact matcher.
        let all = TextDiff.lines(old: old, new: new)
        #expect(all.count(where: { $0.kind == .unchanged }) == 5_000 - 21)
    }

    @Test func aStretchWithNoUniqueLineIsMatchedExactlyWhenSmall() {
        // Two lines alternating, shifted by one: nothing is unique and
        // neither end matches, so no anchor and no trimming help. The
        // exact matcher finds the one line that moved.
        let old = (0..<900).map { $0.isMultiple(of: 2) ? "x" : "y" }
        let new = (0..<900).map { $0.isMultiple(of: 2) ? "y" : "x" }
        #expect(old.count * new.count <= TextDiff.exactLimit)
        let summary = TextDiff.summary(of: TextDiff.hunks(old: old.joined(separator: "\n") + "\n", new: new.joined(separator: "\n") + "\n"))
        #expect(summary == TextDiff.Summary(removed: 1, added: 1))
    }
}
