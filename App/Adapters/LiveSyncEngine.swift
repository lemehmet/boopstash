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
    /// CloudKit would stop the app. The Mac reads its own entitlements;
    /// iOS cannot, so the provisioned build says so in its Info.plist.
    static var isAvailable: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) ?? false
        #else
        return Bundle.main.object(forInfoDictionaryKey: "BoopStashICloud") as? String == "YES"
        #endif
    }

    /// The iCloud environment this build was signed for, as its Info.plist
    /// records it: a store that synced with the other one starts over.
    static var environment: String {
        Bundle.main.object(forInfoDictionaryKey: "BoopStashICloudEnvironment") as? String ?? "Production"
    }

    /// What the app shows about sync.
    enum Event: Sendable {
        /// Remote changes are in. The first time since launch, synced
        /// attachments may be swept (#107), after drafts are saved, which
        /// only the app can do.
        case fetched(Date, first: Bool)
        /// Local changes went up; `failed` when some did not, so a problem
        /// already shown stays shown.
        case sent(Date, failed: Bool)
        case account(String?)
        case problem(String)
        /// iCloud data was deleted (Settings ▸ Apple Account ▸ iCloud): sync
        /// stops, and everything here stays.
        case stoppedByServer(String)
    }

    private let store: NoteStore
    private let report: @Sendable (Event) -> Void
    /// Runs the application of fetched changes where edits happen (the
    /// main actor): unsaved drafts are saved first, so changed notes merge
    /// instead of being overwritten, and open editors reload what changed.
    typealias ApplyRemote = @Sendable (_ work: @escaping @Sendable () -> RemoteOutcome) async -> RemoteOutcome?

    /// What applying fetched changes did: the notes it changed, for editors
    /// to reload, and what failed, to try again (#127).
    struct RemoteOutcome: Sendable {
        var changed: Set<UUID> = []
        var failedRecords: [CKRecord.ID] = []
        var failedDeletions: [Deletion] = []
    }

    struct Deletion: Sendable {
        var kind: SyncRecord.Kind
        var name: String
    }
    private let applyRemote: ApplyRemote
    private let container: CKContainer
    private let state = Mutex(State())
    private static let log = Logger(subsystem: "com.lemehmet.boopstash", category: "sync")

    private struct State {
        var engine: CKSyncEngine?
        /// The version each record was sent at, for its acknowledgement.
        var sentVersions: [CKRecord.ID: Int] = [:]
        /// Whether remote changes have been fetched since launch, after
        /// which synced attachments may be swept (#107).
        var fetched = false
        /// Whether a save failed in the send under way.
        var sendFailed = false
        /// Records whose save or delete failed for good: not given back to
        /// the engine automatically, only by Sync Now, so a permanent error
        /// does not fail again on every send.
        var heldBack: Set<CKRecord.ID> = []
        /// Moves on with every account change and reset, so a retry started
        /// for the previous account never applies to the new one.
        var generation = 0
        /// Deletions from the server waiting to be applied again; one whose
        /// record arrives again meanwhile is dropped, not applied over it.
        var retryingDeletions: Set<String> = []
        var watcher: Task<Void, Never>?
    }

    init(store: NoteStore, report: @escaping @Sendable (Event) -> Void, applyRemote: @escaping ApplyRemote) throws {
        self.store = store
        self.report = report
        self.applyRemote = applyRemote
        let container = CKContainer(identifier: Self.containerID)
        self.container = container
        // Synced with the other environment before (a development build's
        // store, opened by a release): start afresh rather than fetch with a
        // change token that means nothing here.
        try store.prepareSync(environment: Self.environment)
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

    /// Fetches and sends now, for Sync Now. Everything the store still has
    /// to send is given to the engine again first: a failed save (a full
    /// iCloud, say) leaves the engine without it.
    func syncNow() async {
        guard let engine = state.withLock({ $0.engine }) else { return }
        // Sync Now tries everything again, failed for good or not.
        state.withLock { $0.heldBack = [] }
        do {
            add(try store.currentPendingSyncNames(), to: engine)
        } catch {
            // Sending now would report success over changes it never saw.
            report(.problem("Changes waiting to sync could not be read: \(error.localizedDescription)"))
            return
        }
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
                    self.add(pending, to: engine, except: self.state.withLock { $0.heldBack })
                }
            } catch {
                self?.report(.problem(error.localizedDescription))
            }
        }
        state.withLock { $0.watcher = task }
    }

    private func add(_ pending: SyncPending, to engine: CKSyncEngine, except held: Set<CKRecord.ID> = []) {
        let known = Set(engine.state.pendingRecordZoneChanges)
        let changes = pending.saves.map { Self.recordID($0.name) }.filter { !held.contains($0) }.map(CKSyncEngine.PendingRecordZoneChange.saveRecord)
            + pending.deletes.map { Self.recordID($0.name) }.filter { !held.contains($0) }.map(CKSyncEngine.PendingRecordZoneChange.deleteRecord)
        let new = changes.filter { !known.contains($0) }
        if !new.isEmpty { engine.state.add(pendingRecordZoneChanges: new) }
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
            await applyFetched(changes.modifications.map(\.record),
                               deletions: changes.deletions.map { ($0.recordID, $0.recordType) })
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: syncEngine)
        case .didFetchChanges:
            let first = state.withLock { state in
                defer { state.fetched = true }
                return !state.fetched
            }
            report(.fetched(Date(), first: first))
        case .willSendChanges:
            state.withLock { $0.sendFailed = false }
        case .didSendChanges:
            // A record held back after failing for good is still a problem,
            // whatever this send did.
            report(.sent(Date(), failed: state.withLock { $0.sendFailed || !$0.heldBack.isEmpty }))
        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
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
            startOver(engine, makingZone: true)
            report(.account(Self.describe(.available)))
        case .signOut:
            startOver(engine, makingZone: false)
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
            startOver(engine, makingZone: true)
        case .deleted, .purged:
            // Deleted from iCloud on purpose: notes here stay, and sync stops
            // rather than putting them back.
            try? store.resetSyncForReupload()
            state.withLock { $0.generation += 1 }
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
            case .zoneNotFound where (failure.error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? Bool) == true:
                // The iCloud Keychain was reset and the zone went with it
                // (ADR 0002): everything goes up again, not just this record.
                startOver(engine, makingZone: true)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            case .serverRecordChanged:
                // Changed elsewhere first: merge the server's version in; the
                // store marks what is still to send, and the watcher re-adds it.
                // The generation now, not when the task runs: an account switch
                // in between must not take this account's record.
                let generation = state.withLock { $0.generation }
                if let server = failure.error.serverRecord { Task { await self.applyFetched([server], deletions: [], generation: generation) } }
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
                // Kept for the next send: Sync Now, or the engine's own.
                state.withLock { $0.sendFailed = true }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                report(.problem("Your iCloud storage is full, so changes are waiting on this Mac."))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated, .operationCancelled:
                // The engine tries again by itself.
                state.withLock { $0.sendFailed = true }
            case .batchRequestFailed, .limitExceeded:
                // Failed with another record of the batch, or with a batch too
                // big: nothing wrong with this one, so it goes again.
                state.withLock { $0.sendFailed = true }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            default:
                // Not one to retry blindly; it stays pending in the store, so
                // Sync Now tries it again, and the problem stays shown.
                state.withLock {
                    $0.sendFailed = true
                    $0.heldBack.insert(record.recordID)
                }
                report(.problem("A change could not be saved to iCloud: \(failure.error.localizedDescription)"))
                Self.log.error("save of \(record.recordID.recordName, privacy: .public) failed: \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        for id in sent.deletedRecordIDs {
            acknowledgeDelete(id)
        }
        for (id, error) in sent.failedRecordDeletes {
            switch error.code {
            case .unknownItem:
                // Never on the server, or gone already: nothing left to delete.
                acknowledgeDelete(id)
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited, .notAuthenticated,
                 .operationCancelled, .batchRequestFailed, .limitExceeded:
                state.withLock { $0.sendFailed = true }
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(id)])
            default:
                state.withLock {
                    $0.sendFailed = true
                    $0.heldBack.insert(id)
                }
                report(.problem("A deletion could not be sent to iCloud: \(error.localizedDescription)"))
                Self.log.error("delete of \(id.recordName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // An edit saved while its record was on the way is still pending in
        // the store, but the engine's change for it is spent; the names did
        // not change, so the watcher says nothing (#126).
        requeuePending(engine)
    }

    /// Everything goes up again as new (another account, a keychain reset):
    /// nothing is held back any more, retries for before are void, and the
    /// engine is given everything.
    private func startOver(_ engine: CKSyncEngine, makingZone: Bool) {
        try? store.resetSyncForReupload()
        state.withLock {
            $0.heldBack = []
            $0.generation += 1
        }
        if makingZone { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]) }
        requeuePending(engine)
    }

    /// Gives the engine everything the store still has to send.
    private func requeuePending(_ engine: CKSyncEngine) {
        do {
            add(try store.currentPendingSyncNames(), to: engine, except: state.withLock { $0.heldBack })
        } catch {
            // Changes may be waiting that the engine no longer knows of; the
            // problem stays shown until Sync Now gives them back.
            state.withLock { $0.sendFailed = true }
            report(.problem("Changes waiting to sync could not be read: \(error.localizedDescription)"))
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
        do {
            for kind in [SyncRecord.Kind.note, .attachment] {
                if case .save(let record, let systemFields, let version)? = try store.pendingSave(kind: kind, name: id.recordName) {
                    state.withLock { $0.sentVersions[id] = version }
                    return Self.ckRecord(from: record, systemFields: systemFields)
                }
            }
        } catch {
            // Could not be read now: the change stays pending for the next
            // send, unlike one with nothing left to send.
            state.withLock { $0.sendFailed = true }
            report(.problem("A note could not be read for sync: \(error.localizedDescription)"))
            Task { engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)]) }
            return nil
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

    /// A server record ready to apply, its file already read.
    private struct Incoming: Sendable {
        var record: SyncRecord
        var systemFields: Data
        var asset: Data?
    }

    /// Reads the files of fetched records here, then applies everything at
    /// once where edits happen (`applyRemote`). A record whose downloaded
    /// file cannot be read is not applied: it is fetched again by itself.
    private func applyFetched(_ records: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)], attempt: Int = 1,
                              generation: Int? = nil) async {
        let generation = generation ?? state.withLock { $0.generation }
        var incoming: [Incoming] = []
        var unreadable: [CKRecord.ID] = []
        for record in records {
            guard let sync = Self.syncRecord(from: record) else { continue }
            var asset: Data?
            if let file = (record["file"] as? CKAsset)?.fileURL {
                guard let data = try? Data(contentsOf: file) else {
                    unreadable.append(record.recordID)
                    continue
                }
                asset = data
            }
            incoming.append(Incoming(record: sync, systemFields: Self.systemFields(of: record), asset: asset))
        }
        let deleted = deletions.compactMap { id, type in SyncRecord.Kind(rawValue: type).map { Deletion(kind: $0, name: id.recordName) } }
        let outcome = await apply(incoming, deletions: deleted, generation: generation)
        let retry = unreadable + (outcome?.failedRecords ?? [])
        if !retry.isEmpty { refetch(retry, attempt: attempt, generation: generation) }
        if let failed = outcome?.failedDeletions, !failed.isEmpty { retryDeletions(failed, attempt: attempt, generation: generation) }
    }

    /// `retrying`: the deletions are retries, applied only if their record
    /// has not come back since; checked here, in the same main-actor step
    /// as any record that clears it, so none can land in between.
    private func apply(_ incoming: [Incoming], deletions: [Deletion], generation: Int, retrying: Bool = false) async -> RemoteOutcome? {
        let store = self.store
        return await applyRemote { [self] in
            var outcome = RemoteOutcome()
            // Fetched for an account this device no longer syncs with.
            guard state.withLock({ $0.generation }) == generation else { return outcome }
            for item in incoming {
                do {
                    let copy = try store.applyServerRecord(item.record, systemFields: item.systemFields, assetData: item.asset)
                    // A newer version arrived: an older deletion waiting to be
                    // applied again no longer holds.
                    _ = state.withLock { $0.retryingDeletions.remove(item.record.name) }
                    if item.record.kind == .note, let id = UUID(uuidString: item.record.name) { outcome.changed.insert(id) }
                    if let copy { outcome.changed.insert(copy.id) }
                } catch {
                    outcome.failedRecords.append(Self.recordID(item.record.name))
                    Self.log.error("applying \(item.record.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            for deletion in deletions {
                if retrying, state.withLock({ $0.retryingDeletions.remove(deletion.name) }) == nil { continue }
                do {
                    try store.applyServerDeletion(kind: deletion.kind, name: deletion.name)
                    if deletion.kind == .note, let id = UUID(uuidString: deletion.name) { outcome.changed.insert(id) }
                } catch {
                    // Armed here, in the same main-actor step: a newer record
                    // applied after this clears it before the retry runs.
                    state.withLock { _ = $0.retryingDeletions.insert(deletion.name) }
                    outcome.failedDeletions.append(deletion)
                }
            }
            return outcome
        }
    }

    /// Applies again deletions from the server that failed here: the
    /// engine will not send them again.
    private func retryDeletions(_ deletions: [Deletion], attempt: Int, generation: Int) {
        guard attempt <= 3 else {
            report(.problem("Some deletions from iCloud could not be applied on this Mac."))
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(5 * attempt))
            guard state.withLock({ $0.engine != nil && $0.generation == generation }) else { return }
            if let failed = await apply([], deletions: deletions, generation: generation, retrying: true)?.failedDeletions, !failed.isEmpty {
                retryDeletions(failed, attempt: attempt + 1, generation: generation)
            }
        }
    }

    /// Fetches records again whose files could not be read, or that could
    /// not be applied, a few times with a growing pause.
    private func refetch(_ ids: [CKRecord.ID], attempt: Int, generation: Int) {
        guard attempt <= 3 else {
            report(.problem("Some changes from iCloud could not be applied on this Mac; they will come with the next change to them."))
            return
        }
        Task { [container] in
            try? await Task.sleep(for: .seconds(5 * attempt))
            guard state.withLock({ $0.engine != nil && $0.generation == generation }) else { return }
            do {
                let results = try await container.privateCloudDatabase.records(for: ids)
                let records = results.values.compactMap { try? $0.get() }
                // Each record can fail alone; those go round again too.
                let missing = ids.filter { (try? results[$0]?.get()) == nil }
                await applyFetched(records, deletions: [], attempt: attempt + 1, generation: generation)
                if !missing.isEmpty { refetch(missing, attempt: attempt + 1, generation: generation) }
            } catch {
                refetch(ids, attempt: attempt + 1, generation: generation)
            }
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
