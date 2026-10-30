import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// Semantic search in the app (#157).
@MainActor
@Suite(.serialized)
struct SemanticSearchTests {
    /// The bundled model, as the app loads it: meaning, not words.
    @Test func theBundledModelRanksByMeaning() throws {
        let embedder = LiveEmbedder.shared
        #expect(embedder.isAvailable)
        let invoice = try #require(embedder.embed("invoice"))
        let bill = try #require(embedder.embed("bill for March"))
        let sql = try #require(embedder.embed("Weekly signups by region SELECT region"))
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(invoice.count == 384)
        #expect(abs(dot(invoice, invoice) - 1) < 0.01, "unit length")
        #expect(dot(invoice, bill) > NoteStore.similarityThreshold)
        #expect(dot(invoice, sql) < NoteStore.similarityThreshold)
    }

    /// A stand-in embedder: the axis a note's first word names.
    static let embed: Embedder = { text in
        let word = text.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() } ?? ""
        guard let axis = ["money", "invoice", "bill", "code"].firstIndex(of: word) else { return [] }
        // "money", "invoice" and "bill" mean the same here.
        return axis == 3 ? [0, 1] : [1, 0]
    }

    func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @Test func aSearchListsNotesCloseInMeaningAfterItsMatches() async throws {
        let model = AppModel(store: try .inMemory())
        model.embed = Self.embed
        model.semanticSearchEnabled = { true }
        let bill = Note(title: "bill for March", titleIsUserSet: true, body: "", createdAt: Date())
        let code = Note(title: "code review", titleIsUserSet: true, body: "", createdAt: Date())
        try model.store.save(bill)
        try model.store.save(code)
        // The pending-count observation starts the worker by itself.
        #expect(try await eventually { (try? model.store.notesAwaitingEmbedding().isEmpty) == true })
        model.query.text = "invoice"
        #expect(try await eventually { model.related.map(\.id) == [bill.id] })
        #expect(model.notes.isEmpty, "no note has the word")
        model.showSimilar(to: bill.id)
        #expect(model.query.text.isEmpty)
        #expect(try await eventually { model.related.isEmpty }, "nothing else is about money")
    }

    /// Turning the setting off clears what is shown; on again embeds the
    /// backlog without waiting for an edit.
    @Test func theSettingTakesEffectAtOnce() async throws {
        var enabled = false
        let model = AppModel(store: try .inMemory())
        model.embed = Self.embed
        model.semanticSearchEnabled = { enabled }
        model.semanticSearchChanged()
        try model.store.save(Note(title: "bill for March", titleIsUserSet: true, body: "", createdAt: Date()))
        try await Task.sleep(for: .milliseconds(300))
        #expect(try model.store.notesAwaitingEmbedding().count == 1, "off: nothing embedded")
        enabled = true
        model.semanticSearchChanged()
        #expect(try await eventually { (try? model.store.notesAwaitingEmbedding().isEmpty) == true })
        model.query.text = "invoice"
        #expect(try await eventually { !model.related.isEmpty })
        enabled = false
        model.semanticSearchChanged()
        #expect(model.related.isEmpty)
    }
}
