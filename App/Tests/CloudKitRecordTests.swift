import BoopstashCore
import CloudKit
import Foundation
import Testing
@testable import Boopstash

/// How the adapter turns sync records into `CKRecord`s (ADR 0002, 0011).
/// Offline: nothing here talks to CloudKit.
struct CloudKitRecordTests {
    let note = Note(title: "t", body: "b", createdAt: Date(timeIntervalSince1970: 1_000))

    /// The system fields of a record already on the server.
    func serverSystemFields(_ type: String, _ name: String) -> Data {
        LiveSyncEngine.systemFields(of: CKRecord(recordType: type, recordID: LiveSyncEngine.recordID(name)))
    }

    /// A record rebuilt from system fields holds no values: a field this
    /// app's schema has but the record leaves out (the last label removed,
    /// the syntax override reset) is set to nil explicitly, so the server
    /// clears it. Unknown fields are left alone.
    @Test func fieldsLeftOutAreCleared() throws {
        let sync = SyncMapping.record(for: note)
        let record = LiveSyncEngine.ckRecord(from: sync, systemFields: serverSystemFields("Note", sync.name))
        let changed = Set(record.changedKeys())
        #expect(changed.isSuperset(of: ["labelIDs", "syntaxOverride", "sourceBundleID"]))
        #expect(record.encryptedValues["labelIDs"] == nil)
        #expect(!changed.contains("pinned"), "a newer app's field is not touched")
    }

    @Test func labelIDsTravelEncryptedAndRoundTrip() throws {
        let ids: Set<UUID> = [UUID(), UUID()]
        let sync = SyncMapping.record(for: note, labelIDs: ids)
        let record = LiveSyncEngine.ckRecord(from: sync, systemFields: nil)
        #expect(record.encryptedValues["labelIDs"] as? [String] == ids.map { $0.uuidString.lowercased() }.sorted())
        #expect(record["labelIDs"] == nil, "nothing in the clear")
        let back = try #require(LiveSyncEngine.syncRecord(from: record))
        #expect(SyncMapping.labelIDs(from: back) == ids)
        #expect(SyncMapping.note(from: back) == note)
    }

    /// A note upload's identity (ADR 0015) is an encrypted field like the
    /// rest: nothing of it in the clear, and it reads back as sent.
    @Test func theUploadIdentityTravelsEncryptedAndRoundTrips() throws {
        let identity = "0b6f3c58-1d67-4d0c-9a57-3a52f0f7f3c1"
        let sync = SyncMapping.record(for: note, uploadID: identity)
        let record = LiveSyncEngine.ckRecord(from: sync, systemFields: nil)
        #expect(record.encryptedValues[SyncMapping.uploadIDField] as? String == identity)
        #expect(record[SyncMapping.uploadIDField] == nil, "nothing in the clear")
        #expect(!record.recordID.recordName.contains(identity))
        let back = try #require(LiveSyncEngine.syncRecord(from: record))
        #expect(back == sync)
        #expect(SyncMapping.uploadID(from: back) == identity)
        #expect(SyncMapping.note(from: back) == note)
    }

    /// A record of this version always says what its identity is: one built
    /// without it clears the server's, so a stale one is never left beside
    /// content it did not go up with. A client from before identities does
    /// not know the key and leaves it, as `pinned` is left here.
    @Test func aRecordWithoutAnIdentityClearsTheServers() throws {
        let sync = SyncMapping.record(for: note)
        let record = LiveSyncEngine.ckRecord(from: sync, systemFields: serverSystemFields("Note", sync.name))
        #expect(record.changedKeys().contains(SyncMapping.uploadIDField))
        #expect(record.encryptedValues[SyncMapping.uploadIDField] == nil)
        let sent = LiveSyncEngine.ckRecord(from: SyncMapping.record(for: note, uploadID: "a"), systemFields: serverSystemFields("Note", sync.name))
        #expect(sent.encryptedValues[SyncMapping.uploadIDField] as? String == "a")
    }

    @Test func aLabelTravelsEncrypted() throws {
        let label = NoteLabel(name: "Bug", color: "#b60205", details: "Broken", createdAt: Date(timeIntervalSince1970: 1_000))
        let record = LiveSyncEngine.ckRecord(from: SyncMapping.record(for: label), systemFields: nil)
        #expect(record.recordType == "Label")
        #expect(Set(record.encryptedValues.allKeys()) == SyncMapping.schemaFields[.label])
        for key in record.encryptedValues.allKeys() { #expect(record[key] == nil, "\(key) is not in the clear") }
        #expect(LiveSyncEngine.syncRecord(from: record).flatMap(SyncMapping.label(from:)) == label)
    }
}
