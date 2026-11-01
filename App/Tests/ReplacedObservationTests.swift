import BoopstashCore
import Foundation
import Synchronization
import Testing
@testable import Boopstash

/// A replaced observation never overwrites the one that replaced it
/// (#200, #221). The race needs a value the old observation has already
/// received when it is cancelled; a hand-fed sequence whose `next()`
/// ignores cancellation, as a value already on its way does, makes that
/// happen every time instead of once in fifty runs.
@MainActor
@Suite struct ReplacedObservationTests {
    @Test func aReplacedNoteListDoesNotOverwriteTheNewOne() async throws {
        let model = AppModel(store: try NoteStore.inMemory())
        model.semanticSearchEnabled = { false }
        var gates: [Gate<[Note]>] = []
        model.noteResults = { _ in
            let gate = Gate<[Note]>()
            gates.append(gate)
            return gate
        }
        model.query.text = "first"
        let old = try #require(gates.last)
        #expect(try await eventually { old.requests == 1 })
        model.query.text = "second"
        let new = try #require(gates.last)
        #expect(new !== old)
        #expect(try await eventually { new.requests == 1 })

        let fresh = [Note(title: "fresh", body: "fresh", createdAt: .now)]
        new.deliver(fresh)
        #expect(try await eventually { model.notes == fresh })
        old.deliver([Note(title: "stale", body: "stale", createdAt: .now)])
        // Asking for another value means the old loop handled this one;
        // ending means it stopped without doing so.
        #expect(try await eventually { old.requests == 2 || old.ended })
        #expect(model.notes == fresh)
        for gate in gates { gate.finish() }
    }

    @Test func aReplacedLabelCatalogDoesNotOverwriteTheNewOne() async throws {
        let model = AppModel(store: try NoteStore.inMemory())
        var gates: [Gate<LabelCatalog>] = []
        model.labelCatalogResults = {
            let gate = Gate<LabelCatalog>()
            gates.append(gate)
            return gate
        }
        model.observeLabels()
        let old = try #require(gates.last)
        #expect(try await eventually { old.requests == 1 })
        model.observeLabels()
        let new = try #require(gates.last)
        #expect(try await eventually { new.requests == 1 })

        let fresh = LabelCatalog(labels: [NoteLabel(name: "fresh", color: "#0e8a16", createdAt: .now)])
        new.deliver(fresh)
        #expect(try await eventually { model.labelCatalog == fresh })
        old.deliver(LabelCatalog(labels: [NoteLabel(name: "stale", color: "#d73a4a", createdAt: .now)]))
        #expect(try await eventually { old.requests == 2 || old.ended })
        #expect(model.labelCatalog == fresh)
        for gate in gates { gate.finish() }
    }
}

/// Values the test hands over one at a time. `next()` waits for the next
/// `deliver` and is not ended by cancelling the task reading it.
final class Gate<Element: Sendable>: AsyncSequence, Sendable {
    typealias Failure = any Error

    private struct State {
        var waiting: CheckedContinuation<Element?, Never>?
        var requests = 0
        var ended = false
    }
    private let state = Mutex(State())

    /// How many times a reader has asked for a value.
    var requests: Int { state.withLock { $0.requests } }
    /// Whether the reader has let go of its iterator.
    var ended: Bool { state.withLock { $0.ended } }

    func deliver(_ value: Element) {
        state.withLock { state in
            state.waiting?.resume(returning: value)
            state.waiting = nil
        }
    }

    /// Ends the sequence for a reader still waiting, so none is left
    /// suspended after the test.
    func finish() {
        state.withLock { state in
            state.waiting?.resume(returning: nil)
            state.waiting = nil
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator(gate: self, reader: Reader(gate: self)) }

    struct Iterator: AsyncIteratorProtocol {
        let gate: Gate
        let reader: Reader

        func next() async throws -> Element? {
            await withCheckedContinuation { continuation in
                gate.state.withLock { state in
                    state.requests += 1
                    state.waiting = continuation
                }
            }
        }
    }

    /// Held by the iterator only, so its end is the reader's.
    final class Reader: Sendable {
        let gate: Gate
        init(gate: Gate) { self.gate = gate }
        deinit { gate.state.withLock { $0.ended = true } }
    }
}
