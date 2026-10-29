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

    /// Cancelled before it starts (the task cancels itself first), so the
    /// result is deterministic: the parser's check must turn it into a
    /// failure, not a formatted document.
    @Test func aCancelledFormatStops() async {
        let task = Task.detached { () -> Result<String, FormatError> in
            withUnsafeCurrentTask { $0?.cancel() }
            return JSONFormatter.format("[1, 2, 3]")
        }
        guard case .failure(let error) = await task.value else {
            Issue.record("a cancelled format still formatted")
            return
        }
        #expect(error.message == "cancelled")
    }

    @Test func aByteOrderMarkIsTolerated() throws {
        #expect(try json("\u{FEFF}[1]") == "[\n  1\n]\n")
        // The caret before "1" (after the BOM and "[") stays before "1".
        let formatted = try json("\u{FEFF}[1]")
        let mapped = DocumentFormatter.caret(2, from: "\u{FEFF}[1]", to: formatted)
        #expect((formatted as NSString).substring(from: mapped).hasPrefix("1"))
    }

    @Test func deepNestingIsRefusedNotRecursedInto() throws {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        guard case .failure(let error) = JSONFormatter.format(deep) else {
            Issue.record("formatted 100,000 levels")
            return
        }
        #expect(error == FormatError(message: "nested deeper than 256 levels", line: 1, column: 257))
        let allowed = String(repeating: "[", count: 256) + String(repeating: "]", count: 256)
        #expect((try? json(allowed)) != nil, "256 levels still format")
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

@Suite struct JSFormattingTests {
    @Test func languagesMapToTheirFormatter() throws {
        #expect(JSFormatting.prettierParser(for: .typescript) == "typescript")
        #expect(JSFormatting.prettierParser(for: .json) == nil, "JSON is formatted natively")
        let sql = try #require(JSFormatting.request(for: "select 1", as: .sql, settings: FormatSettings(sqlDialect: "sqlite", keywordCase: .upper)))
        #expect(sql.engine == .sqlFormatter)
        #expect(sql.options == #"{"keywordCase":"upper","language":"sqlite","tabWidth":2}"#)
        let js = try #require(JSFormatting.request(for: "x", as: .javascript, settings: FormatSettings(tabWidth: 4, singleQuote: true)))
        #expect(js.options == #"{"parser":"babel","singleQuote":true,"tabWidth":4}"#)
        #expect(JSFormatting.request(for: "x", as: .python) == nil)
    }

    @Test func settingsAreClamped() {
        #expect(FormatSettings(tabWidth: 99).tabWidth == 8)
        #expect(FormatSettings(sqlDialect: "oracle-ish").sqlDialect == "sql")
    }

    @Test func formatDocumentCoversJavaScriptLanguages() {
        #expect(DocumentFormatter.canFormat(.markdown))
        #expect(DocumentFormatter.canFormat(.sql))
        #expect(!DocumentFormatter.canFormat(.sql, style: .sortedKeys))
        #expect(!DocumentFormatter.canFormatNatively(.css))
    }
}

/// The indent width setting reaches the native formatters (#112), and a
/// superseded format stops inside long tokens (#98).
@Suite struct FormatFollowUpTests {
    @Test func jsonTakesTheIndentWidth() {
        #expect(DocumentFormatter.format(#"{"a":[1]}"#, as: .json, indent: 4) == .success("{\n    \"a\": [\n        1\n    ]\n}\n"))
        #expect(DocumentFormatter.format(#"{"a":1}"#, as: .json, style: .sortedKeys, indent: 3) == .success("{\n   \"a\": 1\n}\n"))
    }

    @Test func xmlTakesTheIndentWidth() throws {
        let xml = "<a><b><c>x</c></b></a>"
        let two = try DocumentFormatter.format(xml, as: .xml, indent: 2).get()
        #expect(two.contains("\n  <b>") && two.contains("\n    <c>x</c>"), "\(two)")
        let four = try DocumentFormatter.format(xml, as: .xml, indent: 4).get()
        #expect(four.contains("\n    <b>"), "\(four)")
    }

    /// Lines inside CDATA and comments keep their own whitespace.
    @Test func reindentingLeavesCDATAAndCommentsAlone() {
        let pretty = """
            <a>
                <b><![CDATA[
                    <kept/>
                ]]></b>
                <!--
                    <also kept/>
                -->
                <c/>
            </a>
            """
        let expected = """
            <a>
              <b><![CDATA[
                    <kept/>
                ]]></b>
              <!--
                    <also kept/>
                -->
              <c/>
            </a>
            """
        #expect(XMLFormatter.reindent(pretty, to: 2) == expected)
    }

    /// Cancelled while scanning one huge string: it stops there, instead of
    /// at the next value.
    @Test func cancellationStopsInsideALongString() async {
        let huge = "\"" + String(repeating: "a", count: 1 << 20) + "\""
        let task = Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            var parser = JSONFormatter.Parser(huge)
            return try? parser.string()
        }
        #expect(await task.value == nil)
        // Not cancelled, the same string reads to its end.
        var parser = JSONFormatter.Parser(huge)
        #expect((try? parser.string())?.count == (1 << 20) + 2)
    }

    /// Escapes move two to six bytes a step; the check still comes due.
    @Test func cancellationStopsInsideAnEscapedString() async {
        let huge = "\"" + String(repeating: "\\n", count: 1 << 19) + "\""
        let task = Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            var parser = JSONFormatter.Parser(huge)
            return try? parser.string()
        }
        #expect(await task.value == nil)
    }

    /// Processing instructions keep their data's whitespace.
    @Test func reindentingLeavesProcessingInstructionsAlone() {
        let pretty = "<r>\n    <?p data\n        <kept>?>\n    <c/>\n</r>"
        #expect(XMLFormatter.reindent(pretty, to: 2) == "<r>\n  <?p data\n        <kept>?>\n  <c/>\n</r>")
    }

    @Test func cancellationStopsWhileWriting() async {
        let wide = "[" + Array(repeating: "1", count: JSONFormatter.checkEvery * 2).joined(separator: ",") + "]"
        let task = Task { () -> Result<String, FormatError> in
            var parser = JSONFormatter.Parser(wide)
            guard let value = try? parser.document() else { return .failure(FormatError(message: "parse", line: nil, column: nil)) }
            withUnsafeCurrentTask { $0?.cancel() }
            var out = "", written = 0
            do {
                try JSONFormatter.write(value, into: &out, depth: 0, indent: "  ", sortKeys: false, written: &written)
                return .success(out)
            } catch let error as FormatError {
                return .failure(error)
            } catch {
                return .failure(FormatError(message: "\(error)", line: nil, column: nil))
            }
        }
        #expect(await task.value == .failure(.cancelled))
    }
}
