import BoopstashCore
import Foundation
import JavaScriptCore

/// Runs one script request in a fresh `JSContext` with Boop's API and
/// nothing else (ADR 0005, ADR 0007). JavaScriptCore has no network, timers
/// or file access unless they are injected, and none are. A run past its
/// time limit ends this process; the app starts a new one for the next run.
final class ScriptHost: NSObject, ScriptServiceProtocol {
    func run(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let response: ScriptResponse
        if let request = try? JSONDecoder().decode(ScriptRequest.self, from: request) {
            let watchdog = DispatchWorkItem { exit(0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + request.timeLimit, execute: watchdog)
            response = Self.run(request)
            watchdog.cancel()
        } else {
            response = ScriptResponse(outputs: [], errors: ["The script request could not be read."])
        }
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }

    static func run(_ request: ScriptRequest) -> ScriptResponse {
        var outputs: [String] = []
        let messages = Messages()
        for state in request.states {
            let execution = ScriptExecution(state: state, messages: messages)
            let context = makeContext(name: request.scriptName, messages: messages)
            context.evaluateScript(request.source, withSourceURL: URL(string: "boop://script"))
            guard messages.errors.isEmpty else { break }
            guard let main = context.objectForKeyedSubscript("main"), !main.isUndefined else {
                messages.errors.append("The script has no main function.")
                break
            }
            main.call(withArguments: [execution])
            outputs.append(execution.state.text ?? "")
        }
        // A run that failed changes nothing; what it posted is still shown.
        return ScriptResponse(outputs: messages.errors.isEmpty ? outputs : [], errors: messages.errors, infos: messages.infos)
    }

    final class Messages {
        var errors: [String] = []
        var infos: [String] = []
    }

    static func makeContext(name: String, messages: Messages) -> JSContext {
        let context = JSContext()!
        context.name = name
        context.exceptionHandler = { _, exception in
            messages.errors.append("[\(name)] \(exception?.toString() ?? "Unknown error")")
        }
        // `require('@boop/<module>')`: Boop's bundled libraries, wrapped as
        // CommonJS modules the way Boop wraps them. Nothing else resolves.
        let require: @convention(block) (String) -> JSValue? = { path in
            guard path.hasPrefix("@boop/") else { return nil }
            var module = String(path.dropFirst("@boop/".count))
            if module.hasSuffix(".js") { module.removeLast(3) }
            guard !module.contains("/"), !module.contains(".."),
                  let url = Bundle.main.url(forResource: module, withExtension: "js", subdirectory: "lib"),
                  let code = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            let wrapped = """
            (function() {
                var module = { exports: {} };
                (function (exports, module) {
            \(code)
                }).apply(module.exports, [module.exports, module]);
                return module.exports;
            })();
            """
            return JSContext.current()?.evaluateScript(wrapped, withSourceURL: url)
        }
        context.setObject(require, forKeyedSubscript: "require" as NSString)
        return context
    }
}

@objc protocol ScriptExecutionExports: JSExport {
    var selection: String? { get set }
    var fullText: String? { get set }
    var text: String? { get set }
    var isSelection: Bool { get }
    func postError(_ error: String)
    func postInfo(_ info: String)
    func insert(_ value: String)
}

/// Boop's `state` object, as JavaScript sees it; the logic is Core's
/// `ScriptState`.
final class ScriptExecution: NSObject, ScriptExecutionExports {
    var state: ScriptState
    let messages: ScriptHost.Messages

    init(state: ScriptState, messages: ScriptHost.Messages) {
        self.state = state
        self.messages = messages
    }

    var selection: String? {
        get { state.selection }
        set { state.selection = newValue }
    }
    var fullText: String? {
        get { state.fullText }
        set { state.fullText = newValue }
    }
    var text: String? {
        get { state.text }
        set { state.text = newValue }
    }
    var isSelection: Bool { state.isSelection }

    func postError(_ error: String) { messages.errors.append(error) }
    func postInfo(_ info: String) { messages.infos.append(info) }
    func insert(_ value: String) { state.insert(value) }
}
