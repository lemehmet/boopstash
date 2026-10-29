import Foundation

/// The script service's entry point (ADR 0007). Each connection gets a
/// `ScriptHost`; requests run one at a time across all of them
/// (`ScriptHost.inTurn`).
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.exportedObject = ScriptHost()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
