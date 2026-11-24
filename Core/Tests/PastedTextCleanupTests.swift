import Foundation
import Testing
@testable import BoopstashCore

/// Clean Up Pasted Text (#244). Every fixture is synthetic.
@Suite struct PastedTextCleanupTests {
    func clean(_ text: String) -> String { PastedTextCleanup.clean(text) }

    static let boxTable = """
    ┌──────┬───────┐
    │ Name │ Count │
    ├──────┼───────┤
    │ ant  │ 1     │
    │ bee  │ 22    │
    └──────┴───────┘
    """

    static let markdownTable = """
    | Name | Count |
    | --- | --- |
    | ant | 1 |
    | bee | 22 |
    """

    // MARK: Escape codes

    @Test func coloursAndCursorCodesAreRemoved() {
        let e = "\u{1B}"
        #expect(PastedTextCleanup.removingEscapeCodes("\(e)[1;31mred\(e)[0m and \(e)[38;5;208morange\(e)[m") == "red and orange")
        #expect(PastedTextCleanup.removingEscapeCodes("\(e)[2K\(e)[1Gline\(e)[?25h") == "line")
        #expect(PastedTextCleanup.removingEscapeCodes("\(e)7saved\(e)8 \(e)(Bascii") == "saved ascii")
        #expect(PastedTextCleanup.removingEscapeCodes("\u{9B}32mgreen\u{9B}0m") == "green")
    }

    @Test func titlesAndHyperlinksAreRemovedButNotTheirText() {
        let e = "\u{1B}"
        #expect(PastedTextCleanup.removingEscapeCodes("\(e)]0;window title\u{07}prompt$") == "prompt$")
        #expect(PastedTextCleanup.removingEscapeCodes("\(e)]8;;https://example.com\(e)\\link\(e)]8;;\(e)\\ after") == "link after")
    }

    @Test func anUnfinishedTitleStopsAtItsLine() {
        #expect(PastedTextCleanup.removingEscapeCodes("\u{1B}]0;never closed\nnext line") == "0;never closed\nnext line")
    }

    @Test func bracketsThatAreNotEscapesStay() {
        let text = "array[0m] and [31m are text\r\nso is this"
        #expect(PastedTextCleanup.removingEscapeCodes(text) == text)
    }

    @Test func aSequenceUncoveredByARemovalGoesToo() {
        #expect(PastedTextCleanup.removingEscapeCodes("\u{1B}\u{1B}[0m[1mx") == "x")
    }

    // MARK: Indent

    @Test func aSharedIndentIsRemovedAndRelativeIndentKept() {
        #expect(PastedTextCleanup.removingCommonIndent("  one\n    two\n  three\n") == "one\n  two\nthree\n")
    }

    @Test func blankLinesDoNotDecideTheIndent() {
        #expect(PastedTextCleanup.removingCommonIndent("  one\n\n \n    two") == "one\n\n\n  two")
    }

    @Test func tabsAndSpacesShareOnlyWhatIsWrittenTheSame() {
        #expect(PastedTextCleanup.removingCommonIndent("\tone\n\t\ttwo") == "one\n\ttwo")
        #expect(PastedTextCleanup.removingCommonIndent("\t one\n\t  two") == "one\n two")
        let mixed = "\tone\n    two"
        #expect(PastedTextCleanup.removingCommonIndent(mixed) == mixed, "a tab and four spaces share nothing")
    }

    @Test func textWithAnUnindentedLineIsLeftAlone() {
        let text = "one\n  two\n    three"
        #expect(PastedTextCleanup.removingCommonIndent(text) == text)
    }

    @Test func aFenceBehindAGutterKeepsItsRelativeIndent() {
        let text = "  before\n  ```swift\n  func f() {\n      return\n  }\n  ```\n"
        #expect(clean(text) == "before\n```swift\nfunc f() {\n    return\n}\n```\n")
    }

    // MARK: Trailing whitespace

    @Test func trailingSpacesAndTabsAreRemoved() {
        #expect(PastedTextCleanup.removingTrailingWhitespace("one  \ntwo\t \n   \nthree") == "one\ntwo\n\nthree")
        #expect(PastedTextCleanup.removingTrailingWhitespace("  kept in front  ") == "  kept in front")
    }

    @Test func lineEndingsSurvive() {
        #expect(PastedTextCleanup.removingTrailingWhitespace("a \r\nb\t\rc \u{2028}d ") == "a\r\nb\rc\u{2028}d")
        #expect(clean("  a \r\n  b \r\n") == "a\r\nb\r\n")
    }

