import Foundation

/// What the script runner says of one run of a script. The runner itself
/// (a child process with JavaScriptCore) is the executable's; this is its
/// answer, so that judging it is pure and tested.
public enum ScriptRun: Equatable, Sendable {
    /// The script ran to its end: the text it left, or nil and the errors
    /// it raised or posted.
    case finished(output: String?, errors: [String])
    /// The script was still running at the time limit and was killed.
    case timedOut
    /// The runner failed, not the script: the child could not be started,
    /// or it exited without a result (a trap inside the sandbox, say).
    case runnerFailed(String)

    /// Seconds a script may run.
    public static let timeLimit: TimeInterval = 2

    /// How the runner's child process ended, for `ended`.
    public enum Exit: Equatable, Sendable {
        case status(Int32)
        case signal(Int32)
    }

    /// What a child that left no result amounts to. It timed out only
    /// when the watchdog is what ended it: the watchdog had fired and the
    /// child died of the watchdog's own signal. A child that exited or
    /// trapped by itself, even a moment before the watchdog would have
    /// reached it, failed as a runner and is not the script's timeout.
    public static func ended(watchdogFired: Bool, exit: Exit, watchdogSignal: Int32 = 15) -> ScriptRun {
        switch exit {
        case .signal(let signal) where watchdogFired && signal == watchdogSignal: .timedOut
        case .signal(let signal): .runnerFailed("the runner was ended by signal \(signal) and no result")
        case .status(let status): .runnerFailed("the runner exited with status \(status) and no result")
        }
    }
}

/// How one attempt ended.
public enum Outcome: Equatable, Sendable {
    case pass
    case noScript(reply: String)
    case scriptError(String)
    case timedOut
    case wrong(line: Int, expected: String?, actual: String?, matching: Int, of: Int, head: String)
    case modelError(String)
    /// The script runner failed on every attempt. Nothing is known about
    /// the script, so this is neither a pass nor the model's failure: the
    /// attempt is reported apart and counted nowhere.
    case runnerError(String)

    public var passed: Bool { self == .pass }

    public var kind: String {
        switch self {
        case .pass: "pass"
        case .noScript: "no script in the reply"
        case .scriptError: "script error"
        case .timedOut: "timed out"
        case .wrong: "wrong output"
        case .modelError: "model error"
        case .runnerError: "runner error"
        }
    }

    public var detail: String {
        switch self {
        case .pass: ""
        case .noScript(let reply): "reply began: \(reply.prefix(80).replacingOccurrences(of: "\n", with: "⏎"))"
        case .scriptError(let message): Self.short(message)
        case .timedOut: "killed after \(Int(ScriptRun.timeLimit)) s"
        case .wrong(let line, let expected, let actual, let matching, let of, _):
            "\(matching) of \(of) lines right; line \(line) was \(Self.quoted(actual)), expected \(Self.quoted(expected))"
        case .modelError(let name): name
        case .runnerError(let why): Self.short(why)
        }
    }

    /// One line of at most 120 characters, for the report.
    public static func short(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: "⏎")
        return line.count > 120 ? line.prefix(120) + "…" : line
    }

    /// A line in backticks, or the words for a line past the end.
    public static func quoted(_ line: String?) -> String {
        line.map { "`\(short($0))`" } ?? "nothing (past the end)"
    }

    /// What the one retry tells the model, or nil when there is nothing to
    /// send back: a pass, a failed call, and a runner error, which is not
    /// the model's to fix.
    public var retryProblem: RetryProblem? {
        switch self {
        case .pass, .modelError, .runnerError: nil
        case .noScript: .noScript
        case .scriptError(let message): .error(message)
        case .timedOut: .timedOut
        case .wrong(let line, let expected, let actual, _, _, let head):
            .wrongOutput(line: line, expected: expected, actual: actual, head: head)
        }
    }
}

public enum Judge {
    /// How many times a script is given to the runner before the runner is
    /// given up on. A runner failure says nothing about the script, so the
    /// script is run again rather than scored.
    public static let runnerAttempts = 3

