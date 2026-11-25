import Foundation

/// Clean Up Pasted Text (#244): what a copy from a terminal or an agent's
/// window leaves behind, removed by independent passes run in a fixed
/// order. Deterministic, no model; each pass is text in, text out, and
/// leaves text it does not recognise exactly as it was. Lines end where
/// NSString says they do and keep their own terminators, as in
/// `LineEditing.mapLines`, so CRLF text stays CRLF.
public enum PastedTextCleanup {
    /// The passes in the order they run. Escape codes go first, since they
    /// sit inside table borders and indents; the indent goes before tables,
    /// so a fence behind a gutter is seen where it stands and a table keeps
    /// only the indent it has beyond its surroundings; trailing whitespace
    /// goes last, after anything a pass leaves at a line's end.
    public enum Pass: CaseIterable, Sendable {
        case escapeCodes
        case commonIndent
        case tables
        case trailingWhitespace

        public func apply(_ text: String) -> String {
            switch self {
            case .escapeCodes: PastedTextCleanup.removingEscapeCodes(text)
            case .commonIndent: PastedTextCleanup.removingCommonIndent(text)
            case .tables: PastedTextCleanup.convertingTables(text)
            case .trailingWhitespace: PastedTextCleanup.removingTrailingWhitespace(text)
            }
        }
    }

    /// Every pass, in order. Cleaning clean text returns it unchanged.
    /// `preceding` is the text in front of `text` when it is a part of
    /// something longer (a selection): a code fence left open there is
    /// still open where `text` starts.
    public static func clean(_ text: String, after preceding: String = "") -> String {
        let fence = openFence(atEndOf: preceding)
        return Pass.allCases.reduce(text) { $1 == .tables ? convertingTables($0, in: fence) : $1.apply($0) }
    }

    /// What a run on a note puts in place of each non-empty selected range,
    /// or of the whole text when nothing is selected, in the order
    /// `ScriptEdits.replacements` takes them. Each selection is cleaned on
    /// its own, knowing only whether it starts inside a code fence.
    public static func outputs(fullText: String, selections: [NSRange]) -> [String] {
        let ns = fullText as NSString
        let ranges = selections.filter { $0.length > 0 }
        guard !ranges.isEmpty else { return [clean(fullText)] }
        return ranges.map { clean(ns.substring(with: $0), after: ns.substring(to: $0.location)) }
    }

    // MARK: - Lines

    struct Line {
        var content: String
        var terminator: String
    }

