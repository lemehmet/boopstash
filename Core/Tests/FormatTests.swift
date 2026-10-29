import Foundation
import Testing
@testable import BoopstashCore

@Suite struct FormatTests {
    func json(_ text: String, sortKeys: Bool = false) throws -> String {
        try JSONFormatter.format(text, sortKeys: sortKeys).get()
    }

    @Test func jsonIsIndentedWithKeysInOrder() throws {
        #expect(try json(#"{"b":1,"a":[true,null,{}],"c":[]}"#) == """
        {
          "b": 1,
          "a": [
            true,
            null,
            {}
          ],
          "c": []
        }

        """)
    }

    /// Only whitespace changes: a parse into Double or String would lose
    /// these.
    @Test func numbersAndEscapesSurviveExactly() throws {
        let source = #"[1e400, 0.10000000000000001, -0, 12345678901234567890, "é\n\"", "é", "\/"]"#
        let out = try json(source)
        for token in ["1e400", "0.10000000000000001", "-0", "12345678901234567890", #""é\n\"""#, #""é""#, #""\/""#] {
            #expect(out.contains(token), "\(token) changed")
        }
    }

    @Test func formattingIsIdempotent() throws {
        let once = try json(#"{"a": {"b": [1, 2, {"c": "d"}]}, "e": "f"}"#)
        #expect(try json(once) == once)
    }

    @Test func sortingKeysUsesTheirDecodedText() throws {
        #expect(try json(#"{"b":1,"\u0061":2,"c":{"z":0,"y":0}}"#, sortKeys: true) == """
        {
          "\\u0061": 2,
          "b": 1,
          "c": {
            "y": 0,
            "z": 0
          }
        }

        """)
    }

    @Test(arguments: [
        (#"{"a": 1,}"#, 1, 9, "expected a quoted key"),
        ("{\n  \"a\": tru\n}", 2, 8, "expected a value"),
        (#"[1 2]"#, 1, 4, "expected ',' or ']'"),
        (#"{"a": 01}"#, 1, 8, "expected ',' or '}'"),
        ("\"tab\tin string\"", 1, 5, "a control character inside a string must be escaped"),
        (#"{"a": 1} x"#, 1, 10, "unexpected text after the JSON value"),
        ("// comment\n{}", 1, 1, "expected a value"),
        (#""\x""#, 1, 3, "bad escape in a string"),
        ("[", 1, 2, "the JSON ends early"),
    ])
    func invalidJSONSaysWhereAndWhy(_ text: String, _ line: Int, _ column: Int, _ message: String) {
        #expect(JSONFormatter.format(text) == .failure(FormatError(message: message, line: line, column: column)))
    }

    @Test func aByteOrderMarkIsTolerated() throws {
        #expect(try json("\u{FEFF}[1]") == "[\n  1\n]\n")
    }

    @Test func xmlKeepsCommentsCDATAAndOrder() throws {
        let source = #"<?xml version="1.0"?><root><!-- note --><b>2</b><a><![CDATA[<raw> & stuff]]></a><empty/></root>"#
        let out = try XMLFormatter.format(source).get()
        #expect(out.contains("<!-- note -->"))
        #expect(out.contains("<![CDATA[<raw> & stuff]]>"))
        #expect(out.range(of: "<b>")!.lowerBound < out.range(of: "<a>")!.lowerBound)
        #expect(out.contains("\n    <b>2</b>"), "indented children:\n\(out)")
        #expect(try XMLFormatter.format(out).get() == out, "idempotent")
    }

    @Test func plistKeysKeepTheirOrder() throws {
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>zeta</key><string>1</string><key>alpha</key><true/></dict></plist>"#
        let out = try XMLFormatter.format(plist).get()
        #expect(out.range(of: "zeta")!.lowerBound < out.range(of: "alpha")!.lowerBound)
    }

    @Test func malformedXMLFails() {
        guard case .failure(let error) = XMLFormatter.format("<a><b></a>") else {
            Issue.record("mismatched tags formatted")
            return
        }
        #expect(error.line == 1)
    }

    @Test func externalEntitiesAreNeverLoaded() throws {
        let source = #"<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/hosts">]><r>&x;</r>"#
        let out = (try? XMLFormatter.format(source).get()) ?? ""
        #expect(!out.contains("localhost"), "the entity must not be resolved")
    }

    @Test func formatterIsChosenByLanguage() {
        #expect(DocumentFormatter.canFormat(.json))
        #expect(DocumentFormatter.canFormat(.json, style: .sortedKeys))
        #expect(DocumentFormatter.canFormat(.xml))
        #expect(!DocumentFormatter.canFormat(.xml, style: .sortedKeys))
        #expect(!DocumentFormatter.canFormat(.python))
        #expect(!DocumentFormatter.canFormat(nil))
        #expect(DocumentFormatter.format("x", as: .python) == .failure(FormatError(message: "No formatter for Python", line: nil, column: nil)))
    }

    @Test func theCaretStaysOnItsCharacter() throws {
        let original = #"{"a":[1,2],"bc":3}"#
        let formatted = try json(original)
        // Caret just before "bc".
        let offset = (original as NSString).range(of: #""bc""#).location
        let mapped = DocumentFormatter.caret(offset, from: original, to: formatted)
        #expect((formatted as NSString).substring(from: mapped).hasPrefix(#""bc""#))
        #expect(DocumentFormatter.caret(0, from: original, to: formatted) == 0)
        #expect(DocumentFormatter.caret(original.utf16.count, from: original, to: formatted) <= formatted.utf16.count)
    }

    @Test func errorsReadWell() {
        #expect(FormatError(message: "expected a value", line: 3, column: 7).description == "Line 3, column 7: expected a value")
        #expect(FormatError(message: "no", line: nil, column: nil).description == "no")
    }
}

extension Result where Success == String, Failure == FormatError {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.success(a), .success(b)): a == b
        case let (.failure(a), .failure(b)): a == b
        default: false
        }
    }
}
