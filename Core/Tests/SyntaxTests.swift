import Foundation
import Testing
@testable import BoopstashCore

@Suite struct SyntaxLanguageTests {
    @Test(arguments: [
        (#"{"a": 1}"#, SyntaxLanguage?.some(.json)),
        ("name: x\nversion: 1\nitems:\n  - a", .yaml),
        ("[package]\nname = \"boop\"\nversion = \"0.1.0\"", .toml),
        ("# Title\n\nSome [link](x) and\n- [ ] task", .markdown),
        ("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b", .diff),
        ("import SwiftUI\n\nstruct V: View {\n    @State var x = 0\n    var body: some View { Text(\"x\") }\n}", .swift),
        ("guard let x = y else { return }\nfunc f() -> Int {\n  return 1\n}", .swift),
        ("import os\n\ndef main():\n    print(os.getcwd())\n\nif __name__ == '__main__':\n    main()", .python),
        ("const x = require('x');\nfunction f() { console.log(x); }\nmodule.exports = f;", .javascript),
        ("interface User {\n  name: string;\n}\nconst u: User = { name: 'a' };\nexport type Id = number;", .typescript),
        ("package main\n\nimport \"fmt\"\n\nfunc main() {\n\tx := 1\n\tfmt.Println(x)\n}", .go),
        ("use std::io;\n\nfn main() {\n    let mut x = vec![1];\n    println!(\"{:?}\", x);\n}", .rust),
        ("#include <stdio.h>\n\nint main(void) {\n    printf(\"hi\\n\");\n}", .c),
        ("import java.util.List;\n\npublic class A {\n    @Override\n    public String toString() { return \"\"; }\n}", .java),
        ("#!/bin/bash\nset -e\nexport X=1\nif [ -f x ]; then\n  echo hi\nfi", .bash),
        (".button,\n.link {\n  color: red;\n  margin: 0;\n}", .css),
        ("Remember to call the plumber and buy milk if the store is open.", nil),
        ("Traceback (most recent call last):\n  File \"x.py\", line 1\nKeyError: 'a'", nil),
    ])
    func detects(_ text: String, _ expected: SyntaxLanguage?) {
        #expect(SyntaxLanguage.detect(text) == expected, "scores: \(SyntaxLanguage.scores(text).filter { $0.value > 0 })")
    }

    @Test func shellCommandsInPlainTextNeedStrongEvidence() {
        #expect(SyntaxLanguage.detect("git status") == nil)
        #expect(SyntaxLanguage.detect("$ git status\n$ git push\n$ docker ps\n$ kubectl get pods") == .bash)
    }
}

@Suite struct SyntaxEngineTests {
    static let samples: [SyntaxLanguage: String] = [
        .json: #"{"name": "x", "n": 1, "ok": true}"#,
        .yaml: "name: x\nlist:\n  - 1\n",
        .toml: "[a]\nb = \"c\"\n",
        .xml: "<a href=\"x\">text</a>\n",
        .markdown: "# Title\n\n```swift\nlet x = 1\n```\n",
        .html: "<div class=\"x\">hi</div>\n",
        .css: ".a { color: red; }\n",
        .javascript: "const x = \"s\"; function f() { return 1; }\n",
        .typescript: "interface A { b: string }\nconst x: number = 1;\n",
        .python: "def f(x):\n    return \"s\" + str(1)\n",
        .bash: "#!/bin/bash\necho \"hi\" $HOME\n",
        .go: "package main\nfunc main() { x := \"s\" }\n",
        .rust: "fn main() { let s = \"x\"; }\n",
        .c: "int main(void) { return 0; }\n",
        .java: "class A { String s = \"x\"; }\n",
        .swift: "func f() -> String { let s = \"x\"; return s }\n",
        .diff: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n",
    ]

    @Test(arguments: SyntaxLanguage.allCases)
    func everyLanguageHighlights(_ language: SyntaxLanguage) async throws {
        let engine = try SyntaxEngine(language: language)
        let text = try #require(Self.samples[language])
        _ = await engine.reset(text)
        let (_, highlights) = await engine.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        #expect(!highlights.isEmpty, "\(language) produced no highlights")
        #expect(highlights.allSatisfy { NSMaxRange($0.range) <= (text as NSString).length })
    }

