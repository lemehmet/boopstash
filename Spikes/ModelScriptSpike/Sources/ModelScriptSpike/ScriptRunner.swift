import Foundation
import JavaScriptCore
import SpikeKit

/// Runs a script much as the app's script service does (ADR 0007): a fresh
/// `JSContext` with Boop's `state` object, in a sandboxed process of its own
/// that is killed at the time limit. The child is this same executable
/// started with `--run-script`.
///
/// Two differences from the service, both on purpose. The spike has no
/// `require('@boop/…')`: the bundled libraries are the app's, and the prompt
/// tells the model there is no `require`, so a script that asks for one is a
/// failure here. And the child is confined by `sandbox_init` with the
/// system's pure-computation profile (no files, no network) rather than by
/// the App Sandbox, which a SwiftPM executable cannot carry.
enum ScriptRunner {
    static let timeLimit = ScriptRun.timeLimit

    struct Request: Codable {
        var source: String
        var text: String
    }

    struct Response: Codable {
        var output: String?
        var errors: [String]
    }

    /// Parent side: start the child, give it the request, kill it if it is
    /// still running at the time limit. A child that could not be started,
    /// or that ended without a result, is the runner's failure and is
    /// reported as that, never as the script's error.
    static func run(source: String, text: String) -> ScriptRun {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--run-script"]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return .runnerFailed("could not start the runner: \(error.localizedDescription)") }

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

        // A complete response wins: a child that finished as the watchdog
        // fired has still finished. A child with no result timed out only
        // if the watchdog's SIGTERM is what ended it; one that exited or
        // trapped by itself as the watchdog fired is a runner failure.
        if let response = try? JSONDecoder().decode(Response.self, from: data) {
            return .finished(output: response.output, errors: response.errors)
        }
        let exit: ScriptRun.Exit = child.terminationReason == .uncaughtSignal
            ? .signal(child.terminationStatus) : .status(child.terminationStatus)
        return ScriptRun.ended(watchdogFired: killed.isSet, exit: exit, watchdogSignal: SIGTERM)
    }

    /// Whether the child's sandbox refuses a file read and a socket, asked
    /// of a child started for the purpose. The self-check uses it.
    static func sandboxHolds() -> Bool {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--run-script", "--probe-sandbox"]
        let output = Pipe()
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        guard (try? child.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return String(decoding: data, as: UTF8.self) == "file denied, socket denied"
    }

    /// Confines this process before any script runs: no file access, no
    /// network. `sandbox_init` is deprecated and still the only way for a
    /// plain executable to sandbox itself; the child exits if it fails, so
    /// a script never runs unconfined.
    static func enterSandbox() {
        var message: UnsafeMutablePointer<CChar>?
        // "pure-computation" is kSBXProfilePureComputation and 1 is
        // SANDBOX_NAMED in <sandbox.h>, which Swift does not import.
        guard sandbox_init("pure-computation", 1, &message) == 0 else { exit(3) }
    }

    /// Child side: read one request from standard input, run it, write the
    /// response to standard output.
    static func serve() {
        if CommandLine.arguments.contains("--probe-sandbox") {
            enterSandbox()
            let file = FileManager.default.contents(atPath: "/etc/hosts") == nil ? "denied" : "allowed"
            FileHandle.standardOutput.write(Data("file \(file), socket \(connectIsRefused() ? "denied" : "allowed")".utf8))
            return
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else { exit(2) }
        // JavaScriptCore cannot start inside the sandbox, so the context is
        // made first, empty, and the sandbox entered before it sees any code.
        let context = JSContext()!
        enterSandbox()
        let response = execute(request, in: context)
        FileHandle.standardOutput.write((try? JSONEncoder().encode(response)) ?? Data())
    }

    /// Whether the sandbox, not the network, refuses a connection: a
    /// connect to the loopback address fails with EPERM.
    static func connectIsRefused() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result != 0 && errno == EPERM
    }

    /// Follows `ScriptHost.run` in App/ScriptService, less `require`:
    /// evaluate, find `main`, call it with the state, and report nothing as
    /// output if anything was posted as an error.
    static func execute(_ request: Request, in context: JSContext) -> Response {
        let state = SpikeState(text: request.text)
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

@_silgen_name("sandbox_init")
private func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

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
