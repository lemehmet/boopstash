import BoopstashCore
import Foundation
import Security

/// The app's end of the model helper (ADR 0014). The app makes no network
/// request itself and has no entitlement to: it hands the helper what one
/// request carries and gets the answer back. A connection is opened for a
/// request and closed after it, so the helper process starts only when a
/// request is made and holds nothing in between; closing the connection
/// early is how a request is cancelled.
enum LiveModelService {
    @Sendable static func send(_ request: ModelServiceRequest) async -> ModelServiceResponse {
        guard let data = try? JSONEncoder().encode(request) else {
            return ModelServiceResponse(failure: .failed("The request could not be handed to the model helper."))
        }
        let call = Call()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                call.start(data, continuation)
            }
        } onCancel: {
            call.finish(ModelServiceResponse(failure: .cancelled))
        }
    }

    /// One request's connection and its answer. The reply, the error
    /// handler and a cancel can all fire; the first one wins, and closes
    /// the connection.
    private final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ModelServiceResponse, Never>?
        private var connection: NSXPCConnection?
        private var answer: ModelServiceResponse?

        func start(_ data: Data, _ continuation: CheckedContinuation<ModelServiceResponse, Never>) {
            lock.lock()
            // Cancelled before it began: no connection, no helper.
            if let answer {
                lock.unlock()
                continuation.resume(returning: answer)
                return
            }
            let connection = NSXPCConnection(serviceName: ModelService.name)
            connection.remoteObjectInterface = NSXPCInterface(with: ModelServiceProtocol.self)
            self.continuation = continuation
            self.connection = connection
            // Resumed under the lock, so a cancel cannot close it first.
            connection.resume()
            lock.unlock()
            // Both handlers run on XPC's queue, not the main actor.
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] _ in
                self?.finish(ModelServiceResponse(failure: .failed("The model helper stopped before it answered.")))
            } as? ModelServiceProtocol
            guard let proxy else {
                finish(ModelServiceResponse(failure: .failed("The model helper is not available.")))
                return
            }
            proxy.perform(data) { @Sendable [weak self] reply in
                self?.finish((try? JSONDecoder().decode(ModelServiceResponse.self, from: reply))
                    ?? ModelServiceResponse(failure: .failed("The model helper's answer could not be read.")))
            }
        }

        func finish(_ response: ModelServiceResponse) {
            lock.lock()
            guard answer == nil else {
                lock.unlock()
                return
            }
            answer = response
            let continuation = continuation
            let connection = connection
            self.continuation = nil
            self.connection = nil
            lock.unlock()
            connection?.invalidate()
            continuation?.resume(returning: response)
        }
    }
}

/// Where the API key is kept. The Keychain in the app; a dictionary in
/// tests, which never touch the user's Keychain.
protocol ModelKeyStore: Sendable {
    /// The key saved for `account`, nil when there is none.
    func read(account: String) throws -> String?
    /// Saves `key` for `account`; an empty key removes it.
    func write(_ key: String, account: String) throws
}

/// The API key (ADR 0014): the app's to keep. It is a generic password in
/// the data-protection keychain, in the app's own access group, under the
/// endpoint it was entered for, so a key saved for one host is never read
/// for another. It stays on this device (not synchronised), is read only
/// when a request is made, and is never logged or written anywhere else.
/// The model helper is another program, shares no access group with the
/// app and calls no Keychain API at all.
///
/// The data-protection keychain needs the application identifier a
/// provisioned build is signed with. A build without one (an ad hoc Debug
/// build) is refused by the Keychain, and says so: the key is not kept
/// anywhere else instead.
struct KeychainModelKeyStore: ModelKeyStore {
    static let service = "com.lemehmet.boopstash.model-endpoint"

    struct Failure: Error, LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            if status == errSecMissingEntitlement {
                return "This build of BoopStash is not signed in a way that lets it use the Keychain, so it cannot keep an API key."
            }
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read(account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    func write(_ key: String, account: String) throws {
        let query = query(account)
        guard !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrLabel as String] = "BoopStash model endpoint"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}