    /// Extract the script from a reply, run it on the whole input and
    /// score it. Nothing here throws or traps: a bad reply is an outcome.
    public static func judge(_ reply: String, input: String, expected: String,
                             run: (_ source: String, _ text: String) -> ScriptRun) -> Outcome {
        guard let script = ScriptReply.extract(reply) else { return .noScript(reply: reply) }
        var failure = ""
        for _ in 0..<runnerAttempts {
            switch run(script, input) {
            case .timedOut: return .timedOut
            case .runnerFailed(let why): failure = why
            case .finished(let output, let errors):
                guard let output else { return .scriptError(errors.joined(separator: "; ")) }
                switch Score.compare(actual: output, expected: expected) {
                case .pass: return .pass
                case .wrong(let line, let expected, let actual, let matching, let of):
                    let head = output.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
                    return .wrong(line: line, expected: expected, actual: actual, matching: matching, of: of, head: head)
                }
            }
        }
        return .runnerError(failure)
    }
}

/// One run of a fixture in a variation: the first try and, when it failed
/// in a way the model can be told about, the one retry.
public struct Run: Sendable {
    public var first: Outcome
    public var firstSeconds: Double
    public var retry: Outcome?
    public var retrySeconds: Double?
    /// The retry sent back the script of the first try, unchanged.
    public var retryRepeated: Bool

    public init(first: Outcome, firstSeconds: Double, retry: Outcome? = nil, retrySeconds: Double? = nil, retryRepeated: Bool = false) {
        self.first = first
        self.firstSeconds = firstSeconds
        self.retry = retry
        self.retrySeconds = retrySeconds
        self.retryRepeated = retryRepeated
    }

    public var passedInTheEnd: Bool { first.passed || retry?.passed == true }

    /// What the runner failed with, on the first try or on the retry.
    public var runnerErrors: [String] {
        [first, retry].compactMap { outcome in
            if case .runnerError(let why) = outcome { why } else { nil }
        }
    }

    /// Whether the first try counts: it does unless the runner failed on
    /// it. A runner error on the retry leaves the first try what it was,
    /// a known failure, and it stays in the first-try figures.
    public var firstIsScored: Bool {
        if case .runnerError = first { false } else { true }
    }

    /// Whether the run's end counts, for the figures after the retry and
    /// about the retry. It does not when the runner failed on either try:
    /// how the run would have ended is not known.
    public var isScored: Bool { runnerErrors.isEmpty }
}

/// One of the self-check's failure probes: a reply, the kind of failure it
/// must be reported as and, for a script error, a piece of the message
/// that only the script's own error carries. The kind alone cannot tell a
/// script's error from anything else reported under the same name.
public struct Probe: Sendable {
    public var reply: String
    public var kind: String
    public var message: String?
    public var what: String

    public static let all = [
        Probe(reply: "function main(state) { while (true) {} }", kind: "timed out", message: nil, what: "a script that loops"),
        Probe(reply: "function main(state) { state.text = ; }", kind: "script error", message: "SyntaxError",
              what: "a script that does not parse"),
        Probe(reply: "function main(state) { state.text = state.text.missing.length; }", kind: "script error", message: "TypeError",
              what: "a script that throws"),
        Probe(reply: "function main(state) { state.postError('no'); state.text = ''; }", kind: "script error", message: "no",
              what: "a script that posts an error"),
        Probe(reply: "function main(state) { state.text = require('fs').readFileSync('/etc/hosts', 'utf8'); }", kind: "script error",
              message: "ReferenceError", what: "a script that asks for require"),
        Probe(reply: "Sorry, I can't write that.", kind: "no script in the reply", message: nil, what: "a reply with no script"),
        Probe(reply: "function main(state) { state.text = 'nope'; }", kind: "wrong output", message: nil,
              what: "a script that writes the wrong text"),
    ]

    /// What is wrong with how the probe was reported, or nil.
    public func problem(with outcome: Outcome) -> String? {
        guard outcome.kind == kind else { return "\(what) was reported as \(outcome.kind), not \(kind)" }
        guard let message else { return nil }
        guard case .scriptError(let reported) = outcome, reported.hasPrefix(message) else {
            return "\(what) was reported as \(kind), but with \"\(outcome.detail)\", not with a message that begins \"\(message)\""
        }
        return nil
    }
}
