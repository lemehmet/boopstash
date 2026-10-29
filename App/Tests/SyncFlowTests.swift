import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// How changes from iCloud meet edits in progress (#124).
@MainActor
@Suite(.serialized)
struct SyncFlowTests {
    let model: AppModel

    init() throws {
        model = AppModel(store: try .inMemory())
    }

    /// An edit still in its draft is saved before the server's version is
    /// applied, so the two merge: the server's text wins, this Mac's is
    /// kept as a conflict copy, and the open editor is told to reload.
    @Test func aRemoteChangeMergesWithAnUnsavedEdit() throws {
        var note = Note(title: "t", body: "original", createdAt: Date(), updatedAt: Date())
        try model.store.applyServerRecord(SyncMapping.record(for: note), systemFields: Data("f".utf8))
        model.updateBody(note.id, to: "typed here")
        note.body = "changed elsewhere"
        note.updatedAt = Date().addingTimeInterval(60)
        let server = SyncMapping.record(for: note)
        model.applyRemote {
            _ = try? self.model.store.applyServerRecord(server, systemFields: Data("g".utf8))
            return [note.id]
        }
        #expect(try model.store.note(id: note.id)?.body == "changed elsewhere")
        let bodies = try model.store.notes(matching: NoteQuery()).map(\.body)
        #expect(bodies.contains("typed here"), "kept as a conflict copy")
        #expect(model.remoteRevisions[note.id] == 1)
        #expect(model.note(id: note.id)?.body == "changed elsewhere", "what the editor reloads")
    }
}
