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

    // MARK: Catalog

    @Test func aUserScriptReplacesTheBundledOneOfTheSameName() {
        let bundled = [script("Base64 Encode"), script("Sort Lines")]
        var mine = script("Sort Lines", description: "my way")
        mine.isBundled = false
        let merged = ScriptCatalog.merge(bundled: bundled, user: [mine])
        #expect(merged.map(\.name) == ["Base64 Encode", "Sort Lines"])
        #expect(merged.last?.description == "my way" && merged.last?.isBundled == false)
    }

    @Test func aUserScriptReplacesTheBundledOneWhateverTheCase() {
        var mine = script("sort LINES", description: "my way")
        mine.isBundled = false
        let merged = ScriptCatalog.merge(bundled: [script("Base64 Encode"), script("Sort Lines")], user: [mine])
        #expect(merged.map(\.name) == ["Base64 Encode", "sort LINES"])
        #expect(ScriptCatalog.nameKey(" Sort Lines\n") == "sort lines")
        // A built-in command is shadowed the same way.
        var clean = script("clean up pasted text")
        clean.isBundled = false
        #expect(ScriptCatalog.all(bundled: [], user: [clean]).map(\.name) == ["clean up pasted text"])
    }

    @Test func theCatalogStartsWithTheBuiltInCommands() {
        let all = ScriptCatalog.all(bundled: [script("Base64 Encode")], user: [])
        #expect(all.map(\.name) == ["Clean Up Pasted Text", "Base64 Encode"])
        #expect(all[0].builtIn == .cleanUpPastedText && all[0].isBundled && all[0].source.isEmpty)
        #expect(all[1].builtIn == nil)
        #expect(ScriptCatalog.all(bundled: [], user: []).map(\.builtIn) == [.cleanUpPastedText], "with no scripts at all")
    }

    @Test func aUserScriptReplacesTheBuiltInCommandOfTheSameName() {
        var mine = script("Clean Up Pasted Text", description: "my way")
        mine.isBundled = false
        let all = ScriptCatalog.all(bundled: [], user: [mine])
        #expect(all.count == 1 && all[0].builtIn == nil && all[0].description == "my way")
    }

    @Test func theBuiltInCommandIsFoundByWhatItDoes() {
        let all = ScriptCatalog.all(bundled: [script("Base64 Encode")], user: [])
        for query in ["clean", "pasted", "table", "ansi"] {
            #expect(ScriptSearch.rank(all, for: query).first?.builtIn == .cleanUpPastedText, "\(query)")
        }
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

    }

    @Test func requestsAndResponsesRoundTripAsJSON() throws {
        let request = ScriptRequest(scriptName: "x", source: "s", states: [ScriptState(selection: "a", fullText: "ab")])
        let decoded = try JSONDecoder().decode(ScriptRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.states == request.states && decoded.timeLimit == 2)
    }
}

/// Where a script's error is (#309): read from an exception, counted into
/// the script's text, and carried in the response.
@Suite struct ScriptErrorLocationTests {
    @Test func anExceptionInTheScriptHasItsOwnPlace() {
        let location = ScriptErrorLocation.make(sourceURL: "boop://script", line: 12, column: 5, stack: nil)
        #expect(location == ScriptErrorLocation(line: 12, column: 5))
        #expect(location?.description == "line 12, column 5")
    }

    @Test func aMissingColumnIsTheLinesStart() {
        #expect(ScriptErrorLocation.make(sourceURL: "boop://script", line: 3, column: nil, stack: nil) == ScriptErrorLocation(line: 3, column: 1))
        #expect(ScriptErrorLocation.make(sourceURL: "boop://script", line: 3, column: 0, stack: nil) == ScriptErrorLocation(line: 3, column: 1))
    }

    @Test func anExceptionInALibraryHasThePlaceTheScriptCalledItFrom() {
        let stack = "decode@file:///lib/base64.js:40:22\nmain@boop://script:7:19\nglobal code@boop://script:1:1"
        let location = ScriptErrorLocation.make(sourceURL: "file:///lib/base64.js", line: 40, column: 22, stack: stack)
        #expect(location == ScriptErrorLocation(line: 7, column: 19))
    }

