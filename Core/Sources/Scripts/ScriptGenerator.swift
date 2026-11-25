import Foundation

/// Something that writes a first draft of a workbench script from a plain
/// instruction (#247, ADR 0013). This is the seam only: nothing in the app
/// implements it yet, and with no generator the workbench shows no prompt
/// field and no Generate button.
///
/// The draft is untrusted text. It goes into the workbench's script editor
/// and nowhere else: it runs only when the user chooses Run, in the script
/// service (ADR 0007), and reaches the note only through Keep.
public protocol ScriptGenerator: Sendable {
    /// Whether a request can be made now and, if so, where it would go.
    /// The workbench asks each time its sheet opens, so this should answer
    /// quickly and without sending the user's text anywhere.
    func availability() async -> ScriptGeneratorAvailability

    /// Writes a script for `request`. Runs in the caller's task: when that
    /// task is cancelled the generator stops what it is doing and answers
    /// `.failure(.cancelled)`. Success is the script's text alone (no
    /// prose, no code fence), defining `main(state)`.
    func generate(_ request: ScriptGenerationRequest) async -> Result<String, ScriptGenerationFailure>
}

/// What a generator is given: the user's instruction and a bounded sample
/// of the text the script will run on, never the whole of a long note.
public struct ScriptGenerationRequest: Sendable, Hashable {
    public var instruction: String
    public var sample: ScriptSample

    public init(instruction: String, sample: ScriptSample) {
        self.instruction = instruction
        self.sample = sample
    }
}

public enum ScriptGeneratorAvailability: Sendable, Hashable {
    /// Ready; the destination is what the workbench shows next to Generate.
    case available(ScriptGeneratorDestination)
    /// Not now, and why, in a sentence: nothing configured, the model is
    /// not reachable. The workbench offers no Generate then.
    case unavailable(reason: String)
}

/// Where a request goes, for the user to see before sending one.
public struct ScriptGeneratorDestination: Sendable, Hashable {
    /// A few words: "the model on this Mac", "the model at 127.0.0.1:8080".
    public var summary: String
    /// The instruction and the sample leave this device.
    public var leavesDevice: Bool

    public init(summary: String, leavesDevice: Bool) {
        self.summary = summary
        self.leavesDevice = leavesDevice
    }

    /// The line under the prompt field.
    public var notice: String {
        let what = "Your instruction and a sample of the text go to \(summary)."
        return leavesDevice ? what + " That is outside this device." : what
    }
}

public enum ScriptGenerationFailure: Error, Sendable, Hashable {
    /// The caller's task was cancelled.
    case cancelled
    /// A reply came, and nothing in it defines `main`.
    case noScript
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
        case .unavailable(let reason), .failed(let reason): reason
        }
    }
}

/// The workbench's side of a generator: what it shows, and one request.
public enum ScriptGeneration {
    /// Where Generate would send a request, or nil when the workbench
    /// shows no prompt field and no Generate button: there is no
    /// generator, or it is not available now.
    public static func destination(_ availability: ScriptGeneratorAvailability?) -> ScriptGeneratorDestination? {
        guard case .available(let destination) = availability else { return nil }
        return destination
    }

    /// Asks `generator` for a script for `instruction`, with a sample of
    /// `target` no larger than the budget. An empty instruction is not
    /// sent. A cancelled task answers `.cancelled` whatever the generator
    /// returned, and a blank script is `.noScript`.
    public static func run(_ generator: any ScriptGenerator, instruction: String, target: String,
                           budget: Int = ScriptSampling.defaultBudget, maxLines: Int = ScriptSampling.defaultMaxLines)
        async -> Result<String, ScriptGenerationFailure> {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return .failure(.failed("Say what the script should do.")) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let sample = ScriptSampling.sample(of: target, budget: budget, maxLines: maxLines)
        let result = await generator.generate(ScriptGenerationRequest(instruction: instruction, sample: sample))
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
}

public enum ScriptSampling {
    /// Characters of the text a request may carry.
    public static let defaultBudget = 2_000
    public static let defaultMaxLines = 40

    /// A sample of `target` of at most `budget` characters and `maxLines`
    /// lines: all of a text that fits, otherwise its leading whole lines,
    /// with the line endings they have. A first line longer than the
    /// budget is cut at the budget, between characters, as a sample must
    /// show something.
    public static func sample(of target: String, budget: Int = defaultBudget, maxLines: Int = defaultMaxLines) -> ScriptSample {
        let budget = max(0, budget)
        let maxLines = max(1, maxLines)
        // A carriage return and line feed are one character to Swift, and
        // one line ending here.
        let lines = target.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        var taken = 0
        var used = 0
        for line in lines.prefix(maxLines) {
            // A line after the first costs its line feed too.
            let cost = line.count + (taken == 0 ? 0 : 1)
            guard used + cost <= budget else { break }
            used += cost
            taken += 1
        }
        if taken == lines.count {
            return ScriptSample(text: target, isWholeText: true, totalLines: lines.count)
        }
        let text = taken == 0 ? String(lines[0].prefix(budget)) : String(target[..<lines[taken - 1].endIndex])
        return ScriptSample(text: text, isWholeText: false, totalLines: lines.count)
    }
}
