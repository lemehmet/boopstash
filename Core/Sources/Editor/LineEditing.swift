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

    /// Swaps the block of whole lines `lines` with the line above or below.
    /// Nil at the top or bottom of the text. The last line has no newline, so
    /// when it takes part the newline moves to keep every line terminated
    /// except the new last one.
    public static func swap(_ text: String, lines: NSRange, up: Bool) -> Edit? {
        let ns = text as NSString
        var block = ns.substring(with: lines)
        if up {
            guard lines.location > 0 else { return nil }
            let previous = ns.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            var above = ns.substring(with: previous)
            if !block.hasSuffix("\n") {
                block += "\n"
                above.removeLast()
            }
            return Edit(
                range: NSRange(location: previous.location, length: previous.length + lines.length),
                replacement: block + above,
                caretShift: -previous.length
            )
        } else {
            guard NSMaxRange(lines) < ns.length else { return nil }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
            var below = ns.substring(with: next)
            if !below.hasSuffix("\n") {
                below += "\n"
                block.removeLast()
            }
            return Edit(
                range: NSRange(location: lines.location, length: lines.length + next.length),
                replacement: below + block,
                caretShift: (below as NSString).length
            )
        }
    }
}
