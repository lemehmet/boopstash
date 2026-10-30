import BoopstashCore
import Foundation
import JavaScriptCore

/// Runs one script request in a fresh `JSContext` with Boop's API and
/// nothing else (ADR 0005, ADR 0007). JavaScriptCore has no network, timers
/// or file access unless they are injected, and none are. A run past its
/// time limit ends this process; the app starts a new one for the next run.
final class ScriptHost: NSObject, ScriptServiceProtocol {
    /// One request at a time in the whole process, across connections
    /// (#111): the formatters' contexts are cached and shared, and their
    /// request globals must not be written by two requests at once. Each
    /// connection's queue is serial, but connections run in parallel.
    private static let turn = NSLock()

    /// Runs `work` in its turn, with the watchdog started only once the
    /// turn is its own, so waiting never counts against its time limit and
    /// one request's watchdog never ends another's run.
    static func inTurn<T>(timeLimit: TimeInterval, _ work: () -> T) -> T {
        turn.lock()
        defer { turn.unlock() }
        let watchdog = DispatchWorkItem { exit(0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit, execute: watchdog)
        defer { watchdog.cancel() }
        return work()
    }

    func run(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let response: ScriptResponse
        if let request = try? JSONDecoder().decode(ScriptRequest.self, from: request) {
            response = Self.inTurn(timeLimit: request.timeLimit) { Self.run(request) }
        } else {
            response = ScriptResponse(outputs: [], errors: ["The script request could not be read."])
        }
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }

    func format(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let response: JSFormatResponse
        if let request = try? JSONDecoder().decode(JSFormatRequest.self, from: request) {
            response = Self.inTurn(timeLimit: request.timeLimit) { Formatters.format(request) }
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

/// Prettier and sql-formatter (#56, #57), and formatters compiled to
/// WebAssembly (#158, ADR 0010), each loaded once per service process into
/// a context of its own and reused: they keep no state between calls, and
/// loading is most of the cost. Like scripts, they get nothing beyond
/// JavaScriptCore itself; WebAssembly runs in its interpreter, as the
/// service has no JIT entitlement.
enum Formatters {
    nonisolated(unsafe) private static var prettier: JSContext?
    nonisolated(unsafe) private static var sql: JSContext?
    nonisolated(unsafe) private static var wasm: [JSFormatRequest.Engine: JSContext] = [:]

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
        case .ruff, .gofmt, .shfmt, .clangFormat:
            if wasm[request.engine] == nil { wasm[request.engine] = loadWasm(request.engine) }
            context = wasm[request.engine]
        }
        guard let context else {
            return JSFormatResponse(error: FormatError(message: "The formatter could not be loaded.", line: nil, column: nil))
        }
        context.setObject(request.source, forKeyedSubscript: "__source" as NSString)
        context.setObject(request.options, forKeyedSubscript: "__options" as NSString)
        // Prettier answers with a promise; JavaScriptCore settles it before
        // evaluateScript returns, so the result is there to read.
        let call = switch request.engine {
        case .prettier: ""
        case .sqlFormatter: "sqlFormatter.format(__source, __o)"
        case .ruff: "__module.format(__source, 'note.py', __o)"
        case .gofmt: "__formatWithMemory(__wasm, __source, null, null)"
        case .shfmt: "__formatWithMemory(__wasm, __source, __o, null)"
        case .clangFormat: "__module.format(__source, __o.filename, __o.style)"
        }
        let script = request.engine == .prettier
            ? """
              var __result = null, __error = null;
              prettier.format(__source, Object.assign(JSON.parse(__options), { plugins: Object.values(prettierPlugins) }))
                .then(function (r) { __result = r }, function (e) { __error = e });
              """
            : """
              var __result = null, __error = null;
              try { var __o = JSON.parse(__options); __result = \(call) } catch (e) { __error = e }
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
        // gofmt and shfmt start theirs with "line:column: ".
        if line == nil, let match = trimmed.firstMatch(of: /^(?:<[^>]*>:)?(\d+):(\d+): (.+)$/) {
            return FormatError(message: String(match.3), line: Int(match.1), column: Int(match.2))
        }
        return FormatError(message: trimmed, line: line, column: column)
    }

    /// A formatter compiled to WebAssembly: the host's TextEncoder and
    /// helpers, the package's own glue, and the module, instantiated once.
    private static func loadWasm(_ engine: JSFormatRequest.Engine) -> JSContext? {
        let context = JSContext()!
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        func resource(_ name: String, _ type: String) -> URL? { Bundle.main.url(forResource: name, withExtension: type) }
        guard let host = resource("WasmHost", "js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return nil }
        context.evaluateScript(host)
        /// An ES module of the package, unmodified on disk: its exports
        /// become the properties of `__module` (one module per context).
        func evaluateModule(_ name: String) -> Bool {
            guard let url = resource(name, "js"), let code = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let exported = code.matches(of: /(?m)^export (?:async )?(?:function|class|const|let|var) ([A-Za-z0-9_$]+)/).map { String($0.1) }
            let body = code.replacing(/(?m)^export (?=(?:async )?(?:function|class|const|let|var) )/, with: "")
            context.evaluateScript("var __module = Object.assign(globalThis.__module || {}, (function () {\n\(body)\nreturn { \(exported.joined(separator: ", ")) };\n})());",
                                   withSourceURL: url)
            return !failed
        }
        /// The module's bytes, as `__bytes`.
        func setBytes(_ name: String) -> Bool {
            guard let data = resource(name, "wasm").flatMap({ try? Data(contentsOf: $0) }),
                  let array = context.evaluateScript("new Uint8Array(\(data.count))"),
                  let pointer = JSObjectGetTypedArrayBytesPtr(context.jsGlobalContextRef, array.jsValueRef, nil)
            else { return false }
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
            context.setObject(array, forKeyedSubscript: "__bytes" as NSString)
            return true
        }
        let ready: Bool
        switch engine {
        case .gofmt, .shfmt:
            let name = engine == .gofmt ? "gofmt" : "shfmt"
            ready = setBytes("WasmFormatters/\(name)/\(name)")
            context.evaluateScript("var __wasm = new WebAssembly.Instance(new WebAssembly.Module(__bytes), {}).exports; if (__wasm._initialize) __wasm._initialize();")
        case .ruff:
            ready = evaluateModule("WasmFormatters/ruff_fmt/ruff_fmt_bg") && setBytes("WasmFormatters/ruff_fmt/ruff_fmt_bg")
            context.evaluateScript("""
                (function () {
                  const { __wbg_set_wasm, format, format_range, ...imports } = __module;
                  const instance = new WebAssembly.Instance(new WebAssembly.Module(__bytes), { "./ruff_fmt_bg.js": imports });
                  __wbg_set_wasm(instance.exports);
                  if (instance.exports.__wbindgen_start) instance.exports.__wbindgen_start();
                })();
                """)
        case .clangFormat:
            ready = evaluateModule("WasmFormatters/clang-format/clang-format") && evaluateModule("WasmFormatters/clang-format/clang-format-binding")
                && setBytes("WasmFormatters/clang-format/clang-format")
            context.evaluateScript("__module.set_wasm(__module.createModule({ wasm: new WebAssembly.Module(__bytes) }));")
        case .prettier, .sqlFormatter:
            return nil
        }
        context.evaluateScript("__bytes = null;")
        guard ready, !failed else { return nil }
        // Not nil: JavaScriptCore crashes reporting an exception with no
        // handler, and reading an error without `loc` (sql-formatter's,
        // gofmt's) raises one.
        context.exceptionHandler = { _, _ in }
        return context
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
        // Not nil: JavaScriptCore crashes reporting an exception with no
        // handler, and reading an error without `loc` (sql-formatter's,
        // gofmt's) raises one.
        context.exceptionHandler = { _, _ in }
        return context
    }
}
