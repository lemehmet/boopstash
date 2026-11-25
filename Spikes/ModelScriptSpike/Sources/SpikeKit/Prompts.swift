import Foundation

public enum Wording: String, Sendable, Codable {
    /// The script API spelled out, the limits named, and one example.
    case detailed
    /// One sentence.
    case terse
}

public struct Variation: Sendable, Codable, Hashable {
    public var id: String
    public var wording: Wording
    /// The first lines of the text only, or all of it.
    public var fullSample: Bool
    /// Guided generation (`@Generable`) rather than a free-text reply.
    public var guided: Bool
    /// The request also shows what the sample must become, as a user
    /// could by typing the first lines of the result they want.
    public var showsOutput = false

    /// One change at a time from the baseline, not the full factorial: see
    /// the ADR for why.
    public static let all = [
        Variation(id: "baseline", wording: .detailed, fullSample: false, guided: false),
        Variation(id: "terse", wording: .terse, fullSample: false, guided: false),
        Variation(id: "full-sample", wording: .detailed, fullSample: true, guided: false),
        Variation(id: "guided", wording: .detailed, fullSample: false, guided: true),
        Variation(id: "with-output", wording: .detailed, fullSample: false, guided: false, showsOutput: true),
    ]
}

public enum Prompts {
    public static func instructions(_ wording: Wording, guided: Bool) -> String {
        let reply = guided
            ? "Give the complete script and nothing else."
            : "Reply with the complete script in one ```js code block and nothing else."
        switch wording {
        case .terse:
            return "Write a JavaScript function main(state) that reads state.text and assigns the transformed text to state.text. \(reply)"
        case .detailed:
            return """
            You write small scripts for a text editor. A script is plain JavaScript that defines one function, main(state).
            - state.text is the text to transform, a string with lines separated by "\\n". Assign the result to state.text.
            - Use only the JavaScript language itself: strings, arrays, regular expressions. There is no require, no console, no files and no network.
            - The script runs on the whole text, which is longer than the sample you are shown, so write general rules, never the sample's values.
            - If the text cannot be transformed, call state.postError("why") and leave state.text alone.
            \(reply)

            An example, for "trim every line and drop empty lines":
            function main(state) {
              const lines = state.text.split("\\n");
              state.text = lines.map(line => line.trim()).filter(line => line.length > 0).join("\\n");
            }
            """
        }
    }

    public static func request(instruction: String, sample: String, isWholeText: Bool, sampleOutput: String? = nil) -> String {
        let label = isWholeText ? "The text:" : "A sample of the text (the whole text has more lines like these):"
        let wanted = sampleOutput.map { "\n\nFor that sample, the script must produce exactly:\n\($0)" } ?? ""
        return "Task: \(instruction)\n\n\(label)\n\(sample)\(wanted)"
    }

    /// The one retry: what went wrong, said the way the workbench could say
    /// it. For a wrong output the spike knows the expected line; in the
    /// workbench that line is the user's correction.
    public static func retry(_ problem: RetryProblem) -> String {
        let ask = "Fix the script and reply with the complete corrected script."
        switch problem {
        case .noScript:
            return "Your reply had no main(state) function. Reply with the complete script, defining function main(state)."
        case .error(let message):
            return "Running the script failed with this error:\n\(message)\n\(ask)"
        case .timedOut:
            return "The script did not finish within 2 seconds, so it probably loops forever. \(ask)"
        case .wrongOutput(let line, let expected, let actual, let head):
            return """
            The script ran, but its output is wrong. Line \(line) of the output was:
            \(actual.isEmpty ? "(missing)" : actual)
            It should be:
            \(expected.isEmpty ? "(nothing: the output should have ended)" : expected)
            The output began:
            \(head)
            \(ask)
            """
        }
    }
}

public enum RetryProblem: Sendable {
    case noScript
    case error(String)
    case timedOut
    case wrongOutput(line: Int, expected: String, actual: String, head: String)
}
