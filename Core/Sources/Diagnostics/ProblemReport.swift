import Foundation
import Markdown

/// Help ▸ Report a Problem… (#185): what a bug report needs about the app
/// and what was on screen, as a note the user fills in and keeps. It holds
/// facts only — versions, settings, counts, IDs — and never the text or
/// title of any note, so rendering it cannot leak one (ADR 0001: nothing
/// is sent anywhere; the user decides what to share).
public struct ProblemReport: Equatable, Sendable {
    /// How this copy of the app was distributed.
    public enum Distribution: String, Equatable, Sendable {
        case appStore = "App Store"
        case developerID = "Developer ID (Homebrew)"
        case debug = "Debug build"
    }

    /// Sync with iCloud as it stood.
    public enum Sync: Equatable, Sendable {
        case unavailable
        case off
        /// On; the last exchange with iCloud and whatever problem Settings shows.
        case on(lastSynced: Date?, problem: String?)
    }

    public struct Environment: Equatable, Sendable {
        public var appVersion: String
        public var build: String
        public var distribution: Distribution
        public var macOSVersion: String
        public var chip: String
        /// Whether the on-device model can run, and if not why.
        public var appleIntelligence: String
        public var iCloudEnvironment: String
        public var sync: Sync
        public var semanticSearch: Bool
        public var keymapPreset: String
        public var linuxHabits: Bool

        public init(appVersion: String, build: String, distribution: Distribution, macOSVersion: String, chip: String,
                    appleIntelligence: String, iCloudEnvironment: String, sync: Sync, semanticSearch: Bool,
                    keymapPreset: String, linuxHabits: Bool) {
            self.appVersion = appVersion
            self.build = build
            self.distribution = distribution
            self.macOSVersion = macOSVersion
            self.chip = chip
            self.appleIntelligence = appleIntelligence
            self.iCloudEnvironment = iCloudEnvironment
            self.sync = sync
            self.semanticSearch = semanticSearch
            self.keymapPreset = keymapPreset
            self.linuxHabits = linuxHabits
        }
    }

    /// The selected note, described without its text.
    public struct SelectedNote: Equatable, Sendable {
        public enum Preview: String, Equatable, Sendable {
            case hidden = "hidden"
            case beside = "beside the editor"
            case replacing = "in place of the editor"
        }

        public var id: UUID
        /// The language highlighted, nil for plain text.
        public var language: String?
        /// True when the language was detected rather than chosen.
        public var languageDetected: Bool
        public var characters: Int
        public var lines: Int
        public var attachments: Int
        /// Folded regions; nil when no editor showed the note.
        public var folds: Int?
        public var preview: Preview

        public init(id: UUID, language: String?, languageDetected: Bool, characters: Int, lines: Int, attachments: Int,
                    folds: Int?, preview: Preview) {
            self.id = id
            self.language = language
            self.languageDetected = languageDetected
            self.characters = characters
            self.lines = lines
            self.attachments = attachments
            self.folds = folds
            self.preview = preview
        }

        /// The note's size in characters and lines, the only facts taken
        /// from its text.
        public init(id: UUID, body: String, language: String?, languageDetected: Bool, attachments: Int, folds: Int?, preview: Preview) {
            self.init(id: id, language: language, languageDetected: languageDetected, characters: body.count,
                      lines: ProblemReport.lineCount(body), attachments: attachments, folds: folds, preview: preview)
        }
    }

    /// The note list's filter. The filter text itself is never recorded.
    public struct List: Equatable, Sendable {
        public var scope: String
        public var days: Int?
        /// The names of the labels filtered by: catalog names, not note text.
        public var labels: [String]
        public var hasFilterText: Bool
        /// Whether the list shows notes similar to one, and if so whether
        /// that one is the selected note.
        public var similarNotes: String

        public init(scope: String, days: Int?, labels: [String], hasFilterText: Bool, similarNotes: String) {
            self.scope = scope
            self.days = days
            self.labels = labels
            self.hasFilterText = hasFilterText
            self.similarNotes = similarNotes
        }
    }

