import Foundation

/// The model helper's one call (ADR 0014): a JSON-encoded
/// `ModelServiceRequest` in, a JSON-encoded `ModelServiceResponse` out.
/// Data rather than objects, so the connection carries nothing but what
/// the app chose to send. The app opens a connection for a request and
/// closes it afterwards; closing it early cancels the request.
@objc protocol ModelServiceProtocol {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

enum ModelService {
    /// The helper's bundle identifier, which is also its XPC name.
    static let name = "com.lemehmet.boopstash.model"
}
