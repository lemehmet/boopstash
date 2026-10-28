import Foundation
import Testing
@testable import BoopstashCore

@Suite struct KeymapTests {
    @Test func homeAndEndStayOnTheLineInEveryPreset() {
        for preset in KeymapPreset.allCases {
            let keymap = Keymap(preset: preset)
            #expect(keymap.command(for: KeyChord("home")) == .moveToLineStart, "\(preset)")
            #expect(keymap.command(for: KeyChord("end")) == .moveToLineEnd, "\(preset)")
        }
    }

    @Test func presetsDifferWhereTheEditorsDo() {
        #expect(Keymap(preset: .vsCode).command(for: KeyChord("k", [.command, .shift])) == .deleteLine)
        #expect(Keymap(preset: .jetBrains).command(for: KeyChord("d", .command)) == .duplicateLineDown)
        #expect(Keymap(preset: .vsCode).command(for: KeyChord("d", .command)) == nil)
        #expect(Keymap(preset: .emacs).command(for: KeyChord("a", .control)) == .moveToLineStart)
        #expect(Keymap(preset: .vsCode).command(for: KeyChord("a", .control)) == nil)
    }

    @Test func vsCodeIsTheDefault() {
        #expect(Keymap().bindings == Keymap(preset: .vsCode).bindings)
    }

    @Test func linuxHabitsLayerOverAnyPreset() {
        let plain = Keymap(preset: .jetBrains)
        let linux = Keymap(preset: .jetBrains, linuxHabits: true)
        #expect(plain.command(for: KeyChord("left", .control)) == nil)
        #expect(linux.command(for: KeyChord("left", .control)) == .moveWordLeft)
        #expect(linux.command(for: KeyChord("d", .command)) == .duplicateLineDown, "preset bindings survive")
    }

    @Test func pasteAsMarkdownIsEverywhere() {
        for preset in KeymapPreset.allCases {
            #expect(Keymap(preset: preset).command(for: KeyChord("v", [.command, .option, .shift])) == .pasteAsMarkdown)
        }
    }

    // MARK: Parsing

    @Test(arguments: [
        ("cmd+shift+k", KeyChord("k", [.command, .shift])),
        ("ctrl+left", KeyChord("left", .control)),
        ("alt+up", KeyChord("up", .option)),
        ("Option+Shift+Down", KeyChord("down", [.option, .shift])),
        ("home", KeyChord("home")),
        ("cmd+[", KeyChord("[", .command)),
        ("cmd++", KeyChord("+", .command)),
    ])
    func parses(_ text: String, _ expected: KeyChord) {
        #expect(KeyChord(parsing: text) == expected)
    }

    @Test(arguments: ["", "cmd+", "hyper+k", "cmd+shift+enterr", "ctrl"])
    func rejects(_ text: String) {
        #expect(KeyChord(parsing: text) == nil)
    }

    @Test func descriptionRoundTrips() {
        let chord = KeyChord("k", [.command, .shift, .option, .control])
        #expect(chord.description == "ctrl+alt+shift+cmd+k")
        #expect(KeyChord(parsing: chord.description) == chord)
    }

    // MARK: Overrides

    @Test func overridesAddReplaceAndRemove() throws {
        let json = """
        // My bindings
        [
          { "key": "cmd+d", "command": "duplicateLineDown" },
          { "key": "alt+up", "command": "moveToDocumentStart" },
          { "key": "cmd+shift+k", "command": "-deleteLine" },
          { "key": "cmd+/", "command": "-deleteLine" },
        ]
        """
        let file = try Keymap.overrides(fromJSON: Data(json.utf8))
        #expect(file.problems.isEmpty)
        let keymap = Keymap(preset: .vsCode, overrides: file.overrides)
        #expect(keymap.command(for: KeyChord("d", .command)) == .duplicateLineDown)
        #expect(keymap.command(for: KeyChord("up", .option)) == .moveToDocumentStart)
        #expect(keymap.command(for: KeyChord("k", [.command, .shift])) == nil)
        // Removing a command from a key it is not bound to leaves that key alone.
        #expect(keymap.command(for: KeyChord("/", .command)) == .toggleComment)
        #expect(keymap.problems.isEmpty)
    }

    @Test func malformedEntriesAreSkippedNotFatal() throws {
        let json = #"[{"key": "cmd+d"}, {"key": "cmd+e", "command": "deleteLine"}, 42, {"key": 1, "command": "x"}]"#
        let file = try Keymap.overrides(fromJSON: Data(json.utf8))
        #expect(file.overrides == [.init(key: "cmd+e", command: "deleteLine")])
        #expect(file.problems == [
            "entry 1: missing or non-text \"command\"",
            "entry 3: not an object",
            "entry 4: missing or non-text \"key\"",
        ])
        let keymap = Keymap(overrides: file.overrides, fileProblems: file.problems)
        #expect(keymap.command(for: KeyChord("e", .command)) == .deleteLine)
        #expect(keymap.problems.count == 3)
    }

    @Test func aFileThatIsNotAnArrayThrows() {
        #expect(throws: (any Error).self) { try Keymap.overrides(fromJSON: Data("{ nope".utf8)) }
    }

    @Test func tabIsLeftToTheTextView() {
        // Tab and Shift-Tab go to NSTextView's insertTab/insertBacktab, which
        // decide between indenting lines and inserting at the caret; binding
        // them would route them through "indent lines" instead.
        for preset in KeymapPreset.allCases {
            #expect(Keymap(preset: preset).command(for: KeyChord("tab")) == nil)
            #expect(Keymap(preset: preset).command(for: KeyChord("tab", .shift)) == nil)
        }
    }

    @Test func badOverridesAreReportedNotFatal() {
        let keymap = Keymap(overrides: [
            .init(key: "hyper+x", command: "deleteLine"),
            .init(key: "cmd+x", command: "launchMissiles"),
            .init(key: "cmd+e", command: "deleteLine"),
        ])
        #expect(keymap.problems.count == 2)
        #expect(keymap.command(for: KeyChord("e", .command)) == .deleteLine)
    }
}
