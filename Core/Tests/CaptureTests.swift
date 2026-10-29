import Foundation
import Testing
@testable import BoopstashCore

@Suite struct CapturePolicyTests {
    @Test func ordinaryTextIsAccepted() {
        #expect(CapturePolicy.decide(types: ["public.utf8-plain-text", "public.html"]) == .accept)
    }

    @Test func passwordManagerItemsAreRefused() {
        #expect(CapturePolicy.decide(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]) == .refuseConcealed)
        #expect(CapturePolicy.decide(types: ["com.agilebits.onepassword", "public.utf8-plain-text"]) == .refuseConcealed)
    }

    @Test func transientItemsAreRefused() {
        #expect(CapturePolicy.decide(types: ["org.nspasteboard.TransientType", "public.utf8-plain-text"]) == .refuseTransient)
        #expect(CapturePolicy.decide(types: ["de.petermaurer.TransientPasteboardType"]) == .refuseTransient)
    }

    @Test func concealedWinsOverTransient() {
        #expect(CapturePolicy.decide(types: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]) == .refuseConcealed)
    }
}

@Suite struct ContentKindTests {
    @Test(arguments: [
        ("https://github.com/lemehmet/boopstash/pull/3", ContentKind.url),
        (#"{"id": 1, "name": "x"}"#, .json),
        ("[1, 2, 3]", .json),
        ("diff --git a/x.swift b/x.swift\n--- a/x.swift\n+++ b/x.swift\n@@ -1 +1 @@\n-a\n+b", .diff),
        ("--- old.txt\n+++ new.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+c", .diff),
        ("<!DOCTYPE html>\n<html><body>hi</body></html>", .html),
        ("<?xml version=\"1.0\"?>\n<plist><dict><key>a</key></dict></plist>", .xml),
        ("Traceback (most recent call last):\n  File \"x.py\", line 1, in <module>\nValueError: bad", .stackTrace),
        ("Exception in thread \"main\" java.lang.NullPointerException\n\tat com.x.Y.run(Y.java:12)", .stackTrace),
        ("TypeError: x is undefined\n    at render (app.js:10:5)\n    at main (app.js:20:1)", .stackTrace),
        ("thread 'main' panicked at src/main.rs:2:5:\nboom", .stackTrace),
        ("goroutine 1 [running]:\nmain.main()", .stackTrace),
        ("2026-10-28 10:00:01 INFO start\n2026-10-28 10:00:02 WARN slow\n2026-10-28 10:00:03 ERROR fail", .log),
        ("[INFO] building\n[INFO] compiling\n[ERROR] failed", .log),
        ("SELECT id, name\nFROM users\nWHERE active = 1;", .sql),
        ("with recent as (select * from t) select * from recent", .sql),
        ("# Release notes\n\nSome text with a [link](https://x.y).", .markdown),
        ("- [ ] one\n- [x] two\nplain", .markdown),
        ("name: boopstash\nversion: 1\ndependencies:\n  - grdb", .yaml),
        ("---\nkey: value", .yaml),
        ("func main() {\n    print(\"hi\")\n}\nlet x = 1", .code),
        ("def f(x):\n    return x\nimport os", .code),
        ("Remember to buy milk and call the plumber.", .plain),
        ("   \n  ", .plain),
    ])
    func detects(_ text: String, _ expected: ContentKind) {
        #expect(ContentKind.detect(text) == expected)
    }

    @Test func urlWithSpacesIsNotAURL() {
        #expect(ContentKind.detect("see https://example.com for details") != .url)
    }

    @Test func largeXMLIsStillXML() {
        let xml = "<root>" + String(repeating: "<item>x</item>", count: 6_000) + "</root>"
        #expect(xml.utf8.count > ContentKind.sampleLimit)
        #expect(ContentKind.detect(xml) == .xml)
        #expect(ContentKind.detect("<?xml version=\"1.0\"?>\n" + xml) == .xml)
    }

    @Test func largeJSONIsJSONWithoutAFullParse() {
        let json = "[" + Array(repeating: #"{"id": 1, "name": "x"}"#, count: 120_000).joined(separator: ",") + "]"
        #expect(json.utf8.count > ContentKind.jsonParseLimit)
        let elapsed = ContinuousClock().measure { #expect(ContentKind.detect(json) == .json) }
        #expect(elapsed < .milliseconds(200), "took \(elapsed)")
    }

    /// Bounded work takes about as long on a buffer as on a hundredth of
    /// it, on any machine; a full scan would take a hundred times longer.
    /// The fastest of three runs of each, to keep scheduling noise out.
    func expectBounded(_ huge: String, small: String) {
        func fastest(_ text: String) -> Duration {
            (0..<3).map { _ in ContinuousClock().measure { _ = ContentKind.detect(text) } }.min()!
        }
        let large = fastest(huge), base = fastest(small)
        #expect(large < base * 10 + .milliseconds(50), "took \(large) against \(base)")
    }

    @Test func whitespaceFreeBuffersAreBounded() {
        // e.g. a base64 dump
        expectBounded(String(repeating: "a", count: 20_000_000), small: String(repeating: "a", count: 200_000))
        #expect(ContentKind.detect("https://example.com/" + String(repeating: "a", count: 5_000)) != .url)
    }

    /// A large bridged string, as AppKit hands over, is bounded too (#123).
    @Test func bridgedBuffersAreBounded() {
        let native = String(repeating: "plain words without structure ", count: 700_000)
        let bridged = NSMutableString(string: native) as String
        let small = NSMutableString(string: String(repeating: "plain words without structure ", count: 7_000)) as String
        expectBounded(bridged, small: small)
        #expect(ContentKind.detect(bridged) == ContentKind.detect(native))
    }

    @Test func utf8LimitsCountBytes() {
        #expect("abc".utf8Fits(3))
        #expect(!"abcd".utf8Fits(3))
        #expect("é".utf8Fits(2) && !"é".utf8Fits(1))
        #expect("".utf8Fits(0))
    }

    @Test func detectionReadsOnlyASample() {
        // A huge buffer must not be scanned in full; this would take seconds
        // if every heuristic walked 20 MB.
        expectBounded(String(repeating: "plain words without structure ", count: 700_000),
                      small: String(repeating: "plain words without structure ", count: 7_000))
    }
}

@Suite struct RuleTitlerTests {
    func title(_ body: String) -> String {
        RuleTitler.title(for: body, kind: ContentKind.detect(body))
    }

    @Test func firstMeaningfulLineWins() {
        #expect(title("\n\n```\n}\n# Deploy checklist\nstep one") == "Deploy checklist")
        #expect(title("- [ ] ship the release\n- [ ] tell people") == "ship the release")
        #expect(title("> quoted   text   here") == "quoted text here")
    }

    @Test func longLinesAreCutAtAWord() {
        let long = "This is a very long first line that keeps going well past the sixty character limit"
        let result = title(long)
        #expect(result.count <= RuleTitler.maxLength)
        #expect(result.hasSuffix("…"))
        #expect(!result.dropLast().hasSuffix(" "))
        #expect(long.hasPrefix(String(result.dropLast())))
    }

    @Test func jsonObjectsListTheirFirstKeysInSourceOrder() {
        #expect(title(#"{"zeta": 1, "alpha": {"nested": true}, "mid": [1], "last": 0}"#) == "JSON {zeta, alpha, mid, …}")
        #expect(title(#"{"only": "one"}"#) == "JSON {only}")
        #expect(title(#"{"a\"b": 1}"#) == #"JSON {a"b}"#)
    }

    @Test func jsonKeysAreDecoded() {
        #expect(title(#"{"\u0061": 1, "caf\u00e9": 2}"#) == "JSON {a, café}")
    }

    @Test func largeJSONWithLeadingWhitespaceKeepsItsShape() {
        let array = "\n\n  [" + Array(repeating: #"{"id": 1}"#, count: 120_000).joined(separator: ",") + "]"
        #expect(array.utf8.count > ContentKind.jsonParseLimit)
        #expect(title(array) == "JSON array")
        let object = "\n {" + #""first": 1, "second": ""# + String(repeating: "x", count: ContentKind.jsonParseLimit) + #"", "third": 3}"#
        // Only the 64 KB head is read, so the key after the long string is
        // not seen.
        #expect(title(object) == "JSON {first, second, …}")
    }

    @Test func jsonArraysGiveTheirLength() {
        #expect(title("[1, 2, 3]") == "JSON array of 3")
    }

    @Test func urlsBecomeHostAndPath() {
        #expect(title("https://www.example.com/docs/intro/") == "example.com/docs/intro")
        #expect(title("https://github.com") == "github.com")
    }

    @Test func diffsNameTheirFiles() {
        let diff = """
        diff --git a/Core/A.swift b/Core/A.swift
        --- a/Core/A.swift
        +++ b/Core/A.swift
        @@ -1 +1 @@
        -x
        +y
        --- a/B.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -z
        """
        #expect(title(diff) == "Diff: A.swift, B.swift")
    }

    @Test func deletedFilesAreNamedFromTheOldSide() {
        let diff = "diff --git a/Core/A.swift b/Core/A.swift\ndeleted file mode 100644\n--- a/Core/A.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-x"
        #expect(title(diff) == "Diff: A.swift")
    }

    @Test func pythonTracesUseTheLastLineWhateverItSays() {
        #expect(title("Traceback (most recent call last):\n  File \"x.py\", line 9, in <module>\n    time.sleep(5)\nKeyboardInterrupt\n") == "KeyboardInterrupt")
    }

    @Test func titlingAHugeNoteIsBounded() {
        let huge = String(repeating: "\n", count: 5_000_000) + "finally a line"
        let elapsed = ContinuousClock().measure { _ = RuleTitler.title(for: huge, kind: .plain) }
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }

    @Test func detectingAHugeBlankPrefixIsBounded() {
        let huge = String(repeating: "\n", count: 5_000_000) + "{\"a\": 1}"
        let elapsed = ContinuousClock().measure { _ = ContentKind.detect(huge) }
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }

    @Test func leadingSampleSkipsWhitespaceWithinItsLimit() {
        #expect(ContentKind.leadingSample(of: " \t\r\n[1]") == "[1]")
        #expect(ContentKind.leadingSample(of: "") == "")
        #expect(ContentKind.leadingSample(of: "\u{3000}\u{A0}é") == "é", "Unicode spaces are whitespace too")
        let blank = String(repeating: " ", count: ContentKind.sampleLimit + 10) + "x"
        #expect(ContentKind.leadingSample(of: blank) == String(repeating: " ", count: 10) + "x",
                "the skip stops after sampleLimit scalars")
        #expect(ContentKind.leadingSample(of: String(repeating: "y", count: ContentKind.sampleLimit * 2)).count
                == ContentKind.sampleLimit)
    }

    @Test func aByteOrderMarkDoesNotChangeTheTitle() {
        let array = "\u{FEFF}[" + Array(repeating: "{\"k\": 1}", count: 150_000).joined(separator: ",") + "]"
        #expect(array.utf8.count > ContentKind.jsonParseLimit)
        let title = RuleTitler.title(for: array, kind: ContentKind.detect(array))
        #expect(title.hasPrefix("JSON array"), "got \(title)")
    }

    @Test func aByteOrderMarkDoesNotHideTheKind() {
        #expect(ContentKind.detect("\u{FEFF}{\"a\":1}") == .json)
        #expect(SyntaxLanguage.detect("\u{FEFF}{\"a\":1}") == .json)
        #expect(SyntaxChoice.automatic.resolve(for: "\u{FEFF}<a><b/></a>") == .xml)
    }

    @Test func stackTracesNameTheFailure() {
        #expect(title("Traceback (most recent call last):\n  File \"x.py\", line 3\nKeyError: 'id'") == "KeyError: 'id'")
        #expect(title("java.lang.IllegalStateException: closed\n\tat a.B.c(B.java:1)\n\tat a.B.d(B.java:2)")
            == "java.lang.IllegalStateException: closed")
    }

    @Test func nothingToSayFallsBackToTheKind() {
        #expect(RuleTitler.title(for: "{}\n()\n;;", kind: .code) == "Code")
        #expect(RuleTitler.title(for: "", kind: .plain) == "Text")
    }
}