    @Test func anExceptionFromOutsideTheScriptHasNoPlace() {
        #expect(ScriptErrorLocation.make(sourceURL: "file:///lib/base64.js", line: 40, column: 22, stack: "decode@file:///lib/base64.js:40:22") == nil)
        #expect(ScriptErrorLocation.make(sourceURL: nil, line: nil, column: nil, stack: nil) == nil)
        #expect(ScriptErrorLocation.make(sourceURL: "boop://script", line: 0, column: 1, stack: nil) == nil)
        // A frame that only mentions the URL is not one in the script.
        #expect(ScriptErrorLocation.make(sourceURL: nil, line: nil, column: nil, stack: "f@file:///boop://script:1:2/x.js:9:9") == nil)
        #expect(ScriptErrorLocation.make(sourceURL: "file:///lib.js", line: 40, column: 1, stack: "f@file:///boop://script:9:9") == nil)
        #expect(ScriptErrorLocation.make(sourceURL: nil, line: nil, column: nil, stack: "f@https://x/?u=boop://script:9:9") == nil)
        // A frame that is only the URL, as global code's can be.
        #expect(ScriptErrorLocation.make(sourceURL: nil, line: nil, column: nil, stack: "boop://script:4:2") == ScriptErrorLocation(line: 4, column: 2))
    }

    @Test(arguments: [
        (1, 1, 0), (1, 3, 2), (2, 1, 4), (3, 2, 9),
        // A column past the line's end is the line's end.
        (1, 99, 3), (2, 99, 7),
        // The last line, and past it.
        (3, 99, 11), (4, 1, 11), (99, 1, 11),
        // Not a place: the start.
        (0, 1, 0), (1, 0, 0),
    ])
    func aPlaceIsAnOffsetInTheText(line: Int, column: Int, offset: Int) {
        #expect(ScriptErrorLocation(line: line, column: column).offset(in: "abc\ndef\nxyz") == offset)
    }

    @Test func linesEndAsJavaScriptsDo() {
        // CRLF is one line end; CR, U+2028 and U+2029 are each one.
        let text = "a\r\nb\rc\u{2028}d\u{2029}e"
        #expect(ScriptErrorLocation(line: 2, column: 1).offset(in: text) == 3)
        #expect(ScriptErrorLocation(line: 3, column: 1).offset(in: text) == 5)
        #expect(ScriptErrorLocation(line: 4, column: 1).offset(in: text) == 7)
        #expect(ScriptErrorLocation(line: 5, column: 1).offset(in: text) == 9)
        // A column past a CRLF line's end stops before the CR.
        #expect(ScriptErrorLocation(line: 1, column: 9).offset(in: text) == 1)
        // A text that ends with a line end has an empty last line.
        #expect(ScriptErrorLocation(line: 2, column: 1).offset(in: "a\n") == 2)
        #expect(ScriptErrorLocation(line: 1, column: 1).offset(in: "") == 0)
    }

    @Test func offsetsCountUTF16AsATextViewDoes() {
        #expect(ScriptErrorLocation(line: 2, column: 2).offset(in: "😀\nab") == 4)
    }

    @Test func aResponseCarriesThePlaceAndShowsIt() throws {
        let response = ScriptResponse(outputs: [], errors: ["[Test] SyntaxError: Unexpected token '}'", "bad input"],
                                      errorLocations: [0: ScriptErrorLocation(line: 12, column: 5)])
        #expect(response.shownErrors == ["[Test] SyntaxError: Unexpected token '}' (line 12, column 5)", "bad input"])
        let read = try JSONDecoder().decode(ScriptResponse.self, from: JSONEncoder().encode(response))
        #expect(read == response)
    }

    @Test func anAnswerWithoutPlacesStillReads() throws {
        let old = Data(#"{"outputs":["x"],"errors":["e"],"infos":[]}"#.utf8)
        let read = try JSONDecoder().decode(ScriptResponse.self, from: old)
        #expect(read == ScriptResponse(outputs: ["x"], errors: ["e"]))
        #expect(read.shownErrors == ["e"])
    }

    @Test func theWorkbenchsNotesCarryThePlace() {
        let response = ScriptResponse(outputs: [], errors: ["[W] ReferenceError: x", "posted"], infos: ["fyi"],
                                      errorLocations: [0: ScriptErrorLocation(line: 2, column: 3)])
        let notes = ScriptWorkbenchResult.make(response: response, fullText: "t", selections: []).notes
        #expect(notes.map(\.text) == ["[W] ReferenceError: x (line 2, column 3)", "posted", "fyi"])
        #expect(notes.map(\.location) == [ScriptErrorLocation(line: 2, column: 3), nil, nil])
        #expect(notes.map(\.kind) == [.error, .error, .info])
        #expect(Set(notes.map(\.id)).count == 3)
    }
}