    // MARK: Tables

    @Test func aBoxDrawingTableBecomesAMarkdownTable() {
        #expect(clean(Self.boxTable) == Self.markdownTable)
    }

    @Test func aTableRuledBetweenEveryRow() {
        let table = """
        ┏━━━━━━┳━━━━━━━┓
        ┃ Name ┃ Count ┃
        ┡━━━━━━╇━━━━━━━┩
        │ ant  │ 1     │
        ├──────┼───────┤
        │ bee  │ 22    │
        └──────┴───────┘
        """
        #expect(clean(table) == Self.markdownTable)
    }

    @Test func anASCIITableBecomesAMarkdownTable() {
        let table = """
        +------+-------+
        | Name | Count |
        +======+=======+
        | ant  | 1     |
        | bee  | 22    |
        +------+-------+
        """
        #expect(clean(table) == Self.markdownTable)
    }

    @Test func aTableWithoutOuterBorders() {
        let table = """
         Name | Count
        ------+-------
         ant  |     1
              |    22
        """
        #expect(clean(table) == "| Name | Count |\n| --- | --- |\n| ant | 1 |\n|  | 22 |")
    }

    @Test func aTableWithoutAHeaderRuleTakesItsFirstRowAsTheHeader() {
        let table = "┌───┬───┐\n│ a │ b │\n│ c │ d │\n└───┴───┘\n"
        #expect(clean(table) == "| a | b |\n| --- | --- |\n| c | d |\n")
    }