    public var createdAt: Date
    public var environment: Environment
    public var note: SelectedNote?
    public var list: List
    /// Recent log lines; nil when the user left them out.
    public var logLines: [String]?
    /// Why the log could not be read, when the user asked for it.
    public var logError: String?
    /// The screenshot's attachment markdown; nil when left out.
    public var screenshot: String?

    public init(createdAt: Date, environment: Environment, note: SelectedNote?, list: List, logLines: [String]? = nil,
                logError: String? = nil, screenshot: String? = nil) {
        self.createdAt = createdAt
        self.environment = environment
        self.note = note
        self.list = list
        self.logLines = logLines
        self.logError = logError
        self.screenshot = screenshot
    }

    // MARK: Constants

    /// The label every report carries, made with GitHub's colour for it
    /// when the catalog has none.
    public static let labelName = "bug"
    public static let labelColor = "#d73a4a"
    /// Where Copy as GitHub Issue sends the user: the bare page, nothing in
    /// the URL (#185).
    public static let newIssueURL = URL(string: "https://github.com/lemehmet/boopstash/issues/new")!
    /// How far back the log goes, and how much of it is kept.
    public static let logWindow: TimeInterval = 10 * 60
    public static let maxLogLines = 200
    public static let maxLogLineLength = 500
    /// What stands in for an attachment in an issue: GitHub cannot read the
    /// store, so the user drags the image in.
    public static let attachmentPlaceholder = "_[Screenshot: drag the image from the note in BoopStash into this issue.]_"

    // MARK: Rendering

    public static func title(for date: Date, timeZone: TimeZone = .current) -> String {
        "Problem report — \(stamp(date, timeZone: timeZone))"
    }

