import BoopstashCore
import Foundation

/// Makes one request to the model endpoint the user configured (ADR 0014).
/// This file and `main.swift` beside it are the only code in BoopStash
/// that reaches the network, and they are compiled into the model helper
/// alone: the app, which holds the notes, has no network entitlement.
///
/// What is sent is what `ModelServiceRequest.urlRequest()` builds from
/// what the app handed over, and nothing else: no cookies, no cache, no
/// stored credentials, and no redirect is followed, so the text and the
/// key go to the host the user typed and to no other. Certificates are
/// judged by the system; nothing here overrides that. One client makes
/// one request and keeps nothing afterwards.
final class ModelClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var received = Data()
    private var status: Int?
    private var failure: ModelServiceResponse.Failure?
    private var completion: (@Sendable (ModelServiceResponse) -> Void)?
    private let maxReplyBytes: Int
    private let configure: @Sendable (URLSessionConfiguration) -> Void

    /// - Parameters:
    ///   - maxReplyBytes: the largest reply read.
    ///   - configure: for tests, to answer requests without a network.
    init(maxReplyBytes: Int = ModelServiceRequest.maxReplyBytes,
         configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in }) {
        self.maxReplyBytes = maxReplyBytes
        self.configure = configure
    }

    /// Makes `request` and calls `completion` once, on any queue.
    func perform(_ request: ModelServiceRequest, completion: @escaping @Sendable (ModelServiceResponse) -> Void) {
        let urlRequest: URLRequest
        switch request.urlRequest() {
        case .success(let made): urlRequest = made
        case .failure(let failure):
            completion(ModelServiceResponse(failure: failure))
            return
        }
        let limit = ModelServiceRequest.limit(request.timeLimit)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = limit
        configuration.timeoutIntervalForResource = limit
        configure(configuration)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        lock.lock()
        guard self.completion == nil, self.session == nil else {
            lock.unlock()
            session.invalidateAndCancel()
            completion(ModelServiceResponse(failure: .refused("A model client makes one request.")))
            return
        }
        self.completion = completion
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    /// Stops the request; its completion answers `.cancelled`.
    func cancel() {
        stop(with: .cancelled)
    }

    private func stop(with failure: ModelServiceResponse.Failure) {
        lock.lock()
        if self.failure == nil { self.failure = failure }
        let task = task
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSession

    /// A redirect is not followed: it could carry the text and the key to
    /// a host the user did not type.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        stop(with: .redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        status = (response as? HTTPURLResponse)?.statusCode
        lock.unlock()
        if response.expectedContentLength > Int64(maxReplyBytes) {
            completionHandler(.cancel)
            stop(with: .tooLarge)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received.append(data)
        let tooLarge = received.count > maxReplyBytes
        if tooLarge { received = Data() }
        lock.unlock()
        if tooLarge { stop(with: .tooLarge) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let completion = completion
        self.completion = nil
        let response: ModelServiceResponse
        if let failure {
            response = ModelServiceResponse(failure: failure)
        } else if let error = error as NSError? {
            response = ModelServiceResponse(failure: .init(urlErrorCode: error.code, description: error.localizedDescription))
        } else if let status {
            response = ModelServiceResponse(status: status, body: received)
        } else {
            response = ModelServiceResponse(failure: .failed("The answer was not an HTTP response."))
        }
        received = Data()
        self.task = nil
        self.session = nil
        lock.unlock()
        // Also lets go of this delegate, which the session holds.
        session.finishTasksAndInvalidate()
        completion?(response)
    }
}
