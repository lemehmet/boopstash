import BoopstashCore
import CloudKit
import Foundation
import Security
import Synchronization
import os

/// iCloud sync (#64): `CKSyncEngine` against the private database of the
/// app's container, driving the Core sync model. The store stays the
/// source of truth (ADR 0002); this turns its records into `CKRecord`s and
/// back, and nothing else. It exists only while the user has sync turned
/// on: creating it is the first time the app talks to CloudKit (ADR 0008).
final class LiveSyncEngine: CKSyncEngineDelegate, Sendable {
    static let containerID = "iCloud.com.lemehmet.boopstash"
    static let zoneID = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)

    /// Whether this build was signed with iCloud: only a build with its
    /// provisioning profile is (ADR 0008), and without the entitlement
    /// CloudKit would stop the app.
    static var isAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) ?? false
    }

    /// What the app shows about sync.
    enum Event: Sendable {
        case synced(Date)
        case account(String?)
        case problem(String)
        /// iCloud data was deleted (Settings ▸ Apple Account ▸ iCloud): sync
        /// stops, and everything here stays.
        case stoppedByServer(String)
    }

    private let store: NoteStore
    private let report: @Sendable (Event) -> Void
    private let state = Mutex(State())
    private static let log = Logger(subsystem: "com.lemehmet.boopstash", category: "sync")

    private struct State {
        var engine: CKSyncEngine?
        /// The version each record was sent at, for its acknowledgement.
        var sentVersions: [CKRecord.ID: Int] = [:]
        /// Whether remote changes have been fetched since launch, after
        /// which synced attachments may be swept (#107).
        var fetched = false
        var watcher: Task<Void, Never>?
    }

    init(store: NoteStore, report: @escaping @Sendable (Event) -> Void) throws {
        self.store = store
        self.report = report
        let container = CKContainer(identifier: Self.containerID)
        let saved = try store.syncEngineState().flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        let engine = CKSyncEngine(configuration)
        if saved == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        state.withLock { $0.engine = engine }
        watchLocalChanges()
        Task { [report] in
            let status = try? await container.accountStatus()
            report(.account(Self.describe(status)))
        }
    }

    /// Stops syncing. The engine's state stays, so turning sync back on
    /// continues where it left off.
    func stop() {
        state.withLock { state in
            state.watcher?.cancel()
            state.watcher = nil
            state.engine = nil
        }
    }

    /// Fetches and sends now, for Sync Now.
    func syncNow() async {
        guard let engine = state.withLock({ $0.engine }) else { return }
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
        } catch {
            report(.problem(error.localizedDescription))
        }
    }

    // MARK: Local changes

    /// Tells the engine about every record waiting in the store, now and
    /// whenever that changes.
    private func watchLocalChanges() {
        let names = store.pendingSyncNames()
        let task = Task { [weak self] in
            do {
                for try await pending in names {
                    guard let self, let engine = self.state.withLock({ $0.engine }) else { return }
                    let known = Set(engine.state.pendingRecordZoneChanges)
                    let changes = pending.saves.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID($0.name)) }
                        + pending.deletes.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(Self.recordID($0.name)) }
                    let new = changes.filter { !known.contains($0) }
                    if !new.isEmpty { engine.state.add(pendingRecordZoneChanges: new) }
                }
            } catch {
                self?.report(.problem(error.localizedDescription))
            }
        }
        state.withLock { $0.watcher = task }
    }

    // MARK: CKSyncEngineDelegate

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        // Notes before attachments, so an attachment's note is there first.
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let ranks = changes.map { (change: $0, rank: rank($0)) }
        let ordered = ranks.sorted { $0.rank < $1.rank }.map(\.change)
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: ordered) { [self] id in
            record(for: id, engine: syncEngine)
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            try? store.setSyncEngineState(JSONEncoder().encode(update.stateSerialization))
        case .accountChange(let change):
            handleAccountChange(change, engine: syncEngine)
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                handleZoneDeletion(deletion.reason, engine: syncEngine)
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications { apply(modification.record) }
            for deletion in changes.deletions {
                guard let kind = SyncRecord.Kind(rawValue: deletion.recordType) else { continue }
                try? store.applyServerDeletion(kind: kind, name: deletion.recordID.recordName)
            }
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine)
        case .didFetchChanges:
            let first = state.withLock { state in
                defer { state.fetched = true }
                return !state.fetched
            }
            if first { _ = try? store.removeUnreferencedAttachments(includingSynced: true) }
            report(.synced(Date()))
        case .didSendChanges:
            report(.synced(Date()))
        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .willSendChanges:
            break
        @unknown default:
            break
        }
    }

    // MARK: Events

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange, engine: CKSyncEngine) {
        switch change.changeType {
        case .signIn:
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            report(.account(Self.describe(.available)))
        case .switchAccounts:
            // Another person's iCloud: this one's notes stay here and go up
            // to the new account as new records.
            try? store.resetSyncForReupload()
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            report(.account(Self.describe(.available)))
        case .signOut:
            try? store.resetSyncForReupload()
            report(.account(Self.describe(.noAccount)))
        @unknown default:
            break
        }
    }

    private func handleZoneDeletion(_ reason: CKDatabase.DatabaseChange.Deletion.Reason, engine: CKSyncEngine) {
        switch reason {
        case .encryptedDataReset:
            // The iCloud Keychain was reset: the server's copy can no longer
            // be read, so everything goes up again (ADR 0002).
            try? store.resetSyncForReupload()
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        case .deleted, .purged:
            // Deleted from iCloud on purpose: notes here stay, and sync stops
            // rather than putting them back.
            try? store.resetSyncForReupload()
            report(.stoppedByServer("BoopStash's data was deleted from iCloud. Your notes on this Mac are unchanged; turn sync on again to upload them."))
        @unknown default:
            break
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        for record in sent.savedRecords {
            guard let kind = SyncRecord.Kind(rawValue: record.recordType) else { continue }
            let version = state.withLock { $0.sentVersions.removeValue(forKey: record.recordID) }
            if let version {
                try? store.acknowledgeSave(kind: kind, name: record.recordID.recordName, version: version, systemFields: Self.systemFields(of: record))
            }
        }
        for failure in sent.failedRecordSaves {
            let record = failure.record
            state.withLock { _ = $0.sentVersions.removeValue(forKey: record.recordID) }
            switch failure.error.code {
            case .serverRecordChanged:
                // Changed elsewhere first: merge the server's version in; the
                // store marks what is still to send, and the watcher re-adds it.
                if let server = failure.error.serverRecord { apply(server) }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            case .unknownItem:
                // Deleted on the server meanwhile: the store keeps the unsent
                // change and sends it again as new.
                if let kind = SyncRecord.Kind(rawValue: record.recordType) {
                    try? store.applyServerDeletion(kind: kind, name: record.recordID.recordName)
                }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            case .quotaExceeded:
                report(.problem("Your iCloud storage is full, so changes are waiting on this Mac."))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated, .operationCancelled:
                // The engine tries again by itself.
                break
            default:
                Self.log.error("save of \(record.recordID.recordName, privacy: .public) failed: \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        for id in sent.deletedRecordIDs {
            acknowledgeDelete(id)
        }
        for (id, error) in sent.failedRecordDeletes {
            // Never on the server, or gone already: nothing left to delete.
            if error.code == .unknownItem { acknowledgeDelete(id) }
        }
    }

    private func acknowledgeDelete(_ id: CKRecord.ID) {
        for kind in [SyncRecord.Kind.note, .attachment] {
            try? store.acknowledgeDelete(kind: kind, name: id.recordName)
        }
    }

    // MARK: Records

    /// Builds the record to send, or nil when there is nothing to send for
    /// it any more (the engine then drops the change).
    private func record(for id: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        for kind in [SyncRecord.Kind.note, .attachment] {
            if case .save(let record, let systemFields, let version)? = try? store.pendingSave(kind: kind, name: id.recordName) {
                state.withLock { $0.sentVersions[id] = version }
                return Self.ckRecord(from: record, systemFields: systemFields)
            }
        }
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
        return nil
    }

    private func rank(_ change: CKSyncEngine.PendingRecordZoneChange) -> Int {
        switch change {
        case .saveRecord(let id): (try? store.pendingSave(kind: .note, name: id.recordName)) != nil ? 0 : 1
        case .deleteRecord: 2
        @unknown default: 3
        }
    }

    private func apply(_ record: CKRecord) {
        guard let sync = Self.syncRecord(from: record) else { return }
        let data = (record["file"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        do {
            try store.applyServerRecord(sync, systemFields: Self.systemFields(of: record), assetData: data)
        } catch {
            Self.log.error("applying \(record.recordID.recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// Every field the app defines goes in `encryptedValues` (ADR 0002);
    /// in the clear are only the record's name, type, its note reference and
    /// the asset, whose key CloudKit keeps in an encrypted field.
    static func ckRecord(from sync: SyncRecord, systemFields: Data?) -> CKRecord {
        let record = systemFields.flatMap(record(fromSystemFields:))
            ?? CKRecord(recordType: sync.kind.rawValue, recordID: recordID(sync.name))
        for key in record.encryptedValues.allKeys() where sync.encrypted[key] == nil {
            record.encryptedValues[key] = nil
        }
        for (key, value) in sync.encrypted {
            switch value {
            case .string(let string): record.encryptedValues[key] = string
            case .date(let date): record.encryptedValues[key] = date
            case .bool(let bool): record.encryptedValues[key] = bool
            case .int(let int): record.encryptedValues[key] = int
            }
        }
        record["note"] = sync.parent.map { CKRecord.Reference(recordID: recordID($0), action: .none) }
        if let file = sync.assetFile { record["file"] = CKAsset(fileURL: file) }
        return record
    }

    static func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard let kind = SyncRecord.Kind(rawValue: record.recordType) else { return nil }
        var fields: [String: SyncValue] = [:]
        for key in record.encryptedValues.allKeys() {
            let value = record.encryptedValues[key]
            if let string = value as? String {
                fields[key] = .string(string)
            } else if let date = value as? Date {
                fields[key] = .date(date)
            } else if let number = value as? NSNumber {
                fields[key] = SyncMapping.booleanFields.contains(key) ? .bool(number.boolValue) : .int(number.intValue)
            }
        }
        return SyncRecord(kind: kind, name: record.recordID.recordName, encrypted: fields,
                          parent: (record["note"] as? CKRecord.Reference)?.recordID.recordName,
                          assetFile: (record["file"] as? CKAsset)?.fileURL)
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func describe(_ status: CKAccountStatus?) -> String? {
        switch status {
        case .available?: nil
        case .noAccount?: "Sign in to iCloud in System Settings to sync."
        case .restricted?: "iCloud is restricted on this Mac."
        case .temporarilyUnavailable?: "iCloud is temporarily unavailable."
        default: "Could not check the iCloud account."
        }
    }
}
