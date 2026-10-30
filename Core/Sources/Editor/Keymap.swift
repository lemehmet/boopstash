import Foundation

/// Something the editor can do in response to a key combination (ADR 0003).
/// Raw values are the names `keybindings.json` uses.
public enum EditorCommand: String, CaseIterable, Codable, Sendable {
    case moveToLineStart, moveToLineEnd, selectToLineStart, selectToLineEnd
    case moveToDocumentStart, moveToDocumentEnd
    case moveWordLeft, moveWordRight, selectWordLeft, selectWordRight
    case moveUp, moveDown, moveCharacterLeft, moveCharacterRight
    case deleteWordBackward, deleteWordForward, deleteToLineEnd, deleteLine, deleteForward
    case duplicateLineDown, duplicateLineUp, swapLineUp, swapLineDown
    case indentLines, unindentLines
    case fold, unfold, foldAll, unfoldAll
    case toggleComment
    case pasteAsMarkdown
    case formatDocument, formatJSONSortingKeys
}

/// A key combination, independent of AppKit so presets are plain data that
/// Core can test. The app translates `NSEvent`s into this.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// Named keys, plus any single character in lower case.
    public static let namedKeys: Set<String> = [
        "left", "right", "up", "down", "home", "end", "pageup", "pagedown",
        "backspace", "delete", "tab", "enter", "escape", "space",
    ]

    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses VS Code's spelling: `cmd+shift+k`, `ctrl+left`, `alt+up`,
    /// `home`. Modifier names: cmd/command, alt/opt/option, ctrl/control,
    /// shift. Nil when the string names no key or an unknown one.
    public init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { return nil }
        // "cmd++" would split into "cmd", "", "": the key is "+".
        let key = last.isEmpty && parts.count >= 2 && parts[parts.count - 2].isEmpty ? "+" : last
        let modifierNames = key == "+" ? parts.dropLast(2) : parts.dropLast()
        var modifiers: Modifiers = []
        for name in modifierNames {
            switch name {
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard Self.namedKeys.contains(key) || key.count == 1 else { return nil }
        self.init(key, modifiers)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

/// The built-in tables. VS Code is the default (ADR 0003).
public enum KeymapPreset: String, CaseIterable, Codable, Sendable {
    case vsCode, jetBrains, emacs

    public var displayName: String {
        switch self {
        case .vsCode: "VS Code"
        case .jetBrains: "JetBrains"
        case .emacs: "Emacs"
        }
    }

    public var bindings: [KeyChord: EditorCommand] {
        switch self {
        case .vsCode: Self.shared.merging(Self.vsCodeOnly) { _, new in new }
        case .jetBrains: Self.shared.merging(Self.jetBrainsOnly) { _, new in new }
        case .emacs: Self.shared.merging(Self.emacsOnly) { _, new in new }
        }
    }

    /// What every preset agrees on, which is mostly the macOS conventions
    /// plus the one thing AppKit gets wrong for editors: Home and End.
    static let shared: [KeyChord: EditorCommand] = [
        KeyChord("home"): .moveToLineStart,
        KeyChord("end"): .moveToLineEnd,
        KeyChord("home", .shift): .selectToLineStart,
        KeyChord("end", .shift): .selectToLineEnd,
        KeyChord("left", .command): .moveToLineStart,
        KeyChord("right", .command): .moveToLineEnd,
        KeyChord("up", .command): .moveToDocumentStart,
        KeyChord("down", .command): .moveToDocumentEnd,
        KeyChord("left", .option): .moveWordLeft,
        KeyChord("right", .option): .moveWordRight,
        KeyChord("left", [.option, .shift]): .selectWordLeft,
        KeyChord("right", [.option, .shift]): .selectWordRight,
        KeyChord("backspace", .option): .deleteWordBackward,
        KeyChord("delete", .option): .deleteWordForward,
        KeyChord("/", .command): .toggleComment,
        KeyChord("v", [.command, .option, .shift]): .pasteAsMarkdown,
    ]

    static let vsCodeOnly: [KeyChord: EditorCommand] = [
        KeyChord("k", [.command, .shift]): .deleteLine,
        KeyChord("down", [.option, .shift]): .duplicateLineDown,
        KeyChord("up", [.option, .shift]): .duplicateLineUp,
        KeyChord("up", .option): .swapLineUp,
        KeyChord("down", .option): .swapLineDown,
        KeyChord("]", .command): .indentLines,
        KeyChord("[", .command): .unindentLines,
        KeyChord("[", [.command, .option]): .fold,
        KeyChord("]", [.command, .option]): .unfold,
        KeyChord("f", [.option, .shift]): .formatDocument,
    ]

    static let jetBrainsOnly: [KeyChord: EditorCommand] = [
        KeyChord("d", .command): .duplicateLineDown,
        KeyChord("backspace", .command): .deleteLine,
        KeyChord("up", [.option, .shift]): .swapLineUp,
        KeyChord("down", [.option, .shift]): .swapLineDown,
        KeyChord("-", .command): .fold,
        KeyChord("=", .command): .unfold,
        KeyChord("-", [.command, .shift]): .foldAll,
        KeyChord("=", [.command, .shift]): .unfoldAll,
        KeyChord("l", [.command, .option]): .formatDocument,
    ]

    static let emacsOnly: [KeyChord: EditorCommand] = [
        KeyChord("a", .control): .moveToLineStart,
        KeyChord("e", .control): .moveToLineEnd,
        KeyChord("f", .control): .moveCharacterRight,
        KeyChord("b", .control): .moveCharacterLeft,
        KeyChord("n", .control): .moveDown,
        KeyChord("p", .control): .moveUp,
        KeyChord("f", .option): .moveWordRight,
        KeyChord("b", .option): .moveWordLeft,
        KeyChord("d", .control): .deleteForward,
        KeyChord("d", .option): .deleteWordForward,
        KeyChord("k", .control): .deleteToLineEnd,
        KeyChord("<", [.option, .shift]): .moveToDocumentStart,
        KeyChord(">", [.option, .shift]): .moveToDocumentEnd,
    ]

    /// Layered over any preset for people whose fingers learned on Linux.
    /// Ctrl+←/→ reach the app only after Mission Control's shortcuts are
    /// changed in System Settings (ADR 0006).
    static let linuxHabits: [KeyChord: EditorCommand] = [
        KeyChord("left", .control): .moveWordLeft,
        KeyChord("right", .control): .moveWordRight,
        KeyChord("left", [.control, .shift]): .selectWordLeft,
        KeyChord("right", [.control, .shift]): .selectWordRight,
        KeyChord("backspace", .control): .deleteWordBackward,
        KeyChord("delete", .control): .deleteWordForward,
        KeyChord("home", .control): .moveToDocumentStart,
        KeyChord("end", .control): .moveToDocumentEnd,
    ]
}

/// The bindings in force: a preset, optionally the Linux-habits layer, then
/// the user's overrides, each layer winning over the one before.
public struct Keymap: Sendable {
    public private(set) var bindings: [KeyChord: EditorCommand]
    /// Override entries that could not be applied, for Settings to show.
    public private(set) var problems: [String]

    /// `fileProblems` are carried through from reading `keybindings.json`
    /// (`OverridesFile.problems`), so Settings shows one list.
    public init(preset: KeymapPreset = .vsCode, linuxHabits: Bool = false, overrides: [Override] = [], fileProblems: [String] = []) {
        var bindings = preset.bindings
        if linuxHabits { bindings.merge(KeymapPreset.linuxHabits) { _, new in new } }
        var problems = fileProblems
        for entry in overrides {
            guard let chord = KeyChord(parsing: entry.key) else {
                problems.append("\"\(entry.key)\": unknown key")
                continue
            }
            // VS Code's convention: "-command" removes that command's binding
            // on that key and leaves every other binding alone.
            let removing = entry.command.hasPrefix("-")
            let name = removing ? String(entry.command.dropFirst()) : entry.command
            guard let command = EditorCommand(rawValue: name) else {
                problems.append("\"\(entry.key)\": unknown command \"\(name)\"")
                continue
            }
            if removing {
                if bindings[chord] == command { bindings[chord] = nil }
            } else {
                bindings[chord] = command
            }
        }
        self.bindings = bindings
        self.problems = problems
    }

    public func command(for chord: KeyChord) -> EditorCommand? {
        bindings[chord]
    }

    /// One `keybindings.json` entry, in VS Code's shape.
    public struct Override: Codable, Equatable, Sendable {
        public var key: String
        public var command: String

        enum CodingKeys: String, CodingKey { case key, command }
        public init(key: String, command: String) {
            self.key = key
            self.command = command
        }
    }

    /// The usable entries of a `keybindings.json` and what was wrong with
    /// the rest.
    public struct OverridesFile: Equatable, Sendable {
        public var overrides: [Override]
        public var problems: [String]

        public init(overrides: [Override], problems: [String]) {
            self.overrides = overrides
            self.problems = problems
        }
    }

    /// Reads `keybindings.json`. VS Code's files may carry comments and
    /// trailing commas, so both are tolerated. Entries are decoded one at a
    /// time: a bad entry is reported and skipped, never allowed to discard the
    /// good ones. Only a file that is not a JSON array at all throws.
    public static func overrides(fromJSON data: Data) throws -> OverridesFile {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let entries = try decoder.decode([LossyEntry].self, from: data)
        var file = OverridesFile(overrides: [], problems: [])
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .valid(let override): file.overrides.append(override)
            case .invalid(let reason): file.problems.append("entry \(index + 1): \(reason)")
            }
        }
        return file
    }

    enum LossyEntry: Decodable {
        case valid(Override)
        case invalid(String)

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Override.CodingKeys.self) else {
                self = .invalid("not an object")
                return
            }
            let key = try? container.decode(String.self, forKey: .key)
            let command = try? container.decode(String.self, forKey: .command)
            switch (key, command) {
            case let (key?, command?): self = .valid(Override(key: key, command: command))
            case (nil, _): self = .invalid("missing or non-text \"key\"")
            case (_, nil): self = .invalid("missing or non-text \"command\"")
            }
        }
    }
}
