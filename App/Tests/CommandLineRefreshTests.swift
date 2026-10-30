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
}
