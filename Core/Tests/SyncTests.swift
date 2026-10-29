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

    @Test func deletingASyncedNoteLeavesATombstone() throws {
        let synced = note("a")
        try store.save(synced)
        let name = synced.id.uuidString.lowercased()
        try store.acknowledgeSave(kind: .note, name: name, version: try #require(try version(of: name)), systemFields: fields)
        try store.delete(id: synced.id)
        #expect(try pendingNames() == ["delete Note \(name)"])
        try store.acknowledgeDelete(kind: .note, name: name)
        #expect(try pendingNames().isEmpty)
    }

    /// Deleted while its first upload may be on its way: the server still
    /// hears of the deletion, so the note does not come back.
    @Test func aDeletionDuringTheFirstUploadIsStillSent() throws {
        let fresh = note("new")
        try store.save(fresh)
        let name = fresh.id.uuidString.lowercased()
        let sent = try #require(try version(of: name))
        try store.delete(id: fresh.id)
        try store.acknowledgeSave(kind: .note, name: name, version: sent, systemFields: fields)
        #expect(try pendingNames() == ["delete Note \(name)"])
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

    /// Another device deleted a note this one edited: the edit is kept and
    /// sent again as a new record.
    @Test func aServerDeletionKeepsUnsentEdits() throws {
        var mine = note("synced")
        try store.applyServerRecord(SyncMapping.record(for: mine), systemFields: fields)
        mine.body = "edited here"
        try store.save(mine)
        try store.applyServerDeletion(kind: .note, name: mine.id.uuidString.lowercased())
        #expect(try store.note(id: mine.id)?.body == "edited here")
        guard case .save(let record, let systemFields, _) = try store.pendingSyncChanges().first else {
            Issue.record("not pending")
            return
        }
        #expect(record.name == mine.id.uuidString.lowercased() && systemFields == nil, "sent as new")
    }

    /// Recovery from a server deletion survives the acknowledgement of the
    /// upload that was in flight: the edit still goes up as new.
    @Test func anAcknowledgementDoesNotUndoDeletionRecovery() throws {
        var mine = note("synced")
        try store.applyServerRecord(SyncMapping.record(for: mine), systemFields: fields)
        mine.body = "edited"
        try store.save(mine)
        let name = mine.id.uuidString.lowercased()
        let sent = try #require(try version(of: name))
        try store.applyServerDeletion(kind: .note, name: name)
        try store.acknowledgeSave(kind: .note, name: name, version: sent, systemFields: fields)
        guard case .save(_, let systemFields, _) = try store.pendingSyncChanges().first else {
            Issue.record("no longer pending")
            return
        }
        #expect(systemFields == nil, "still sent as new")
    }

    /// Deleted here while a stale save comes from the server: the deletion
    /// wins and the note does not come back.
    @Test func aTombstoneWinsOverAStaleServerSave() throws {
        let synced = note("x")
        try store.applyServerRecord(SyncMapping.record(for: synced), systemFields: fields)
        try store.delete(id: synced.id)
        try store.applyServerRecord(SyncMapping.record(for: synced), systemFields: fields)
        #expect(try store.note(id: synced.id) == nil)
        try store.acknowledgeDelete(kind: .note, name: synced.id.uuidString.lowercased())
        #expect(try store.note(id: synced.id) == nil)
    }

    /// A first upload edited while in flight keeps the metadata its
    /// acknowledgement brings, so the next upload updates the record
    /// instead of creating it again (#106).
    @Test func aFirstUploadEditedInFlightKeepsItsMetadata() throws {
        var mine = note("first")
        try store.save(mine)
        let name = mine.id.uuidString.lowercased()
        let sent = try #require(try version(of: name))
        mine.body = "edited in flight"
        try store.save(mine)
        try store.acknowledgeSave(kind: .note, name: name, version: sent, systemFields: fields)
        guard case .save(_, let systemFields, _) = try store.pendingSyncChanges().first else {
            Issue.record("no longer pending")
            return
        }
        #expect(systemFields == fields)
    }

    /// After recovery from a server deletion, the upload built afterwards
    /// is acknowledged normally, even when edited in flight.
    @Test func theUploadAfterRecoveryKeepsItsMetadata() throws {
        var mine = note("synced")
        try store.applyServerRecord(SyncMapping.record(for: mine), systemFields: fields)
        mine.body = "edited"
        try store.save(mine)
        let name = mine.id.uuidString.lowercased()
        try store.applyServerDeletion(kind: .note, name: name)
        let resent = try #require(try version(of: name))
        mine.body = "edited again"
        try store.save(mine)
        let newFields = Data("new-record".utf8)
        try store.acknowledgeSave(kind: .note, name: name, version: resent, systemFields: newFields)
        guard case .save(_, let systemFields, _) = try store.pendingSyncChanges().first else {
            Issue.record("no longer pending")
            return
        }
        #expect(systemFields == newFields)
    }

    /// A server version identical to this device's ends recovery's pending
    /// state; the next edit's acknowledgement still keeps its metadata.
    @Test func aMatchingServerVersionDoesNotStrandTheCutoff() throws {
        var mine = note("synced")
        try store.applyServerRecord(SyncMapping.record(for: mine), systemFields: fields)
        mine.body = "edited"
        try store.save(mine)
        let name = mine.id.uuidString.lowercased()
        try store.applyServerDeletion(kind: .note, name: name)
        // Another device uploads exactly this text.
        try store.applyServerRecord(SyncMapping.record(for: mine), systemFields: fields)
        #expect(try pendingNames().isEmpty)
        mine.body = "edited later"
        try store.save(mine)
        let next = try #require(try version(of: name))
        let newFields = Data("later".utf8)
        try store.acknowledgeSave(kind: .note, name: name, version: next, systemFields: newFields)
        #expect(try pendingNames().isEmpty)
        mine.body = "and again"
        try store.save(mine)
        guard case .save(_, let systemFields, _) = try store.pendingSyncChanges().first else {
            Issue.record("not pending")
            return
        }
        #expect(systemFields == newFields)
    }

    /// A late acknowledgement of an upload from before recovery never
    /// overwrites the metadata of the one after it.
    @Test func aLateStaleAcknowledgementIsIgnored() throws {
        var mine = note("synced")
        try store.applyServerRecord(SyncMapping.record(for: mine), systemFields: fields)
        mine.body = "edited"
        try store.save(mine)
        let name = mine.id.uuidString.lowercased()
        let stale = try #require(try version(of: name))
        try store.applyServerDeletion(kind: .note, name: name)
        let resent = try #require(try version(of: name))
        let newFields = Data("new-record".utf8)
        try store.acknowledgeSave(kind: .note, name: name, version: resent, systemFields: newFields)
        try store.acknowledgeSave(kind: .note, name: name, version: stale, systemFields: Data("old-record".utf8))
        mine.body = "edited again"
        try store.save(mine)
        guard case .save(_, let systemFields, _) = try store.pendingSyncChanges().first else {
            Issue.record("not pending")
            return
        }
        #expect(systemFields == newFields)
    }

    /// An attachment changed here keeps its own file when the server's
    /// arrives; one in step takes the server's.
    @Test func aServerFileReplacesOnlyAnAttachmentInStep() throws {
        let attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 1)
        let record = SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused"))
        try store.applyServerRecord(record, systemFields: fields, assetData: Data([1]))
        try store.setRecognizedText("local", for: attachment.id)
        try store.applyServerRecord(record, systemFields: fields, assetData: Data([2]))
        let changed = try #require(try store.attachment(id: attachment.id))
        #expect(try store.data(for: changed) == Data([1]))
        guard case .save(_, _, let version) = try store.pendingSyncChanges().first else { return }
        try store.acknowledgeSave(kind: .attachment, name: attachment.id.uuidString.lowercased(), version: version, systemFields: fields)
        try store.applyServerRecord(record, systemFields: fields, assetData: Data([3]))
        #expect(try store.data(for: changed) == Data([3]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.attachmentsDirectory.path).filter { $0.hasSuffix(".incoming") }
        #expect(leftovers.isEmpty)
    }

    /// Text recognised after an upload is a change to send, and text
    /// recognised during one is not cleared by its acknowledgement (#108).
    @Test func recognisedTextIsSent() throws {
        let attachment = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        let name = attachment.id.uuidString.lowercased()
        let sent = try #require(try version(of: name))
        try store.setRecognizedText("receipt", for: attachment.id)
        try store.acknowledgeSave(kind: .attachment, name: name, version: sent, systemFields: fields)
        #expect(try pendingNames() == ["save Attachment \(name)"])
        guard case .save(let record, _, let version) = try store.pendingSyncChanges().first else { return }
        #expect(record.encrypted["recognizedText"] == .string("receipt"))
        try store.acknowledgeSave(kind: .attachment, name: name, version: version, systemFields: fields)
        try store.setRecognizedText("receipt total", for: attachment.id)
        #expect(try pendingNames() == ["save Attachment \(name)"])
    }

    /// Notes from the server, conflict copies and attachment updates keep
    /// image-text search current (#109).
    @Test func serverWritesRefreshImageText() throws {
        var attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 1, recognizedText: "invoice")
        try store.applyServerRecord(SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused")), systemFields: fields, assetData: Data([1]))
        let remote = note("see " + AttachmentReference.markdown(for: attachment.id))
        try store.applyServerRecord(SyncMapping.record(for: remote), systemFields: fields)
        #expect(try store.imageText(of: remote.id) == "invoice")
        attachment.recognizedText = "invoice paid"
        try store.applyServerRecord(SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused")), systemFields: fields, assetData: Data([1]))
        #expect(try store.imageText(of: remote.id) == "invoice paid")
        // Both sides change the body: the copy keeps this device's text and
        // its image's words.
        var mine = remote
        mine.body = "mine " + AttachmentReference.markdown(for: attachment.id)
        try store.save(mine)
        var theirs = remote
        theirs.body = "theirs, no image"
        theirs.updatedAt = Date(timeIntervalSince1970: 5_000)
        let copy = try #require(try store.applyServerRecord(SyncMapping.record(for: theirs), systemFields: fields))
        #expect(try store.imageText(of: remote.id) == nil)
        #expect(try store.imageText(of: copy.id) == "invoice paid")
    }

    /// A synced attachment nothing here refers to is kept by the launch
    /// sweep until remote changes are in (#107).
    @Test func theSweepKeepsSyncedAttachmentsUntilAFetch() throws {
        let attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 1, createdAt: Date(timeIntervalSince1970: 0))
        try store.applyServerRecord(SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused")), systemFields: fields, assetData: Data([1]))
        #expect(try store.removeUnreferencedAttachments() == 0)
        #expect(try store.attachment(id: attachment.id) != nil)
        #expect(try store.removeUnreferencedAttachments(includingSynced: true) == 1)
        #expect(try store.attachment(id: attachment.id) == nil)
    }

    @Test func aNewAttachmentWithoutItsAssetWaits() throws {
        let attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 3)
        try store.applyServerRecord(SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused")), systemFields: fields)
        #expect(try store.attachment(id: attachment.id) == nil)
    }

    /// An attachment from iCloud whose note has not arrived yet is not
    /// swept as an orphan (and so not deleted on every device).
    @Test func theSweepWaitsForAnAttachmentsNote() throws {
        let attachment = NoteAttachment(noteID: UUID(), contentType: "public.png", byteSize: 3, createdAt: Date(timeIntervalSince1970: 0))
        try store.applyServerRecord(SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused")), systemFields: fields, assetData: Data([1, 2, 3]))
        #expect(try store.removeUnreferencedAttachments() == 0)
        #expect(try store.attachment(id: attachment.id) != nil)
    }

    @Test func deletingAnAttachmentDirectlyIsSent() throws {
        let attachment = try store.addAttachment(Data([1]), contentType: "public.png", noteID: nil)
        try store.deleteAttachment(id: attachment.id)
        #expect(try pendingNames() == ["delete Attachment \(attachment.id.uuidString.lowercased())"])
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

    @Test func aServerUpdateToAnAttachmentApplies() throws {
        var attachment = NoteAttachment(noteID: nil, contentType: "public.png", byteSize: 3)
        try store.applyServerRecord(SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused")), systemFields: fields, assetData: Data([1, 2, 3]))
        attachment.recognizedText = "read elsewhere"
        attachment.byteSize = 4
        try store.applyServerRecord(SyncMapping.record(for: attachment, file: URL(fileURLWithPath: "/unused")), systemFields: fields, assetData: Data([1, 2, 3, 4]))
        let stored = try #require(try store.attachment(id: attachment.id))
        #expect(stored.recognizedText == "read elsewhere" && stored.byteSize == 4)
        #expect(try store.data(for: stored) == Data([1, 2, 3, 4]))
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

    /// The adapter learns every name waiting to be sent, and again when
    /// that changes.
    @Test func pendingNamesAreStreamed() async throws {
        var iterator = store.pendingSyncNames().makeAsyncIterator()
        #expect(try await iterator.next() == SyncPending())
        let mine = note("new")
        try store.save(mine)
        let name = mine.id.uuidString.lowercased()
        #expect(try await iterator.next()?.saves == [SyncPending.Name(kind: .note, name: name)])
        try store.delete(id: mine.id)
        #expect(try await iterator.next() == SyncPending(saves: [], deletes: [SyncPending.Name(kind: .note, name: name)]))
    }

    /// One record is built when the engine asks for it, and not once it
    /// has nothing to send.
    @Test func aPendingSaveIsBuiltOnDemand() throws {
        let mine = note("new")
        try store.save(mine)
        let name = mine.id.uuidString.lowercased()
        guard case .save(let record, nil, let version)? = try store.pendingSave(kind: .note, name: name) else {
            Issue.record("not built")
            return
        }
        #expect(record == SyncMapping.record(for: mine))
        try store.acknowledgeSave(kind: .note, name: name, version: version, systemFields: fields)
        #expect(try store.pendingSave(kind: .note, name: name) == nil)
        #expect(try store.pendingSave(kind: .attachment, name: name) == nil)
    }

    /// A store synced with one iCloud environment starts over in another:
    /// everything goes up again as new, and the engine state goes.
    @Test func anotherEnvironmentStartsOver() throws {
        #expect(try store.prepareSync(environment: "Development") == false, "nothing synced yet")
        let mine = note("synced in development")
        try store.applyServerRecord(SyncMapping.record(for: mine), systemFields: fields)
        try store.setSyncEngineState(Data("token".utf8))
        #expect(try store.prepareSync(environment: "Development") == false, "same environment")
        #expect(try pendingNames().isEmpty)
        #expect(try store.prepareSync(environment: "Production"))
        guard case .save(_, let systemFields, _)? = try store.pendingSyncChanges().first else {
            Issue.record("not pending")
            return
        }
        #expect(systemFields == nil, "sent as new")
        #expect(try store.syncEngineState() == nil)
        #expect(try store.prepareSync(environment: "Production") == false, "recorded")
    }

    /// A store that synced before environments were recorded is treated as
    /// from another one.
    @Test func anUnrecordedEnvironmentStartsOver() throws {
        try store.applyServerRecord(SyncMapping.record(for: note("x")), systemFields: fields)
        #expect(try store.prepareSync(environment: "Production"))
        #expect(try pendingNames().count == 1)
    }

    /// A keychain reset keeps the environment recorded.
    @Test func aResetKeepsTheEnvironment() throws {
        try store.prepareSync(environment: "Production")
        try store.resetSyncForReupload()
        #expect(try store.prepareSync(environment: "Production") == false)
    }

    @Test func theEngineStateIsKept() throws {
        #expect(try store.syncEngineState() == nil)
        try store.setSyncEngineState(Data([1, 2]))
        #expect(try store.syncEngineState() == Data([1, 2]))
    }
}
