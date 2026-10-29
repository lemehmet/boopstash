import Foundation
import Testing
@testable import BoopstashCore

@Suite struct ScriptTests {
    func script(_ name: String, tags: String = "", description: String = "", bias: Double = 0) -> BoopScript {
        let header = #"{"api":1,"name":"\#(name)","description":"\#(description)","tags":"\#(tags)","bias":\#(bias)}"#
        return try! BoopScript.parse("/**\n\(header)\n**/\nfunction main(state) {}", id: "t/\(name).js", bundled: true).get()
    }

    // MARK: Headers

    @Test func boopHeadersParse() throws {
        let source = """
        /**
            {
                "api":1,
                "name":"Base64 Encode",
                "description":"Encodes your text to Base64",
                "author":"See Source",
                "icon":"Metamorphose",
                "tags":"base64,atob,btoa"
            }
        **/

        function main(input) { input.text = btoa(input.text) }
        """
        let parsed = try BoopScript.parse(source, id: "bundled/Base64Encode.js", bundled: true).get()
        #expect(parsed.name == "Base64 Encode")
        #expect(parsed.description == "Encodes your text to Base64")
        #expect(parsed.author == "See Source")
        #expect(parsed.icon == "metamorphose")
        #expect(parsed.tags == ["base64", "atob", "btoa"])
        #expect(parsed.bias == 0)
        #expect(parsed.source == source)
    }

    @Test(arguments: [
        ("function main() {}", "no /** … **/ header"),
        ("/** not json **/", "the header is not a JSON object"),
        (#"/** {"api":1} **/"#, #"the header has no "name""#),
        (#"/** {"name":"  "} **/"#, #"the header has no "name""#),
        (#"/** [1, 2] **/"#, "the header is not a JSON object"),
    ])
    func badHeadersSayWhy(_ source: String, _ message: String) {
        #expect(BoopScript.parse(source, id: "user/x.js", bundled: false) == .failure(ScriptProblem(scriptID: "user/x.js", message: message)))
    }

    // MARK: Search

    @Test func nameMatchesBeatTagsBeatDescriptions() {
        let scripts = [
            script("Count Words", description: "counts base64 things"),
            script("URL Encode", tags: "base64"),
            script("Base64 Encode"),
        ]
        #expect(ScriptSearch.rank(scripts, for: "base64").map(\.name) == ["Base64 Encode", "URL Encode", "Count Words"])
    }

    @Test func lettersInOrderStillMatch() {
        let scripts = [script("Base64 Decode"), script("Sort Lines")]
        #expect(ScriptSearch.rank(scripts, for: "b64").map(\.name) == ["Base64 Decode"])
        #expect(ScriptSearch.rank(scripts, for: "zzz").isEmpty)
    }

    @Test func anEmptyQueryListsEverythingByBiasThenName() {
        let scripts = [script("b"), script("A"), script("c", bias: 1)]
        #expect(ScriptSearch.rank(scripts, for: " ").map(\.name) == ["c", "A", "b"])
    }

    // MARK: State

    @Test func textIsTheSelectionOrTheWholeNote() {
        var selected = ScriptState(selection: "sel", fullText: "all sel all")
        #expect(selected.text == "sel")
        selected.text = "SEL"
        #expect(selected.selection == "SEL" && selected.fullText == "all sel all")
        var whole = ScriptState(selection: nil, fullText: "all")
        whole.text = "ALL"
        #expect(whole.fullText == "ALL" && !whole.isSelection)
    }

    /// Boop's insert: at the caret, after earlier inserts of the same run.
    @Test func insertGoesAtTheCaretInOrder() {
        var state = ScriptState(selection: nil, fullText: "ab|cd", insertIndex: 3)
        state.insert("1")
        state.insert("2")
        #expect(state.fullText == "ab|12cd")
        var noCaret = ScriptState(selection: nil, fullText: "old")
        noCaret.insert("new")
        #expect(noCaret.fullText == "new")
        var selected = ScriptState(selection: "x", fullText: "x")
        selected.insert("y")
        #expect(selected.selection == "y")
    }

    /// A combining mark inserted first must not move the point inside the
    /// character it joins, nor make the next insert replace the note.
    @Test func insertAfterACombiningMarkStaysInPlace() {
        var state = ScriptState(selection: nil, fullText: "ab", insertIndex: 1)
        state.insert("\u{301}")
        state.insert("X")
        #expect(state.fullText == "a\u{301}Xb")
    }

    @Test func insertCountsUTF16AtTheCaretAndCharactersAfter() {
        // The caret is after "é🙂" (1 + 2 UTF-16 units).
        var state = ScriptState(selection: nil, fullText: "é🙂z", insertIndex: 3)
        state.insert("!")
        #expect(state.fullText == "é🙂!z")
    }

    // MARK: Edits

    @Test func aRunCoversEachSelectionOrTheWholeNote() {
        let text = "one two three"
        let states = ScriptEdits.states(fullText: text, selections: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)])
        #expect(states.map(\.selection) == ["one", "three"])
        let whole = ScriptEdits.states(fullText: text, selections: [NSRange(location: 4, length: 0)])
        #expect(whole.count == 1 && whole[0].selection == nil && whole[0].insertIndex == 4)
    }

    @Test func outputsBecomeReplacements() throws {
        let text = "one two"
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)]
        let edits = try #require(ScriptEdits.replacements(fullText: text, selections: ranges, response: ScriptResponse(outputs: ["1", "2"])))
        #expect(edits.map(\.1) == ["1", "2"] && edits.map(\.0) == ranges)
        let whole = try #require(ScriptEdits.replacements(fullText: text, selections: [NSRange(location: 2, length: 0)], response: ScriptResponse(outputs: ["X"])))
        #expect(whole.count == 1 && whole[0].0 == NSRange(location: 0, length: 7))
        #expect(ScriptEdits.replacements(fullText: text, selections: ranges, response: ScriptResponse(outputs: ["only one"])) == nil)
        // One selected range whose script rewrote the whole note.
        let rewritten = try #require(ScriptEdits.replacements(fullText: text, selections: [ranges[0]],
                                                              response: ScriptResponse(outputs: ["one"], wholeNote: "ONE TWO")))
        #expect(rewritten.count == 1 && rewritten[0].0 == NSRange(location: 0, length: 7) && rewritten[0].1 == "ONE TWO")
    }

    @Test func requestsAndResponsesRoundTripAsJSON() throws {
        let request = ScriptRequest(scriptName: "x", source: "s", states: [ScriptState(selection: "a", fullText: "ab")])
        let decoded = try JSONDecoder().decode(ScriptRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.states == request.states && decoded.timeLimit == 2)
    }
}
