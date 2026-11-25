import Foundation
import SpikeKit

// The child process that runs one script; see ScriptRunner.
if CommandLine.arguments.contains("--run-script") {
    ScriptRunner.serve()
    exit(0)
}

func say(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func value(of flag: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: flag), at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}

if CommandLine.arguments.contains("--help") {
    print("""
    ModelScriptSpike [--runs N] [--fixtures id,id] [--variations id,id] [--out report.md] [--dump directory] [--selfcheck]
      --runs        runs per fixture and variation (default 10)
      --fixtures    \(Fixture.all.map(\.id).joined(separator: ", ")) (default all)
      --variations  \(Variation.all.map(\.id).joined(separator: ", ")) (default all)
      --out         also write the report to this file
      --dump        write every prompt-reply-outcome to this directory
      --selfcheck   check the fixtures and the runner without the model, then stop
    """)
    exit(0)
}

/// How one attempt ended.
enum Outcome {
    case pass
    case noScript(reply: String)
    case scriptError(String)
    case timedOut
    case wrong(line: Int, expected: String?, actual: String?, matching: Int, of: Int, head: String)
    case modelError(String)

    var passed: Bool { if case .pass = self { true } else { false } }

    var kind: String {
        switch self {
        case .pass: "pass"
        case .noScript: "no script in the reply"
        case .scriptError: "script error"
        case .timedOut: "timed out"
        case .wrong: "wrong output"
        case .modelError: "model error"
        }
    }

    var detail: String {
        switch self {
        case .pass: ""
        case .noScript(let reply): "reply began: \(reply.prefix(80).replacingOccurrences(of: "\n", with: "⏎"))"
        case .scriptError(let message): Self.short(message)
        case .timedOut: "killed after \(Int(ScriptRunner.timeLimit)) s"
        case .wrong(let line, let expected, let actual, let matching, let of, _):
            "\(matching) of \(of) lines right; line \(line) was \(Self.quoted(actual)), expected \(Self.quoted(expected))"
        case .modelError(let name): name
        }
    }

    /// One line of at most 120 characters, for the report.
    static func short(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: "⏎")
        return line.count > 120 ? line.prefix(120) + "…" : line
    }

    /// A line in backticks, or the words for a line past the end.
    static func quoted(_ line: String?) -> String {
        line.map { "`\(short($0))`" } ?? "nothing (past the end)"
    }

    var retryProblem: RetryProblem? {
        switch self {
        case .pass, .modelError: nil
        case .noScript: .noScript
        case .scriptError(let message): .error(message)
        case .timedOut: .timedOut
        case .wrong(let line, let expected, let actual, _, _, let head):
            .wrongOutput(line: line, expected: expected, actual: actual, head: head)
        }
    }
}

/// Extract the script from a reply, run it on the fixture's whole input and
/// score it. Nothing here throws or traps: a bad reply is an outcome.
func judge(_ reply: String, _ fixture: Fixture) -> Outcome {
    guard let script = ScriptReply.extract(reply) else { return .noScript(reply: reply) }
    switch ScriptRunner.run(source: script, text: fixture.input) {
    case .timedOut: return .timedOut
    case .crashed(let why): return .scriptError(why)
    case .finished(let response):
        guard let output = response.output else { return .scriptError(response.errors.joined(separator: "; ")) }
        switch Score.compare(actual: output, expected: fixture.expected) {
        case .pass: return .pass
        case .wrong(let line, let expected, let actual, let matching, let of):
            let head = output.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
            return .wrong(line: line, expected: expected, actual: actual, matching: matching, of: of, head: head)
        }
    }
}

struct Run {
    var first: Outcome
    var firstSeconds: Double
    var retry: Outcome?
    var retrySeconds: Double?
    /// The retry sent back the script of the first try, unchanged.
    var retryRepeated = false
    var passedInTheEnd: Bool { first.passed || retry?.passed == true }
}

// MARK: Self-check: the fixtures and the runner, without the model

