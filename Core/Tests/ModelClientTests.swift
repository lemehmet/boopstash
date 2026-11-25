import Foundation
import Testing
@testable import BoopstashCore

/// The model helper's client (ADR 0014), the one piece of BoopStash that
/// makes a network request, with its requests answered here by a
/// `URLProtocol` stub: nothing in these tests leaves the process. Each
/// test has an address of its own under `stub.invalid`, which resolves
/// nowhere.
@Suite(.timeLimit(.minutes(1)))
struct ModelClientTests {
    /// What the stub does with a request for a test's path.
    enum Behavior: Sendable {
        case respond(status: Int, headers: [String: String] = [:], body: Data)
        /// The body in pieces, as a large reply arrives.
        case stream(status: Int, chunk: Data, count: Int)
        case fail(code: Int)
        case redirect(to: String)
        /// Never answers.
        case hang
        /// Answers, then sends a little more every so often, for ever.
        case trickle
    }

    /// Answers the client's requests from a table, and keeps what it saw.
    final class Stub: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var behaviors: [String: Behavior] = [:]
        nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]
        nonisolated(unsafe) private static var bodies: [String: [Data]] = [:]

        static func set(_ behavior: Behavior, for test: String) {
            lock.withLock { behaviors[test] = behavior }
        }

        static func requests(for test: String) -> [URLRequest] {
            lock.withLock { seen[test] ?? [] }
        }

        static func bodies(for test: String) -> [Data] {
            lock.withLock { bodies[test] ?? [] }
        }

        /// A request's test: the first label of its host.
        private static func test(of request: URLRequest) -> String {
            request.url?.host?.split(separator: ".").first.map(String.init) ?? ""
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let test = Self.test(of: request)
            // A data task hands its body over as a stream.
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    body.append(buffer, count: read)
                }
                stream.close()
            }
            let behavior = Self.lock.withLock { () -> Behavior? in
                Self.seen[test, default: []].append(request)
                Self.bodies[test, default: []].append(body)
                return Self.behaviors[test]
            }
            guard let behavior, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
                return
            }
            switch behavior {
            case .respond(let status, let headers, let body):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            case .stream(let status, let chunk, let count):
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for _ in 0..<count { client?.urlProtocol(self, didLoad: chunk) }
                client?.urlProtocolDidFinishLoading(self)
            case .fail(let code):
                client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code))
            case .redirect(let target):
                let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
                var next = request
                next.url = URL(string: target)
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            case .hang:
                break
            case .trickle:
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                drip()
            }
        }

        private let stopped = NSLock()
        private var isStopped = false

        private func drip() {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                guard let self, !self.stopped.withLock({ self.isStopped }) else { return }
                self.client?.urlProtocol(self, didLoad: Data("x".utf8))
                self.drip()
            }
        }

        override func stopLoading() {
            stopped.withLock { isStopped = true }
        }
    }

    /// One request through a client whose session only the stub answers.
    func perform(_ request: ModelServiceRequest, maxReplyBytes: Int = ModelServiceRequest.maxReplyBytes,
                 cancelAfter: Duration? = nil) async -> ModelServiceResponse {
        let client = ModelClient(maxReplyBytes: maxReplyBytes) { $0.protocolClasses = [Stub.self] }
        if let cancelAfter {
            Task {
                try? await Task.sleep(for: cancelAfter)
                client.cancel()
            }
        }
        return await withCheckedContinuation { continuation in
            client.perform(request) { continuation.resume(returning: $0) }
        }
    }

    /// A base URL no other test uses. `.invalid` never resolves. HTTPS,
    /// as plain HTTP is refused for a host that is not local.
    func base(_ test: String) -> String { "https://\(test).stub.invalid" }

    func chat(_ test: String, key: String? = "sk-test-1", body: String = #"{"model":"m"}"#, timeLimit: Double = 30) -> ModelServiceRequest {
        ModelServiceRequest(call: .chat, baseURL: base(test), apiKey: key, body: Data(body.utf8), timeLimit: timeLimit)
    }

    @Test func aChatRequestIsPostedAsItWasHandedOver() async throws {
        let test = "posted"
        Stub.set(.respond(status: 200, body: Data(#"{"choices":[]}"#.utf8)), for: test)
        let response = await perform(chat(test, body: #"{"model":"m","messages":[]}"#))
        #expect(response == ModelServiceResponse(status: 200, body: Data(#"{"choices":[]}"#.utf8)))
        let seen = Stub.requests(for: test)
        #expect(seen.count == 1)
        let request = try #require(seen.first)
        #expect(request.url?.absoluteString == "https://posted.stub.invalid/v1/chat/completions" && request.httpMethod == "POST")
        #expect(Stub.bodies(for: test) == [Data(#"{"model":"m","messages":[]}"#.utf8)], "the body the app made, byte for byte")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-1")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "BoopStash", "no version, no system")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let sent = Set((request.allHTTPHeaderFields ?? [:]).keys)
        #expect(sent.isSubset(of: ["Content-Type", "Accept", "User-Agent", "Accept-Language", "Authorization", "Content-Length", "Accept-Encoding"]),
                "\(sent)")
    }

    @Test func theModelListIsAGetWithTheKey() async throws {
        let test = "listed"
        Stub.set(.respond(status: 200, body: Data(#"{"data":[{"id":"a"}]}"#.utf8)), for: test)
        let response = await perform(ModelServiceRequest(call: .models, baseURL: base(test), apiKey: "sk-test-1", body: nil, timeLimit: 15))
        #expect(ModelList.parse(response.body) == ["a"] && response.status == 200)
        let request = try #require(Stub.requests(for: test).first)
        #expect(request.url?.path == "/v1/models" && request.httpMethod == "GET")
        #expect(Stub.bodies(for: test) == [Data()], "the key and nothing else")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-1")
    }

    @Test func anHTTPErrorComesBackWithItsStatusAndBody() async {
        let test = "refused"
        Stub.set(.respond(status: 400, body: Data(#"{"error":{"message":"unknown field"}}"#.utf8)), for: test)
        let response = await perform(chat(test))
        #expect(response.status == 400 && response.failure == nil)
        #expect(ModelChat.outcome(of: response, host: "h", timeLimit: 30) == .failure(.failed("h answered with an error (HTTP 400): unknown field")))
    }

    @Test func aHungConnectionEndsAtTheTimeLimit() async {
        let test = "hung"
        Stub.set(.hang, for: test)
        let started = ContinuousClock.now
        // Five seconds is the shortest limit a request may have.
        let response = await perform(chat(test, timeLimit: 1))
        #expect(response == ModelServiceResponse(failure: .timedOut))
        let took = ContinuousClock.now - started
        #expect(took >= .seconds(4) && took < .seconds(30), "\(took)")
    }

    @Test func aReplyThatKeepsTricklingStillEndsAtTheTimeLimit() async {
        // Bytes keep arriving, so no idle timeout would ever fire: the
        // limit is for the whole request.
        let test = "trickling"
        Stub.set(.trickle, for: test)
        let started = ContinuousClock.now
        let response = await perform(chat(test, timeLimit: 5))
        #expect(response == ModelServiceResponse(failure: .timedOut))
        let took = ContinuousClock.now - started
        #expect(took >= .seconds(4) && took < .seconds(20), "\(took)")
    }

    @Test func cancellingStopsARequestInFlight() async {
        let test = "cancelled"
        Stub.set(.hang, for: test)
        let started = ContinuousClock.now
        let response = await perform(chat(test, timeLimit: 600), cancelAfter: .milliseconds(200))
        #expect(response == ModelServiceResponse(failure: .cancelled))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aHugeReplyIsDroppedNotRead() async {
        let streamed = "huge"
        Stub.set(.stream(status: 200, chunk: Data(repeating: 0x61, count: 1_024), count: 64), for: streamed)
        #expect(await perform(chat(streamed), maxReplyBytes: 8_192) == ModelServiceResponse(failure: .tooLarge))
        // One that says its size up front is refused before its body.
        let declared = "declared"
        Stub.set(.respond(status: 200, headers: ["Content-Length": "999999"], body: Data(repeating: 0x61, count: 16)), for: declared)
        #expect(await perform(chat(declared), maxReplyBytes: 8_192) == ModelServiceResponse(failure: .tooLarge))
        // At the limit is fine.
        let fits = "fits"
        Stub.set(.stream(status: 200, chunk: Data(repeating: 0x61, count: 1_024), count: 8), for: fits)
        #expect(await perform(chat(fits), maxReplyBytes: 8_192).body.count == 8_192)
    }

    @Test func aCertificateThatIsNotTrustedFailsTheRequest() async {
        // The stub stands in for the system's refusal of the certificate;
        // the client has no code that could accept one the system refuses.
        for (test, code) in [("untrusted", NSURLErrorServerCertificateUntrusted), ("unknownroot", NSURLErrorServerCertificateHasUnknownRoot)] {
            Stub.set(.fail(code: code), for: test)
            guard case .certificate = await perform(chat(test)).failure else {
                Issue.record("\(test): a certificate failure")
                continue
            }
        }
    }

    @Test func aHostThatCannotBeReachedSaysSo() async {
        let test = "down"
        Stub.set(.fail(code: NSURLErrorCannotConnectToHost), for: test)
        guard case .unreachable = await perform(chat(test)).failure else {
            Issue.record("unreachable")
            return
        }
    }

    @Test func aRedirectIsNotFollowed() async {
        let test = "redirecting"
        Stub.set(.redirect(to: "https://elsewhere.stub.invalid/v1/chat/completions"), for: test)
        Stub.set(.respond(status: 200, body: Data("{}".utf8)), for: "elsewhere")
        let response = await perform(chat(test))
        #expect(response == ModelServiceResponse(failure: .redirected))
        #expect(Stub.requests(for: "elsewhere").isEmpty, "the text and the key went to the host the user typed and no other")
        #expect(Stub.requests(for: test).count == 1)
    }

    @Test func aRequestTheRulesRefuseIsNeverMade() async {
        let test = "plain"
        Stub.set(.respond(status: 200, body: Data("{}".utf8)), for: test)
        let plain = ModelServiceRequest(call: .chat, baseURL: "http://\(test).stub.invalid", apiKey: "sk-test-1", body: Data("{}".utf8), timeLimit: 30)
        guard case .refused(let reason) = await perform(plain).failure else {
            Issue.record("plain HTTP to a host that is not local is refused")
            return
        }
        #expect(reason.contains("https://"))
        #expect(Stub.requests(for: test).isEmpty)
    }

    @Test func aClientMakesOneRequest() async {
        let test = "once"
        Stub.set(.respond(status: 200, body: Data("{}".utf8)), for: test)
        let client = ModelClient { $0.protocolClasses = [Stub.self] }
        let first = await withCheckedContinuation { continuation in
            client.perform(chat(test)) { continuation.resume(returning: $0) }
        }
        #expect(first.status == 200)
        Stub.set(.hang, for: "twice")
        let hanging = ModelClient { $0.protocolClasses = [Stub.self] }
        async let held: ModelServiceResponse = withCheckedContinuation { continuation in
            hanging.perform(chat("twice", timeLimit: 600)) { continuation.resume(returning: $0) }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let second = await withCheckedContinuation { continuation in
            hanging.perform(chat("twice")) { continuation.resume(returning: $0) }
        }
        #expect(second == ModelServiceResponse(failure: .refused("A model client makes one request.")))
        hanging.cancel()
        #expect(await held == ModelServiceResponse(failure: .cancelled))
    }
}
