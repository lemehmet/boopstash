import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// Prettier, sql-formatter and the WebAssembly formatters in the script
/// service (#56, #57, #158).
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

    /// Formatters compiled to WebAssembly (#158, ADR 0010), through the
    /// real service.
    @Test(arguments: [
        (SyntaxLanguage.python, "def f( a,b ):\n  return {'k':a}", "def f(a, b):\n    return {\"k\": a}\n"),
        (.go, "package main\nfunc main(){\nx:=1\n_=x}", "package main\n\nfunc main() {\n\tx := 1\n\t_ = x\n}\n"),
        (.bash, "if [ -n \"$a\" ];then\necho  hi\nfi", "if [ -n \"$a\" ]; then\n  echo hi\nfi\n"),
        (.c, "int main(){return 0;}", "int main() { return 0; }"),
        (.java, "class A{void f(){int x=1;}}", "class A {\n  void f() { int x = 1; }\n}"),
    ])
    func wasmFormattersFormatEachLanguage(_ language: SyntaxLanguage, _ source: String, _ expected: String) async throws {
        #expect(try await format(source, as: language) == .success(expected))
    }

    @Test func wasmSyntaxErrorsSayWhere() async throws {
        guard case .failure(let error) = try await format("package main\nfunc main( {", as: .go) else {
            Issue.record("formatted invalid Go")
            return
        }
        #expect(error.line == 2 && error.column == 12, "\(error)")
        #expect(error.message == "expected ')', found '{'")
        guard case .failure = try await format("def f(:\n", as: .python) else {
            Issue.record("formatted invalid Python")
            return
        }
        guard case .failure = try await format("if then fi ((", as: .bash) else {
            Issue.record("formatted invalid shell")
            return
        }
        // The service lived through the errors.
        #expect(try await format("x=1", as: .python) == .success("x = 1\n"))
    }

    /// Non-ASCII text survives the host's own UTF-8 encoder and decoder.
    @Test func unicodeRoundTrips() async throws {
        #expect(try await format("s = 'héllo 🌍 中文'", as: .python) == .success("s = \"héllo 🌍 中文\"\n"))
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

    /// Two clients formatting at once each get their own result: the
    /// service takes their requests in turn, not in parallel on its shared
    /// formatter contexts (#111).
    @Test func twoClientsGetTheirOwnResults() async throws {
        let other = LiveScriptRunner()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<24 {
                let client = index.isMultiple(of: 2) ? runner : other
                let request = try #require(JSFormatting.request(for: "let v\(index)={a:\(index)}", as: .javascript))
                group.addTask { await client.format(request) == .success("let v\(index) = { a: \(index) };\n") }
            }
            for try await matched in group { #expect(matched) }
        }
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
