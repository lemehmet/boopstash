import Foundation
import Testing
@testable import BoopstashCore

@Suite struct DiffReviewTests {
    func range(_ text: String, of part: String) -> NSRange {
        (text as NSString).range(of: part)
    }

    @Test func aWholeNoteEditIsOnePartNumberedFromOne() {
        let text = "a\nb\nc\n"
        let review = DiffReviewContent.make(fullText: text, edits: [(NSRange(location: 0, length: 6), "a\nB\nc\n")])
        #expect(review.parts.count == 1)
        #expect(review.parts[0].firstLine == 1)
        #expect(review.summary == TextDiff.Summary(removed: 1, added: 1))
        #expect(review.parts[0].hunks[0].lines.map(\.oldNumber) == [1, 2, nil, 3])
    }

    @Test func aSelectionIsDiffedAloneAndNumberedWhereItSits() {
        let text = "one\ntwo\nthree\nfour\n"
        let review = DiffReviewContent.make(fullText: text, edits: [(range(text, of: "three"), "THREE")])
        #expect(review.parts.count == 1)
        #expect(review.parts[0].firstLine == 3)
        let lines = review.parts[0].hunks.flatMap(\.lines)
        #expect(lines.map(\.text) == ["three", "THREE"], "no context from outside the selection")
        #expect(lines.map(\.kind) == [.removed, .added])
        #expect(lines[0].oldNumber == 3 && lines[1].newNumber == 3)
    }

    @Test func severalSelectionsAreSeveralPartsInTextOrder() {
        let text = "one\ntwo\nthree\nfour\n"
        let review = DiffReviewContent.make(fullText: text, edits: [(range(text, of: "four"), "4"), (range(text, of: "one"), "1")])
        #expect(review.parts.map(\.firstLine) == [1, 4])
        #expect(review.parts.map(\.id) == [0, 1])
        #expect(review.summary == TextDiff.Summary(removed: 2, added: 2))
    }

    /// A part after one that added lines sits lower in the result: its
    /// new-side numbers say where, its old-side numbers where it is now.
    @Test func laterPartsAreNumberedWhereTheyWouldSitAfterTheEarlierOnes() {
        let text = "one\ntwo\nthree\nfour\n"
        let review = DiffReviewContent.make(fullText: text, edits: [(range(text, of: "one"), "1\n1b"), (range(text, of: "four"), "4")])
        #expect(review.parts.map(\.firstLine) == [1, 4])
        let second = review.parts[1].hunks.flatMap(\.lines)
        #expect(second.map(\.oldNumber) == [4, nil])
        #expect(second.map(\.newNumber) == [nil, 5], "one line was added above it")
        #expect(second[1].spokenDescription == "Added, line 5: 4")

        let removing = DiffReviewContent.make(fullText: text, edits: [(range(text, of: "one\ntwo\n"), ""), (range(text, of: "four"), "4")])
        #expect(removing.parts[1].hunks.flatMap(\.lines).map(\.newNumber) == [nil, 2], "two lines were removed above it")
    }

    @Test func aReplacementThatChangesNothingHasNoPart() {
        let text = "one\ntwo\n"
        let same = DiffReviewContent.make(fullText: text, edits: [(range(text, of: "one"), "one")])
        #expect(same.isEmpty)
        #expect(same.summary.description == "No changes")
        let mixed = DiffReviewContent.make(fullText: text, edits: [(range(text, of: "one"), "one"), (range(text, of: "two"), "2")])
        #expect(mixed.parts.map(\.firstLine) == [2])
    }

    @Test func aRangeOutsideTheTextIsSkipped() {
        #expect(DiffReviewContent.make(fullText: "ab", edits: [(NSRange(location: 1, length: 5), "x")]).isEmpty)
    }

    @Test func lineNumbersCountLineFeedsBeforeTheLocation() {
        let text = "a\r\nb\n\nc" as NSString
        #expect(DiffReviewContent.lineNumber(of: 0, in: text) == 1)
        #expect(DiffReviewContent.lineNumber(of: 3, in: text) == 2)
        #expect(DiffReviewContent.lineNumber(of: 5, in: text) == 3)
        #expect(DiffReviewContent.lineNumber(of: 6, in: text) == 4)
        #expect(DiffReviewContent.lineNumber(of: 99, in: text) == 4)
    }

    @Test func linesAreSpokenWithWhatHappenedAndWhere() {
        let lines = TextDiff.lines(old: "a\nb\n", new: "a\nc\n\n", firstLine: 7)
        #expect(lines.map(\.spokenDescription) == [
            "Unchanged, line 7: a", "Removed, line 8: b", "Added, line 8: c", "Added, line 9: empty line",
        ])
        let ending = TextDiff.lines(old: "a", new: "a\n")
        #expect(ending[0].spokenDescription == "Removed, line 1: a, no newline at the end")
        #expect(ending[1].spokenDescription == "Added, line 1: a, ends with a line feed")
    }
}
