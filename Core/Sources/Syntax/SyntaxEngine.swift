import Foundation
import SwiftTreeSitter

/// One highlighted range: UTF-16 offsets into the text, and the query's
/// capture name ("string", "keyword.function", …).
public struct SyntaxHighlight: Equatable, Sendable {
    public let range: NSRange
    public let name: String
}

/// An edit as the text view reports it: `range` was replaced (in the old
/// text) by `replacementLength` UTF-16 units.
public struct TextChange: Equatable, Sendable {
    public let range: NSRange
    public let replacementLength: Int

    public init(range: NSRange, replacementLength: Int) {
        self.range = range
        self.replacementLength = replacementLength
    }
}

/// Keeps a tree-sitter tree in step with the text, off the main thread.
/// Edits are applied incrementally, so a keystroke in a megabyte reparses
/// only what changed, and highlights are queried for the visible range only.
/// Callers must apply changes in the order they happened.
public actor SyntaxEngine {
    public enum Failure: Error { case grammarUnavailable(SyntaxLanguage) }

    public let language: SyntaxLanguage
    private let parser = Parser()
    private let query: Query
    private var tree: MutableTree?
    private var text: NSString = ""
    /// Bumped by every reset or change, so a caller can tell whether the
    /// highlights it holds describe the text it shows.
    public private(set) var version = 0

    public init(language: SyntaxLanguage) throws {
        guard let grammar = Grammars.language(for: language),
              let source = Grammars.highlightsQuery(for: language)
        else { throw Failure.grammarUnavailable(language) }
        self.language = language
        try parser.setLanguage(grammar)
        query = try Query(language: grammar, data: source)
    }

    /// Parses `text` from scratch.
    public func reset(_ text: String) -> Int {
        self.text = text as NSString
        tree = parser.parse(text)
        version += 1
        return version
    }

    /// Applies one edit and reparses, reusing the old tree.
    public func apply(_ change: TextChange, newText: String) -> Int {
        let old = text
        let new = newText as NSString
        let start = change.range.location
        let oldEnd = NSMaxRange(change.range)
        let newEnd = start + change.replacementLength
        guard let tree, oldEnd <= old.length, newEnd <= new.length else {
            return reset(newText)
        }
        // UTF-16LE: a byte offset is twice the UTF-16 offset, and columns are
        // in bytes too.
        tree.edit(InputEdit(
            startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
            startPoint: Self.point(at: start, in: old),
            oldEndPoint: Self.point(at: oldEnd, in: old),
            newEndPoint: Self.point(at: newEnd, in: new)
        ))
        text = new
        self.tree = parser.parse(tree: tree, string: newText)
        version += 1
        return version
    }

    /// Highlights intersecting `range`, with the version they describe.
    public func highlights(in range: NSRange) -> (version: Int, highlights: [SyntaxHighlight]) {
        guard let tree, let root = tree.rootNode else { return (version, []) }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        // The range limits matching while the cursor iterates, so it is set
        // after execute and before the first match is read.
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(clamped)
        let resolved = cursor.resolve(with: .init(string: text as String))
        let highlights = resolved.highlights()
            .filter { NSIntersectionRange($0.range, clamped).length > 0 || $0.range.length == 0 && NSLocationInRange($0.range.location, clamped) }
            .map { SyntaxHighlight(range: $0.range, name: $0.name) }
        return (version, highlights)
    }

    /// Row and byte column of a UTF-16 offset. Tree-sitter counts rows at
    /// "\n" only.
    static func point(at offset: Int, in text: NSString) -> Point {
        var row = 0
        var lineStart = 0
        var searchRange = NSRange(location: 0, length: min(offset, text.length))
        while true {
            let found = text.range(of: "\n", options: .literal, range: searchRange)
            guard found.location != NSNotFound else { break }
            row += 1
            lineStart = found.location + 1
            searchRange = NSRange(location: lineStart, length: min(offset, text.length) - lineStart)
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }
}
