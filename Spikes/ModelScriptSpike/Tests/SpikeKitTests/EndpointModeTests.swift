import Foundation
import Testing
@testable import SpikeKit

/// Issue #278: reasoning whose opening tag was in the prompt.
@Suite struct ClosingOnlyThinkingTests {
    func reply(_ content: String?, finish: String = "stop") -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content { message["content"] = content }
        return try! JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finish]]])
    }

    @Test func reasoningWithOnlyAClosingTagIsDropped() {
        #expect(ChatCompletion.withoutThinking("reasoning</think>answer") == "answer")
        #expect(ChatCompletion.reply(in: reply("reasoning</think>answer")) == .content("answer"))
        #expect(ChatCompletion.content(in: reply("first this\nthen that\n</think>\n\n```js\nfunction main(state) {}\n```")) == "```js\nfunction main(state) {}\n```")
    }

    @Test func aClosingOnlyTagThenPairsAreAllDropped() {
        #expect(ChatCompletion.withoutThinking("a</think>x<think>b</think>y") == "xy")
    }

    @Test func aClosingTagAfterAnOpeningOneIsAPairNotALeadingTag() {
        #expect(ChatCompletion.withoutThinking("before<think>a</think>after") == "beforeafter")
        #expect(ChatCompletion.withoutThinking("<think>a</think>x") == "x")
    }

    @Test func onlyTheFirstUnmatchedClosingTagEndsTheReasoning() {
        #expect(ChatCompletion.withoutThinking("a</think>answer with </think> in it") == "answer with </think> in it")
    }

    /// Where it can be told: the reasoning closed and nothing followed.
    @Test func closedReasoningWithNoAnswerAtTheLimitWasCutOff() {
        #expect(ChatCompletion.reply(in: reply("reasoning</think>", finish: "length")) == .cutOff)
        #expect(ChatCompletion.reply(in: reply("reasoning</think>\n", finish: "length")) == .cutOff)
        #expect(ChatCompletion.reply(in: reply("reasoning</think>half an answer", finish: "length")) == .content("half an answer"))
    }

    /// Where it cannot: reasoning with no tag at all reads like any other
    /// text, and is judged as it stands.
    @Test func untaggedTextAtTheLimitIsLeftToTheJudge() {
        #expect(ChatCompletion.reply(in: reply("still thinking about it", finish: "length")) == .content("still thinking about it"))
    }
}

/// Issue #278: what an extra request field may not replace, and the
/// report's line about the settings.
@Suite struct ExtraBodyTests {
    @Test func modelMessagesAndStreamAreRefused() {
        #expect(ChatCompletion.refusedExtraFields(in: ["model": "x"]) == ["model"])
        #expect(ChatCompletion.refusedExtraFields(in: ["stream": true, "messages": [], "model": "x", "seed": 1]) == ["messages", "model", "stream"])
    }

    @Test func otherFieldsAreAllowed() {
        #expect(ChatCompletion.refusedExtraFields(in: [:]).isEmpty)
        #expect(ChatCompletion.refusedExtraFields(in: ["max_tokens": 64, "chat_template_kwargs": ["enable_thinking": false]]).isEmpty)
    }

    @Test func theSettingsLineStatesTheTimeout() {
        let line = ChatCompletion.settingsLine(temperature: 0.2, topP: 1, maxTokens: 2048, timeout: 120, extra: [:])
        #expect(line == "temperature 0.2, top-p 1.0, replies capped at 2048 tokens, each request limited to 120 s in total")
        #expect(ChatCompletion.settingsLine(temperature: 0.2, topP: 1, maxTokens: 2048, timeout: 7.5, extra: [:]).hasSuffix("limited to 7.5 s in total"))
    }

    @Test func theSettingsLineStatesWhatWentOut() {
        let line = ChatCompletion.settingsLine(temperature: 0.2, topP: 1, maxTokens: 2048, timeout: 300,
                                               extra: ["max_tokens": 64, "chat_template_kwargs": ["enable_thinking": false]])
        #expect(line.contains("replies capped at 64 tokens"))
        #expect(line.contains("limited to 300 s in total"))
        #expect(line.hasSuffix(#", extra request fields as given {"chat_template_kwargs":{"enable_thinking":false},"max_tokens":64}"#))
    }
}

/// Issue #278: a command line that would measure something other than
/// what was asked for is refused.
@Suite struct ArgumentTests {
    func problem(_ line: String) -> String? {
        SpikeArguments.problem(in: line.split(separator: " ").map(String.init))
    }

    @Test func aPlainCommandLineIsFine() {
        #expect(problem("") == nil)
        #expect(problem("--selfcheck") == nil)
        #expect(problem("--runs 3 --fixtures urls,defines --variations baseline --out report.md --dump dumps") == nil)
        #expect(problem("--endpoint http://localhost:8080 --model m") == nil)
        #expect(problem("--endpoint https://example.com/v1 --model m --temperature 0 --top-p 0.9 --max-tokens 512 --timeout 30.5") == nil)
        #expect(SpikeArguments.problem(in: ["--endpoint", "http://localhost:8080", "--model", "m", "--extra-body",
                                            #"{"chat_template_kwargs":{"enable_thinking":false}}"#]) == nil)
    }

    @Test func endpointAsTheLastArgumentIsRefused() {
        #expect(problem("--endpoint") == "--endpoint needs a value")
        #expect(problem("--runs 3 --endpoint") == "--endpoint needs a value")
    }

    @Test func aFlagFollowedByAFlagHasNoValue() {
        #expect(problem("--endpoint --model m") == "--endpoint needs a value")
        #expect(problem("--runs --selfcheck") == "--runs needs a value")
    }

