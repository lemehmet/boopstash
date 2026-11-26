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

let arguments = Array(CommandLine.arguments.dropFirst())

func value(of flag: String) -> String? {
    SpikeArguments.value(of: flag, in: arguments)
}

let usage = """
ModelScriptSpike [--runs N] [--fixtures id,id] [--variations id,id] [--out report.md] [--dump directory] [--selfcheck]
                 [--endpoint URL --model NAME [--temperature T] [--top-p P] [--max-tokens N] [--timeout S] [--extra-body JSON]]
  --runs        runs per fixture and variation (default 10)
  --fixtures    \(Fixture.all.map(\.id).joined(separator: ", ")) (default all)
  --variations  \(Variation.all.map(\.id).joined(separator: ", ")) (default all)
  --out         also write the report to this file
  --dump        write every prompt-reply-outcome to this directory
  --selfcheck   check the fixtures and the runner without the model, then stop
  --endpoint    measure a model behind an OpenAI-compatible API at this base URL, not the on-device one;
                its key, if it needs one, is read from MODEL_SPIKE_API_KEY. The URL is not written to the report.
  --model       the model's name at that endpoint (required with --endpoint)
  --temperature, --top-p, --max-tokens
                generation settings for the endpoint (defaults 0.2, 1.0, 2048)
  --timeout     seconds one request may take in all, from sending it to the end of the reply (default 120, at most 86400);
                it is written to the report
  --extra-body  a JSON object merged into each request, for what the server at hand needs,
                such as '{"chat_template_kwargs":{"enable_thinking":false}}' to switch off a model's reasoning.
                It is written to the report as given, values and all: never put a key or a password in it.
                It may not set model, messages or stream.
The options from --model on are for --endpoint only.
Exit status: 0 measured; 1 the self-check failed or the on-device model is unavailable;
2 the command line was refused; 3 measured, but the script runner failed on some runs.
"""

if arguments.contains("--help") {
    print(usage)
    exit(0)
}

// Before anything runs: a command line that is not understood measures
// nothing. "--endpoint" with its value missing would otherwise measure the
// on-device model.
if let problem = SpikeArguments.problem(in: arguments) {
    say(problem)
    say(usage)
    exit(2)
}

