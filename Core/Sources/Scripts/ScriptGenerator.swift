import Foundation

// macOS only (ADR 0014): the safeguard this rests on, an app without a
// network entitlement and a separate sandboxed helper that makes the
// request, does not exist on iOS, so none of this is compiled there.
#if os(macOS)

/// Something that writes a first draft of a workbench script from a plain
/// instruction (#247, ADR 0013). The one implementation is
/// `ModelEndpointGenerator`, over a model the user runs themselves
/// (ADR 0014); with nothing configured the workbench shows no prompt
/// field and no Generate button.
///
/// The draft is untrusted text. It goes into the workbench's script editor
/// and nowhere else: it runs only when the user chooses Run, in the script
/// service (ADR 0007), and reaches the note only through Keep.
///
/// A generator may send the instruction, the sample and the marked
/// examples to where the user configured it to (ADR 0014), and says where
/// in its destination: this Mac, the local network or elsewhere, which
/// the workbench shows as a warning mark beside Generate. Sending them
/// anywhere the user did not configure, or sending anything else, needs
/// its own ADR first.
public protocol ScriptGenerator: Sendable {
    /// Whether a request can be made now and, if so, where it would go.
    /// The workbench asks each time its sheet opens, so this should answer
    /// quickly and without sending anything anywhere.
    func availability() async -> ScriptGeneratorAvailability

    /// Writes a script for `request`. Runs in the caller's task: when that
    /// task is cancelled the generator stops what it is doing and answers
    /// `.failure(.cancelled)`. Success is the script's text alone (no
    /// prose, no code fence), defining `main(state)`.
    func generate(_ request: ScriptGenerationRequest) async -> Result<String, ScriptGenerationFailure>
}

/// What a generator is given: the user's instruction, a bounded sample of
/// the text the script will run on, and the lines the user marked as
/// examples. Never the whole of a long note, and nothing else of it.
public struct ScriptGenerationRequest: Sendable, Hashable {
    public var instruction: String
    public var sample: ScriptSample
    public var examples: [ScriptExample]
    /// Where the workbench said the request goes, when it showed a
    /// destination. A generator whose destination is no longer this one
    /// sends nothing.
    public var destination: ScriptGeneratorDestination?

    public init(instruction: String, sample: ScriptSample, examples: [ScriptExample] = [],
                destination: ScriptGeneratorDestination? = nil) {
        self.instruction = instruction
        self.sample = sample
        self.examples = examples
        self.destination = destination
    }
}

public enum ScriptGeneratorAvailability: Sendable, Hashable {
    /// Ready; the destination is what the workbench shows next to Generate.
    case available(ScriptGeneratorDestination)
    /// Set up, but not usable now, and why, in a sentence: the address is
    /// not valid, no model is chosen. The workbench shows Generate
    /// disabled, with the reason.
    case unavailable(reason: String)
    /// Nothing is set up: the workbench shows no prompt field and no
    /// Generate, as with no generator at all.
    case notConfigured
}

/// What a request is given to, for the user to see before sending one.
public struct ScriptGeneratorDestination: Sendable, Hashable {
    /// A few words: "the model at localhost:8080".
    public var summary: String
    /// The host a request goes to; nil for a generator inside this app.
    public var host: String?
    /// Where that host is.
    public var locality: ModelHostLocality
    /// How much of the text a request may carry.
    public var allowance: ScriptSampleAllowance

    public init(summary: String, host: String? = nil, locality: ModelHostLocality = .thisMac,
                allowance: ScriptSampleAllowance = .standard) {
        self.summary = summary
        self.host = host
        self.locality = locality
        self.allowance = allowance
    }

    /// The line under the prompt field.
    public var notice: String {
        let leaving = locality == .elsewhere ? " That text leaves your local network." : ""
        return "Your instruction and the sample shown under What Is Sent go to \(summary).\(leaving)"
    }

    /// The warning mark beside Generate, for a request that goes to a
    /// host (ADR 0014).
    public var indicator: ModelEndpointIndicator? {
        host.map { ModelEndpointIndicator(host: $0, locality: locality, place: .workbench) }
    }
}

public enum ScriptGenerationFailure: Error, Sendable, Hashable {
    /// The caller's task was cancelled.
    case cancelled
    /// A reply came, and nothing in it defines `main`.
    case noScript
    /// The reply stopped at the token limit before there was a script: a
    /// model that reasons first spent its allowance on the reasoning.
    case cutOff
    /// The generator stopped being available between the check and the
    /// request.
    case unavailable(String)
    /// Anything else, in a sentence.
    case failed(String)