    @Test func raggedRowsArePaddedAndAnEmptyCellStaysEmpty() {
        let table = """
        +---+---+---+
        | a | b | c |
        +---+---+---+
        | 1 |   | 3 |
        | 4 | 5 |
        | 6 | 7 | 8 | 9 |
        +---+---+---+
        """
        #expect(clean(table) == """
        | a | b | c |  |
        | --- | --- | --- | --- |
        | 1 |  | 3 |  |
        | 4 | 5 |  |  |
        | 6 | 7 | 8 | 9 |
        """)
    }

    @Test func aCellWrappedOverSeveralLinesIsJoinedWithASpace() {
        let table = """
        ┌──────┬────────────┐
        │ Name │ Notes      │
        ├──────┼────────────┤
        │ ant  │ small and  │
        │      │ quite busy │
        ├──────┼────────────┤
        │ bee  │ flies      │
        └──────┴────────────┘
        """
        #expect(clean(table) == """
        | Name | Notes |
        | --- | --- |
        | ant | small and quite busy |
        | bee | flies |
        """)
    }

    @Test func aHeaderWrappedOverTwoLinesIsOneRow() {
        let table = """
        +-------+-------+
        | First | Total |
        | name  | count |
        +-------+-------+
        | ant   | 1     |
        | bee   |       |
        +-------+-------+
        """
        #expect(clean(table) == "| First name | Total count |\n| --- | --- |\n| ant | 1 |\n| bee |  |")
    }

    /// Under a header rule alone, a row with an empty cell is a row, not
    /// the rest of the one above; so is each row of a body that sits
    /// between two rules with every cell filled (a totals row under it).
    @Test func rowsAreNotMergedWithoutEvidence() {
        let table = """
        +------+-----+
        | item | qty |
        +------+-----+
        | ant  | 1   |
        | bee  | 2   |
        +------+-----+
        | all  | 3   |
        +------+-----+
        """
        #expect(clean(table) == "| item | qty |\n| --- | --- |\n| ant | 1 |\n| bee | 2 |\n| all | 3 |")
    }

    @Test func aPipeInACellIsEscaped() {
        let table = "┌─────┬────────┐\n│ op  │ means  │\n├─────┼────────┤\n│ a|b │ a or b │\n└─────┴────────┘"
        #expect(clean(table) == "| op | means |\n| --- | --- |\n| a\\|b | a or b |")
    }

    @Test func proseAroundATableStaysWhereItIs() {
        let text = "Here are the counts:\n\(Self.boxTable)\nThat is all.\n"
        #expect(clean(text) == "Here are the counts:\n\(Self.markdownTable)\nThat is all.\n")
    }

    @Test func aTableKeepsCRLF() {
        let table = Self.boxTable.replacingOccurrences(of: "\n", with: "\r\n") + "\r\nafter\r\n"
        #expect(clean(table) == Self.markdownTable.replacingOccurrences(of: "\n", with: "\r\n") + "\r\nafter\r\n")
    }

    @Test func aTableIndentedUnderProseKeepsThatIndent() {
        let text = "Counts:\n  ┌───┬───┐\n  │ a │ b │\n  │ c │ d │\n  └───┴───┘\n"
        #expect(clean(text) == "Counts:\n  | a | b |\n  | --- | --- |\n  | c | d |\n")
    }

    @Test func aTableBehindColourCodesAndAGutter() {
        let e = "\u{1B}"
        let text = "  \(e)[2m┌───┬───┐\(e)[0m  \n  \(e)[2m│\(e)[0m \(e)[1ma\(e)[0m \(e)[2m│\(e)[0m b \(e)[2m│\(e)[0m\n  │ c │ d │\n  └───┴───┘\n"
        #expect(clean(text) == "| a | b |\n| --- | --- |\n| c | d |\n")
    }

    @Test func aTableInsideACodeFenceIsLeftAlone() {
        for fence in ["```", "~~~~"] {
            let text = "\(fence)text\n\(Self.boxTable)\n\(fence)\n"
            #expect(clean(text) == text)
        }
        // A shorter run of the marker does not close the fence, and an
        // unclosed fence runs to the end.
        let long = "````\n```\n\(Self.boxTable)\n"
        #expect(clean(long) == long)
    }

    @Test func aTableAfterAClosedFenceIsConverted() {
        let text = "```\ncode\n```\n\(Self.boxTable)"
        #expect(clean(text) == "```\ncode\n```\n\(Self.markdownTable)")
    }

    @Test(arguments: [
        // Markdown already, with or without a border above it.
        "| a | b |\n| --- | --- |\n| c | d |\n",
        "+---+---+\n| a | b |\n|---|---|\n| c | d |\n",
        // One row is a box around text, not a table.
        "┌───┬───┐\n│ a │ b │\n└───┴───┘\n",
        // One cell per row is a panel.
        "╭──────────╮\n│ a note   │\n│ in a box │\n╰──────────╯\n",
        // No border line at all.
        "a | b\nc | d\ne | f\n",
        "│ a │ b │\n│ c │ d │\n",
        // `tree` output draws with the same characters.
        ".\n├── src\n│   ├── a.swift\n│   └── b.swift\n└── README.md\n",
        // Shell pipes, a rule, a diff.
        "cat x | sort | uniq\ngrep a | wc -l\n",
        "---\ntitle: x\n---\n",
        "--- a/file\n+++ b/file\n+--\n-| a | b |\n",
    ])
    func whatIsNotConvincinglyATableIsLeftAlone(_ text: String) {
        #expect(clean(text) == text)
    }

    // MARK: Together

    @Test func everyPassRunsInOrder() {
        #expect(PastedTextCleanup.Pass.allCases == [.escapeCodes, .commonIndent, .tables, .trailingWhitespace])
    }

    @Test func textWithNothingToCleanIsReturnedAsItIs() {
        let text = "# Title\n\nSome prose, `code`, and a list:\n\n- one\n    - nested\n\n```\n  indented code\n```\n\n| a | b |\n| --- | --- |\n| c | d |\n"
        #expect(clean(text) == text)
        #expect(clean("") == "")
    }

    @Test(arguments: [
        boxTable,
        "  \u{1B}[1mTitle\u{1B}[0m  \n\n  \(boxTable.replacingOccurrences(of: "\n", with: "\n  "))\n\n  ```\n    kept  \n  ```\n",
        "+---+---+---+\n| a | b | c |\n+---+---+---+\n| 1 |   | 3 |\n| 4 | 5 |\n+---+---+---+\r\n",
        "┌─────┬────────┐\n│ op  │ means  │\n├─────┼────────┤\n│ a|b │ a or b │\n└─────┴────────┘",
        "┌──────┬───────┐\n│ Name │ Notes │\n├──────┼───────┤\n│ ant  │ small │\n│      │ busy  │\n├──────┼───────┤\n│ bee  │ flies │\n└──────┴───────┘\n",
        " Name | Count\n------+-------\n ant  |     1\n      |    22\n",
        "Counts:\n  ┌───┬───┐\n  │ a │ b │\n  │ c │ d │\n  └───┴───┘\n",
        "\tone  \n\t\ttwo\t\n",
        // A box table straight above an ASCII border: the Markdown rows
        // must not be read as that border's table the second time.
        "┌───┬───┐\n│ a │ b │\n│ c │ d │\n└───┴───┘\n+---+---+\n",
    ])
    func cleaningTwiceIsCleaningOnce(_ text: String) {
        let once = clean(text)
        #expect(clean(once) == once)
    }
}