    @Test func anEndpointOnlyFlagWithoutAnEndpointIsRefused() {
        for flag in ["--model m", "--temperature 0.5", "--top-p 0.5", "--max-tokens 64", "--timeout 10", #"--extra-body {"a":1}"#] {
            let name = String(flag.split(separator: " ")[0])
            #expect(problem(flag) == "\(name) is for --endpoint, which was not given", "\(flag)")
        }
    }

    @Test func anEndpointNeedsAnHTTPURLAndAModel() {
        #expect(problem("--endpoint localhost:8080 --model m") == "--endpoint needs an http or https URL with a host, such as http://localhost:8080")
        #expect(problem("--endpoint http://localhost:8080") == "--endpoint needs --model, the model's name at that endpoint")
    }

    @Test func aModelInTheExtraBodyIsRefused() {
        let problem = SpikeArguments.problem(in: ["--endpoint", "http://localhost:8080", "--model", "m", "--extra-body", #"{"model":"x"}"#])
        #expect(problem == "--extra-body may not set model: the report would name a request that was not the one sent")
        #expect(SpikeArguments.problem(in: ["--endpoint", "http://localhost:8080", "--model", "m", "--extra-body", "[1]"])
            == "--extra-body needs a JSON object")
        #expect(SpikeArguments.problem(in: ["--endpoint", "http://localhost:8080", "--model", "m", "--extra-body", "{"])
            == "--extra-body needs a JSON object")
    }

    @Test func numbersMustBeNumbers() {
        #expect(problem("--runs ten") == "--runs needs a whole number of at least 1")
        #expect(problem("--runs 0") == "--runs needs a whole number of at least 1")
        #expect(problem("--endpoint http://localhost:8080 --model m --timeout soon") == "--timeout needs a number of seconds above 0")
        #expect(problem("--endpoint http://localhost:8080 --model m --timeout 0") == "--timeout needs a number of seconds above 0")
        #expect(problem("--endpoint http://localhost:8080 --model m --timeout inf") == "--timeout needs a number of seconds above 0")
        #expect(problem("--endpoint http://localhost:8080 --model m --max-tokens 1.5") == "--max-tokens needs a whole number of at least 1")
        #expect(problem("--endpoint http://localhost:8080 --model m --temperature -1") == "--temperature needs a number of 0 or more")
        #expect(problem("--endpoint http://localhost:8080 --model m --top-p 2") == "--top-p needs a number above 0 and at most 1")
    }

    @Test func anUnknownOrRepeatedArgumentIsRefused() {
        #expect(problem("--endpont http://localhost:8080") == "--endpont is not an option")
        #expect(problem("stray") == "stray is not an option")
        #expect(problem("--runs 1 --runs 2") == "--runs was given twice")
    }

    @Test func valuesAreReadByFlag() {
        let arguments = ["--runs", "3", "--endpoint", "http://localhost:8080"]
        #expect(SpikeArguments.value(of: "--runs", in: arguments) == "3")
        #expect(SpikeArguments.value(of: "--endpoint", in: arguments) == "http://localhost:8080")
        #expect(SpikeArguments.value(of: "--model", in: arguments) == nil)
    }
}

/// A stub server that sends one byte every few milliseconds and never
/// finishes, so the idle timeout never fires. Nothing leaves the process.
final class TricklingProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Thread.detachNewThread { [self] in
            while !lock.withLock({ stopped }) {
                client?.urlProtocol(self, didLoad: Data(" ".utf8))
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    override func stopLoading() { lock.withLock { stopped = true } }
}

/// A stub server that answers at once.
final class PromptProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("done".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Issue #278: `--timeout` is a limit on the whole request.
@Suite struct DeadlineTests {
    func session(_ stub: AnyClass) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [stub]
        return URLSession(configuration: configuration)
    }

    func seconds(_ work: () async -> Void) async -> Double {
        let start = ContinuousClock.now
        await work()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test func workThatFinishesInTimeReturnsItsValue() async throws {
        #expect(try await Deadline.run(seconds: 5) { 42 } == 42)
    }

    @Test func workThatThrowsThrowsItsOwnError() async {
        struct Broken: Error {}
        await #expect(throws: Broken.self) { try await Deadline.run(seconds: 5) { throw Broken() } as Int }
    }

    @Test func workThatNeverEndsStopsAtTheLimit() async {
        let took = await seconds {
            await #expect(throws: DeadlineExceeded.self) {
                try await Deadline.run(seconds: 0.2) { () async throws -> Int in
                    while true { try await Task.sleep(for: .milliseconds(10)) }
                }
            }
        }
        #expect(took >= 0.2 && took < 5)
    }

    @Test func theLimitIsCountedByTheGivenClock() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await Deadline.run(seconds: 3600, sleep: { limit in #expect(limit == 3600) }) { () async throws -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
    }

    /// The acceptance criterion: a server that trickles bytes past the
    /// limit. The idle timeout (5 s here) never fires, the deadline does.
    @Test func aServerThatTricklesBytesIsCutAtTheLimit() async {
        let request = URLRequest(url: URL(string: "http://localhost/v1/chat/completions")!, timeoutInterval: 5)
        let session = session(TricklingProtocol.self)
        let took = await seconds {
            await #expect(throws: DeadlineExceeded.self) {
                _ = try await Deadline.data(for: request, session: session, within: 0.3)
            }
        }
        #expect(took >= 0.3 && took < 4, "ended at the limit, not at the idle timeout: \(took) s")
    }

    @Test func aServerThatAnswersInTimeIsRead() async throws {
        let request = URLRequest(url: URL(string: "http://localhost/v1/chat/completions")!, timeoutInterval: 5)
        let (data, response) = try await Deadline.data(for: request, session: session(PromptProtocol.self), within: 5)
        #expect(String(decoding: data, as: UTF8.self) == "done")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
