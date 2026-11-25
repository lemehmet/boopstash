import Foundation
import Testing
@testable import BoopstashCore

/// Recognised text rebuilt into the rows it has in the picture (#243).
/// Boxes are in pixels, y downwards; text is 20 high unless said.
@Suite struct TextRowsTests {
    func cell(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 60, height: CGFloat = 20) -> TextObservation {
        TextObservation(text: text, box: CGRect(x: x, y: y, width: width, height: height))
    }

    @Test func nothingGivesNothing() {
        #expect(TextRows.text(from: []) == "")
        #expect(TextRows.text(from: [cell("", x: 0, y: 0)]) == "", "an empty observation is no row")
    }

    @Test func aSingleColumnIsOneLineEach() {
        let lines = [cell("first line", x: 10, y: 10, width: 200), cell("second", x: 10, y: 40, width: 120), cell("third one", x: 10, y: 70, width: 180)]
        #expect(TextRows.text(from: lines) == "first line\nsecond\nthird one")
    }

    @Test func aGridIsTabSeparatedCellsInReadingOrder() {
        let grid = [
            cell("Name", x: 10, y: 10), cell("Qty", x: 200, y: 10), cell("Price", x: 400, y: 10),
            cell("Bolt", x: 10, y: 50), cell("12", x: 200, y: 50), cell("0.40", x: 400, y: 50),
        ]
        #expect(TextRows.text(from: grid) == "Name\tQty\tPrice\nBolt\t12\t0.40")
    }

    /// The recogniser's order is not relied on: right to left, bottom to
    /// top, or shuffled, the text comes out left to right, top to bottom.
    @Test func theOrderOfTheInputDoesNotMatter() {
        let grid = [
            cell("Name", x: 10, y: 10), cell("Qty", x: 200, y: 10), cell("Price", x: 400, y: 10),
            cell("Bolt", x: 10, y: 50), cell("12", x: 200, y: 50), cell("0.40", x: 400, y: 50),
        ]
        let expected = "Name\tQty\tPrice\nBolt\t12\t0.40"
        #expect(TextRows.text(from: grid.reversed()) == expected, "right to left, bottom to top")
        #expect(TextRows.text(from: [grid[4], grid[2], grid[0], grid[5], grid[3], grid[1]]) == expected)
    }

    /// A photo taken at a slight angle: each cell sits a little lower than
    /// the one before, and the row is still one row.
    @Test func slightlySkewedBaselinesStayOneRow() {
        let skewed = [
            cell("a", x: 10, y: 10), cell("b", x: 200, y: 14), cell("c", x: 400, y: 18),
            cell("d", x: 10, y: 50), cell("e", x: 200, y: 54), cell("f", x: 400, y: 58),
        ]
        #expect(TextRows.text(from: skewed) == "a\tb\tc\nd\te\tf")
    }

    /// Words close together are words; only a gap wider than the text is
    /// tall is a cell boundary.
    @Test func aNarrowGapIsASpace() {
        let words = [cell("Total", x: 10, y: 10), cell("due", x: 78, y: 10, width: 40), cell("42.00", x: 400, y: 10)]
        #expect(TextRows.text(from: words) == "Total due\t42.00")
    }

    /// Boxes that overlap sideways are one after the other with a space;
    /// lines whose boxes touch or overlap a little vertically (tight line
    /// spacing) stay separate lines.
    @Test func overlappingBoxes() {
        let sideways = [cell("over", x: 10, y: 10, width: 100), cell("lap", x: 90, y: 10, width: 60), cell("next", x: 400, y: 10)]
        #expect(TextRows.text(from: sideways) == "over lap\tnext")
        let tight = [cell("line one", x: 10, y: 10, width: 200), cell("line two", x: 10, y: 26, width: 200)]
        #expect(TextRows.text(from: tight) == "line one\nline two")
        // A box inside a wider one does not pull the gap after it back.
        let nested = [cell("wide", x: 10, y: 10, width: 300), cell("in", x: 50, y: 10, width: 20), cell("far", x: 320, y: 10)]
        #expect(TextRows.text(from: nested) == "wide in far")
    }

    /// A tall heading beside two short lines is not one row with both.
    @Test func aTallBoxDoesNotSwallowTwoLines() {
        let mixed = [cell("BIG", x: 10, y: 10, width: 100, height: 60), cell("upper", x: 300, y: 12), cell("lower", x: 300, y: 48)]
        #expect(TextRows.text(from: mixed) == "upper\nBIG\nlower")
    }
}
