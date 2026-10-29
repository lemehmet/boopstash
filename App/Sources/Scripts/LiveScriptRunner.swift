import BoopstashCore
import Foundation

/// The app's end of the script service (ADR 0007). One connection, opened
/// on first use; the service process starts on demand and is started again
/// after a run past its time limit ends it.
@MainActor
final class LiveScriptRunner {
    private var connection: NSXPCConnection?

    /// Requests go to the service one at a time, each after the previous
    /// one has finished: a superseded format still runs to its end or its
    /// watchdog, and a watchdog ends the whole service process, which would
    /// fail whatever request was in flight beside it.
    private var queue: Task<Void, Never>?

    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    func run(_ request: ScriptRequest) async -> ScriptResponse {
        await serialized { await self.send(request) }
    }

    func format(_ request: JSFormatRequest) async -> Result<String, FormatError> {
        await serialized { await self.send(request) }
    }

    private func send(_ request: ScriptRequest) async -> ScriptResponse {
        guard let data = try? JSONEncoder().encode(request) else {
            return ScriptResponse(outputs: [], errors: ["The script could not be sent."])
        }
        let connection = connect()
        let stopped = "\(request.scriptName) took longer than \(Int(request.timeLimit)) seconds and was stopped."
        return await withCheckedContinuation { continuation in
            let once = Once<ScriptResponse>(continuation)
            // Both handlers run on XPC's queue, not the main actor: @Sendable
            // keeps them nonisolated, or Swift's isolation check traps.
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                // Interrupted: the service ended mid-run, which is the time
                // limit (or a crash in the script engine).
                once.resume(ScriptResponse(outputs: [], errors: [(error as NSError).code == NSXPCConnectionInterrupted ? stopped : "The script service failed: \(error.localizedDescription)"]))
            } as? ScriptServiceProtocol
            guard let proxy else {
                once.resume(ScriptResponse(outputs: [], errors: ["The script service is not available."]))
                return
            }
            proxy.run(data) { reply in
                let response = (try? JSONDecoder().decode(ScriptResponse.self, from: reply))
                    ?? ScriptResponse(outputs: [], errors: ["The script service's answer could not be read."])
                once.resume(response)
            }
        }
    }

    /// Formats with Prettier or sql-formatter in the service.
    private func send(_ request: JSFormatRequest) async -> Result<String, FormatError> {
        guard let data = try? JSONEncoder().encode(request) else {
            return .failure(FormatError(message: "The text could not be sent to the formatter.", line: nil, column: nil))
        }
        let connection = connect()
        let stopped = FormatError(message: "Formatting took longer than \(Int(request.timeLimit)) seconds and was stopped.", line: nil, column: nil)
        let response: JSFormatResponse = await withCheckedContinuation { continuation in
            let once = Once<JSFormatResponse>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(JSFormatResponse(error: (error as NSError).code == NSXPCConnectionInterrupted
                    ? stopped : FormatError(message: "The formatter failed: \(error.localizedDescription)", line: nil, column: nil)))
            } as? ScriptServiceProtocol
            guard let proxy else {
                once.resume(JSFormatResponse(error: FormatError(message: "The formatter is not available.", line: nil, column: nil)))
                return
            }
            proxy.format(data) { reply in
                once.resume((try? JSONDecoder().decode(JSFormatResponse.self, from: reply))
                    ?? JSFormatResponse(error: FormatError(message: "The formatter's answer could not be read.", line: nil, column: nil)))
            }
        }
        if let formatted = response.formatted { return .success(formatted) }
        return .failure(response.error ?? FormatError(message: "Formatting failed.", line: nil, column: nil))
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: ScriptService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// The reply and the error handler can both fire; the first one wins.
    private final class Once<Response: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Response, Never>?

        init(_ continuation: CheckedContinuation<Response, Never>) {
            self.continuation = continuation
        }

        func resume(_ response: Response) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: response)
        }
    }
}
