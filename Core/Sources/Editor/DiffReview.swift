import Foundation

/// What a set of replacements would do to a text, ready to show for
/// review before they are applied (#245). One part per replaced range
/// that changes: a whole-note edit has one, an edit of several selections
/// one each, and each diff covers its own range only.
public struct DiffReviewContent: Sendable, Hashable {
    public struct Part: Sendable, Hashable, Identifiable {
        public var id: Int
        /// The 1-based number of the line the replaced range starts in.
        public var firstLine: Int
        public var hunks: [TextDiff.Hunk]

        public init(id: Int, firstLine: Int, hunks: [TextDiff.Hunk]) {
            self.id = id
            self.firstLine = firstLine
            self.hunks = hunks
        }
    }

    public var parts: [Part]

    public init(parts: [Part]) { self.parts = parts }

    /// Nothing would change: there is nothing to review.
    public var isEmpty: Bool { parts.isEmpty }

    public var summary: TextDiff.Summary {
        let all = parts.map { TextDiff.summary(of: $0.hunks) }
        return TextDiff.Summary(removed: all.reduce(0) { $0 + $1.removed }, added: all.reduce(0) { $0 + $1.added })
    }

    /// The review of replacing each range of `fullText` with its text, in
    /// the order of the ranges. A replacement that leaves its range as it
    /// was has no part. Ranges are in UTF-16 units, as the editor has
    /// them; one outside the text is skipped.
    public static func make(fullText: String, edits: [(NSRange, String)], context: Int = 3) -> DiffReviewContent {
        let ns = fullText as NSString
        var parts: [Part] = []
        for (range, replacement) in edits.sorted(by: { $0.0.location < $1.0.location }) {
            guard range.location >= 0, NSMaxRange(range) <= ns.length else { continue }
            let old = ns.substring(with: range)
            guard old != replacement else { continue }
            let firstLine = lineNumber(of: range.location, in: ns)
            let hunks = TextDiff.hunks(old: old, new: replacement, context: context, firstLine: firstLine)
            guard !hunks.isEmpty else { continue }
            parts.append(Part(id: parts.count, firstLine: firstLine, hunks: hunks))
        }
        return DiffReviewContent(parts: parts)
    }

    /// The 1-based line a UTF-16 location is in, counting line feeds.
    static func lineNumber(of location: Int, in text: NSString) -> Int {
        var line = 1
        var search = NSRange(location: 0, length: min(max(0, location), text.length))
        while search.length > 0 {
            let found = text.range(of: "\n", options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            line += 1
            search = NSRange(location: NSMaxRange(found), length: NSMaxRange(search) - NSMaxRange(found))
        }
        return line
    }
}

extension TextDiff.Line {
    /// The line as VoiceOver reads it: what happened to it, where, and
    /// its text.
    public var spokenDescription: String {
        let what: String
        let number: Int?
        switch kind {
        case .unchanged: (what, number) = ("Unchanged", newNumber)
        case .removed: (what, number) = ("Removed", oldNumber)
        case .added: (what, number) = ("Added", newNumber)
        }
        let place = number.map { ", line \($0)" } ?? ""
        let content = text.isEmpty ? "empty line" : text
        let ending = endingChanged ? ", \(self.ending.spokenChange)" : ""
        return "\(what)\(place): \(content)\(ending)"
    }
}

extension TextDiff.Ending {
    /// What a line whose ending changed has now, in words.
    public var spokenChange: String {
        switch self {
        case .none: "no newline at the end"
        case .lf: "ends with a line feed"
        case .crlf: "ends with a carriage return and line feed"
        }
    }

    /// The same as a short mark beside the line.
    public var mark: String {
        switch self {
        case .none: "no newline"
        case .lf: "LF"
        case .crlf: "CRLF"
        }
    }
}
