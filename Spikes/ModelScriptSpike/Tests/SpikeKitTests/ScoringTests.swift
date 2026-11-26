import Foundation
import Testing
@testable import SpikeKit

/// A script runner that answers from a list, one answer per call, and
/// counts the calls.
final class ScriptedRunner {
    var answers: [ScriptRun]
    var calls = 0

    init(_ answers: [ScriptRun]) { self.answers = answers }

    func run(_ source: String, _ text: String) -> ScriptRun {
        calls += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

@Suite struct JudgeTests {
    let script = "function main(state) { state.text = 'x'; }"

    func judge(_ reply: String, expected: String = "x", _ answers: [ScriptRun]) -> (Outcome, Int) {
        let runner = ScriptedRunner(answers)
        let outcome = Judge.judge(reply, input: "in", expected: expected, run: runner.run)
        return (outcome, runner.calls)
    }

    @Test func aRightOutputPasses() {
        #expect(judge(script, [.finished(output: "x", errors: [])]).0 == .pass)
    }

    @Test func aReplyWithoutAScriptNeverReachesTheRunner() {
        let (outcome, calls) = judge("Sorry, no.", [.finished(output: "x", errors: [])])
        #expect(outcome == .noScript(reply: "Sorry, no."))
        #expect(calls == 0)
    }

    @Test func whatTheScriptReportsIsAScriptError() {
        let (outcome, calls) = judge(script, [.finished(output: nil, errors: ["TypeError: no", "second"])])
        #expect(outcome == .scriptError("TypeError: no; second"))
        #expect(calls == 1, "a script's own error is not run again")
    }

    @Test func aScriptKilledAtTheLimitTimedOut() {
        #expect(judge(script, [.timedOut]).0 == .timedOut)
    }

    @Test func aWrongOutputSaysWhere() {
        let (outcome, _) = judge(script, expected: "a\nb", [.finished(output: "a\nc", errors: [])])
        #expect(outcome == .wrong(line: 2, expected: "b", actual: "c", matching: 1, of: 2, head: "a\nc"))
    }

    /// Issue #270: the runner failing is not the model's script failing.
    @Test func aRunnerThatKeepsFailingIsARunnerErrorNotAScriptError() {
        let (outcome, calls) = judge(script, [.runnerFailed("the runner exited with status 5 and no result")])
        #expect(outcome == .runnerError("the runner exited with status 5 and no result"))
        #expect(outcome.kind == "runner error")
        #expect(outcome.kind != Outcome.scriptError("x").kind)
        #expect(calls == Judge.runnerAttempts, "the script is run again before the runner is given up on")
    }

    @Test func aRunnerThatFailsOnceIsRunAgainAndTheScriptScored() {
        let (outcome, calls) = judge(script, [.runnerFailed("could not start the runner"), .finished(output: "x", errors: [])])
        #expect(outcome == .pass)
        #expect(calls == 2)
        let (second, _) = judge(script, [.runnerFailed("once"), .runnerFailed("twice"), .finished(output: nil, errors: ["SyntaxError: no"])])
        #expect(second == .scriptError("SyntaxError: no"))
    }

    @Test func aRunnerErrorIsNeverSentBackToTheModel() {
        #expect(Outcome.runnerError("x").retryProblem == nil)
        #expect(Outcome.modelError("x").retryProblem == nil)
        #expect(Outcome.pass.retryProblem == nil)
        #expect(Outcome.scriptError("x").retryProblem != nil)
        #expect(Outcome.timedOut.retryProblem != nil)
        #expect(Outcome.noScript(reply: "x").retryProblem != nil)
    }

    @Test func aRunWithARunnerErrorIsNotScored() {
        #expect(Run(first: .pass, firstSeconds: 1).isScored)
        #expect(Run(first: .scriptError("x"), firstSeconds: 1, retry: .wrong(line: 1, expected: "a", actual: nil, matching: 0, of: 1, head: "")).isScored)
        #expect(!Run(first: .runnerError("x"), firstSeconds: 1).isScored)
        #expect(!Run(first: .scriptError("x"), firstSeconds: 1, retry: .runnerError("y")).isScored,
                "the retry could not be scored, so the run's end is unknown")
        #expect(Run(first: .scriptError("x"), firstSeconds: 1, retry: .runnerError("y")).runnerErrors == ["y"])
        #expect(Run(first: .scriptError("x"), firstSeconds: 1, retry: .pass).passedInTheEnd)
    }

    @Test func theDetailOfATimeoutNamesTheLimit() {
        #expect(Outcome.timedOut.detail == "killed after 2 s")
        #expect(Outcome.runnerError("the runner exited with status 5 and no result").detail == "the runner exited with status 5 and no result")
    }
}

/// Issue #270: the self-check's probes tell a script error from a crash by
/// the message, not only by the kind.
@Suite struct ProbeTests {
    func probe(_ what: String) -> Probe { Probe.all.first { $0.what == what }! }