    static func lines(_ text: String) -> [Line] {
        let ns = text as NSString
        var lines: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            lines.append(Line(content: ns.substring(with: line),
                              terminator: ns.substring(with: NSRange(location: NSMaxRange(line), length: NSMaxRange(enclosing) - NSMaxRange(line)))))
        }
        return lines
    }

    static func joined(_ lines: [Line]) -> String {
        lines.map { $0.content + $0.terminator }.joined()
    }

    static func isIndent(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    static func indent(of line: String) -> Substring {
        line.prefix(while: isIndent)
    }

    static func commonPrefix(_ a: Substring, _ b: Substring) -> Substring {
        var end = a.startIndex
        var other = b.startIndex
        while end < a.endIndex, other < b.endIndex, a[end] == b[other] {
            end = a.index(after: end)
            other = b.index(after: other)
        }
        return a[..<end]
    }

    // MARK: - Escape codes

    /// ANSI escape sequences: OSC (a window title or a hyperlink, up to its
    /// BEL or ST, never past the line), CSI (colours, cursor movement), and
    /// the two- and three-character escapes (charset selection, save and
    /// restore cursor). An ESC or a one-character CSI that starts none of
    /// these goes on its own: it is a control character, never text, and
    /// left in place it could become a sequence once a later pass writes
    /// after it (a table's ` |`), so cleaning twice would differ.
    static let escapeCodes = try! NSRegularExpression(pattern: [
        #"\x1B\][^\x07\x1B\r\n\u0085\u2028\u2029]*(?:\x07|\x1B\\)"#,
        #"\x1B\[[0-?]*[ -/]*[@-~]"#,
        #"\u009B[0-?]*[ -/]*[@-~]"#,
        #"\x1B[ -/]*[0-~]"#,
        #"[\x1B\u009B]"#,
    ].joined(separator: "|"))

    /// Removes ANSI escape sequences, everywhere: they are never text.
    public static func removingEscapeCodes(_ text: String) -> String {
        // One pass leaves no ESC and no CSI character behind, so nothing
        // can read as a sequence afterwards.
        escapeCodes.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    // MARK: - Indent

    /// Removes the leading spaces and tabs every non-blank line shares: a
    /// terminal's gutter, or the indent of a quoted block. The shared
    /// indent is compared character for character, so a tab and spaces of
    /// the same width share nothing, and what a line has beyond it stays:
    /// relative indentation, inside a code fence too, is kept.
    public static func removingCommonIndent(_ text: String) -> String {
        var all = lines(text)
        var shared: Substring?
        for line in all where !line.content.allSatisfy(isIndent) {
            let own = indent(of: line.content)
            shared = shared.map { commonPrefix($0, own) } ?? own
            if shared?.isEmpty == true { return text }
        }
        guard let shared, !shared.isEmpty else { return text }
        for index in all.indices {
            // A blank line gives up as much of the indent as it has.
            let drop = commonPrefix(shared, indent(of: all[index].content)).count
            all[index].content.removeFirst(drop)
        }
        return joined(all)
    }

    // MARK: - Trailing whitespace

    /// Removes the spaces and tabs at the end of every line.
    public static func removingTrailingWhitespace(_ text: String) -> String {
        var all = lines(text)
        for index in all.indices {
            while let last = all[index].content.last, isIndent(last) { all[index].content.removeLast() }
        }
        return joined(all)
    }

    // MARK: - Tables

    enum LineKind: Equatable {
        /// `┌──┬──┐`, `├──┼──┤`: box-drawing characters only.
        case boxBorder
        /// `│ a │ b │`
        case boxRow
        /// `+---+---+`, or psql's `----+----`
        case asciiBorder
        /// `| a | b |`, or psql's ` a | b`
        case asciiRow
        /// `| --- | --- |`: the table is Markdown already.
        case markdownRule
        case other

        var isBox: Bool { self == .boxBorder || self == .boxRow }
        var isASCII: Bool { self == .asciiBorder || self == .asciiRow || self == .markdownRule }
        var isBorder: Bool { self == .boxBorder || self == .asciiBorder }
    }

    static let boxVerticals: Set<Character> = ["│", "┃", "║", "╎", "╏", "┆", "┇", "┊", "┋"]
    /// What a border is drawn with between its corners and junctions.
    static let boxHorizontals: Set<Character> = ["─", "━", "═", "╌", "╍", "┄", "┅", "┈", "┉", "╴", "╶", "╸", "╺", "╼", "╾"]

    static func isBoxDrawing(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return (0x2500...0x257F).contains(scalar.value)
    }

    static func kind(of line: String) -> LineKind {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else { return .other }
        if text.allSatisfy(isBoxDrawing) {
            return text.allSatisfy({ boxVerticals.contains($0) }) ? .other : .boxBorder
        }
        if text.contains(where: { boxVerticals.contains($0) }) { return .boxRow }
        if text.allSatisfy({ "+-=".contains($0) }) {
            return text.contains("+") && text.contains(where: { $0 == "-" || $0 == "=" }) ? .asciiBorder : .other
        }
        guard text.contains("|") else { return .other }
        if text.contains("-"), text.allSatisfy({ "|-: ".contains($0) }) { return .markdownRule }
        return .asciiRow
    }

    /// A code fence's opening line: three or more backticks or tildes.
    static func fenceOpening(_ line: String) -> (marker: Character, length: Int)? {
        let text = line.drop(while: isIndent)
        guard let marker = text.first, marker == "`" || marker == "~" else { return nil }
        let run = text.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        // A backtick fence's info string has no backtick; with one, the
        // line is inline code.
        if marker == "`", text.dropFirst(run.count).contains("`") { return nil }
        return (marker, run.count)
    }

    static func closesFence(_ line: String, _ fence: (marker: Character, length: Int)) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count >= fence.length && text.allSatisfy { $0 == fence.marker }
    }

    /// The code fence still open after the last line of `text`, if any.
    static func openFence(atEndOf text: String) -> (marker: Character, length: Int)? {
        var fence: (marker: Character, length: Int)?
        for line in lines(text) {
            if let open = fence {
                if closesFence(line.content, open) { fence = nil }
            } else {
                fence = fenceOpening(line.content)
            }
        }
        return fence
    }

    /// Turns box-drawing tables (`┌─┬─┐`, `│`) and ASCII tables (`+---+`,
    /// `|`) into Markdown tables. A wrong guess damages text, so a block of
    /// lines is a table only when it has a border line, at least two rows,
    /// and a first row of at least two cells; a Markdown table, a one-cell
    /// box around prose, `tree` output and anything inside a code fence
    /// are left alone.
    public static func convertingTables(_ text: String) -> String {
        convertingTables(text, in: nil)
    }

    /// `fence` is the code fence the text starts inside, if any.
    static func convertingTables(_ text: String, in fence: (marker: Character, length: Int)?) -> String {
        let all = lines(text)
        var result: [Line] = []
        result.reserveCapacity(all.count)
        var fence = fence
        var index = 0
        while index < all.count {
            let content = all[index].content
            if let open = fence {
                if closesFence(content, open) { fence = nil }
                result.append(all[index])
                index += 1
                continue
            }
            if let open = fenceOpening(content) {
                fence = open
                result.append(all[index])
                index += 1
                continue
            }
            let first = kind(of: content)
            guard first != .other else {
                result.append(all[index])
                index += 1
                continue
            }
            // The run of lines of the same family, box or ASCII.
            var end = index + 1
            while end < all.count {
                let next = kind(of: all[end].content)
                guard next != .other, next.isBox == first.isBox else { break }
                end += 1
            }
            let block = Array(all[index..<end])
            if let rows = markdownTable(block, box: first.isBox) {
                for (offset, row) in rows.enumerated() {
                    result.append(Line(content: row, terminator: offset == rows.count - 1 ? block[block.count - 1].terminator : block[0].terminator))
                }
            } else {
                result.append(contentsOf: block)
            }
            index = end
        }
        return joined(result)
    }

    /// The Markdown rows for a block of border and row lines, or nil when
    /// the block is not convincingly a table.
    static func markdownTable(_ block: [Line], box: Bool) -> [String]? {
        let kinds = block.map { kind(of: $0.content) }
        guard !kinds.contains(.markdownRule), kinds.contains(where: \.isBorder) else { return nil }
        let separators: Set<Character> = box ? boxVerticals : ["|"]
        let rowTexts = zip(block, kinds).map { $1.isBorder ? nil : $0.content.trimmingCharacters(in: .whitespaces) }
        let borderTexts = zip(block, kinds).compactMap { $1.isBorder ? $0.content.trimmingCharacters(in: .whitespaces) : nil }
        // Rows closed at both ends lose the empty pieces outside the outer
        // separators; psql's open rows keep every piece.
        let closed = rowTexts.compactMap { $0 }.allSatisfy { row in
            row.count >= 2 && separators.contains(row.first!) && separators.contains(row.last!)
        }
        func cells(_ row: String) -> [String] {
            var pieces = row.split(omittingEmptySubsequences: false, whereSeparator: { separators.contains($0) })
            if closed { pieces = Array(pieces.dropFirst().dropLast()) }
            return pieces.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        // A border has a corner or a junction (`+`, `┼`) wherever the rows
        // have a separator. Rows open at the ends (psql) go with a border
        // open at the ends, `----+----`; under `+---+` a row that is not
        // closed is a line of something else, such as a diff's
        // `+| a | b |`, and so is a first row whose separators do not match
        // the borders' junctions: a commit graph's `│ ○ abc` over `├─╯`.
        func isJoint(_ character: Character) -> Bool { box ? !boxHorizontals.contains(character) : character == "+" }
        let openBorders = borderTexts.allSatisfy { !isJoint($0.first!) && !isJoint($0.last!) }
        guard closed || openBorders else { return nil }
        let columns = rowTexts.compactMap { $0 }.first?.count(where: { separators.contains($0) })
        guard borderTexts.allSatisfy({ $0.count(where: isJoint) == columns }) else { return nil }
        // The rows between one border and the next.
        var segments: [[[String]]] = [[]]
        for row in rowTexts {
            if let row { segments[segments.count - 1].append(cells(row)) } else { segments.append([]) }
        }
        segments.removeAll(where: \.isEmpty)

        /// Several lines of one row: each cell's pieces joined with a space.
        func merged(_ lines: [[String]]) -> [String] {
            let width = lines.map(\.count).max() ?? 0
            return (0..<width).map { column in
                lines.compactMap { $0.indices.contains(column) && !$0[column].isEmpty ? $0[column] : nil }.joined(separator: " ")
            }
        }
        var rows: [[String]] = []
        for (number, segment) in segments.enumerated() {
            // With a border under it, the first segment is the header,
            // however many lines it wraps over. In a table ruled between
            // every row (three segments or more), a segment whose later
            // lines each start with an empty cell is one row with a wrapped
            // cell; otherwise each line is a row of its own, as in the body
            // under a header rule, where an empty cell is just an empty
            // cell, or in a body above a totals rule, where a row with a
            // name and no value is a row.
            let wrapped = segments.count >= 3 && segment.dropFirst().allSatisfy { $0.first?.isEmpty == true }
            if segments.count > 1, number == 0 || wrapped {
                rows.append(merged(segment))
            } else {
                rows.append(contentsOf: segment)
            }
        }
        // Empty lines above the first row and below the last are a box's
        // padding; an empty row between two others is a row and stays.
        func isEmpty(_ row: [String]) -> Bool { row.allSatisfy(\.isEmpty) }
        rows = Array(rows.drop(while: isEmpty))
        while let last = rows.last, isEmpty(last) { rows.removeLast() }
        // Only rows with text count as evidence of a table.
        guard rows.count(where: { !isEmpty($0) }) >= 2, rows[0].count >= 2 else { return nil }

        let width = rows.map(\.count).max() ?? 0
        // The indent the whole block shares stays in front of every row.
        let indents = block.map { indent(of: $0.content) }
        let shared = String(indents.dropFirst().reduce(indents[0]) { commonPrefix($0, $1) })
        func markdown(_ row: [String]) -> String {
            let padded = row.map { $0.replacingOccurrences(of: "|", with: "\\|") } + Array(repeating: "", count: width - row.count)
            return shared + "| " + padded.joined(separator: " | ") + " |"
        }
        let rule = shared + "|" + Array(repeating: " --- ", count: width).joined(separator: "|") + "|"
        return [markdown(rows[0]), rule] + rows.dropFirst().map(markdown)
    }
}
