import Foundation

/// The spike's command line, checked before anything is measured. A
/// command line that is not understood is refused, never run as something
/// else: `--endpoint` with its value missing would otherwise measure the
/// on-device model and report it under the name asked for.
public enum SpikeArguments {
    /// Options that stand alone.
    static let switches: Set<String> = ["--selfcheck", "--help"]
    /// Options for the endpoint mode only, each with a value.
    static let endpointOnly = ["--model", "--temperature", "--top-p", "--max-tokens", "--timeout", "--extra-body"]
    /// Every option that takes a value.
    static let valued: Set<String> = Set(["--runs", "--fixtures", "--variations", "--out", "--dump", "--endpoint"] + endpointOnly)

    /// The value that follows `flag`, or nil when the flag is absent.
    public static func value(of flag: String, in arguments: [String]) -> String? {
        guard let at = arguments.firstIndex(of: flag), at + 1 < arguments.count else { return nil }
        return arguments[at + 1]
    }

    /// What is wrong with the arguments (the program's name not among
    /// them), in words for the person who typed them, or nil.
    public static func problem(in arguments: [String]) -> String? {
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard switches.contains(argument) || valued.contains(argument) else { return "\(argument) is not an option" }
            guard seen.insert(argument).inserted else { return "\(argument) was given twice" }
            index += 1
            if valued.contains(argument) {
                // A value never begins with two dashes; a negative number has one.
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { return "\(argument) needs a value" }
                index += 1
            }
        }
        func value(_ flag: String) -> String? { self.value(of: flag, in: arguments) }

        if let runs = value("--runs"), (Int(runs) ?? 0) < 1 { return "--runs needs a whole number of at least 1" }
        guard let endpoint = value("--endpoint") else {
            if let stray = endpointOnly.first(where: seen.contains) { return "\(stray) is for --endpoint, which was not given" }
            return nil
        }
        // "localhost:8080" parses with "localhost" as its scheme: only http
        // and https are endpoints.
        guard let base = URL(string: endpoint), ChatCompletion.isEndpoint(base) else {
            return "--endpoint needs an http or https URL with a host, such as http://localhost:8080"
        }
        guard let model = value("--model"), !model.isEmpty else { return "--endpoint needs --model, the model's name at that endpoint" }
        if let text = value("--temperature"), !(Double(text).map { $0.isFinite && $0 >= 0 } ?? false) {
            return "--temperature needs a number of 0 or more"
        }
        if let text = value("--top-p"), !(Double(text).map { $0 > 0 && $0 <= 1 } ?? false) {
            return "--top-p needs a number above 0 and at most 1"
        }
        if let text = value("--max-tokens"), (Int(text) ?? 0) < 1 { return "--max-tokens needs a whole number of at least 1" }
        if let text = value("--timeout"), !(Double(text).map { $0.isFinite && $0 > 0 } ?? false) {
            return "--timeout needs a number of seconds above 0"
        }
        if let text = value("--extra-body") {
            guard let extra = extraBody(text) else { return "--extra-body needs a JSON object" }
            if let field = ChatCompletion.refusedExtraFields(in: extra).first {
                return "--extra-body may not set \(field): the report would name a request that was not the one sent"
            }
        }
        return nil
    }

    /// The JSON object given to `--extra-body`, or nil when it is not one.
    public static func extraBody(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
