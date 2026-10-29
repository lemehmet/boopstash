import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Scripts through the real script service (ADR 0007): Boop's API, its
/// bundled scripts, the sandbox and the time limit.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ScriptServiceTests {
    let runner = LiveScriptRunner()

    func script(_ body: String) -> String {
        "/**\n{\"api\":1,\"name\":\"Test\"}\n**/\n" + body
    }

    func run(_ source: String, on text: String = "abc", selection: String? = nil, timeLimit: Double = 2) async -> ScriptResponse {
        await runner.run(ScriptRequest(scriptName: "Test", source: source,
                                       states: [ScriptState(selection: selection, fullText: text)], timeLimit: timeLimit))
    }

    @Test func aScriptChangesTheText() async {
        let response = await run(script("function main(state) { state.text = state.text.toUpperCase() }"))
        #expect(response == ScriptResponse(outputs: ["ABC"]))
    }

    @Test func boopLibrariesLoad() async {
        let source = script("const { encode } = require('@boop/base64'); function main(state) { state.text = encode(state.text) }")
        #expect(await run(source).outputs == ["YWJj"])
    }

    @Test func messagesComeBack() async {
        let response = await run(script("function main(state) { state.postInfo('fyi'); state.postError('bad input') }"))
        #expect(response.infos == ["fyi"])
        #expect(response.errors == ["bad input"])
        #expect(response.outputs.isEmpty, "a run that posted an error changes nothing")
    }

    @Test func exceptionsAreReported() async {
        let response = await run(script("function main(state) { null.x }"))
        #expect(response.outputs.isEmpty)
        #expect(response.errors.first?.hasPrefix("[Test] TypeError") == true, "\(response.errors)")
    }

    /// Nothing reaches the network or the disk: none of these exist, and
    /// `require` resolves only Boop's bundled libraries.
    @Test func scriptsHaveNoNetworkFilesOrTimers() async {
        let probe = script("""
        function main(state) {
            state.text = [typeof fetch, typeof XMLHttpRequest, typeof setTimeout, typeof WebSocket,
                          String(require('fs')), String(require('@boop/../../../etc/hosts')),
                          String(require('/etc/hosts'))].join(',')
        }
        """)
        #expect(await run(probe).outputs == [Array(repeating: "undefined", count: 7).joined(separator: ",")])
    }

    @Test func aRunawayScriptIsStoppedAndTheNextRunWorks() async {
        let started = ContinuousClock.now
        let response = await run(script("function main(state) { while (true) {} }"), timeLimit: 1)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(response.outputs.isEmpty)
        #expect(response.errors.first?.contains("was stopped") == true, "\(response.errors)")
        #expect(await run(script("function main(state) { state.text = 'ok' }")).outputs == ["ok"])
    }

    @Test func insertGoesAtTheCaret() async {
        let response = await runner.run(ScriptRequest(scriptName: "Test", source: script("function main(state) { state.insert('X') }"),
                                                      states: [ScriptState(selection: nil, fullText: "ab", insertIndex: 1)]))
        #expect(response.outputs == ["aXb"])
    }

    /// Scripts that, as in Boop, throw rather than post an error on input
    /// they cannot read get input they can.
    static let fixtures = [
        "Minify JSON": #"{"a": [1, 2]}"#,
        "Hex To ASCII": "48656c6c6f",
    ]

    /// Every bundled Boop script loads and runs on ordinary text without an
    /// exception. Posting an error (bad input for that script) is fine.
    @Test func everyBundledScriptRuns() async {
        let library = ScriptLibrary.bundled()
        #expect(library.problems.isEmpty, "\(library.problems)")
        #expect(library.scripts.count >= 70)
        var failures: [String] = []
        for script in library.scripts {
            let response = await runner.run(ScriptRequest(
                scriptName: script.name, source: script.source,
                states: [ScriptState(selection: nil, fullText: Self.fixtures[script.name]
                                     ?? "Hello, World! 42\n{\"a\": [1, 2]}\nhttps://example.com/?q=a b")]))
            if let exception = response.errors.first(where: { $0.hasPrefix("[\(script.name)]") }) {
                failures.append(exception)
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func theEditorAppliesARunAsOneUndoableEdit() async {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.string = "one two three"
        view.selectedRanges = [NSValue(range: NSRange(location: 0, length: 3)), NSValue(range: NSRange(location: 8, length: 5))]
        let upper = try! BoopScript.parse(script("function main(state) { state.text = state.text.toUpperCase() }"),
                                          id: "test/upper.js", bundled: false).get()
        await view.run(upper, with: runner)
        #expect(view.string == "ONE two THREE")
        #expect(view.selectedRanges.map(\.rangeValue) == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)])
        view.undoManager?.undo()
        #expect(view.string == "one two three")
        window.close()
    }
}