    /// What the workbench says next to the script; nothing for a request
    /// the user cancelled.
    public var message: String? {
        switch self {
        case .cancelled: nil
        case .noScript: "The reply held no script with a main function."
        case .cutOff:
            "The model ran out of reply tokens before it answered. Switch its reasoning off (Settings ▸ Model ▸ extra request fields) or raise the maximum reply."
        case .unavailable(let reason), .failed(let reason): reason
        }
    }
}

/// The workbench's side of a generator: what it shows, and one request.
public enum ScriptGeneration {
    /// Where Generate would send a request, or nil when the workbench
    /// offers no working Generate: there is no generator, nothing is
    /// configured, or it is not available now.
    public static func destination(_ availability: ScriptGeneratorAvailability?) -> ScriptGeneratorDestination? {
        guard case .available(let destination) = availability else { return nil }
        return destination
    }

    /// Why a generator that is set up cannot be used now; nil when it
    /// can, and when nothing is set up at all.
    public static func unavailableReason(_ availability: ScriptGeneratorAvailability?) -> String? {
        guard case .unavailable(let reason) = availability else { return nil }
        return reason
    }

    /// Asks `generator` for a script for `instruction`, with the examples
    /// and a sample of `target` no larger than the allowance: the same
    /// sample `ScriptSampleAllowance.sample` gives the workbench to show.
    /// An empty instruction is not sent, nor is a request whose examples
    /// leave no room for any of the text. A cancelled task answers
    /// `.cancelled` whatever the generator returned, and a blank script is
    /// `.noScript`.
    public static func run(_ generator: any ScriptGenerator, instruction: String, target: String,
                           examples: [ScriptExample] = [], allowance: ScriptSampleAllowance = .standard)
        async -> Result<String, ScriptGenerationFailure> {
        let sample = allowance.sample(of: target, instruction: instruction, examples: examples)
        return await run(generator, instruction: instruction, sample: sample, examples: examples)
    }

    /// Asks `generator` for a script with exactly this sample and these
    /// examples, which are the ones the workbench showed, to the
    /// destination it showed: nothing is read from the note again here.
    public static func run(_ generator: any ScriptGenerator, instruction: String, sample: ScriptSample,
                           examples: [ScriptExample] = [], destination: ScriptGeneratorDestination? = nil)
        async -> Result<String, ScriptGenerationFailure> {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return .failure(.failed("Say what the script should do.")) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard !sample.text.isEmpty || sample.isWholeText else {
            return .failure(.failed("The instruction and the examples leave no room for a sample of the text. Remove examples, or raise the context length in Settings ▸ Model."))
        }
        let result = await generator.generate(ScriptGenerationRequest(
            instruction: instruction, sample: sample, examples: examples, destination: destination))
        guard !Task.isCancelled else { return .failure(.cancelled) }
        return result.flatMap { script in
            script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failure(.noScript) : .success(script)
        }
    }
}

/// The part of a text a generator is shown.
public struct ScriptSample: Sendable, Hashable {
    public var text: String
    /// The sample is all of the text.
    public var isWholeText: Bool
    /// How many lines the whole text has.
    public var totalLines: Int

    public init(text: String, isWholeText: Bool, totalLines: Int) {
        self.text = text
        self.isWholeText = isWholeText
        self.totalLines = totalLines
    }

    /// What the workbench says above the sample it shows.
    public var summary: String {
        if isWholeText { return totalLines == 1 ? "All of the text, 1 line:" : "All of the text, \(totalLines) lines:" }
        let shown = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).count
        return "The first \(shown) of \(totalLines) lines:"
    }
}

/// A line of the text the user marked as an example for the generator,
/// with what it should become if they said.
public struct ScriptExample: Sendable, Hashable, Identifiable {
    /// The line's number in the text the script runs on, from 1.
    public var line: Int
    public var text: String
    /// What the line should become; empty when the user did not say.
    public var expected: String

    public var id: Int { line }

    public init(line: Int, text: String, expected: String = "") {
        self.line = line
        self.text = text
        self.expected = expected
    }

    /// The expected result, when there is one to send.
    public var wanted: String? {
        expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : expected
    }
}

public enum ScriptExamples {
    /// Examples a request may carry.
    public static let limit = 12

