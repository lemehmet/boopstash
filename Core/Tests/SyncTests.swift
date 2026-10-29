import Foundation
import GRDB
import Testing
@testable import BoopstashCore

@Suite struct SyncTests {
    let store: NoteStore
    let fields = Data("system-fields".utf8)

    init() throws {
        store = try .inMemory()
    }

    func pendingNames() throws -> [String] {
        try store.pendingSyncChanges().map { change in
            switch change {
            case .save(let record, _, _): "save \(record.kind.rawValue) \(record.name)"
            case .delete(let kind, let name, _): "delete \(kind.rawValue) \(name)"
            }
        }
    }

    func version(of name: String) throws -> Int? {
        try store.pendingSyncChanges().compactMap { change -> Int? in
            if case .save(let record, _, let version) = change, record.name == name { return version }
            return nil
        }.first
    }

    func note(_ body: String, title: String = "t", at seconds: TimeInterval = 0) -> Note {
        Note(title: title, body: body, createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000 + seconds))
    }

    // MARK: Mapping

    @Test func everyFieldTravelsEncryptedAndRoundTrips() throws {
        var original = note("body")
        original.sourceAppName = "Terminal"
        original.syntaxOverride = "json"
        original.modelTitledHash = "abc"
        let record = SyncMapping.record(for: original)
        #expect(record.parent == nil && record.assetFile == nil)
        #expect(Set(record.encrypted.keys) == ["title", "titleIsUserSet", "body", "createdAt", "updatedAt", "sourceAppName", "modelTitledHash", "syntaxOverride"])
        #expect(SyncMapping.note(from: record) == original)
        #expect(SyncMapping.note(from: SyncRecord(kind: .note, name: "not-a-uuid", encrypted: record.encrypted)) == nil)
    }

    @Test func attachmentsCarryTheirNoteAndFile() throws {
        let owner = UUID()
        let attachment = NoteAttachment(noteID: owner, contentType: "public.png", byteSize: 3, recognizedText: "hi")
        let record = SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/tmp/x.png"))
        #expect(record.parent == owner.uuidString.lowercased())
        #expect(SyncMapping.attachment(from: record) == attachment)
    }

    // MARK: Local changes

    @Test func aNewNoteIsPendingUntilAcknowledged() throws {
        let new = note("hello")
        try store.save(new)
        let name = new.id.uuidString.lowercased()
        #expect(try pendingNames() == ["save Note \(name)"])
        try store.acknowledgeSave(kind: .note, name: name, version: try #require(try version(of: name)), systemFields: fields)
        #expect(try pendingNames().isEmpty)
    }

    /// An edit made while the previous version was on its way stays
    /// pending after that version is acknowledged.
    @Test func anEditDuringUploadStaysPending() throws {
        var edited = note("one")
        try store.save(edited)
        let name = edited.id.uuidString.lowercased()
        let sent = try #require(try version(of: name))
        edited.body = "two"
        try store.save(edited)
        try store.acknowledgeSave(kind: .note, name: name, version: sent, systemFields: fields)
        #expect(try pendingNames() == ["save Note \(name)"])
    }

    @Test func deletingASyncedNoteLeavesATombstoneAnUnsyncedOneDoesNot() throws {
        let synced = note("a")
        let local = note("b")
        try store.save(synced)
        try store.save(local)
        let name = synced.id.uuidString.lowercased()
        try store.acknowledgeSave(kind: .note, name: name, version: try #require(try version(of: name)), systemFields: fields)
        try store.delete(id: synced.id)
        try store.delete(id: local.id)
        #expect(try pendingNames() == ["delete Note \(name)"])
        try store.acknowledgeDelete(kind: .note, name: name)
        #expect(try pendingNames().isEmpty)
    }

    // MARK: Server changes

    @Test func aServerNoteIsAppliedWithoutBecomingALocalChange() throws {
        let remote = note("from the other Mac")
        try store.applyServerRecord(SyncMapping.record(for: remote), systemFields: fields)
        #expect(try store.note(id: remote.id) == remote)
        #expect(try pendingNames().isEmpty)
    }

    @Test func replayingAnAppliedChangeChangesNothing() throws {
        let remote = note("same")
        let record = SyncMapping.record(for: remote)
        try store.applyServerRecord(record, systemFields: fields)
        #expect(try store.applyServerRecord(record, systemFields: fields) == nil)
        #expect(try store.notes(matching: NoteQuery()).count == 1)
        #expect(try pendingNames().isEmpty)
    }

    /// Both sides changed the body: the server's wins, this device's is
    /// kept as a conflict copy, and nothing is lost.
    @Test func aBodyChangedOnBothSidesKeepsBoth() throws {
        let base = note("base", title: "Plan")
        try store.applyServerRecord(SyncMapping.record(for: base), systemFields: fields)
        var mine = base
        mine.body = "my edit"
        mine.updatedAt = base.updatedAt.addingTimeInterval(10)
        try store.save(mine)
        var theirs = base
        theirs.body = "their edit"
        theirs.updatedAt = base.updatedAt.addingTimeInterval(5)

        let copy = try #require(try store.applyServerRecord(SyncMapping.record(for: theirs), systemFields: fields))
        #expect(try store.note(id: base.id)?.body == "their edit")
        #expect(copy.body == "my edit" && copy.title == "Plan (conflict)" && copy.titleIsUserSet)
        #expect(try store.note(id: copy.id) == copy)
        #expect(try pendingNames().contains("save Note \(copy.id.uuidString.lowercased())"), "the copy is sent too")
    }

    @Test func aUserTitleBeatsAGeneratedOne() {
        var local = note("same", title: "My name")
        local.titleIsUserSet = true
        let server = note("same", title: "Generated", at: 50)
        let outcome = SyncMerge.merge(local: local, server: server)
        #expect(outcome.note.title == "My name" && outcome.note.titleIsUserSet)
        #expect(outcome.conflictCopy == nil)
        #expect(outcome.stillPending, "the server still has the generated title")
        var serverNamed = server
        serverNamed.titleIsUserSet = true
        let generatedLocal = note("same", title: "Generated here", at: 99)
        #expect(SyncMerge.merge(local: generatedLocal, server: serverNamed).note.title == "Generated")
    }

    @Test func betweenTwoUserTitlesTheNewerWins() {
        var local = note("x", title: "Local", at: 30)
        local.titleIsUserSet = true
        var server = note("x", title: "Server", at: 20)
        server.titleIsUserSet = true
        #expect(SyncMerge.merge(local: local, server: server).note.title == "Local")
        server.updatedAt = Date(timeIntervalSince1970: 2_000)
        #expect(SyncMerge.merge(local: local, server: server).note.title == "Server")
    }

    @Test func aServerDeletionLeavesNoTombstone() throws {
        let remote = note("gone soon")
        try store.applyServerRecord(SyncMapping.record(for: remote), systemFields: fields)
        try store.applyServerDeletion(kind: .note, name: remote.id.uuidString.lowercased())
        #expect(try store.note(id: remote.id) == nil)
        #expect(try pendingNames().isEmpty)
    }

    @Test func aServerAttachmentArrivesWithItsFile() throws {
        let attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 3)
        let record = SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused"))
        try store.applyServerRecord(record, systemFields: fields, assetData: Data([1, 2, 3]))
        let stored = try #require(try store.attachment(id: attachment.id))
        #expect(try store.data(for: stored) == Data([1, 2, 3]))
        #expect(try pendingNames().isEmpty)
    }

    @Test func aKeychainResetSendsEverythingAgain() throws {
        let remote = note("synced")
        try store.applyServerRecord(SyncMapping.record(for: remote), systemFields: fields)
        try store.setSyncEngineState(Data([9]))
        try store.resetSyncForReupload()
        #expect(try pendingNames() == ["save Note \(remote.id.uuidString.lowercased())"])
        #expect(try store.syncEngineState() == nil)
        guard case .save(_, let systemFields, _) = try store.pendingSyncChanges().first else { return }
        #expect(systemFields == nil, "sent as a new record")
    }

    @Test func existingNotesAreSentOnceAfterTheMigration() throws {
        let queue = try DatabaseQueue(configuration: NoteStore.configuration)
        try NoteStore.migrator.migrate(queue, upTo: "v4-attachments")
        let old = note("from before sync")
        try queue.write { db in try old.insert(db) }
        let migrated = try NoteStore(queue, attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(try migrated.pendingSyncChanges().count == 1)
    }

    @Test func theEngineStateIsKept() throws {
        #expect(try store.syncEngineState() == nil)
        try store.setSyncEngineState(Data([1, 2]))
        #expect(try store.syncEngineState() == Data([1, 2]))
    }
}
