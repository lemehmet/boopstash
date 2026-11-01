import Foundation

/// Waits until `condition` holds, checking every few milliseconds, and
/// returns whether it did (#200). The flow tests wait for an observation or
/// a background task to deliver; the deadline is long so that only a real
/// failure trips it on a busy CI runner, and a passing test returns as soon
/// as the condition holds.
@MainActor
func eventually(within limit: Duration = .seconds(10), _ condition: () throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try condition()
}
