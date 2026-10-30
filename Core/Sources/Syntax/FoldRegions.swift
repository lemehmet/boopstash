import Foundation
import SwiftTreeSitter

/// A block the editor can fold (#155): its first line stays visible, the
/// lines in `hidden` go, and `lastLine` is where the block ends (after
/// `hidden` when a closing bracket stays visible). Lines are 0-based,
/// counted at "\n".
public struct FoldRegion: Hashable, Sendable {
    public let startLine: Int
    public let hidden: ClosedRange<Int>
    public let lastLine: Int

    public init(startLine: Int, hidden: ClosedRange<Int>, lastLine: Int? = nil) {
        self.startLine = startLine
        self.hidden = hidden
        self.lastLine = lastLine ?? hidden.upperBound
    }

    /// The whole block, first line to last.
    public var lines: ClosedRange<Int> { startLine...lastLine }

    /// The same block `offset` lines further down.
    public func shifted(by offset: Int) -> FoldRegion {
        FoldRegion(startLine: startLine + offset, hidden: (hidden.lowerBound + offset)...(hidden.upperBound + offset), lastLine: lastLine + offset)
    }
}

public enum FoldRegions {
    /// One region per start line, the widest, in order: two blocks opening
    /// on one line (`{ "a": [`) fold together.
    static func normalized(_ regions: [FoldRegion]) -> [FoldRegion] {
        var widest: [Int: FoldRegion] = [:]
        for region in regions where widest[region.startLine].map({ region.hidden.upperBound > $0.hidden.upperBound }) ?? true {
            widest[region.startLine] = region
        }
        return widest.values.sorted { $0.startLine < $1.startLine }
    }

    /// Named nodes that close a block as a bracket does.
    static let closingTags: Set<String> = ["end_tag", "ETag", "erroneous_end_tag"]

    /// Blocks in a syntax tree: every node spanning several lines folds
    /// under its first. A closing token alone on the last line (`}`, `]`,
    /// `)`, a closing tag) stays visible, as editors show it; one after
    /// other text there (`"a": 1 }`), or a block without one (a Markdown
    /// section, a Python body), hides to its last line.
    static func fromTree(_ root: Node, text: NSString) -> [FoldRegion] {
        /// Only whitespace before `location` on its line.
        func startsLine(_ location: Int) -> Bool {
            var index = min(location, text.length) - 1
            while index >= 0 {
                let unit = text.character(at: index)
                if unit == 10 { return true }
                if unit != 32, unit != 9, unit != 13 { return false }
                index -= 1
            }
            return true
        }
        var regions: [FoldRegion] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            let range = node.pointRange
            let startRow = Int(range.lowerBound.row)
            // A node ending at column 0 ends with the line before.
            let endRow = Int(range.upperBound.row) - (range.upperBound.column == 0 && range.upperBound.row > range.lowerBound.row ? 1 : 0)
            guard endRow > startRow else { continue }
            if node.parent != nil {
                // The closing token may sit deeper: a JSON pair ends with its
                // array, whose last token is the "]".
                var last = endRow
                var tail = node.lastChild
                while let current = tail, Int(current.pointRange.upperBound.row) == Int(range.upperBound.row) {
                    // A bracket, or a whole closing tag (HTML's end_tag, XML's
                    // ETag), whose own last token is the ">".
                    if !current.isNamed || Self.closingTags.contains(current.nodeType ?? "") {
                        // Alone: nothing before it on its line.
                        if Int(current.pointRange.lowerBound.row) == endRow, startsLine(current.range.location) { last -= 1 }
                        break
                    }
                    tail = current.lastChild
                }
                if last > startRow { regions.append(FoldRegion(startLine: startRow, hidden: (startRow + 1)...last, lastLine: endRow)) }
            }
            for index in 0..<node.childCount {
                if let child = node.child(at: index) { stack.append(child) }
            }
        }
        return normalized(regions)
    }

    /// For text without a grammar: a line followed by more deeply indented
    /// lines folds them, blank lines inside included, trailing ones not.
    public static func byIndentation(_ text: String) -> [FoldRegion] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        func indent(_ line: Substring) -> Int? {
            guard line.contains(where: { !$0.isWhitespace }) else { return nil }
            return line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }
        let indents = lines.map(indent)
        var regions: [FoldRegion] = []
        for (index, level) in indents.enumerated() {
            guard let level else { continue }
            var last = index
            var next = index + 1
            while next < indents.count {
                if let deeper = indents[next] {
                    guard deeper > level else { break }
                    last = next
                }
                next += 1
            }
            if last > index { regions.append(FoldRegion(startLine: index, hidden: (index + 1)...last)) }
        }
        return normalized(regions)
    }
}

extension SyntaxEngine {
    /// The foldable blocks of the text as last parsed.
    public func foldRegions() -> [FoldRegion] {
        guard let root = currentRoot else { return [] }
        return FoldRegions.fromTree(root, text: currentText)
    }
}
