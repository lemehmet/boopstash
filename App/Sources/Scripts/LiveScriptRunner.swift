import BoopstashCore
import Foundation

/// The app's end of the script service (ADR 0007). One connection, opened
/// on first use; the service process starts on demand and is started again
/// after a run past its time limit ends it.
@MainActor
final class LiveScriptRunner {
    private var connection: NSXPCConnection?

    func run(_ request: ScriptRequest) async -> ScriptResponse {
        guard let data = try? JSONEncoder().encode(request) else {
            return ScriptResponse(outputs: [], errors: ["The script could not be sent."])
        }
        let connection = connect()
        let stopped = "\(request.scriptName) took longer than \(Int(request.timeLimit)) seconds and was stopped."
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
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
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ScriptResponse, Never>?

        init(_ continuation: CheckedContinuation<ScriptResponse, Never>) {
            self.continuation = continuation
        }

        func resume(_ response: ScriptResponse) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: response)
        }
    }
}
