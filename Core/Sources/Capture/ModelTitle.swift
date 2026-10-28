import Foundation

/// The prompt for the on-device model and the clean-up of what it says.
/// Pure, so the parts that decide what a generated title looks like are
/// tested here; the app's adapter only moves strings to and from the model.
public enum ModelTitle {
    public static let instructions = """
    You name notes in a scratch pad for programmers. Reply with one title of \
    at most eight words saying what the note is about. Plain text only: no \
    quotes, no markdown, no trailing punctuation, no explanation.
    """

    /// The on-device model's context is a few thousand tokens and titles
    /// come from the beginning of a note, so only the head is sent.
    public static let excerptLimit = 2_500

    public static func prompt(for body: String, kind: ContentKind) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = trimmed.count > excerptLimit ? String(trimmed.prefix(excerptLimit)) + "\n[…]" : trimmed
        return "The note looks like: \(kind.displayName).\n\nNote:\n\(excerpt)"
    }

    /// The first line of the reply, without the wrapping small models add:
    /// "Title:" prefixes, quotes, markdown emphasis or headings, a trailing
    /// period. Nil when nothing is left, so the caller keeps its rule-based
    /// title.
    public static func clean(_ output: String) -> String? {
        guard var line = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let wrappers = CharacterSet(charactersIn: "\"'“”‘’`*_ ")
        // Wrappers and prefixes nest in either order ("**Title: x**",
        // "Title: **x**"), so peel until nothing changes.
        var previous = ""
        while previous != line {
            previous = line
            line = line.trimmingCharacters(in: wrappers)
            line = line.replacingOccurrences(of: #"^(#+\s*)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(?i)title\s*:\s*"#, with: "", options: .regularExpression)
        }
        while let last = line.last, ".:;,".contains(last) { line.removeLast() }
        line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: wrappers)
        guard line.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return RuleTitler.truncated(line)
    }
}
