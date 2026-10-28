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

    @Test func detectionReadsOnlyASample() {
        // A huge buffer must not be scanned in full; this would take seconds
        // if every heuristic walked 20 MB.
        let huge = String(repeating: "plain words without structure ", count: 700_000)
        let elapsed = ContinuousClock().measure { _ = ContentKind.detect(huge) }
        #expect(elapsed < .seconds(1), "took \(elapsed)")
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
        #expect(title(diff) == "Diff: A.swift")
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
