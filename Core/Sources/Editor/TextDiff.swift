import Foundation

/// What a change does to a text, line by line, for a review before it is
/// applied (#245): the lines removed and added, with the words that differ
/// inside a changed line, grouped into hunks with a few lines of context.
///
/// Pure and deterministic: the same two texts always give the same hunks.
/// Lines are matched the patience way (lines that occur once on each side
/// anchor the rest), which keeps a moved or repeated line from pairing with
/// the wrong neighbour, and what lies between anchors is matched exactly
/// when it is small and taken as replaced when it is not, so the work
/// stays bounded on any input.
public enum TextDiff {
    /// How a line ends. Part of the line: a line that only changed its
    /// ending did change.
    public enum Ending: String, Sendable, Hashable {
        /// The last line of a text without a final newline.
        case none
        case lf
        case crlf
    }

    public enum Kind: Sendable, Hashable {
        case unchanged, removed, added
    }

    public struct Line: Sendable, Hashable {
        public var kind: Kind
        /// The line without its ending.
        public var text: String
        public var ending: Ending
        /// The line's number in the old text, from 1 (plus the offset the
        /// diff was asked for); nil for an added line.
        public var oldNumber: Int?
        /// The line's number in the new text; nil for a removed line.
        public var newNumber: Int?
        /// The parts of `text` that differ from the line it replaced or
        /// was replaced by, as UTF-16 ranges. Empty when the line has no
        /// counterpart, or differs from it too much for marks to help.
        public var changes: [NSRange]
        /// The other side of the change ends this line differently (a
        /// final newline gained or lost, or LF against CRLF), which the
        /// text alone does not show.
        public var endingChanged: Bool

        public init(kind: Kind, text: String, ending: Ending, oldNumber: Int?, newNumber: Int?,
                    changes: [NSRange] = [], endingChanged: Bool = false) {
            self.kind = kind
            self.text = text
            self.ending = ending
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.changes = changes
            self.endingChanged = endingChanged
        }
    }

    /// A run of changes with the unchanged lines around it.
    public struct Hunk: Sendable, Hashable {
        public var lines: [Line]

        public init(lines: [Line]) { self.lines = lines }
    }

    /// The numbers of lines a change removes and adds.
    public struct Summary: Sendable, Hashable {
        public var removed: Int
        public var added: Int

        public init(removed: Int, added: Int) {
            self.removed = removed
            self.added = added
        }

        /// "2 lines removed, 3 added", "1 line added", or "No changes".
        public var description: String {
            func lines(_ count: Int) -> String { count == 1 ? "1 line" : "\(count) lines" }
            switch (removed, added) {
            case (0, 0): return "No changes"
            case (_, 0): return "\(lines(removed)) removed"
            case (0, _): return "\(lines(added)) added"
            default: return "\(lines(removed)) removed, \(added) added"
            }
        }
    }

    /// The hunks that turn `old` into `new`, each with up to `context`
    /// unchanged lines before and after; changes closer together than
    /// twice that share a hunk. Empty when the texts are equal.
    /// `firstLine` is the number of the first line of the old text, for a
    /// diff of part of a note, and `firstNewLine` that of the new text
    /// when it differs: a part that follows one that added or removed
    /// lines starts elsewhere afterwards.
    public static func hunks(old: String, new: String, context: Int = 3, firstLine: Int = 1, firstNewLine: Int? = nil) -> [Hunk] {
        let lines = self.lines(old: old, new: new, firstLine: firstLine, firstNewLine: firstNewLine)
        let context = max(0, context)
        var hunks: [Hunk] = []
        var start: Int?
        var lastChange = 0
        for (index, line) in lines.enumerated() where line.kind != .unchanged {
            if let open = start, index - lastChange > 2 * context + 1 {
                hunks.append(Hunk(lines: Array(lines[open...min(lines.count - 1, lastChange + context)])))
                start = nil
            }
            if start == nil { start = max(0, index - context) }
            lastChange = index
        }
        if let open = start {
            hunks.append(Hunk(lines: Array(lines[open...min(lines.count - 1, lastChange + context)])))
        }
        return hunks
    }