    /// The note's body: the user's sections first, then the facts.
    public func markdown(timeZone: TimeZone = .current) -> String {
        var out: [String] = [
            "## What happened", "", "", "## What I expected", "", "", "## Steps", "", "1. ", "",
            "## Environment", "",
        ]
        let env = environment
        out += [
            "- BoopStash: \(env.appVersion) (\(env.build)), \(env.distribution.rawValue)",
            "- macOS: \(env.macOSVersion)",
            "- Chip: \(env.chip)",
            "- Apple Intelligence: \(env.appleIntelligence)",
            "- iCloud environment: \(env.iCloudEnvironment)",
            "- Sync: \(Self.describe(env.sync, timeZone: timeZone))",
            "- Semantic search: \(Self.onOff(env.semanticSearch))",
            "- Key bindings: \(env.keymapPreset), Linux habits \(Self.onOff(env.linuxHabits))",
            "", "## Current view", "",
        ]
        if let note {
            let language = note.language ?? "Plain Text"
            out += [
                "- Note: \(note.id.uuidString.lowercased())",
                "- Language: \(language) (\(note.languageDetected ? "detected" : "chosen"))",
                "- Length: \(note.characters) characters, \(note.lines) lines",
                "- Attachments: \(note.attachments)",
                "- Folds: \(note.folds.map(String.init) ?? "no editor")",
                "- Preview: \(note.preview.rawValue)",
            ]
        } else {
            out.append("- Note: none selected")
        }
        out += [
            "- List scope: \(list.scope)",
            "- Age filter: \(list.days.map { $0 == 1 ? "today" : "last \($0) days" } ?? "none")",
            "- Label filter: \(list.labels.isEmpty ? "none" : list.labels.joined(separator: ", "))",
            "- Filter text: \(list.hasFilterText ? "set" : "none")",
            "- Similar notes: \(list.similarNotes)",
        ]
        if let logError {
            out += ["", "## Recent logs", "", "_The log could not be read: \(logError)_"]
        } else if let logLines {
            let fence = Self.fence(for: logLines)
            out += ["", "## Recent logs", ""]
            out += logLines.isEmpty ? ["_No log lines in the last 10 minutes._"] : [fence] + logLines + [fence]
        }
        if let screenshot {
            out += ["", "## Screenshot", "", screenshot]
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A note as the body of a GitHub issue: every attachment reference
    /// (inline images and link definitions) becomes a line asking the user
    /// to drag the image in by hand, since GitHub cannot reach the store.
    /// Images the parser resolves to an attachment are found by the parser,
    /// so reference-style uses (`![plot][img]`) go too; definitions, which
    /// the parser consumes, are found by pattern, inside quotes and across
    /// CRLF line breaks as well.
    public static func issueMarkdown(_ body: String) -> String {
        let ns = body as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let inline = AttachmentReference.pattern.matches(in: body, range: whole).map(\.range)
        let definitions = issueDefinitionPattern.matches(in: body, range: whole).map { $0.range(at: 1) }
        let ranges = (inline + definitions + parsedAttachmentImageRanges(in: body))
            .sorted { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        var out = ""
        var cursor = 0
        for range in ranges where range.location >= cursor {
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += attachmentPlaceholder
            cursor = range.location + range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// A link reference definition naming an attachment, after any quote
    /// or list markers, its destination on the same line or the next, with an
    /// optional title. Group 1 is the definition without the markers.
    static let issueDefinitionPattern = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*(?:>|[-+*](?=[ \t])|[0-9]{1,9}[.)](?=[ \t])))*[ \t]*(\[(?:[^\]\\]|\\.)+\]:[ \t]*(?:\r?\n(?:[ \t]*>)*)?[ \t]*<?(?i:attachment):[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}>?(?:[ \t]+(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^)\\]|\\.)*\)))?)"#,
        options: [.anchorsMatchLines]
    )

    /// Where each image the parser resolves to an attachment is written,
    /// whatever its form, as UTF-16 ranges of `body`.
    static func parsedAttachmentImageRanges(in body: String) -> [NSRange] {
        guard body.range(of: AttachmentReference.scheme, options: .caseInsensitive) != nil else { return [] }
        var walker = AttachmentImageRanges()
        walker.visit(Document(parsing: body))
        guard !walker.ranges.isEmpty else { return [] }
        // Line starts in UTF-8 bytes, as the parser counts: after \n, after
        // a \r not followed by \n.
        let bytes = Array(body.utf8)
        var starts = [0]
        for (index, byte) in bytes.enumerated() {
            if byte == 0x0A || (byte == 0x0D && (index + 1 == bytes.count || bytes[index + 1] != 0x0A)) {
                starts.append(index + 1)
            }
        }
        func offset(_ location: SourceLocation) -> String.Index? {
            guard location.line >= 1, location.line <= starts.count else { return nil }
            let byte = starts[location.line - 1] + location.column - 1
            guard byte >= 0, byte <= bytes.count else { return nil }
            return body.utf8.index(body.utf8.startIndex, offsetBy: byte, limitedBy: body.utf8.endIndex)
        }
        return walker.ranges.compactMap { range in
            guard let lower = offset(range.lowerBound), let upper = offset(range.upperBound), lower <= upper else { return nil }
            return NSRange(lower..<upper, in: body)
        }
    }

    /// The newest `maxLines` lines, each cut to `maxLineLength` characters.
    public static func cappedLog(_ lines: [String], maxLines: Int = maxLogLines, maxLineLength: Int = maxLogLineLength) -> [String] {
        lines.suffix(max(maxLines, 0)).map { line in
            line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…" : line
        }
    }

    /// Lines as an editor numbers them: none for an empty text, and a
    /// trailing newline does not start another.
    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = 1
        for scalar in text.unicodeScalars where scalar == "\n" { lines += 1 }
        return text.hasSuffix("\n") ? lines - 1 : lines
    }

    // MARK: Helpers

    private static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func describe(_ sync: Sync, timeZone: TimeZone) -> String {
        switch sync {
        case .unavailable: return "not in this build"
        case .off: return "off"
        case .on(let lastSynced, let problem):
            var text = "on, last synced \(lastSynced.map { stamp($0, timeZone: timeZone) } ?? "never")"
            if let problem { text += "; problem: \(problem)" }
            return text
        }
    }

    /// A code fence longer than any run of backticks in the lines, so a
    /// log line cannot close it.
    static func fence(for lines: [String]) -> String {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

/// Walks parsed markdown for the source ranges of images that show an
/// attachment.
private struct AttachmentImageRanges: MarkupWalker {
    var ranges: [SourceRange] = []

    mutating func visitImage(_ image: Markdown.Image) {
        if let source = image.source, AttachmentReference.id(fromSource: source) != nil, let range = image.range {
            ranges.append(range)
        }
    }
}
