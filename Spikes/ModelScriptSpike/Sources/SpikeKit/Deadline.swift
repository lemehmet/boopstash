import Foundation

/// The work ran past its limit.
public struct DeadlineExceeded: Error, Equatable, Sendable {
    public init() {}
}

/// A limit on how long a piece of work may take in all. A URL request's
/// own timeout is an idle one: it starts again with every byte, so a
/// server that keeps sending can hold a request open for as long as it
/// likes. This counts from the start.
public enum Deadline {
    private enum Finish<T: Sendable>: Sendable {
        case value(T)
        case limit
    }

    /// The work's value, or `DeadlineExceeded` when `seconds` pass first.
    /// The work is cancelled at the limit and must end when cancelled, as
    /// `URLSession`'s async calls and `Task.sleep` do. `sleep` is the
    /// clock, for tests.
    public static func run<T: Sendable>(
        seconds: Double,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: Finish<T>.self) { group in
            group.addTask { .value(try await work()) }
            group.addTask {
                try await sleep(seconds)
                return .limit
            }
            defer { group.cancelAll() }
            guard case .value(let value)? = try await group.next() else { throw DeadlineExceeded() }
            return value
        }
    }

    /// One request and its whole reply within `seconds`, whatever the
    /// request's idle timeout is.
    public static func data(for request: URLRequest, session: URLSession = .shared,
                            within seconds: Double) async throws -> (Data, URLResponse) {
        try await run(seconds: seconds) { try await session.data(for: request) }
    }
}
