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
    /// Whether the script assigned `fullText` while a range was selected.
    /// Boop ignores that; with one selected range it is applied to the
    /// whole note, since what the script meant is unambiguous.
    public var fullTextAssigned = false

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
/// posted. `outputs` is empty when the script could not run at all.
/// `wholeNote` is set when a single selected range's script assigned
/// `fullText`: the whole note's new text.
public struct ScriptResponse: Codable, Sendable, Equatable {
    public var outputs: [String]
    public var wholeNote: String?
    public var errors: [String]
    public var infos: [String]

    public init(outputs: [String], wholeNote: String? = nil, errors: [String] = [], infos: [String] = []) {
        self.outputs = outputs
        self.wholeNote = wholeNote
        self.errors = errors
        self.infos = infos
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
        if ranges.count == 1, let wholeNote = response.wholeNote { return [(whole, wholeNote)] }
        guard response.outputs.count == ranges.count else { return nil }
        return Array(zip(ranges, response.outputs))
    }
}