    public static func summary(of hunks: [Hunk]) -> Summary {
        var summary = Summary(removed: 0, added: 0)
        for line in hunks.flatMap(\.lines) {
            switch line.kind {
            case .removed: summary.removed += 1
            case .added: summary.added += 1
            case .unchanged: break
            }
        }
        return summary
    }

    /// Every line of the change in order: unchanged lines once, a changed
    /// stretch as its removed lines followed by its added ones.
    public static func lines(old: String, new: String, firstLine: Int = 1, firstNewLine: Int? = nil) -> [Line] {
        let firstNewLine = firstNewLine ?? firstLine
        let before = split(old)
        let after = split(new)
        var ids: [Entry: Int] = [:]
        func id(_ entry: Entry) -> Int {
            if let known = ids[entry] { return known }
            ids[entry] = ids.count
            return ids.count - 1
        }
        let steps = self.steps(before.map(id), after.map(id))

        var lines: [Line] = []
        var removed: [Int] = []
        var added: [Int] = []
        func flush() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            var removedLines = removed.map { index in
                Line(kind: .removed, text: before[index].text, ending: before[index].ending,
                     oldNumber: firstLine + index, newNumber: nil)
            }
            var addedLines = added.map { index in
                Line(kind: .added, text: after[index].text, ending: after[index].ending,
                     oldNumber: nil, newNumber: firstNewLine + index)
            }
            // A changed stretch pairs its lines in order: the first removed
            // with the first added, and so on. The pair shows which words
            // changed, and whether only the ending did.
            for pair in 0..<min(removedLines.count, addedLines.count) {
                let (was, now) = (removedLines[pair], addedLines[pair])
                if was.ending != now.ending {
                    removedLines[pair].endingChanged = true
                    addedLines[pair].endingChanged = true
                }
                let (wasChanges, nowChanges) = wordChanges(was.text, now.text)
                removedLines[pair].changes = wasChanges
                addedLines[pair].changes = nowChanges
            }
            lines += removedLines + addedLines
            removed.removeAll()
            added.removeAll()
        }
        for step in steps {
            switch step {
            case .keep(let oldIndex, let newIndex):
                flush()
                lines.append(Line(kind: .unchanged, text: before[oldIndex].text, ending: before[oldIndex].ending,
                                  oldNumber: firstLine + oldIndex, newNumber: firstNewLine + newIndex))
            case .remove(let index): removed.append(index)
            case .add(let index): added.append(index)
            }
        }
        flush()
        return lines
    }

    /// Whether two texts are the same code units. Swift's `==` takes
    /// canonically equivalent texts for equal (a precomposed "é" and "e"
    /// with a combining accent); a script that turns one into the other
    /// did change the note, so what counts as "no change" is decided here.
    public static func identical(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    // MARK: - Lines

    /// A line and its ending. Two lines are the same line only when their
    /// text is the same code units: Swift's own string equality takes
    /// "é" as one scalar and as "e" with a combining accent for equal,
    /// and a change between the two is a change the review must show.
    struct Entry: Hashable {
        var text: String
        var ending: Ending

        static func == (a: Entry, b: Entry) -> Bool {
            a.ending == b.ending && a.text.utf8.elementsEqual(b.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ending)
            hasher.combine(text.utf8.count)
            for unit in text.utf8 { hasher.combine(unit) }
        }
    }

    /// The text's lines with their endings. A text ending in a newline
    /// has no empty last line; an empty text has no lines.
    static func split(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var line = String.UnicodeScalarView()
        var pendingReturn = false
        func end(_ ending: Ending) {
            entries.append(Entry(text: String(line), ending: ending))
            line.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if pendingReturn {
                    pendingReturn = false
                    end(.crlf)
                } else {
                    end(.lf)
                }
                continue
            }
            // A return not followed by a line feed is part of the line.
            if pendingReturn {
                line.append("\r")
                pendingReturn = false
            }
            if scalar == "\r" {
                pendingReturn = true
            } else {
                line.append(scalar)
            }
        }
        if pendingReturn { line.append("\r") }
        if !line.isEmpty { end(.none) }
        return entries
    }

    // MARK: - Matching

    enum Step: Equatable {
        case keep(Int, Int)
        case remove(Int)
        case add(Int)
    }

    /// The largest stretch between anchors matched exactly, as the product
    /// of its two lengths; a larger one is taken as replaced.
    static let exactLimit = 1_000_000

    /// The same for the words of one pair of lines. Far smaller: a review
    /// has as many pairs as it has changed lines, and a line too long to
    /// match word by word within this is shown as changed whole.
    static let wordExactLimit = 20_000

    /// How to turn `old` into `new`: what stays, what goes, what comes,
    /// in order, removals before additions within a change.
    static func steps(_ old: [Int], _ new: [Int], exactLimit: Int = TextDiff.exactLimit) -> [Step] {
        var steps: [Step] = []
        steps.reserveCapacity(max(old.count, new.count))
        // Stretches still to match, last in first out, so the steps come
        // out in order without recursion.
        var pending: [Work] = [.match(0..<old.count, 0..<new.count)]
        while let work = pending.popLast() {
            switch work {
            case .emit(let step): steps.append(step)
            case .match(var a, var b):
                while !a.isEmpty, !b.isEmpty, old[a.lowerBound] == new[b.lowerBound] {
                    steps.append(.keep(a.lowerBound, b.lowerBound))
                    a = (a.lowerBound + 1)..<a.upperBound
                    b = (b.lowerBound + 1)..<b.upperBound
                }
                var tail: [Step] = []
                while !a.isEmpty, !b.isEmpty, old[a.upperBound - 1] == new[b.upperBound - 1] {
                    tail.append(.keep(a.upperBound - 1, b.upperBound - 1))
                    a = a.lowerBound..<(a.upperBound - 1)
                    b = b.lowerBound..<(b.upperBound - 1)
                }
                // Pushed in reverse: what is pushed last comes out first.
                for step in tail { pending.append(.emit(step)) }
                if a.isEmpty || b.isEmpty {
                    for index in b.reversed() { pending.append(.emit(.add(index))) }
                    for index in a.reversed() { pending.append(.emit(.remove(index))) }
                    continue
                }
                let anchors = self.anchors(old, a, new, b)
                if anchors.isEmpty {
                    for step in exact(old, a, new, b, limit: exactLimit).reversed() { pending.append(.emit(step)) }
                    continue
                }
                var upperA = a.upperBound
                var upperB = b.upperBound
                for (i, j) in anchors.reversed() {
                    pending.append(.match((i + 1)..<upperA, (j + 1)..<upperB))
                    pending.append(.emit(.keep(i, j)))
                    upperA = i
                    upperB = j
                }
                pending.append(.match(a.lowerBound..<upperA, b.lowerBound..<upperB))
            }
        }
        return steps
    }

    private enum Work {
        case match(Range<Int>, Range<Int>)
        case emit(Step)
    }

    /// The lines that occur exactly once in each stretch, as the longest
    /// run of them that keeps its order on both sides.
    private static func anchors(_ old: [Int], _ a: Range<Int>, _ new: [Int], _ b: Range<Int>) -> [(Int, Int)] {
        var inOld: [Int: (count: Int, index: Int)] = [:]
        for index in a { inOld[old[index], default: (0, index)].count += 1 }
        var inNew: [Int: (count: Int, index: Int)] = [:]
        for index in b { inNew[new[index], default: (0, index)].count += 1 }
        var pairs: [(Int, Int)] = []
        for index in a {
            guard inOld[old[index]]?.count == 1, let other = inNew[old[index]], other.count == 1 else { continue }
            pairs.append((index, other.index))
        }
        guard pairs.count > 1 else { return pairs }
        // Longest increasing run of the new-side positions, by patience
        // sorting: `piles[k]` is the pair ending the best run of length
        // k + 1, `previous` links each pair to the one before it.
        var piles: [Int] = []
        var previous = [Int](repeating: -1, count: pairs.count)
        for (position, pair) in pairs.enumerated() {
            var low = 0
            var high = piles.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[piles[middle]].1 < pair.1 { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[position] = piles[low - 1] }
            if low == piles.count { piles.append(position) } else { piles[low] = position }
        }
        var run: [(Int, Int)] = []
        var position = piles.last ?? -1
        while position >= 0 {
            run.append(pairs[position])
            position = previous[position]
        }
        return run.reversed()
    }

    /// A stretch without anchors, matched by its longest common
    /// subsequence when small enough, otherwise taken as replaced.
    private static func exact(_ old: [Int], _ a: Range<Int>, _ new: [Int], _ b: Range<Int>, limit: Int) -> [Step] {
        let (n, m) = (a.count, b.count)
        guard n * m <= limit else {
            return a.map { Step.remove($0) } + b.map { Step.add($0) }
        }
        // lengths[i][j]: the longest common subsequence of the stretches
        // from i and from j on.
        let width = m + 1
        var lengths = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * width + j] = old[a.lowerBound + i] == new[b.lowerBound + j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var steps: [Step] = []
        var (i, j) = (0, 0)
        while i < n, j < m {
            if old[a.lowerBound + i] == new[b.lowerBound + j] {
                steps.append(.keep(a.lowerBound + i, b.lowerBound + j))
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                steps.append(.remove(a.lowerBound + i))
                i += 1
            } else {
                steps.append(.add(b.lowerBound + j))
                j += 1
            }
        }
        while i < n {
            steps.append(.remove(a.lowerBound + i))
            i += 1
        }
        while j < m {
            steps.append(.add(b.lowerBound + j))
            j += 1
        }
        return ordered(steps)
    }

    /// The same steps with each change's removals before its additions.
    private static func ordered(_ steps: [Step]) -> [Step] {
        var result: [Step] = []
        var removed: [Step] = []
        var added: [Step] = []
        for step in steps {
            switch step {
            case .keep:
                result += removed + added
                removed.removeAll()
                added.removeAll()
                result.append(step)
            case .remove: removed.append(step)
            case .add: added.append(step)
            }
        }
        return result + removed + added
    }

    // MARK: - Words

    /// The parts of two lines that differ, as UTF-16 ranges in each. Empty
    /// for both when the lines share too little for marks to help: then
    /// the whole line is the change.
    static func wordChanges(_ old: String, _ new: String) -> ([NSRange], [NSRange]) {
        let before = tokens(old)
        let after = tokens(new)
        guard !before.isEmpty, !after.isEmpty else { return ([], []) }
        // By code units, as lines are: see `Entry`.
        var ids: [[UInt8]: Int] = [:]
        func id(_ token: Token) -> Int {
            let key = Array(token.text.utf8)
            if let known = ids[key] { return known }
            ids[key] = ids.count
            return ids.count - 1
        }
        let steps = self.steps(before.map(id), after.map(id), exactLimit: wordExactLimit)
        var kept = 0
        var removed: [NSRange] = []
        var added: [NSRange] = []
        for step in steps {
            switch step {
            case .keep(let index, _): if !before[index].isSpace { kept += 1 }
            case .remove(let index): append(before[index].range, to: &removed)
            case .add(let index): append(after[index].range, to: &added)
            }
        }
        let words = max(before.count(where: { !$0.isSpace }), after.count(where: { !$0.isSpace }))
        // Fewer than a third of the words in common: two different lines.
        guard words > 0, kept * 3 >= words else { return ([], []) }
        return (removed, added)
    }

    private static func append(_ range: NSRange, to ranges: inout [NSRange]) {
        if let last = ranges.last, NSMaxRange(last) == range.location {
            ranges[ranges.count - 1].length += range.length
        } else {
            ranges.append(range)
        }
    }

    struct Token {
        var text: Substring
        var range: NSRange
        var isSpace: Bool
    }

    /// A line as runs of letters and digits, runs of spaces, and single
    /// other characters.
    static func tokens(_ line: String) -> [Token] {
        enum Class { case word, space, other }
        func classify(_ character: Character) -> Class {
            if character.isLetter || character.isNumber || character == "_" { return .word }
            if character.isWhitespace { return .space }
            return .other
        }
        var tokens: [Token] = []
        var start = line.startIndex
        var location = 0
        var current: Class?
        func close(at end: String.Index) {
            guard let current, start < end else { return }
            let text = line[start..<end]
            let length = text.utf16.count
            tokens.append(Token(text: text, range: NSRange(location: location, length: length), isSpace: current == .space))
            location += length
        }
        var index = line.startIndex
        while index < line.endIndex {
            let kind = classify(line[index])
            if kind != current || kind == .other {
                close(at: index)
                start = index
                current = kind
            }
            index = line.index(after: index)
        }
        close(at: line.endIndex)
        return tokens
    }
}