/// Extract the script from a reply, run it on the fixture's whole input and
/// score it; see `Judge`. A runner that fails is asked again, and a script
/// it never ran is a runner error, not the model's script error.
func judge(_ reply: String, _ fixture: Fixture) -> Outcome {
    Judge.judge(reply, input: fixture.input, expected: fixture.expected) { source, text in
        ScriptRunner.run(source: source, text: text)
    }
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
// Each probe must be reported as its kind and, for a script error, with
// the script's own message: that is what tells it from a runner crash.
for probe in Probe.all {
    if let problem = probe.problem(with: judge(probe.reply, Fixture.urls)) {
        say("self-check: \(problem)")
        selfCheckFailed = true
    }
}
if !ScriptRunner.sandboxHolds() {
    say("self-check: the script runner's sandbox did not refuse a file read and a socket")
    selfCheckFailed = true
}
if selfCheckFailed { exit(1) }
say("self-check passed: \(Fixture.all.count) reference scripts, \(Probe.all.count) failure probes, the runner's sandbox holds")
if arguments.contains("--selfcheck") { exit(0) }

// MARK: The measurement

// The arguments were checked above, so every value here parses.
let endpoint: Endpoint? = value(of: "--endpoint").flatMap { URL(string: $0) }.map { base in
    Endpoint(base: base, model: value(of: "--model") ?? "", key: ProcessInfo.processInfo.environment["MODEL_SPIKE_API_KEY"],
             temperature: value(of: "--temperature").flatMap(Double.init) ?? 0.2,
             topP: value(of: "--top-p").flatMap(Double.init) ?? 1.0,
             maxTokens: value(of: "--max-tokens").flatMap(Int.init) ?? 2048,
             timeout: value(of: "--timeout").flatMap(Double.init) ?? 120,
             extraBody: value(of: "--extra-body").flatMap(SpikeArguments.extraBody) ?? [:])
}

if let endpoint {
    if !endpoint.extraBody.isEmpty {
        say("The --extra-body fields are written to the report as given. A key belongs in MODEL_SPIKE_API_KEY, never there.")
    }
} else {
    guard ModelChat.availability == "available" else {
        say("The on-device model is \(ModelChat.availability). The spike needs a Mac with Apple Intelligence on, or --endpoint.")
        exit(1)
    }
}

let runsPerCell = value(of: "--runs").flatMap(Int.init) ?? 10
let fixtureIDs = value(of: "--fixtures")?.split(separator: ",").map(String.init)
let variationIDs = value(of: "--variations")?.split(separator: ",").map(String.init)
let fixtures = Fixture.all.filter { fixtureIDs?.contains($0.id) ?? true }
// Guided generation is FoundationModels' own; an endpoint has no such mode here.
let variations = Variation.all.filter { variationIDs?.contains($0.id) ?? true }.filter { endpoint == nil || !$0.guided }
guard !fixtures.isEmpty, !variations.isEmpty else {
    say("Nothing to measure: no fixture or no variation is left of what was asked for."
        + (endpoint != nil ? " The guided variation is FoundationModels' own and is not run against an endpoint." : ""))
    exit(2)
}
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
func attempt(_ chat: Chat, _ prompt: String, _ fixture: Fixture) async -> (outcome: Outcome, reply: String, seconds: Double) {
    let (reply, seconds) = await timed { () -> Result<String, Error> in
        do { return .success(try await chat.ask(prompt)) } catch { return .failure(error) }
    }
    switch reply {
    case .success(let reply): return (judge(reply, fixture), reply, seconds)
    case .failure(let error): return (.modelError(chat.name(of: error)), "", seconds)
    }
}

/// One conversation with whichever model is being measured.
enum Chat {
    case onDevice(ModelChat)
    case endpoint(EndpointChat)

    func ask(_ prompt: String) async throws -> String {
        switch self {
        case .onDevice(let chat): try await chat.ask(prompt)
        case .endpoint(let chat): try await chat.ask(prompt)
        }
    }

    func name(of error: Error) -> String {
        switch self {
        case .onDevice: ModelChat.name(of: error)
        case .endpoint: EndpointChat.name(of: error)
        }
    }
}

var results: [String: [Run]] = [:]
let started = Date()
for fixture in fixtures {
    for variation in variations {
        let key = "\(fixture.id)|\(variation.id)"
        for index in 1...runsPerCell {
            // A new session per run: runs must not learn from each other.
            let chat: Chat = endpoint.map { .endpoint(EndpointChat(endpoint: $0, variation: variation)) }
                ?? .onDevice(ModelChat(variation: variation))
            let prompt = Prompts.request(instruction: fixture.instruction,
                                         sample: variation.fullSample ? fixture.input : fixture.shortSample,
                                         isWholeText: variation.fullSample,
                                         sampleOutput: variation.showsOutput ? fixture.sampleExpected : nil)
            let (first, firstReply, firstSeconds) = await attempt(chat, prompt, fixture)
            var run = Run(first: first, firstSeconds: firstSeconds)
            var log = "## prompt\n\(prompt)\n\n## reply (\(String(format: "%.1f", firstSeconds)) s)\n\(firstReply)\n\n## outcome\n\(first.kind) \(first.detail)\n"
            // A runner error has no retry problem: the model is not asked
            // to fix what was not its script's doing.
            if let problem = first.retryProblem {
                let again = Prompts.retry(problem)
                let (second, secondReply, secondSeconds) = await attempt(chat, again, fixture)
                run.retry = second
                run.retrySeconds = secondSeconds
                run.retryRepeated = ScriptReply.sameScript(firstReply, secondReply)
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

/// The endpoint's generation settings as they are sent, and the time limit.
func describe(_ endpoint: Endpoint) -> String {
    ChatCompletion.settingsLine(temperature: endpoint.temperature, topP: endpoint.topP, maxTokens: endpoint.maxTokens,
                                timeout: endpoint.timeout, extra: endpoint.extraBody)
}

/// The runs of one fixture in one variation whose first try counts: all
/// but those the script runner failed on at the first try. The first-try
/// figures are of these.
func firstScored(_ fixture: Fixture, _ variation: Variation) -> [Run] {
    (results["\(fixture.id)|\(variation.id)"] ?? []).filter(\.firstIsScored)
}

/// The runs whose end counts: no runner failure on either try. The
/// figures after the retry and about the retry are of these.
func scored(_ fixture: Fixture, _ variation: Variation) -> [Run] {
    (results["\(fixture.id)|\(variation.id)"] ?? []).filter(\.isScored)
}

func unscored(_ fixture: Fixture, _ variation: Variation) -> [Run] {
    (results["\(fixture.id)|\(variation.id)"] ?? []).filter { !$0.isScored }
}

let system = ProcessInfo.processInfo.operatingSystemVersionString
let minutes = Date().timeIntervalSince(started) / 60
var report = """
# Model-written scripts: spike results

- \(endpoint.map { "Model `\($0.model)` behind an OpenAI-compatible endpoint (a self-hosted server; its address is not recorded), measured from macOS \(system)" } ?? "macOS \(system), on-device model `SystemLanguageModel.default` (\(ModelChat.availability))")
- \(runsPerCell) runs per fixture and variation, a new conversation each run, \(endpoint.map(describe) ?? "default sampling, replies capped at 1500 tokens")
- A run passes when the script's output on the whole input equals the expected text (trailing spaces aside)
- Scripts run in a sandboxed child process killed after \(Int(ScriptRunner.timeLimit)) s
- Seconds are the model's time from the request to the complete reply, without running the script
- Total time: \(String(format: "%.1f", minutes)) minutes

| Fixture | Variation | First try | After one retry | Median s to first reply | Slowest s | First-try failures |
|---|---|---|---|---|---|---|

"""
for fixture in fixtures {
    for variation in variations {
        let firsts = firstScored(fixture, variation)
        let runs = scored(fixture, variation)
        let first = firsts.filter(\.first.passed).count
        let end = runs.filter(\.passedInTheEnd).count
        let seconds = firsts.map(\.firstSeconds)
        report += "| \(fixture.id) | \(variation.id) | \(first)/\(firsts.count) | \(end)/\(runs.count) | \(String(format: "%.1f", median(seconds))) | \(String(format: "%.1f", seconds.max() ?? 0)) | \(tally(firsts.map(\.first))) |\n"
    }
}

report += "\n## Per fixture, all variations together\n\n| Fixture | First try | After one retry | Retries that fixed it | Retries with the same script again |\n|---|---|---|---|---|\n"
for fixture in fixtures {
    let firsts = variations.flatMap { firstScored(fixture, $0) }
    let runs = variations.flatMap { scored(fixture, $0) }
    let retried = runs.filter { $0.retry != nil }
    report += "| \(fixture.id) | \(firsts.filter(\.first.passed).count)/\(firsts.count) | \(runs.filter(\.passedInTheEnd).count)/\(runs.count) | \(retried.filter(\.passedInTheEnd).count)/\(retried.count) | \(retried.filter(\.retryRepeated).count)/\(retried.count) |\n"
}

let everyFirst = fixtures.flatMap { fixture in variations.flatMap { firstScored(fixture, $0) } }
let everyRun = fixtures.flatMap { fixture in variations.flatMap { scored(fixture, $0) } }
let everyRetry = everyRun.filter { $0.retry != nil }
let everyUnscored = fixtures.flatMap { fixture in variations.flatMap { unscored(fixture, $0) } }
let notScored = everyUnscored.count
let notScoredOnTheRetry = everyUnscored.filter(\.firstIsScored).count
// The count alone when there are none; what it means when there are some.
let runnerErrorLine = notScored == 0 ? "Runner errors: 0." : """
Runner errors: \(notScored) runs, \(notScored - notScoredOnTheRetry) on the first try and \(notScoredOnTheRetry) on the retry. \
On each, every one of the script runner's \(Judge.runnerAttempts) attempts at the script failed, which says nothing of the script. \
A run with one on the first try is in no figure of this report and got no retry. \
A run with one on the retry keeps its first try in the first-try figures and is left out of those after and about the retry.
"""
report += """

## Totals

- First tries: \(everyFirst.filter(\.first.passed).count) of \(everyFirst.count) pass. Failures: \(tally(everyFirst.map(\.first))).
- Retries: \(everyRetry.count) (a model error is not retried). Fixed: \(everyRetry.filter(\.passedInTheEnd).count). The same script again: \(everyRetry.filter(\.retryRepeated).count) (both replies held a script, and the two scripts were equal).
- \(runnerErrorLine)
- Seconds are to the complete first reply, whether or not it held a script.

"""

report += "\n## How failures look\n\nUp to three different first-try failures of each kind per fixture.\n"
for fixture in fixtures {
    let failures = variations.flatMap { firstScored(fixture, $0) }.map(\.first).filter { !$0.passed }
    guard !failures.isEmpty else { continue }
    report += "\n### \(fixture.id)\n\n"
    for (kind, group) in Dictionary(grouping: failures, by: \.kind).sorted(by: { $0.key < $1.key }) {
        var seen: [String] = []
        for detail in group.map(\.detail) where !seen.contains(detail) && seen.count < 3 { seen.append(detail) }
        report += "- **\(kind)** (\(group.count)):\n" + seen.map { "  - \($0)\n" }.joined()
    }
}

if notScored > 0 {
    report += "\n## Runner errors\n\nRuns left out of figures above, wholly or from the retry on (see Totals). Run these cells again before the report is used."
        + " A script that itself brings the runner down every time lands here too: if a cell does so again, read its replies (`--dump`).\n\n"
        + "| Fixture | Variation | Runs | On the first try | On the retry | What the runner said |\n|---|---|---|---|---|---|\n"
    for fixture in fixtures {
        for variation in variations {
            let runs = unscored(fixture, variation)
            guard !runs.isEmpty else { continue }
            var seen: [String] = []
            for message in runs.flatMap(\.runnerErrors).map(Outcome.short) where !seen.contains(message) { seen.append(message) }
            let onRetry = runs.filter(\.firstIsScored).count
            report += "| \(fixture.id) | \(variation.id) | \(runs.count) | \(runs.count - onRetry) | \(onRetry) | \(seen.joined(separator: "; ")) |\n"
        }
    }
}

print(report)
if let out = value(of: "--out") {
    do { try report.write(toFile: out, atomically: true, encoding: .utf8) } catch { say("could not write \(out): \(error.localizedDescription)") }
}
if notScored > 0 {
    say("\(notScored) runs were not scored in full: the script runner failed on them. The report lists them.")
    exit(3)
}