    /// The lines of `target`, as examples number them.
    public static func lines(of target: String) -> [Substring] {
        target.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
    }

    /// `examples` with line `line` of `target` marked too, in line order,
    /// or why it cannot be: there is no such line, it is blank, or there
    /// are `limit` examples already. A line marked before stays as it is.
    public static func marking(line: Int, of target: String, in examples: [ScriptExample]) -> Result<[ScriptExample], Refusal> {
        if examples.contains(where: { $0.line == line }) { return .success(examples) }
        let lines = lines(of: target)
        guard line >= 1, line <= lines.count else {
            return .failure(Refusal(reason: "The text has \(lines.count) \(lines.count == 1 ? "line" : "lines"); there is no line \(line)."))
        }
        let text = String(lines[line - 1])
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(Refusal(reason: "Line \(line) is empty, so it shows the model nothing."))
        }
        guard examples.count < limit else {
            return .failure(Refusal(reason: "A request carries at most \(limit) examples."))
        }
        return .success((examples + [ScriptExample(line: line, text: text)]).sorted { $0.line < $1.line })
    }

    public struct Refusal: Error, Sendable, Hashable {
        public var reason: String
    }
}

/// How much of the text a request may carry.
public enum ScriptSampleAllowance: Sendable, Hashable {
    /// A fixed number of characters and lines.
    case characters(Int, maxLines: Int)
    /// What fits a model's context: its length less the reply limit, the
    /// margin, the fixed prompt, the instruction and the examples
    /// (`ModelSampleBudget`).
    case tokens(context: Int, reply: Int)

    public static let standard = ScriptSampleAllowance.characters(ScriptSampling.defaultBudget, maxLines: ScriptSampling.defaultMaxLines)

    /// The sample of `target` a request with this instruction and these
    /// examples carries. The workbench shows exactly this before Generate
    /// is pressed, and `ScriptGeneration.run` sends exactly this.
    public func sample(of target: String, instruction: String, examples: [ScriptExample]) -> ScriptSample {
        switch self {
        case .characters(let budget, let maxLines):
            return ScriptSampling.sample(of: target, budget: budget, maxLines: maxLines)
        case .tokens(let context, let reply):
            let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = ModelSampleBudget.sampleTokens(context: context, reply: reply, instruction: instruction, examples: examples)
            return ScriptSampling.sample(of: target, budget: tokens, maxLines: .max, measure: { ModelSampleBudget.tokens(in: $0) })
        }
    }
}

public enum ScriptSampling {
    /// Characters of the text a request may carry.
    public static let defaultBudget = 2_000
    public static let defaultMaxLines = 40

    /// A sample of `target` of at most `budget` and `maxLines` lines: all
    /// of a text that fits, otherwise its leading whole lines, with the
    /// line endings they have. A first line longer than the budget is cut
    /// at the budget, between characters, as a sample must show something.
    /// The budget is in what `measure` counts: characters, unless said
    /// otherwise.
    public static func sample(of target: String, budget: Int = defaultBudget, maxLines: Int = defaultMaxLines,
                              measure: (Substring) -> Int = { $0.count }) -> ScriptSample {
        let budget = max(0, budget)
        let maxLines = max(1, maxLines)
        // A carriage return and line feed are one character to Swift, and
        // one line ending here.
        let lines = target.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        var taken = 0
        var used = 0
        for (index, line) in lines.prefix(maxLines).enumerated() {
            // A line after the first costs its line ending too.
            let cost = index == 0 ? measure(line) : measure(target[lines[index - 1].endIndex..<line.endIndex])
            guard used + cost <= budget else { break }
            used += cost
            taken += 1
        }
        if taken == lines.count {
            return ScriptSample(text: target, isWholeText: true, totalLines: lines.count)
        }
        if taken == 0 {
            // As much of the first line as the budget holds.
            var end = lines[0].startIndex
            var cut = 0
            while end < lines[0].endIndex {
                let next = lines[0].index(after: end)
                let cost = measure(lines[0][end..<next])
                guard cut + cost <= budget else { break }
                cut += cost
                end = next
            }
            return ScriptSample(text: String(lines[0][..<end]), isWholeText: false, totalLines: lines.count)
        }
        return ScriptSample(text: String(target[..<lines[taken - 1].endIndex]), isWholeText: false, totalLines: lines.count)
    }
}
#endif