var selfCheckFailed = false
for fixture in Fixture.all {
    let outcome = judge(fixture.reference, fixture)
    if !outcome.passed {
        say("self-check: the reference script for \(fixture.id) does not pass: \(outcome.kind): \(outcome.detail)")
        selfCheckFailed = true
    }
}
let probes: [(String, String, String)] = [
    ("function main(state) { while (true) {} }", "timed out", "a script that loops"),
    ("function main(state) { state.text = ; }", "script error", "a script that does not parse"),
    ("function main(state) { state.text = state.text.missing.length; }", "script error", "a script that throws"),
    ("function main(state) { state.postError('no'); state.text = ''; }", "script error", "a script that posts an error"),
    ("function main(state) { state.text = require('fs').readFileSync('/etc/hosts', 'utf8'); }", "script error", "a script that asks for require"),
    ("Sorry, I can't write that.", "no script in the reply", "a reply with no script"),
    ("function main(state) { state.text = 'nope'; }", "wrong output", "a script that writes the wrong text"),
]
for (reply, kind, what) in probes {
    let outcome = judge(reply, Fixture.urls)
    if outcome.kind != kind {
        say("self-check: \(what) was reported as \(outcome.kind), not \(kind)")
        selfCheckFailed = true
    }
}
if !ScriptRunner.sandboxHolds() {
    say("self-check: the script runner's sandbox did not refuse a file read and a socket")
    selfCheckFailed = true
}
if selfCheckFailed { exit(1) }
say("self-check passed: \(Fixture.all.count) reference scripts, \(probes.count) failure probes, the runner's sandbox holds")
if CommandLine.arguments.contains("--selfcheck") { exit(0) }

// MARK: The measurement

guard ModelChat.availability == "available" else {
    say("The on-device model is \(ModelChat.availability). The spike needs a Mac with Apple Intelligence on.")
    exit(1)
}

let runsPerCell = value(of: "--runs").flatMap(Int.init) ?? 10
let fixtureIDs = value(of: "--fixtures")?.split(separator: ",").map(String.init)
let variationIDs = value(of: "--variations")?.split(separator: ",").map(String.init)
let fixtures = Fixture.all.filter { fixtureIDs?.contains($0.id) ?? true }
let variations = Variation.all.filter { variationIDs?.contains($0.id) ?? true }
let dump = value(of: "--dump").map { URL(fileURLWithPath: $0) }
if let dump { try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }

func timed<T>(_ work: () async -> T) async -> (T, Double) {
    let start = ContinuousClock.now
    let result = await work()
    let elapsed = ContinuousClock.now - start
    return (result, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

/// One question to the model and the verdict on its reply. The seconds are
/// the model's alone, from the request to the complete reply: running and
/// scoring the script is not counted.
func attempt(_ chat: ModelChat, _ prompt: String, _ fixture: Fixture) async -> (outcome: Outcome, reply: String, seconds: Double) {
    let (reply, seconds) = await timed { () -> Result<String, Error> in
        do { return .success(try await chat.ask(prompt)) } catch { return .failure(error) }
    }
    switch reply {
    case .success(let reply): return (judge(reply, fixture), reply, seconds)
    case .failure(let error): return (.modelError(ModelChat.name(of: error)), "", seconds)
    }
}

/// Whether two replies carry the same script: the scripts when both have
/// one, otherwise the replies themselves. A failed call has no reply and
/// repeats nothing.
func sameScript(_ first: String, _ second: String) -> Bool {
    func body(_ reply: String) -> String {
        (ScriptReply.extract(reply) ?? reply).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return !second.isEmpty && body(first) == body(second)
}

var results: [String: [Run]] = [:]
let started = Date()
for fixture in fixtures {
    for variation in variations {
        let key = "\(fixture.id)|\(variation.id)"
        for index in 1...runsPerCell {
            // A new session per run: runs must not learn from each other.
            let chat = ModelChat(variation: variation)
            let prompt = Prompts.request(instruction: fixture.instruction,
                                         sample: variation.fullSample ? fixture.input : fixture.shortSample,
                                         isWholeText: variation.fullSample,
                                         sampleOutput: variation.showsOutput ? fixture.sampleExpected : nil)
            let (first, firstReply, firstSeconds) = await attempt(chat, prompt, fixture)
            var run = Run(first: first, firstSeconds: firstSeconds)
            var log = "## prompt\n\(prompt)\n\n## reply (\(String(format: "%.1f", firstSeconds)) s)\n\(firstReply)\n\n## outcome\n\(first.kind) \(first.detail)\n"
            if let problem = first.retryProblem {
                let again = Prompts.retry(problem)
                let (second, secondReply, secondSeconds) = await attempt(chat, again, fixture)
                run.retry = second
                run.retrySeconds = secondSeconds
                run.retryRepeated = sameScript(firstReply, secondReply)
                log += "\n## retry prompt\n\(again)\n\n## retry reply (\(String(format: "%.1f", secondSeconds)) s)\n\(secondReply)\n\n## retry outcome\n\(second.kind) \(second.detail)\n"
            }
            results[key, default: []].append(run)
            if let dump {
                let name = "\(fixture.id)-\(variation.id)-\(index).md".replacingOccurrences(of: "+", with: "-")
                try? log.write(to: dump.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            say("\(key) run \(index): \(first.kind)\(run.retry.map { " → retry: \($0.kind)" } ?? "") (\(String(format: "%.1f", firstSeconds)) s)")
        }
    }
}

// MARK: The report

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

func tally(_ outcomes: [Outcome]) -> String {
    let failed = outcomes.filter { !$0.passed }
    let kinds = Dictionary(grouping: failed, by: \.kind).map { "\($0.value.count) \($0.key)" }.sorted()
    return kinds.isEmpty ? "none" : kinds.joined(separator: ", ")
}

let system = ProcessInfo.processInfo.operatingSystemVersionString
let minutes = Date().timeIntervalSince(started) / 60
var report = """
# Model-written scripts: spike results

- macOS \(system), on-device model `SystemLanguageModel.default` (\(ModelChat.availability))
- \(runsPerCell) runs per fixture and variation, a new session each run, default sampling, replies capped at 1500 tokens
- A run passes when the script's output on the whole input equals the expected text (trailing spaces aside)
- Scripts run in a sandboxed child process killed after \(Int(ScriptRunner.timeLimit)) s
- Seconds are the model's time from the request to the complete reply, without running the script
- Total time: \(String(format: "%.1f", minutes)) minutes

| Fixture | Variation | First try | After one retry | Median s to first reply | Slowest s | First-try failures |
|---|---|---|---|---|---|---|

"""
for fixture in fixtures {
    for variation in variations {
        let runs = results["\(fixture.id)|\(variation.id)"] ?? []
        let first = runs.filter(\.first.passed).count
        let end = runs.filter(\.passedInTheEnd).count
        let seconds = runs.map(\.firstSeconds)
        report += "| \(fixture.id) | \(variation.id) | \(first)/\(runs.count) | \(end)/\(runs.count) | \(String(format: "%.1f", median(seconds))) | \(String(format: "%.1f", seconds.max() ?? 0)) | \(tally(runs.map(\.first))) |\n"
    }
}

report += "\n## Per fixture, all variations together\n\n| Fixture | First try | After one retry | Retries that fixed it | Retries with the same script again |\n|---|---|---|---|---|\n"
for fixture in fixtures {
    let runs = variations.flatMap { results["\(fixture.id)|\($0.id)"] ?? [] }
    let retried = runs.filter { $0.retry != nil }
    report += "| \(fixture.id) | \(runs.filter(\.first.passed).count)/\(runs.count) | \(runs.filter(\.passedInTheEnd).count)/\(runs.count) | \(retried.filter(\.passedInTheEnd).count)/\(retried.count) | \(retried.filter(\.retryRepeated).count)/\(retried.count) |\n"
}

let everyRun = fixtures.flatMap { fixture in variations.flatMap { results["\(fixture.id)|\($0.id)"] ?? [] } }
let everyRetry = everyRun.filter { $0.retry != nil }
report += """

## Totals

- First tries: \(everyRun.filter(\.first.passed).count) of \(everyRun.count) pass. Failures: \(tally(everyRun.map(\.first))).
- Retries: \(everyRetry.count) (a model error is not retried). Fixed: \(everyRetry.filter(\.passedInTheEnd).count). The same script again: \(everyRetry.filter(\.retryRepeated).count).
- Seconds are to the complete first reply, whether or not it held a script.

"""

report += "\n## How failures look\n\nUp to three different first-try failures of each kind per fixture.\n"
for fixture in fixtures {
    let failures = variations.flatMap { results["\(fixture.id)|\($0.id)"] ?? [] }.map(\.first).filter { !$0.passed }
    guard !failures.isEmpty else { continue }
    report += "\n### \(fixture.id)\n\n"
    for (kind, group) in Dictionary(grouping: failures, by: \.kind).sorted(by: { $0.key < $1.key }) {
        var seen: [String] = []
        for detail in group.map(\.detail) where !seen.contains(detail) && seen.count < 3 { seen.append(detail) }
        report += "- **\(kind)** (\(group.count)):\n" + seen.map { "  - \($0)\n" }.joined()
    }
}

print(report)
if let out = value(of: "--out") {
    do { try report.write(toFile: out, atomically: true, encoding: .utf8) } catch { say("could not write \(out): \(error.localizedDescription)") }
}
