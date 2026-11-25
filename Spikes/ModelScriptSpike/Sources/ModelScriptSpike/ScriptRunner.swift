import Foundation
import JavaScriptCore

/// Runs a script the way the app's script service does (ADR 0007): a fresh
/// `JSContext` with Boop's `state` object and nothing else, in a process of
/// its own that is killed at the time limit. The child is this same
/// executable started with `--run-script`.
enum ScriptRunner {
    static let timeLimit: TimeInterval = 2

    struct Request: Codable {
        var source: String
        var text: String
    }

    struct Response: Codable {
        var output: String?
        var errors: [String]
    }

    enum Outcome {
        case finished(Response)
        case timedOut
        case crashed(String)
    }

    /// Parent side: start the child, give it the request, kill it if it is
    /// still running at the time limit.
    static func run(source: String, text: String) -> Outcome {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--run-script"]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return .crashed("could not start the runner: \(error.localizedDescription)") }

        let killed = Flag()
        let watchdog = DispatchWorkItem {
            killed.set()
            child.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit, execute: watchdog)
        let request = (try? JSONEncoder().encode(Request(source: source, text: text))) ?? Data()
        try? input.fileHandleForWriting.write(contentsOf: request)
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        watchdog.cancel()

        if killed.isSet { return .timedOut }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return .crashed("the runner exited with status \(child.terminationStatus) and no result")
        }
        return .finished(response)
    }

    /// Child side: read one request from standard input, run it, write the
    /// response to standard output.
    static func serve() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else { exit(2) }
        let response = execute(request)
        FileHandle.standardOutput.write((try? JSONEncoder().encode(response)) ?? Data())
    }

    /// Mirrors `ScriptHost.run` in App/ScriptService: evaluate, find `main`,
    /// call it with the state, and report nothing as output if anything was
    /// posted as an error.
    static func execute(_ request: Request) -> Response {
        let state = SpikeState(text: request.text)
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            state.errors.append(exception?.toString() ?? "Unknown error")
        }
        context.evaluateScript(request.source)
        guard state.errors.isEmpty else { return Response(output: nil, errors: state.errors) }
        guard let main = context.objectForKeyedSubscript("main"), !main.isUndefined else {
            return Response(output: nil, errors: ["The script has no main function."])
        }
        main.call(withArguments: [state])
        return Response(output: state.errors.isEmpty ? (state.fullText ?? "") : nil, errors: state.errors)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@objc protocol SpikeStateExports: JSExport {
    var selection: String? { get set }
    var fullText: String? { get set }
    var text: String? { get set }
    var isSelection: Bool { get }
    func postError(_ error: String)
    func postInfo(_ info: String)
    func insert(_ value: String)
}

/// Boop's `state` for a run on the whole note with no selection, which is
/// the only shape the spike needs.
final class SpikeState: NSObject, SpikeStateExports {
    var fullText: String?
    var errors: [String] = []

    init(text: String) { fullText = text }

    var selection: String? {
        get { nil }
        set {}
    }
    var text: String? {
        get { fullText }
        set { fullText = newValue }
    }
    var isSelection: Bool { false }
    func postError(_ error: String) { errors.append(error) }
    func postInfo(_ info: String) {}
    func insert(_ value: String) { fullText = value }
}
