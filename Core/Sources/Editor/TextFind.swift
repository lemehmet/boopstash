import Foundation

/// What the find widget looks for: the text and VS Code's three toggles.
public struct FindQuery: Hashable, Sendable {
    public var text: String
    public var matchCase: Bool
    public var wholeWord: Bool
    public var isRegex: Bool

    public init(_ text: String = "", matchCase: Bool = false, wholeWord: Bool = false, isRegex: Bool = false) {
        self.text = text
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.isRegex = isRegex
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// A query that cannot be searched for: a regular expression that does not
/// parse. The message is what the widget shows.
public struct FindError: Error, Equatable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
}

/// Find and replace inside one text, as pure functions over UTF-16 ranges,
/// in VS Code's terms: a literal or regular-expression query, optional case
/// and whole-word matching, `$1` in replacements for regex queries, and
/// navigation that wraps around.
public enum TextFind {
    /// Where the search stops counting, as VS Code does at 19,999: enough
    /// to be exhaustive on any note a person reads, and a bound on the work
    /// a short query over a large note can cost.
    public static let matchLimit = 20_000

    /// The regular expression a query stands for. A literal query is
    /// escaped, so it matches itself; whole-word wraps either in lookarounds
    /// rather than `\b`, so a query that begins or ends with punctuation
    /// (`-flag`, `foo()`) still means "not inside a word".
    public static func regex(for query: FindQuery) throws(FindError) -> NSRegularExpression {
        var pattern = query.isRegex ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        if query.wholeWord { pattern = "(?<!\\w)(?:" + pattern + ")(?!\\w)" }
        // Anchors are per line, as in VS Code: `^` and `$` find line starts
        // and ends, so "insert at every line start" is a regex replace.
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.matchCase { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw FindError(message: "Invalid regular expression")
        }
    }

    /// Every match of `query` in `text`, in order, at most `limit` of them.
    /// An empty query matches nothing. Zero-length matches (`^`, `a*`) are
    /// kept: they are what a regex replace at every line start works on.
    /// Running inside a cancelled task stops early with what was found so
    /// far; the caller drops such a result, so a runaway expression costs a
    /// background thread, never the window.
    public static func matches(in text: String, for query: FindQuery, limit: Int = matchLimit) throws(FindError) -> [NSRange] {
        try results(in: text, for: query, limit: limit).map(\.range)
    }

    static func results(in text: String, for query: FindQuery, limit: Int) throws(FindError) -> [NSTextCheckingResult] {
        guard !query.isEmpty else { return [] }
        let regex = try regex(for: query)
        let ns = text as NSString
        var found: [NSTextCheckingResult] = []
        // reportProgress calls back during a long match attempt too, so a
        // superseded search ends between calls rather than at its end.
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { result, flags, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            guard let result, !flags.contains(.progress) else { return }
            found.append(result)
            if found.count >= limit { stop.pointee = true }
        }
        return found
    }

    // MARK: Navigation

    /// The match the selection is on: one equal to it, or nil.
    public static func index(of selection: NSRange, in matches: [NSRange]) -> Int? {
        let at = firstIndex(in: matches, startingAtOrAfter: selection.location)
        var index = at
        while index < matches.count, matches[index].location == selection.location {
            if matches[index] == selection { return index }
            index += 1
        }
        return nil
    }

    /// The match to show when a search starts or its query changes: the one
    /// the selection is on, else the first that starts at or after it, else
    /// the first in the text. Nil without matches.
    public static func first(from selection: NSRange, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let on = index(of: selection, in: matches) { return on }
        let index = firstIndex(in: matches, startingAtOrAfter: selection.location)
        return index < matches.count ? index : 0
    }

    /// Enter: the first match starting at or after the selection's end,
    /// wrapping to the first in the text. The match the selection is on is
    /// never the answer, so a zero-length match does not hold the caret.
    public static func next(after selection: NSRange, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let on = index(of: selection, in: matches) { return (on + 1) % matches.count }
        let index = firstIndex(in: matches, startingAtOrAfter: NSMaxRange(selection))
        return index < matches.count ? index : 0
    }

    /// Shift-Enter: the last match ending at or before the selection's
    /// start, wrapping to the last in the text.
    public static func previous(before selection: NSRange, in matches: [NSRange]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let on = index(of: selection, in: matches) { return (on + matches.count - 1) % matches.count }
        var index = firstIndex(in: matches, startingAtOrAfter: selection.location) - 1
        while index >= 0, NSMaxRange(matches[index]) > selection.location { index -= 1 }
        return index >= 0 ? index : matches.count - 1
    }

    /// The first match at or after `location` in the sorted list, or
    /// `matches.count`.
    public static func firstIndex(in matches: [NSRange], startingAtOrAfter location: Int) -> Int {
        var low = 0, high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].location < location { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Replacing

    /// What `match` becomes. For a regex query the template is expanded
    /// (`$1`, `$0`); for a literal one it is taken as written, `$` and `\`
    /// included. The match is re-run in place so the groups are its own;
    /// nil if `match` is not a match of `query` in this text any more.
    public static func replacement(for match: NSRange, in text: String, query: FindQuery, template: String) throws(FindError) -> String? {
        let regex = try regex(for: query)
        // Transparent bounds let the whole-word lookarounds see the
        // characters beside the match; without anchoring bounds, `^` does
        // not match at the range's start merely because it is the start.
        guard let result = regex.firstMatch(in: text, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds], range: match),
              result.range == match
        else { return nil }
        return regex.replacementString(for: result, in: text, offset: 0, template: expanded(template, for: query))
    }

    /// Every match with its replacement, in order, for one edit of them
    /// all.
    public static func replacements(in text: String, for query: FindQuery, template: String, limit: Int = matchLimit) throws(FindError) -> [(range: NSRange, text: String)] {
        let regex = try regex(for: query)
        let template = expanded(template, for: query)
        return try results(in: text, for: query, limit: limit).map { result in
            (result.range, regex.replacementString(for: result, in: text, offset: 0, template: template))
        }
    }

    static func expanded(_ template: String, for query: FindQuery) -> String {
        query.isRegex ? template : NSRegularExpression.escapedTemplate(for: template)
    }

    /// The query a selection seeds: a regex query escapes it, so the
    /// selected text is found as itself (VS Code does the same).
    public static func seed(_ text: String, isRegex: Bool) -> String {
        isRegex ? NSRegularExpression.escapedPattern(for: text) : text
    }
}
