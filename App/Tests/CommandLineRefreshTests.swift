import BoopstashCore
import Foundation
import notify
import Testing
@testable import Boopstash

/// The app sees what the `boopstash` command writes (#156, ADR 0009).
@MainActor
@Suite(.serialized)
struct CommandLineRefreshTests {
    @Test func aWriteFromAnotherStoreShowsAfterTheNotification() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boopstash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.sqlite")
        let model = AppModel(store: try NoteStore.open(at: url, shared: true))
        model.watchOtherProcesses()
        // The model's first fetch is asynchronous: let it finish, or it can
        // read the write below and pass without the notification.
        try await Task.sleep(for: .milliseconds(300))
        // Another pool on the same file stands in for the other process:
        // GRDB's observation does not see its commits either.
        let other = try NoteStore.open(at: url, shared: true)
        let output = CommandLineTool.run(.capture(title: "from the shell"), store: other, input: { Data("hello\n".utf8) }, version: "1")
        #expect(output.wrote)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.notes.isEmpty, "not seen without the notification")
        notify_post(SharedStore.changedNotification)
        for _ in 0..<100 where model.notes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.notes.map(\.title) == ["from the shell"])
    }

    /// The command's notes are embedded for semantic search too: the
    /// pending count is observed in this process only.
    @Test func commandNotesAreEmbedded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boopstash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.sqlite")
        let model = AppModel(store: try NoteStore.open(at: url, shared: true))
        model.semanticSearchEnabled = { true }
        model.embed = { _ in [1, 0] }
        model.watchOtherProcesses()
        try await Task.sleep(for: .milliseconds(200))
        let other = try NoteStore.open(at: url, shared: true)
        _ = CommandLineTool.run(.capture(title: "t"), store: other, input: { Data("hello\n".utf8) }, version: "1")
        notify_post(SharedStore.changedNotification)
        for _ in 0..<150 where (try? model.store.notesAwaitingEmbedding().isEmpty) != true { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try model.store.notesAwaitingEmbedding().isEmpty)
    }

    /// A captured note without --title gets a model title once the app
    /// sees it (ADR 0009).
    @Test func commandNotesGetModelTitles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boopstash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.sqlite")
        let model = AppModel(store: try NoteStore.open(at: url, shared: true))
        model.modelTitlesEnabled = { true }
        model.modelTitlesAvailable = { true }
        model.modelTitler = { _, _ in "Pod listing" }
        model.watchOtherProcesses()
        let other = try NoteStore.open(at: url, shared: true)
        _ = CommandLineTool.run(.capture(title: nil), store: other, input: { Data("NAME READY\napi-1 1/1\n".utf8) }, version: "1")
        notify_post(SharedStore.changedNotification)
        for _ in 0..<150 where model.notes.first?.title != "Pod listing" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.notes.map(\.title) == ["Pod listing"])
    }
}
