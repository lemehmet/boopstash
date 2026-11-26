import Foundation

/// Help (#254): the project's README, bundled with the app and drawn by
/// the Markdown preview. Nothing is fetched; a link opens in the browser
/// only when it is clicked.
///
/// The README is one file for GitHub and for both apps (#263). A part
/// that applies on one platform only (installing with Homebrew, the
/// command-line tool, building from source) stands between two marker
/// lines, each an HTML comment on a line of its own, which GitHub does
/// not show:
///
///     <!-- help:mac -->
///     ## Install
///     …
///     <!-- help:end -->
///
/// The page for a platform leaves out the parts marked for another one,
/// and no page shows a marker line.
public enum HelpPage {
    /// Where a page is read. The raw value is the name a marker carries.
    public enum Platform: String, CaseIterable, Sendable {
        case mac, ios
    }

    /// What a line of the README is to the pages.
    enum Marker: Equatable {
        /// The lines that follow are for this platform only.
        case only(Platform)
        /// The end of such a part.
        case end
    }

    /// The marker a line is, if it is one: `<!-- help:mac -->`,
    /// `<!-- help:ios -->` or `<!-- help:end -->` alone on the line, with
    /// any space around it and inside the comment. Anything else, another
    /// comment or a name that is no platform included, is a line of the
    /// page like any other.
    static func marker(_ line: Substring) -> Marker? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"), trimmed.count >= 7 else { return nil }
        let inner = trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("help:") else { return nil }
        let name = inner.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if name == "end" { return .end }
        return Platform(rawValue: name).map(Marker.only)
    }

    /// The fence a line opens, when it is the opening line of a fenced
    /// code block: at least three backticks or tildes, indented by at most
    /// three spaces.
    private static func fence(opening line: Substring) -> (character: Character, count: Int)? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3, let character = line.dropFirst(indent.count).first, character == "`" || character == "~" else { return nil }
        let count = line.dropFirst(indent.count).prefix { $0 == character }.count
        return count >= 3 ? (character, count) : nil
    }

    /// Each line of `markdown` with the marker it is. A line inside a
    /// fenced code block is code, whatever it says, and is no marker.
    private static func lines(of markdown: String) -> [(text: Substring, marker: Marker?)] {
        var open: (character: Character, count: Int)?
        return markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            if let fence = open {
                // Closed by a line of the same character, at least as long,
                // with nothing after it.
                if let closing = Self.fence(opening: line), closing.character == fence.character, closing.count >= fence.count,
                   line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.character }) {
                    open = nil
                }
                return (line, nil)
            }
            if let marker = marker(line) { return (line, marker) }
            open = fence(opening: line)
            return (line, nil)
        }
    }

    /// The page `platform` shows of `markdown`: without the parts marked
    /// for another platform, and without the marker lines.
    ///
    /// - A marker inside a fenced code block is code, and stays.
    /// - A part that is never ended runs to the end of the file, and one
    ///   that starts inside another takes over from it: parts do not nest.
    /// - An end with nothing to end is dropped like any marker.
    public static func page(_ markdown: String, for platform: Platform) -> String {
        var kept: [Substring] = []
        var shown = true
        for line in lines(of: markdown) {
            switch line.marker {
            case .only(let only): shown = only == platform
            case .end: shown = true
            case nil: if shown { kept.append(line.text) }
            }
        }
        return kept.joined(separator: "\n")
    }

    /// Whether every part of `markdown` that is opened is ended before the
    /// next one opens or the file ends, and every end ends one: what the
    /// README is held to, so that a slip there fails a test instead of
    /// cutting the rest of a page.
    public static func markersAreBalanced(_ markdown: String) -> Bool {
        var inPart = false
        for line in lines(of: markdown) {
            switch line.marker {
            case .only:
                guard !inPart else { return false }
                inPart = true
            case .end:
                guard inPart else { return false }
                inPart = false
            case nil: break
            }
        }
        return !inPart
    }

    /// The bundled file, `README.md`: the repository's own copy.
    public static let resourceName = "README"
    public static let resourceExtension = "md"

    /// Where the README's relative links lead (`docs/adr/`, `SECURITY.md`,
    /// `LICENSE`): the repository on GitHub, where they point when the
    /// README is read there. Those files are not in the app.
    public static let linkBase = URL(string: "https://github.com/lemehmet/boopstash/blob/main/")!

    /// The page `platform` shows of the README, or nil when the file is
    /// missing, unreadable or blank, or nothing of it is for the platform:
    /// the page then says so instead of showing nothing.
    public static func markdown(from data: Data?, for platform: Platform) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let page = page(text, for: platform)
        return page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : page
    }
}
