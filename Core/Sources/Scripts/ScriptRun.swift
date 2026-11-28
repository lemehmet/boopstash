import Foundation

/// What a script sees and changes: Boop's `state` object (ADR 0005), less
/// its JavaScriptCore binding, which the script service adds.
public struct ScriptState: Codable, Hashable, Sendable {
    public var isSelection: Bool
    public var selection: String?
    public var fullText: String?
    /// Where `insert` puts text when nothing is selected: the caret, in
    /// UTF-16 units as the editor reports it.
    public var insertIndex: Int?
    /// How many UTF-16 units earlier `insert` calls added after the caret.
    var insertedUTF16 = 0

    public init(selection: String?, fullText: String, insertIndex: Int? = nil) {
        isSelection = selection != nil
        self.selection = selection
        self.fullText = fullText
        self.insertIndex = insertIndex
    }

    /// The selection when there is one, otherwise the whole note.
    public var text: String? {
        get { isSelection ? selection : fullText }
        set { if isSelection { selection = newValue } else { fullText = newValue } }
    }

    /// Boop's `insert`: replaces the selection; without one, inserts at the
    /// caret (after anything inserted earlier in the run), or replaces the
    /// whole text when there is no caret. The point is kept in UTF-16 units
    /// and the text inserted by Unicode scalar, so an earlier insert of a
    /// combining mark cannot move it inside a character.
    public mutating func insert(_ value: String) {
        guard !isSelection else {
            selection = value
            return
        }
        guard let insertIndex, var full = fullText,
              let point = full.utf16.index(full.utf16.startIndex, offsetBy: insertIndex + insertedUTF16, limitedBy: full.utf16.endIndex),
              let scalarPoint = point.samePosition(in: full.unicodeScalars)
        else {
            fullText = value
            return
        }
        full.unicodeScalars.insert(contentsOf: value.unicodeScalars, at: scalarPoint)
        fullText = full
        insertedUTF16 += value.utf16.count
    }
}

/// One run of a script, sent to the script service (ADR 0007): the script's
/// source and one state per selected range (Boop runs a script once per
/// range of a multiple selection, or once on the whole note).
public struct ScriptRequest: Codable, Sendable {
    public var scriptName: String
    public var source: String
    public var states: [ScriptState]
    /// Seconds before the service gives up on the run.
    public var timeLimit: Double

    public init(scriptName: String, source: String, states: [ScriptState], timeLimit: Double = 2) {
        self.scriptName = scriptName
        self.source = source
        self.states = states
        self.timeLimit = timeLimit
    }
}

/// What came back: each state's final `text`, in order, and what the script
/// posted. `outputs` is empty when the script could not run at all. With a
/// selection, only the selection changes: Boop ignores `fullText` writes
/// then, and so does this (scripts such as Collapse build from the
/// selection but assign `fullText`, which would replace the whole note).
public struct ScriptResponse: Codable, Sendable, Equatable {
    public var outputs: [String]
    public var errors: [String]
    public var infos: [String]
    /// Where in the script an error is (#309), by its index in `errors`.
    /// An error the script posted, or one from outside the script, has none.
    public var errorLocations: [Int: ScriptErrorLocation]

    public init(outputs: [String], errors: [String] = [], infos: [String] = [], errorLocations: [Int: ScriptErrorLocation] = [:]) {
        self.outputs = outputs
        self.errors = errors
        self.infos = infos
        self.errorLocations = errorLocations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputs = try container.decode([String].self, forKey: .outputs)
        errors = try container.decode([String].self, forKey: .errors)
        infos = try container.decode([String].self, forKey: .infos)
        // An answer without locations reads as before.
        errorLocations = try container.decodeIfPresent([Int: ScriptErrorLocation].self, forKey: .errorLocations) ?? [:]
    }

    /// The errors as they are shown: each with its place in the script
    /// when it has one, "… (line 12, column 5)".
    public var shownErrors: [String] {
        errors.enumerated().map { index, text in
            errorLocations[index].map { "\(text) (\($0.description))" } ?? text
        }
    }
}