    @Test func stringsAndNumbersInJSON() async throws {
        let engine = try SyntaxEngine(language: .json)
        let text = #"{"name": "café 🙂", "n": 42}"#
        _ = await engine.reset(text)
        let (_, highlights) = await engine.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        let ns = text as NSString
        let named = highlights.map { (ns.substring(with: $0.range), $0.name) }
        #expect(named.contains { $0 == (#""café 🙂""#, "string") })
        #expect(named.contains { $0.0 == "42" && $0.1.hasPrefix("number") })
    }

    /// The point of incremental parsing: after any sequence of edits the
    /// highlights must be exactly what a fresh parse of the final text gives.
    @Test func incrementalEditsMatchAFreshParse() async throws {
        var text = "func f() {\n    let a = \"one\"\n    return a\n}\n"
        let incremental = try SyntaxEngine(language: .swift)
        _ = await incremental.reset(text)
        let edits: [(NSRange, String)] = [
            (NSRange(location: 0, length: 0), "// header 🙂\n"),
            (NSRange(location: 30, length: 3), "\"two\" + \"three\""),
            (NSRange(location: 5, length: 1), "g"),
            (NSRange(location: 12, length: 0), "\n    let b = 2\n"),
            (NSRange(location: 0, length: 13), ""),
        ]
        for (range, replacement) in edits {
            let ns = text as NSString
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
            text = ns.replacingCharacters(in: clamped, with: replacement)
            _ = await incremental.apply(TextChange(range: clamped, replacementLength: (replacement as NSString).length), newText: text)
        }
        let fresh = try SyntaxEngine(language: .swift)
        _ = await fresh.reset(text)
        let all = NSRange(location: 0, length: (text as NSString).length)
        #expect(await incremental.highlights(in: all).highlights == fresh.highlights(in: all).highlights)
    }

    @Test func highlightsAreLimitedToTheRequestedRange() async throws {
        let engine = try SyntaxEngine(language: .json)
        let text = "[" + Array(repeating: #""s""#, count: 1_000).joined(separator: ", ") + "]"
        _ = await engine.reset(text)
        let (_, some) = await engine.highlights(in: NSRange(location: 0, length: 40))
        #expect(!some.isEmpty)
        #expect(some.allSatisfy { $0.range.location < 40 })
        #expect(some.count < 20)
    }

    @Test func versionsAdvance() async throws {
        let engine = try SyntaxEngine(language: .json)
        let first = await engine.reset("{}")
        let second = await engine.apply(TextChange(range: NSRange(location: 1, length: 0), replacementLength: 3), newText: "{\"\":}")
        #expect(second == first + 1)
        #expect(await engine.highlights(in: NSRange(location: 0, length: 5)).version == second)
    }

    @Test func pointsCountRowsAndByteColumns() {
        let text = "ab\nc🙂d\n" as NSString
        #expect(SyntaxEngine.point(at: 0, in: text) == .init(row: 0, column: 0))
        #expect(SyntaxEngine.point(at: 3, in: text) == .init(row: 1, column: 0))
        #expect(SyntaxEngine.point(at: 6, in: text) == .init(row: 1, column: 6)) // after "c🙂": 3 UTF-16 units
    }

    @Test func aKeystrokeInAMegabyteIsCheap() async throws {
        let text = "[\n" + Array(repeating: #"  {"id": 1, "name": "item", "ok": true}"#, count: 25_000).joined(separator: ",\n") + "\n]\n"
        let engine = try SyntaxEngine(language: .json)
        _ = await engine.reset(text)
        let middle = (text as NSString).length / 2
        let edited = (text as NSString).replacingCharacters(in: NSRange(location: middle, length: 0), with: "x")
        let clock = ContinuousClock()
        let start = clock.now
        _ = await engine.apply(TextChange(range: NSRange(location: middle, length: 0), replacementLength: 1), newText: edited)
        _ = await engine.highlights(in: NSRange(location: middle - 4_000, length: 8_000))
        let elapsed = clock.now - start
        // Debug builds compile the parsers unoptimised; this is a smoke alarm.
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
        print("SYNTAX-BENCH bytes=\(text.utf8.count) keystroke=\(elapsed)")
    }
}
