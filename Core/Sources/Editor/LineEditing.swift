import Foundation

/// Line-level edits as pure functions over text and UTF-16 ranges, so the
/// editor's behaviour is tested here rather than through a window.
public enum LineEditing {
    /// Applies `transform` to each line of a block of whole lines. Lines
    /// end wherever NSString says they do (LF, CRLF, CR, U+2028, U+2029),
    /// the same rule `lineRange(for:)` uses to pick the block, and each
    /// line keeps its own terminator.
    public static func mapLines(_ block: String, _ transform: (String) -> String) -> String {
        let ns = block as NSString
        var lines: [(content: NSRange, terminator: NSRange)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            lines.append((line, NSRange(location: NSMaxRange(line), length: NSMaxRange(enclosing) - NSMaxRange(line))))
        }
        return lines.map { transform(ns.substring(with: $0.content)) + ns.substring(with: $0.terminator) }.joined()
    }

    /// Whether `range` reaches past the end of the line it starts on.
    public static func spansLines(_ text: String, _ range: NSRange) -> Bool {
        let ns = text as NSString
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: range.location, length: 0))
        return NSMaxRange(range) > contentsEnd
    }

    public struct Edit: Equatable, Sendable {
        /// What to replace, in UTF-16 units of the original text.
        public var range: NSRange
        public var replacement: String
        /// How far the moved lines' start travelled, to carry the selection.
        public var caretShift: Int
    }

    /// A block of whole lines split into its text and its final terminator
    /// (empty for the document's unterminated last line).
    struct Block {
        let content: String
        let terminator: String

        init(_ ns: NSString, _ range: NSRange) {
            var contentsEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                            for: NSRange(location: max(NSMaxRange(range) - 1, range.location), length: 0))
            let end = max(min(contentsEnd, NSMaxRange(range)), range.location)
            content = ns.substring(with: NSRange(location: range.location, length: end - range.location))
            terminator = ns.substring(with: NSRange(location: end, length: NSMaxRange(range) - end))
        }
    }

    /// Swaps the block of whole lines `lines` with the line above or below.
    /// Nil at the top or bottom of the text. The two contents trade places
    /// and the terminators stay where they were, so CRLF, CR and Unicode
    /// separators survive (#22) and the last line stays unterminated.
    public static func swap(_ text: String, lines: NSRange, up: Bool) -> Edit? {
        let ns = text as NSString
        let first: NSRange
        let second: NSRange
        if up {
            guard lines.location > 0 else { return nil }
            first = ns.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            second = lines
        } else {
            guard NSMaxRange(lines) < ns.length else { return nil }
            first = lines
            second = ns.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
        }
        let a = Block(ns, first)
        let b = Block(ns, second)
        let replacement = b.content + a.terminator + a.content + b.terminator
        let range = NSRange(location: first.location, length: first.length + second.length)
        // How far the selected block's content moves: up, to where the line
        // above began; down, past the line below's content and the
        // terminator left in between.
        let shift = up
            ? -first.length
            : (b.content as NSString).length + (a.terminator as NSString).length
        return Edit(range: range, replacement: replacement, caretShift: shift)
    }

    /// Duplicates the block of whole lines `lines` above or below itself.
    /// A block that is the unterminated last line borrows the terminator of
    /// the line before it (LF in a one-line document), so the copy is a line
    /// of the same kind.
    public static func duplicate(_ text: String, lines: NSRange, above: Bool) -> Edit {
        let ns = text as NSString
        let block = Block(ns, lines)
        var terminator = block.terminator
        if terminator.isEmpty {
            terminator = lines.location > 0
                ? Block(ns, ns.lineRange(for: NSRange(location: lines.location - 1, length: 0))).terminator
                : "\n"
            if terminator.isEmpty { terminator = "\n" }
        }
        if above || !block.terminator.isEmpty {
            // Insert a full line, content and terminator, at the block's start
            // (above) or end (below, after the block's own terminator).
            let copy = block.content + terminator
            let at = above ? lines.location : NSMaxRange(lines)
            return Edit(range: NSRange(location: at, length: 0), replacement: copy,
                        caretShift: above ? 0 : (copy as NSString).length)
        }
        // Below an unterminated last line: terminate it, then the copy.
        let copy = terminator + block.content
        return Edit(range: NSRange(location: NSMaxRange(lines), length: 0), replacement: copy,
                    caretShift: (copy as NSString).length)
    }
}
