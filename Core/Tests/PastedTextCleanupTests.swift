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

    static let ruledTable = """
    +------+-------+
    | Name | Count |
    +------+-------+
    | ant  | 1     |
    +------+-------+
    """

    static let ruledTableInMarkdown = "| Name | Count |\n| --- | --- |\n| ant | 1 |"

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

    @Test func theOneCharacterFormsOfOSCAndSTCount() {
        let e = "\u{1B}"
        #expect(PastedTextCleanup.removingEscapeCodes("\(e)]0;title\u{9C}prompt$") == "prompt$")
        #expect(PastedTextCleanup.removingEscapeCodes("\u{9D}8;;https://example.com\u{9C}link\u{9D}8;;\(e)\\ after") == "link after")
        #expect(PastedTextCleanup.removingEscapeCodes("\u{9D}0;never closed\nnext") == "0;never closed\nnext")
    }

    @Test func anUnfinishedTitleStopsAtItsLine() {
        #expect(PastedTextCleanup.removingEscapeCodes("\u{1B}]0;never closed\nnext line") == "0;never closed\nnext line")
    }

    @Test(arguments: ["\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"])
    func anUnfinishedTitleStopsAtEveryLineEnding(_ ending: String) {
        #expect(PastedTextCleanup.removingEscapeCodes("\u{1B}]0;open\(ending)keep\u{07}") == "0;open\(ending)keep\u{07}")
    }

    @Test func bracketsThatAreNotEscapesStay() {
        let text = "array[0m] and [31m are text\r\nso is this"
        #expect(PastedTextCleanup.removingEscapeCodes(text) == text)
    }

    /// An ESC or a one-character CSI that starts no sequence is removed
    /// alone, and what follows it stays.
    @Test func aStrayEscapeIsRemovedAlone() {
        #expect(PastedTextCleanup.removingEscapeCodes("a\u{1B} │ b\u{1B}") == "a │ b")
        #expect(PastedTextCleanup.removingEscapeCodes("a\u{9B} │ \u{9B}3 é") == "a │ 3 é")
    }

    /// The text a removal leaves next to a stray ESC was never a sequence.
    @Test func whatARemovalUncoversIsText() {
        #expect(PastedTextCleanup.removingEscapeCodes("\u{1B}\u{1B}[0m[1mx") == "[1mx")
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

    @Test func aBoxTableWithoutOuterBorders() {
        #expect(clean(" Name │ Count\n──────┼───────\n ant  │     1\n bee  │    22\n") == Self.markdownTable + "\n")
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
        ├──────┼────────────┤
        │ cow  │ walks      │
        └──────┴────────────┘
        """
        #expect(clean(table) == """
        | Name | Notes |
        | --- | --- |
        | ant | small and quite busy |
        | bee | flies |
        | cow | walks |
        """)
    }

    /// A header rule and a totals rule do not make a table ruled between
    /// every row: a body row without a name is a row.
    @Test func aRowWithoutANameAboveATotalsRuleStaysARow() {
        let table = "+------+-----+\n| item | qty |\n+------+-----+\n| ant  | 1   |\n|      | 22  |\n+------+-----+\n| all  | 23  |\n+------+-----+"
        #expect(clean(table) == "| item | qty |\n| --- | --- |\n| ant | 1 |\n|  | 22 |\n| all | 23 |")
        // Nor do several ruled sections when one has a row that starts with text.
        let sections = "+---+---+\n| a | b |\n+---+---+\n| c | 1 |\n|   | 2 |\n+---+---+\n| d | 3 |\n| e | 4 |\n+---+---+\n| f | 5 |\n+---+---+"
        #expect(clean(sections) == "| a | b |\n| --- | --- |\n| c | 1 |\n|  | 2 |\n| d | 3 |\n| e | 4 |\n| f | 5 |")
    }

    @Test func aHeaderWrappedOverTwoLinesIsOneRow() {
        let table = """
        +-------+-------+
        | First | Total |
        | name  |       |
        +-------+-------+
        | ant   | 1     |
        | bee   |       |
        +-------+-------+
        """
        #expect(clean(table) == "| First name | Total |\n| --- | --- |\n| ant | 1 |\n| bee |  |")
    }

    /// With every cell filled, the lines above the first inner rule are
    /// rows: a box with no header and a rule above its last row.
    @Test func rowsAboveARuleAreNotAHeaderWithoutEvidence() {
        let table = "┌───┬───┐\n│ a │ 1 │\n│ b │ 2 │\n├───┼───┤\n│ c │ 3 │\n└───┴───┘"
        #expect(clean(table) == "| a | 1 |\n| --- | --- |\n| b | 2 |\n| c | 3 |")
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

    /// A body above a totals rule: a row with a name and no value is a
    /// row, not the rest of the one above.
    @Test func aRowWithAnEmptyCellAboveATotalsRuleStaysARow() {
        let table = """
        +------+-----+
        | item | qty |
        +------+-----+
        | ant  | 1   |
        | bee  |     |
        +------+-----+
        | all  | 1   |
        +------+-----+
        """
        #expect(clean(table) == "| item | qty |\n| --- | --- |\n| ant | 1 |\n| bee |  |\n| all | 1 |")
    }

    @Test func anEmptyRowBetweenRowsStaysAndPaddingGoes() {
        let table = "+---+---+\n| a | b |\n+---+---+\n|   |   |\n| c | d |\n|   |   |\n+---+---+"
        #expect(clean(table) == "| a | b |\n| --- | --- |\n|  |  |\n| c | d |")
        // An empty row is not evidence of a table.
        let box = "+---+---+\n| a | b |\n|   |   |\n+---+---+"
        #expect(clean(box) == box)
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

    /// A selection knows whether it starts inside a fence.
    @Test func aSelectionInsideACodeFenceKeepsItsTables() {
        let before = "intro\n```text\n"
        let note = before + Self.boxTable + "\n```\n" + Self.boxTable + "\n"
        let ns = note as NSString
        let inside = NSRange(location: (before as NSString).length, length: (Self.boxTable as NSString).length)
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [inside]) == [Self.boxTable])
        // From inside the fence to the end: only the table after it.
        let toEnd = NSRange(location: inside.location, length: ns.length - inside.location)
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [toEnd]) == [Self.boxTable + "\n```\n" + Self.markdownTable + "\n"])
        // After the fence has closed, and with no selection.
        let after = ns.range(of: Self.boxTable, options: .backwards)
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [NSRange(location: 3, length: 0), after]) == [Self.markdownTable])
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [NSRange(location: 3, length: 0)]) == [PastedTextCleanup.clean(note)])
        #expect(PastedTextCleanup.clean(note) == before + Self.boxTable + "\n```\n" + Self.markdownTable + "\n")
    }

    @Test(arguments: [("- ", "  "), ("* ", "  "), ("12. ", "    "), ("> ", "> "), (">", ">"), ("> - ", ">   "), ("> > ", "> > "), ("  - ", "    ")])
    func aFenceInAListItemOrAQuoteIsAFence(_ container: String, _ pad: String) {
        let table = Self.boxTable.replacingOccurrences(of: "\n", with: "\n" + pad)
        let fenced = "\(container)```\n\(pad)\(table)\n\(pad)```\n"
        #expect(clean("intro\n" + fenced + Self.boxTable + "\n") == "intro\n" + fenced + Self.markdownTable + "\n")
    }

    /// A fence in a block quote ends where the quote does, closed or not.
    @Test func aFenceLeftOpenInAQuoteEndsWithTheQuote() {
        let quoted = "> ```\n> \(Self.boxTable.replacingOccurrences(of: "\n", with: "\n> "))\n"
        #expect(clean(quoted + "after\n" + Self.boxTable + "\n") == quoted + "after\n" + Self.markdownTable + "\n")
        #expect(clean(quoted + Self.boxTable + "\n") == quoted + Self.markdownTable + "\n")
        let note = quoted + Self.boxTable + "\n"
        let last = (note as NSString).range(of: Self.boxTable, options: .backwards)
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [last]) == [Self.markdownTable])
    }

    /// Four columns further in than the opening line, the marker is a
    /// line of the code, and the fence is still open.
    @Test func aMarkerIndentedInsideAFenceDoesNotCloseIt() {
        let text = "```\n    ```\n\(Self.boxTable)\n```\n"
        #expect(clean(text) == text)
        let closed = "```\n   ```\n\(Self.boxTable)\n"
        #expect(clean(closed) == "```\n   ```\n\(Self.markdownTable)\n")
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
        // A diff that adds or removes a table, Markdown or ruled.
        "+---\n+| a | b |\n+| --- | --- |\n+| c | d |\n",
        "+---\n+| a | b |\n+| c | d |\n",
        "++---+---+\n+| a | b |\n+| c | d |\n++---+---+\n",
        "-+---+---+\n-| a | b |\n-| c | d |\n-+---+---+\n",
        "+ a | b\n+---+---\n+ c | d\n",
        // A diff that changes rows of a table without outer borders.
        " a | b\n-----+----\n- c | d\n+ e | f\n",
        "  a | b\n -----+----\n- c | d\n+ e | f\n   g | h\n",
        // A diff that removes rows of a table without outer borders.
        "- a | b\n-----+----\n- c | d\n- e | f\n",
        // A commit graph (jj log) where a branch merges back, and rows
        // open at the ends under a closed border.
        "│ ○  abc\n│ │  desc\n├─╯\n○  root\n",
        "┌───┬───┐\n a │ b\n c │ d\n└───┴───┘\n",
        // A line with a pipe straight above a table's border.
        "see a | b | c\n----+----\n c | d\n e | f\n",
    ])
    func whatIsNotConvincinglyATableIsLeftAlone(_ text: String) {
        #expect(clean(text) == text)
    }

    // MARK: A line with a pipe next to a table (#258)

    @Test func aLineWithAPipeAboveOrBelowAClosedTableStaysOutOfIt() {
        let above = "Output of `ls | wc`:\n"
        let below = "Counted with `sort | uniq -c`.\n"
        #expect(clean(above + Self.ruledTable + "\n") == above + Self.ruledTableInMarkdown + "\n")
        #expect(clean(Self.ruledTable + "\n" + below) == Self.ruledTableInMarkdown + "\n" + below)
        #expect(clean(above + Self.ruledTable + "\n" + below) == above + Self.ruledTableInMarkdown + "\n" + below)
        // The last line of the text, with no line ending of its own.
        #expect(clean(Self.ruledTable + "\nsee a | b") == Self.ruledTableInMarkdown + "\nsee a | b")
    }

    @Test func aLineWithABoxBarAboveOrBelowABoxTableStaysOutOfIt() {
        let text = "see a │ b\n\(Self.boxTable)\nand c │ d\n"
        #expect(clean(text) == "see a │ b\n\(Self.markdownTable)\nand c │ d\n")
    }

    /// The lines left out of the table are written back as they were, and
    /// the table keeps its own indent and line endings.
    @Test func theLinesLeftOutOfATableAreWrittenBackUnchanged() {
        let text = "note\t| x\r\n  +---+---+\r\n  | a | b |\r\n  | c | d |\r\n  +---+---+\r\nsee | y\r\n"
        #expect(PastedTextCleanup.convertingTables(text) == "note\t| x\r\n  | a | b |\r\n  | --- | --- |\r\n  | c | d |\r\nsee | y\r\n")
    }

    @Test(arguments: [
        // A closed row outside the borders is a row of the table, so the
        // block is one table or none.
        "+---+---+\n| a | b |\n| c | d |\n+---+---+\n| e | f |\nsee g | h\n",
        "| x | y |\nsee g | h\n+---+---+\n| a | b |\n| c | d |\n+---+---+\n",
        // Rows open at the ends have their header above the first border:
        // the lines outside the borders may be the table's own.
        "see a | b | c\n----+----\n c | d\n e | f\n----+----\n g | h\n",
        " a │ b │ x\n──────┼───────\n c │ d\n e │ f\n──────┼───────\n g │ h\n",
        // A Markdown table straight above a ruled one.
        "a | b\n---|---\n+---+---+\n| c | d |\n| e | f |\n+---+---+\n",
        // A line with a pipe between two tables.
        "+---+---+\n| a | b |\n| c | d |\n+---+---+\nsee g | h\n+---+---+\n| e | f |\n| i | j |\n+---+---+\n",
        // What is between the borders is still not a table.
        "see a | b\n+---+---+\n| a | b |\n+---+---+\n",
        "see a | b\n++---+---+\n+| a | b |\n+| c | d |\n++---+---+\n",
        // A diff whose changed rows stand outside the borders: what is
        // between the borders is the diff's context lines.
        "-| a | b |\n+| a | x |\n +---+---+\n | c | d |\n | e | f |\n +---+---+\n-| g | h |\n+| g | y |\n",
        " +---+---+\n | c | d |\n | e | f |\n +---+---+\n-| g | h |\n",
        "+| a | x |\n +---+---+\n | c | d |\n | e | f |\n +---+---+\n",
        "- | a | b |\n+ | a | x |\n  +---+---+\n  | c | d |\n  | e | f |\n  +---+---+\n",
        "-│ a │ b │\n+│ a │ x │\n ┌───┬───┐\n │ c │ d │\n │ e │ f │\n └───┴───┘\n",
    ])
    func aBlockWithLinesOutsideItsBordersIsStillLeftAloneWithoutEvidence(_ text: String) {
        #expect(clean(text) == text)
    }

    // MARK: A fence opener that reads as a row (#260)

    @Test func aFenceOpenerWithAPipeInItsInfoStringIsNotARow() {
        // One row above a border is not a table, and the fence is a fence.
        let text = "a | b\n----+----\n``` |\nc | d\n```\n"
        #expect(clean(text) == text)
        let twoRows = "a | b\n----+----\n``` |\nc | d\ne | f\n```\n"
        #expect(clean(twoRows) == twoRows)
    }

    @Test(arguments: ["``` |", "```sh | tee", "~~~ a|b", "~~~~ x | y", "- ``` |"])
    func aTableStraightAboveAFenceWithAPipeInItsInfoStringIsConverted(_ opener: String) {
        let fenced = "\(opener)\n g | h\n----+----\n i | j\n k | l\n"
        #expect(clean(" a | b\n----+----\n c | d\n e | f\n" + fenced) == "| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n" + fenced)
        #expect(clean(Self.ruledTable + "\n" + fenced) == Self.ruledTableInMarkdown + "\n" + fenced)
        #expect(clean(Self.boxTable + "\n" + fenced) == Self.markdownTable + "\n" + fenced)
    }

    // MARK: The fence a selection starts in (#259)

    func range(of selected: String, after before: String) -> NSRange {
        NSRange(location: (before as NSString).length, length: (selected as NSString).length)
    }

    /// A marker four columns in is a line of the code. It must stay one
    /// when the selection's shared indent is removed and it stands at the
    /// selection's first column.
    @Test func aSelectionKeepsTheFenceItStartsInWhenItsIndentIsRemoved() {
        let before = "```\n"
        let selected = "    ```\n    \(Self.boxTable.replacingOccurrences(of: "\n", with: "\n    "))\n"
        let note = before + selected + "```\n"
        #expect(clean(note) == note)
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [range(of: selected, after: before)]) == ["```\n\(Self.boxTable)\n"])
    }

    /// The other way round: a real closing line in an indented selection
    /// still closes the fence, and the table after it is converted.
    @Test func aSelectionStillSeesItsFenceCloseWhenItsIndentIsRemoved() {
        let before = "  ```\n"
        let selected = "  code\n  ```\n  \(Self.boxTable.replacingOccurrences(of: "\n", with: "\n  "))\n"
        let note = before + selected
        #expect(clean(note) == "```\ncode\n```\n\(Self.markdownTable)\n")
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [range(of: selected, after: before)]) == ["code\n```\n\(Self.markdownTable)\n"])
    }

    @Test func aSelectionSeesAFenceOpenedBehindAColourCode() {
        let before = "\u{1B}[31m```\u{1B}[0m\n"
        let note = before + Self.boxTable + "\n```\n"
        #expect(clean(note) == "```\n\(Self.boxTable)\n```\n")
        #expect(PastedTextCleanup.outputs(fullText: note, selections: [range(of: Self.boxTable, after: before)]) == [Self.boxTable])
        // A fence closed behind a colour code is closed.
        let closed = before + "code\n\u{1B}[31m```\u{1B}[0m\n"
        #expect(PastedTextCleanup.outputs(fullText: closed + Self.boxTable, selections: [range(of: Self.boxTable, after: closed)]) == [Self.markdownTable])
    }

    // MARK: A selection and the whole note agree (#244)

    /// Cleaning never changes a table inside a code fence, and cleaning a
    /// selection of whole lines gives those lines what cleaning the whole
    /// note gives them, apart from the indent the selection's lines share
    /// beyond the note's. `fenced` says the selection is all inside a
    /// fence; `before` and `after` hold no table outside a fence, so the
    /// whole note's lines can be counted.
    @Test(arguments: [
        // #259: the indent, the escape code, and both.
        ("```\n", "    ```\n    ┌───┬───┐\n    │ a │ b │\n    │ c │ d │\n    └───┴───┘\n", "```\n", true),
        ("\u{1B}[31m```\u{1B}[0m\n", "┌───┬───┐\n│ a │ b │\n│ c │ d │\n└───┴───┘\n", "```\n", true),
        ("  \u{1B}[2m~~~\u{1B}[0m\n", "      ~~~\n      +---+---+\n      | a | b |\n      | c | d |\n      +---+---+\n", "  ~~~\n", true),
        ("intro\n  ```\n", "  code\n  ```\n  +---+---+\n  | a | b |\n  | c | d |\n  +---+---+\n", "outro\n", false),
        // #260: a selection inside the fence such an opener starts, and
        // one that holds the opener.
        ("intro\n``` |\n", " a | b\n----+----\n c | d\n e | f\n", "```\n", true),
        ("intro\n", " a | b\n----+----\n x | y\n``` |\n c | d\n e | f\n", "```\noutro\n", false),
        ("intro\n", " a | b\n----+----\n c | d\n e | f\n~~~ x|y\n g | h\n----+----\n i | j\n k | l\n", "~~~\n", false),
        // #258: a line with a pipe next to a table, in a fence and out.
        ("~~~\n", "Output of `ls | wc`:\n+---+---+\n| a | b |\n| c | d |\n+---+---+\nsee e | f\n", "~~~\n", true),
        ("intro\n", "Output of `ls | wc`:\n+---+---+\n| a | b |\n| c | d |\n+---+---+\nsee e | f\n", "outro\n", false),
        ("> ```\n", "> see a │ b\n> ┌───┬───┐\n> │ a │ b │\n> │ c │ d │\n> └───┴───┘\n", "> ```\n", true),
    ])
    func aSelectionIsCleanedAsTheWholeNoteIs(_ before: String, _ selected: String, _ after: String, _ fenced: Bool) {
        let note = before + selected + after
        let output = PastedTextCleanup.outputs(fullText: note, selections: [range(of: selected, after: before)])
        let whole = PastedTextCleanup.lines(clean(note))
            .dropFirst(PastedTextCleanup.lines(before).count)
            .dropLast(PastedTextCleanup.lines(after).count)
        #expect(output == [PastedTextCleanup.removingCommonIndent(PastedTextCleanup.joined(Array(whole)))])
        let withoutTables = [PastedTextCleanup.Pass.escapeCodes, .commonIndent, .trailingWhitespace].reduce(selected) { $1.apply($0) }
        if fenced {
            #expect(output == [withoutTables], "a table inside a code fence is left alone")
        } else {
            #expect(output != [withoutTables], "the table outside the fence is converted")
        }
        // Cleaning what was cleaned changes nothing more.
        #expect(clean(clean(note)) == clean(note))
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
        // A stray ESC or CSI at a cell's end must not become a sequence
        // once the Markdown row puts ` |` after it.
        "│ a\u{1B} │ b │\n├───┼───┤\n│ c\u{9B} │ d\u{1B}[3 │\n└───┴───┘\n",
        "+---+---+\n| a | b |\n+---+---+\n|   |   |\n| c | d |\n+---+---+\n",
        // A box table straight above an ASCII border: the Markdown rows
        // must not be read as that border's table the second time.
        "┌───┬───┐\n│ a │ b │\n│ c │ d │\n└───┴───┘\n+---+---+\n",
        // A line with a pipe above and below a table (#258), and a table
        // straight above a fence with a pipe in its info string (#260).
        "Output of `ls | wc`:\n+---+---+\n| a | b |\n| c | d |\n+---+---+\nsee e | f\n",
        "see a │ b\n┌───┬───┐\n│ a │ b │\n│ c │ d │\n└───┴───┘\n+---+---+\n| e | f |\n",
        " a | b\n----+----\n c | d\n e | f\n``` |\n g | h\n----+----\n i | j\n k | l\n",
    ])
    func cleaningTwiceIsCleaningOnce(_ text: String) {
        let once = clean(text)
        #expect(clean(once) == once)
    }
}
