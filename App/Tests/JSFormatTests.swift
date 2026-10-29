import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// Prettier and sql-formatter in the script service (#56, #57).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct JSFormatTests {
    let runner = LiveScriptRunner()

    func format(_ source: String, as language: SyntaxLanguage, settings: FormatSettings = FormatSettings()) async throws -> Result<String, FormatError> {
        let request = try #require(JSFormatting.request(for: source, as: language, settings: settings))
        return await runner.format(request)
    }

    @Test(arguments: [
        (SyntaxLanguage.javascript, "const a={b:1,c:[1,2]}", "const a = { b: 1, c: [1, 2] };\n"),
        (.typescript, "let x:number=1", "let x: number = 1;\n"),
        (.css, "a{color:red}", "a {\n  color: red;\n}\n"),
        (.html, "<div><p>hi</p></div>", "<div><p>hi</p></div>\n"),
        (.yaml, "a:   1\nb:\n    - x", "a: 1\nb:\n  - x\n"),
        (.markdown, "*  one\n*  two", "- one\n- two\n"),
    ])
    func prettierFormatsEachLanguage(_ language: SyntaxLanguage, _ source: String, _ expected: String) async throws {
        #expect(try await format(source, as: language) == .success(expected))
    }

    @Test func optionsApply() async throws {
        let settings = FormatSettings(tabWidth: 4, singleQuote: true)
        #expect(try await format("function f(){return \"x\"}", as: .javascript, settings: settings)
            == .success("function f() {\n    return 'x';\n}\n"))
    }

    @Test func syntaxErrorsSayWhere() async throws {
        let result = try await format("const a = (", as: .javascript)
        guard case .failure(let error) = result else {
            Issue.record("formatted invalid JavaScript")
            return
        }
        #expect(error.message == "Unexpected token")
        #expect(error.line == 1 && error.column == 12)
    }

    @Test func sqlIsFormattedByDialect() async throws {
        let settings = FormatSettings(sqlDialect: "postgresql", keywordCase: .upper)
        #expect(try await format("select a,b from t where x=1", as: .sql, settings: settings)
            == .success("SELECT\n  a,\n  b\nFROM\n  t\nWHERE\n  x = 1"))
    }

    @Test func formattingIsIdempotent() async throws {
        guard case .success(let once) = try await format("const a={b:1}", as: .javascript) else {
            Issue.record("the first format failed")
            return
        }
        #expect(try await format(once, as: .javascript) == .success(once))
    }

    /// A format sent while an older one is being stopped by the watchdog
    /// is not caught by that stop: requests go one at a time.
    @Test func aRequestBehindARunawayFormatStillWorks() async throws {
        let huge = "const a = [" + Array(repeating: "{ b: 1 }", count: 200_000).joined(separator: ", ") + "];"
        var slow = try #require(JSFormatting.request(for: huge, as: .javascript))
        slow.timeLimit = 0.05
        let small = try #require(JSFormatting.request(for: "let a=1", as: .javascript))
        async let stopped = runner.format(slow)
        async let next = runner.format(small)
        let (first, second) = await (stopped, next)
        guard case .failure = first else {
            Issue.record("the runaway format was not stopped")
            return
        }
        #expect(second == .success("let a = 1;\n"))
    }

    /// A format cancelled while it waits behind another is never sent.
    @Test func aCancelledQueuedFormatIsSkipped() async throws {
        let huge = "const a = [" + Array(repeating: "{ b: 1 }", count: 100_000).joined(separator: ", ") + "];"
        let slow = try #require(JSFormatting.request(for: huge, as: .javascript))
        let small = try #require(JSFormatting.request(for: "let a=1", as: .javascript))
        async let first = runner.format(slow)
        let queued = Task { await runner.format(small) }
        queued.cancel()
        _ = await first
        #expect(await queued.value == .failure(FormatError(message: "cancelled", line: nil, column: nil)))
    }

    /// The service's watchdog stops a format that runs too long, and the
    /// next one works in a fresh process.
    @Test func aRunawayFormatIsStopped() async throws {
        let huge = "const a = [" + Array(repeating: "{ b: 1 }", count: 200_000).joined(separator: ", ") + "];"
        var request = try #require(JSFormatting.request(for: huge, as: .javascript))
        request.timeLimit = 0.05
        guard case .failure(let error) = await runner.format(request) else {
            Issue.record("a 50 ms limit did not stop a huge format")
            return
        }
        #expect(error.message.contains("was stopped"))
        #expect(try await format("let a=1", as: .javascript) == .success("let a = 1;\n"))
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
