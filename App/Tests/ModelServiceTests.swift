import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// The real model helper (ADR 0014), reached the way the app reaches it.
/// Nothing here leaves this Mac: one request is refused by the helper's
/// own rule before any connection, and the other goes to a closed port on
/// the loopback address. What the helper sends and how it reads an answer
/// is tested in Core, where a stub can answer it.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ModelServiceTests {
    @Test func theHelperRefusesWhatTheRulesRefuseWithoutConnecting() async {
        let request = ModelServiceRequest(call: .chat, baseURL: "http://models.example", apiKey: nil, body: Data("{}".utf8), timeLimit: 5)
        let response = await LiveModelService.send(request)
        #expect(response == ModelServiceResponse(failure: .refused(ModelEndpointAddress.Problem.plainHTTP(host: "models.example").message)))
    }

    @Test func aClosedPortOnThisMacIsUnreachable() async {
        let request = ModelServiceRequest(call: .models, baseURL: "http://127.0.0.1:1", apiKey: nil, body: nil, timeLimit: 5)
        let response = await LiveModelService.send(request)
        guard case .unreachable = response.failure else {
            Issue.record("expected unreachable, got \(String(describing: response.failure)) with status \(String(describing: response.status))")
            return
        }
    }

    @Test func aRequestCancelledBeforeItStartsNeverReachesTheHelper() async {
        let task = Task { () -> ModelServiceResponse in
            // Cancelled already when the request is made.
            while !Task.isCancelled { await Task.yield() }
            return await LiveModelService.send(ModelServiceRequest(call: .models, baseURL: "http://127.0.0.1:1", apiKey: nil, body: nil, timeLimit: 5))
        }
        task.cancel()
        #expect(await task.value == ModelServiceResponse(failure: .cancelled))
    }
}
