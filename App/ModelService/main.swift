import BoopstashCore
import Foundation

/// The model helper's entry point (ADR 0014): the one process in
/// BoopStash with the outgoing-network entitlement, and with nothing
/// else: no App Group, so the notes' container is closed to it. It calls
/// no Keychain API; the key comes from the app with each request. For
/// each request the app hands it exactly what the request carries, and it
/// keeps nothing afterwards. It logs nothing.
final class ModelHost: NSObject, ModelServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [ModelClient] = []
    private var closed = false

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? JSONDecoder().decode(ModelServiceRequest.self, from: request) else {
            reply(Self.encoded(ModelServiceResponse(failure: .refused("The model request could not be read."))))
            return
        }
        let client = ModelClient()
        lock.lock()
        let closed = closed
        if !closed { clients.append(client) }
        lock.unlock()
        guard !closed else {
            reply(Self.encoded(ModelServiceResponse(failure: .cancelled)))
            return
        }
        client.perform(request) { [weak self] response in
            self?.forget(client)
            reply(Self.encoded(response))
        }
    }

    /// The connection closed: the app cancelled, or went away.
    func close() {
        lock.lock()
        closed = true
        let running = clients
        clients = []
        lock.unlock()
        for client in running { client.cancel() }
    }

    private func forget(_ client: ModelClient) {
        lock.lock()
        clients.removeAll { $0 === client }
        lock.unlock()
    }

    private static func encoded(_ response: ModelServiceResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let host = ModelHost()
        connection.exportedInterface = NSXPCInterface(with: ModelServiceProtocol.self)
        connection.exportedObject = host
        connection.invalidationHandler = { @Sendable in host.close() }
        connection.interruptionHandler = { @Sendable in host.close() }
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