    @Test func aProbeAsksForTheKind() {
        let loops = probe("a script that loops")
        #expect(loops.problem(with: .timedOut) == nil)
        #expect(loops.problem(with: .scriptError("x")) == "a script that loops was reported as script error, not timed out")
    }

    @Test func aProbeForAScriptErrorAsksForItsMessage() {
        let syntax = probe("a script that does not parse")
        #expect(syntax.problem(with: .scriptError("SyntaxError: Unexpected token ';'")) == nil)
        #expect(syntax.problem(with: .scriptError("the runner exited with status 5 and no result")) != nil,
                "a crash dressed as a script error does not pass")
        #expect(syntax.problem(with: .runnerError("the runner exited with status 5 and no result")) != nil)
        #expect(probe("a script that throws").problem(with: .scriptError("TypeError: undefined is not an object")) == nil)
        #expect(probe("a script that throws").problem(with: .scriptError("SyntaxError: no")) != nil)
        #expect(probe("a script that asks for require").problem(with: .scriptError("ReferenceError: Can't find variable: require")) == nil)
        #expect(probe("a script that asks for require").problem(with: .scriptError("TypeError: no")) != nil)
        #expect(probe("a script that posts an error").problem(with: .scriptError("no")) == nil)
    }

    @Test func everyScriptErrorProbeNamesAMessage() {
        for probe in Probe.all where probe.kind == Outcome.scriptError("").kind {
            #expect(probe.message != nil, "\(probe.what)")
        }
        #expect(Probe.all.count == 7)
    }
}

/// Issue #271: "the same script again" is about scripts.
@Suite struct SameScriptTests {
    let script = "```js\nfunction main(state) { state.text = 'x'; }\n```"

    @Test func theSameScriptInDifferentProseIsTheSameScript() {
        #expect(ScriptReply.sameScript(script, "Sorry, here it is again:\n" + script + "\nThat should work."))
        #expect(ScriptReply.sameScript(script, script))
    }

    @Test func differentScriptsAreNotTheSame() {
        #expect(!ScriptReply.sameScript(script, "```js\nfunction main(state) { state.text = 'y'; }\n```"))
    }

    @Test func identicalRepliesWithoutAScriptAreNotTheSameScript() {
        #expect(!ScriptReply.sameScript("I can't write that.", "I can't write that."))
        #expect(!ScriptReply.sameScript("```js\nconst error_names = [];\n```", "```js\nconst error_names = [];\n```"))
    }

    @Test func aScriptOnOneSideOnlyIsNotTheSame() {
        #expect(!ScriptReply.sameScript("I can't write that.", script))
        #expect(!ScriptReply.sameScript(script, "I can't write that."))
        #expect(!ScriptReply.sameScript(script, ""), "a failed call has no reply")
        #expect(!ScriptReply.sameScript("", ""))
    }
}
