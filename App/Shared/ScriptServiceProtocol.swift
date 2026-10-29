import Foundation

/// The script service's one call (ADR 0007): a JSON-encoded `ScriptRequest`
/// in, a JSON-encoded `ScriptResponse` out. Data rather than objects, so
/// the connection carries nothing but text the app chose to send.
@objc protocol ScriptServiceProtocol {
    func run(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// A JSON-encoded `JSFormatRequest` in, a `JSFormatResponse` out.
    func format(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

enum ScriptService {
    /// The service's bundle identifier, which is also its XPC name.
    static let name = "com.lemehmet.boopstash.scripts"
}
