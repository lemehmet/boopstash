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
    /// the order of the ranges. A replacement identical to what it
    /// replaces, code unit for code unit, has no part: the editor does
    /// not apply one either. Old-side line
    /// numbers are the note's as it is; new-side numbers are the note's
    /// as it would be, so a part after one that added or removed lines is
    /// numbered where it would then sit. Ranges are in UTF-16 units, as
    /// the editor has them; one outside the text is skipped.
    public static func make(fullText: String, edits: [(NSRange, String)], context: Int = 3) -> DiffReviewContent {
        let ns = fullText as NSString
        var parts: [Part] = []
        // Lines the edits before this one add (or, negative, remove).
        var shift = 0
        for (range, replacement) in edits.sorted(by: { $0.0.location < $1.0.location }) {
            guard range.location >= 0, NSMaxRange(range) <= ns.length else { continue }
            let old = ns.substring(with: range)
            guard !TextDiff.identical(old, replacement) else { continue }
            let firstLine = lineNumber(of: range.location, in: ns)
            let hunks = TextDiff.hunks(old: old, new: replacement, context: context,
                                       firstLine: firstLine, firstNewLine: firstLine + shift)
            shift += lineFeeds(in: replacement) - lineFeeds(in: old)
            guard !hunks.isEmpty else { continue }
            parts.append(Part(id: parts.count, firstLine: firstLine, hunks: hunks))
        }
        return DiffReviewContent(parts: parts)
    }

    static func lineFeeds(in text: String) -> Int {
        text.utf8.count(where: { $0 == UInt8(ascii: "\n") })
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
        let ending = endingChanged ? ", \(self.ending.spokenChange)" : ""
        return "\(what)\(place): \(spokenContent)\(ending)"
    }

    /// The line's text as it is read out. Whitespace is silence to
    /// VoiceOver, so a line of nothing else is said as what it holds
    /// ("only 2 spaces"), and whitespace that changed between words is
    /// named after the text (#267).
    private var spokenContent: String {
        if text.isEmpty { return "empty line" }
        if text.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
            return "only " + TextDiff.spokenWhitespace(text.unicodeScalars)
        }
        let ns = text as NSString
        let changed = markedWhitespace.map { TextDiff.spokenWhitespace(ns.substring(with: $0).unicodeScalars) }
        guard !changed.isEmpty else { return text }
        let named = changed.prefix(TextDiff.spokenWhitespaceLimit).joined(separator: "; ")
        let more = changed.count > TextDiff.spokenWhitespaceLimit ? "; and more" : ""
        return "\(text), changed whitespace: \(named)\(more)"
    }

    /// The marks that cover whitespace and nothing else: a change that
    /// neither an underline nor a voice has anything to show on.
    var markedWhitespace: [NSRange] {
        let ns = text as NSString
        return changes.filter { range in
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= ns.length else { return false }
            return (range.location..<NSMaxRange(range)).allSatisfy { TextDiff.whitespaceGlyph(ns.character(at: $0)) != nil }
        }
    }

    /// The text as the review draws it: the same, but for whitespace
    /// under a mark that covers nothing else, which is drawn as a glyph
    /// (a space as "·", a tab as "→"), so a space that became a tab shows
    /// and shows without colour (#267). One UTF-16 unit for each unit of
    /// `text`: the ranges of `changes` fit this text as they fit that.
    /// Whitespace anywhere else is left as it is.
    public var shownText: String {
        let marked = markedWhitespace
        guard !marked.isEmpty else { return text }
        var units = Array(text.utf16)
        for range in marked {
            for index in range.location..<NSMaxRange(range) {
                if let glyph = TextDiff.whitespaceGlyph(units[index]) { units[index] = glyph }
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

extension TextDiff {
    /// How many runs of whitespace, and how many marks, are named when a
    /// line is read out before the rest is "and more".
    static let spokenWhitespaceLimit = 4

    /// The glyph that stands for a whitespace UTF-16 unit, nil for a unit
    /// that is not whitespace. All Unicode whitespace is one unit, and
    /// so is each glyph.
    static func whitespaceGlyph(_ unit: UInt16) -> UInt16? {
        guard let scalar = Unicode.Scalar(unit), scalar.properties.isWhitespace else { return nil }
        let glyph: Unicode.Scalar = switch scalar {
        case " ": "\u{B7}"       // · middle dot
        case "\t": "\u{2192}"    // → rightwards arrow
        case "\u{A0}": "\u{237D}" // ⍽ shouldered open box
        case "\r": "\u{240D}"    // ␍ symbol for carriage return
        default: "\u{2423}"      // ␣ open box
        }
        return UInt16(glyph.value)
    }

    /// Whitespace in words, run by run: "2 spaces, 1 tab".
    static func spokenWhitespace(_ scalars: String.UnicodeScalarView) -> String {
        var runs: [(name: String, plural: String, count: Int)] = []
        for scalar in scalars {
            let (name, plural) = switch scalar {
            case " ": ("space", "spaces")
            case "\t": ("tab", "tabs")
            case "\u{A0}": ("no-break space", "no-break spaces")
            case "\r": ("carriage return", "carriage returns")
            default: ("other whitespace character", "other whitespace characters")
            }
            if runs.last?.name == name {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((name, plural, 1))
            }
        }
        var parts = runs.prefix(spokenWhitespaceLimit).map { "\($0.count) \($0.count == 1 ? $0.name : $0.plural)" }
        if runs.count > spokenWhitespaceLimit { parts.append("and more whitespace") }
        return parts.joined(separator: ", ")
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
