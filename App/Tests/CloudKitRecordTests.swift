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

    @Test func aLabelTravelsEncrypted() throws {
        let label = NoteLabel(name: "Bug", color: "#b60205", details: "Broken", createdAt: Date(timeIntervalSince1970: 1_000))
        let record = LiveSyncEngine.ckRecord(from: SyncMapping.record(for: label), systemFields: nil)
        #expect(record.recordType == "Label")
        #expect(Set(record.encryptedValues.allKeys()) == SyncMapping.schemaFields[.label])
        for key in record.encryptedValues.allKeys() { #expect(record[key] == nil, "\(key) is not in the clear") }
        #expect(LiveSyncEngine.syncRecord(from: record).flatMap(SyncMapping.label(from:)) == label)
    }
}