/// A place in a script's source, as JavaScriptCore reports it and as an
/// editor counts it: both from 1.
public struct ScriptErrorLocation: Codable, Sendable, Hashable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "line \(line), column \(column)" }

    /// The source URL the script service evaluates the user's script
    /// under. A bundled library has its file's.
    public static let scriptURL = "boop://script"

    /// The place in the user's script an exception points at, from the
    /// exception's `sourceURL`, `line`, `column` and `stack`.
    ///
    /// An exception raised in the script has the script's URL and its own
    /// line. One raised in a library the script called has the library's,
    /// and the script's place is the first frame of the stack that is in
    /// the script ("main@boop://script:12:5"). Anything else has no place
    /// in the script: none is better than a wrong one.
    public static func make(sourceURL: String?, line: Int?, column: Int?, stack: String?) -> ScriptErrorLocation? {
        if sourceURL == scriptURL, let line, line >= 1 {
            return ScriptErrorLocation(line: line, column: max(column ?? 1, 1))
        }
        guard let stack else { return nil }
        for frame in stack.split(whereSeparator: \.isNewline) {
            // The frame's URL is the script's: the whole frame, or what
            // follows its function's `@`; never one inside another URL.
            guard let match = frame.firstMatch(of: /(?:^|@)boop:\/\/script:(\d+):(\d+)$/),
                  let line = Int(match.1), let column = Int(match.2), line >= 1 else { continue }
            return ScriptErrorLocation(line: line, column: max(column, 1))
        }
        return nil
    }

    /// The offset in `text`, in UTF-16 units as a text view counts, of
    /// this place: lines end as JavaScript's do (LF, CR, CRLF, U+2028,
    /// U+2029). A column past its line's end is the line's end, and a line
    /// past the text's end is the text's end, so a script edited since
    /// the error still has somewhere to go. A line or column below 1 is 1.
    public func offset(in text: String) -> Int {
        let units = Array(text.utf16)
        let line = max(line, 1)
        var index = 0
        var current = 1
        while current < line, index < units.count {
            let unit = units[index]
            index += 1
            switch unit {
            case 0x0D:
                if index < units.count, units[index] == 0x0A { index += 1 }
                current += 1
            case 0x0A, 0x2028, 0x2029:
                current += 1
            default:
                break
            }
        }
        guard current == line else { return units.count }
        var remaining = max(column, 1) - 1
        while remaining > 0, index < units.count, ![0x0D, 0x0A, 0x2028, 0x2029].contains(units[index]) {
            index += 1
            remaining -= 1
        }
        return index
    }
}

/// Turning a run into edits of the note, Boop's way.
public enum ScriptEdits {
    /// The states for a run: one per non-empty selected range, or one for
    /// the whole text with the caret as the insertion point.
    public static func states(fullText: String, selections: [NSRange]) -> [ScriptState] {
        let ns = fullText as NSString
        let ranges = selections.filter { $0.length > 0 }
        guard !ranges.isEmpty else {
            return [ScriptState(selection: nil, fullText: fullText, insertIndex: selections.first?.location)]
        }
        return ranges.map { ScriptState(selection: ns.substring(with: $0), fullText: fullText) }
    }

    /// The replacements to make, as (range, text) in the original text's
    /// coordinates: the whole text, or each selected range. Nil when the
    /// response does not match the request.
    public static func replacements(fullText: String, selections: [NSRange], response: ScriptResponse) -> [(NSRange, String)]? {
        let ranges = selections.filter { $0.length > 0 }
        let whole = NSRange(location: 0, length: (fullText as NSString).length)
        if ranges.isEmpty {
            guard response.outputs.count == 1 else { return nil }
            return [(whole, response.outputs[0])]
        }
        guard response.outputs.count == ranges.count else { return nil }
        return Array(zip(ranges, response.outputs))
    }
}
