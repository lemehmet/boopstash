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

    func format(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let response: JSFormatResponse
        if let request = try? JSONDecoder().decode(JSFormatRequest.self, from: request) {
            let watchdog = DispatchWorkItem { exit(0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + request.timeLimit, execute: watchdog)
            response = Formatters.format(request)
            watchdog.cancel()
        } else {
            response = JSFormatResponse(error: FormatError(message: "The format request could not be read.", line: nil, column: nil))
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

/// Prettier and sql-formatter (#56, #57), each loaded once per service
/// process into a context of its own and reused: they keep no state
/// between calls, and loading Prettier with its plugins is most of the
/// cost. Like scripts, they get nothing beyond JavaScriptCore itself.
enum Formatters {
    nonisolated(unsafe) private static var prettier: JSContext?
    nonisolated(unsafe) private static var sql: JSContext?

    static func format(_ request: JSFormatRequest) -> JSFormatResponse {
        let context: JSContext?
        switch request.engine {
        case .prettier:
            if prettier == nil {
                prettier = load(["Prettier/standalone", "Prettier/plugins/babel", "Prettier/plugins/estree", "Prettier/plugins/typescript",
                                 "Prettier/plugins/postcss", "Prettier/plugins/html", "Prettier/plugins/yaml", "Prettier/plugins/markdown"])
            }
            context = prettier
        case .sqlFormatter:
            if sql == nil { sql = load(["SQLFormatter/sql-formatter.min"]) }
            context = sql
        }
        guard let context else {
            return JSFormatResponse(error: FormatError(message: "The formatter could not be loaded.", line: nil, column: nil))
        }
        context.setObject(request.source, forKeyedSubscript: "__source" as NSString)
        context.setObject(request.options, forKeyedSubscript: "__options" as NSString)
        // Prettier answers with a promise; JavaScriptCore settles it before
        // evaluateScript returns, so the result is there to read.
        let script = request.engine == .prettier
            ? """
              var __result = null, __error = null;
              prettier.format(__source, Object.assign(JSON.parse(__options), { plugins: Object.values(prettierPlugins) }))
                .then(function (r) { __result = r }, function (e) { __error = e });
              """
            : """
              var __result = null, __error = null;
              try { __result = sqlFormatter.format(__source, JSON.parse(__options)) } catch (e) { __error = e }
              """
        context.evaluateScript(script)
        if let result = context.objectForKeyedSubscript("__result"), result.isString {
            return JSFormatResponse(formatted: result.toString())
        }
        return JSFormatResponse(error: error(from: context.objectForKeyedSubscript("__error")))
    }

    /// Prettier's errors carry `loc.start` (1-based line and column); the
    /// first line of the message is the reason, without the code frame.
    static func error(from value: JSValue?) -> FormatError {
        guard let value, !value.isNull, !value.isUndefined else {
            return FormatError(message: "The formatter returned nothing.", line: nil, column: nil)
        }
        let message = value.objectForKeyedSubscript("message")?.toString() ?? value.toString() ?? "Formatting failed"
        let reason = message.split(separator: "\n").first.map(String.init) ?? message
        let start = value.objectForKeyedSubscript("loc")?.objectForKeyedSubscript("start")
        let line = start?.objectForKeyedSubscript("line").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        let column = start?.objectForKeyedSubscript("column").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
        // The location is also in the message as "(line:column)": drop it,
        // since FormatError says where.
        let trimmed = reason.replacingOccurrences(of: #"\s*\(\d+:\d+\)$"#, with: "", options: .regularExpression)
        return FormatError(message: trimmed, line: line, column: column)
    }

    private static func load(_ names: [String]) -> JSContext? {
        let context = JSContext()!
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let code = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            context.evaluateScript(code, withSourceURL: url)
            if failed { return nil }
        }
        context.exceptionHandler = nil
        return context
    }
}
