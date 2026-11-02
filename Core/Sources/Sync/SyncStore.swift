import Foundation
import GRDB

/// The store's side of iCloud sync (#63): which local changes are waiting,
/// marking them sent, and applying the server's changes without marking
/// them as local ones. The local store stays the source of truth (ADR 0002).
extension NoteStore {
    /// Local changes not yet acknowledged: saves of labels, notes and
    /// attachments, then deletions.
    public func pendingSyncChanges(limit: Int = 200) throws -> [SyncChange] {
        try writer.read { db in
            var changes: [SyncChange] = []
            let labels = try Row.fetchAll(db, sql: "SELECT * FROM label WHERE syncPending > syncAcknowledged LIMIT ?", arguments: [limit])
            for row in labels {
                changes.append(.save(SyncMapping.record(for: try NoteLabel(row: row)), systemFields: row["syncSystemFields"], version: row["syncPending"]))
            }
            let notes = try Row.fetchAll(db, sql: "SELECT * FROM note WHERE syncPending > syncAcknowledged LIMIT ?", arguments: [limit])
            for row in notes {
                let note = try Note(row: row)
                changes.append(.save(SyncMapping.record(for: note, labelIDs: try Self.labelIDs(of: note.id, db)),
                                     systemFields: row["syncSystemFields"], version: row["syncPending"]))
            }
            let attachments = try Row.fetchAll(db, sql: "SELECT * FROM attachment WHERE syncPending > syncAcknowledged LIMIT ?", arguments: [limit])
            for row in attachments {
                let attachment = try NoteAttachment(row: row)
                changes.append(.save(SyncMapping.record(for: attachment, file: fileURL(for: attachment)),
                                     systemFields: row["syncSystemFields"], version: row["syncPending"]))
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM syncTombstone LIMIT ?", arguments: [limit]) {
                guard let kind = SyncRecord.Kind(rawValue: row["kind"]) else { continue }
                changes.append(.delete(kind: kind, name: row["name"], systemFields: row["systemFields"]))
            }
            return changes
        }
    }

    /// The names of everything waiting to be sent, re-delivered whenever
    /// that changes, so the adapter can tell the sync engine. Ends when the
    /// consuming task is cancelled.
    public func pendingSyncNames() -> AsyncThrowingStream<SyncPending, any Error> {
        let values = ValueObservation.tracking(Self.pendingNames).removeDuplicates().values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await pending in values { continuation.yield(pending) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Everything waiting to be sent, now: for reconciling with the sync
    /// engine's own list, which a failed save can leave without it.
    public func currentPendingSyncNames() throws -> SyncPending {
        try writer.read(Self.pendingNames)
    }

    static func pendingNames(_ db: Database) throws -> SyncPending {
        var pending = SyncPending()
        for kind in SyncRecord.Kind.allCases {
            let names = try UUID.fetchAll(db, sql: "SELECT id FROM \(table(kind)) WHERE syncPending > syncAcknowledged")
            pending.saves += names.map { SyncPending.Name(kind: kind, name: $0.uuidString.lowercased()) }
        }
        for row in try Row.fetchAll(db, sql: "SELECT kind, name FROM syncTombstone") {
            guard let kind = SyncRecord.Kind(rawValue: row["kind"]) else { continue }
            pending.deletes.append(SyncPending.Name(kind: kind, name: row["name"]))
        }
        return pending
    }

    /// The save to send for one record, built now; nil when it has nothing
    /// to send (acknowledged, or deleted, meanwhile). A note's body is
    /// remembered as sent until the note is back in step, so the record
    /// coming back is known as this device's own even if its
    /// acknowledgement is lost (#229).
    public func pendingSave(kind: SyncRecord.Kind, name: String) throws -> SyncChange? {
        guard let id = UUID(uuidString: name) else { return nil }
        guard kind == .note else { return try writer.read { db in try buildSave(kind, id, db).change } }
        // Only a note with a save waiting takes the write lock, and its body
        // is written down in the transaction that builds it: a foreign record
        // applied meanwhile forgets it after, never before (#229).
        guard try hasPendingSave(kind: .note, name: name) else { return nil }
        return try writer.write { db in
            let (change, body) = try buildSave(.note, id, db)
            if let body {
                try db.execute(sql: "INSERT OR IGNORE INTO syncUpload (noteID, digest) VALUES (?, ?)",
                               arguments: [id, Note.contentHash(body)])
            }
            return change
        }
    }

    /// The save of one pending record, with a note's body.
    private func buildSave(_ kind: SyncRecord.Kind, _ id: UUID, _ db: Database) throws -> (change: SyncChange?, body: String?) {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(Self.table(kind)) WHERE id = ? AND syncPending > syncAcknowledged", arguments: [id])
        else { return (nil, nil) }
        let record: SyncRecord
        var body: String?
        switch kind {
        case .note:
            let note = try Note(row: row)
            record = SyncMapping.record(for: note, labelIDs: try Self.labelIDs(of: id, db))
            body = note.body
        case .label:
            record = SyncMapping.record(for: try NoteLabel(row: row))
        case .attachment:
            let attachment = try NoteAttachment(row: row)
            record = SyncMapping.record(for: attachment, file: fileURL(for: attachment))
        }
        return (.save(record, systemFields: row["syncSystemFields"], version: row["syncPending"]), body)
    }

    /// Whether a record has a save waiting, without building it.
    public func hasPendingSave(kind: SyncRecord.Kind, name: String) throws -> Bool {
        guard let id = UUID(uuidString: name) else { return false }
        return try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(Self.table(kind)) WHERE id = ? AND syncPending > syncAcknowledged)",
                              arguments: [id]) ?? false
        }
    }

    /// Forgets the bodies sent of a note the server has caught up with, or
    /// moved past: none of them can come back as the server's latest.
    static func forgetUploads(of noteID: UUID, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM syncUpload WHERE noteID = ?", arguments: [noteID])
    }

    /// The server saved what was sent at `version`; the row stays pending
    /// if it changed since. The record's metadata is kept, also when the
    /// row changed since (a first upload edited in flight, #106), unless the
    /// upload was built before the row had to go up again as new, or a
    /// newer upload was acknowledged first. Versions only grow, so neither
    /// check is ever undone.
    public func acknowledgeSave(kind: SyncRecord.Kind, name: String, version: Int, systemFields: Data, changeTag: String? = nil) throws {
        guard let id = UUID(uuidString: name) else { return }
        try writer.write { db in
            // SQLite evaluates every right-hand side with the old values.
            try db.execute(sql: """
                UPDATE \(Self.table(kind)) SET
                    syncSystemFields = CASE WHEN ? >= MAX(syncStaleBelow, syncAcknowledged) THEN ? ELSE syncSystemFields END,
                    syncAcknowledged = MAX(syncAcknowledged, ?)
                WHERE id = ?
                """, arguments: [version, systemFields, version, id])
            // A note's change tag goes with its system fields (#215); the
            // CASE above has already run, so the version check is repeated.
            if kind == .note {
                try db.execute(sql: """
                    UPDATE note SET syncChangeTag = ?
                    WHERE id = ? AND syncSystemFields = ?
                    """, arguments: [changeTag, id, systemFields])
                // In step: the server holds the last body built (#229).
                if try Bool.fetchOne(db, sql: "SELECT syncAcknowledged >= syncPending FROM note WHERE id = ?", arguments: [id]) == true {
                    try Self.forgetUploads(of: id, db)
                }
            }
        }
    }

    public func acknowledgeDelete(kind: SyncRecord.Kind, name: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM syncTombstone WHERE kind = ? AND name = ?", arguments: [kind.rawValue, name])
        }
    }

    /// Applies a record the server sent. For a note this device also
    /// changed, the two are merged (`SyncMerge`); the conflict copy that
    /// merge may produce is saved as a new note and returned. `assetData` is
    /// an attachment's file, written before its row. A label takes the newer
    /// edit, and a label with the same name as another here becomes one with
    /// it (`takeLabel`, ADR 0011).
    @discardableResult
    ///
    /// `changeTag` is the record's server change tag. A note record whose
    /// tag is the one stored at this device's last acknowledgement is its
    /// own upload coming back: the server has not changed since, so unsent
    /// edits here are kept and sent, with no merge and no copy (#215). So is
    /// one whose body this device built for sending since the note was last
    /// in step, acknowledged or not (#229); the server's metadata is then
    /// taken, so the next send is not refused again.
    public func applyServerRecord(_ record: SyncRecord, systemFields: Data, changeTag: String? = nil, assetData: Data? = nil,
                                  now: Date = Date()) throws -> Note? {
        // Deleted here, deletion not yet sent: a stale save from the server
        // must not bring the record back. Checked again inside each write,
        // where a local delete cannot slip in between (#110).
        guard try !writer.read({ db in try Self.isTombstoned(record, db) }) else { return nil }
        switch record.kind {
        case .label:
            guard let server = SyncMapping.label(from: record) else { return nil }
            try writer.write { db in
                guard try !Self.isTombstoned(record, db) else { return }
                let row = try Row.fetchOne(db, sql: "SELECT syncPending, syncAcknowledged FROM label WHERE id = ?", arguments: [server.id])
                let changedHere = row.map { ($0["syncPending"] as Int) > ($0["syncAcknowledged"] as Int) } ?? false
                if changedHere, let local = try NoteLabel.fetchOne(db, key: server.id), local.updatedAt > server.updatedAt {
                    // This device's edit is newer: it stays, to be sent.
                    try db.execute(sql: "UPDATE label SET syncSystemFields = ? WHERE id = ?", arguments: [systemFields, server.id])
                    return
                }
                guard try Self.takeLabel(server, systemFields: systemFields, db) == server.id else { return }
                try db.execute(sql: "UPDATE label SET syncAcknowledged = syncPending, syncSystemFields = ? WHERE id = ?",
                               arguments: [systemFields, server.id])
            }
            return nil
        case .attachment:
            guard let attachment = SyncMapping.attachment(from: record) else { return nil }
            // The server's file goes to a temporary name first and into place
            // only inside the transaction that decides, from the row as it is
            // then, whether this device takes it (#121).
            var incoming: URL?
            if let assetData {
                try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                let url = attachmentsDirectory.appendingPathComponent("\(UUID().uuidString).incoming")
                try assetData.write(to: url, options: .atomic)
                incoming = url
            }
            defer { if let incoming { try? FileManager.default.removeItem(at: incoming) } }
            let final = fileURL(for: attachment)
            try writer.write { db in
                guard try !Self.isTombstoned(record, db) else { return }
                let row = try Row.fetchOne(db, sql: "SELECT syncPending, syncAcknowledged FROM attachment WHERE id = ?", arguments: [attachment.id])
                let changedHere = row.map { ($0["syncPending"] as Int) > ($0["syncAcknowledged"] as Int) } ?? false
                // A row is written only after its file (the store's rule): a
                // new attachment without its asset waits for one. A new image,
                // or one unchanged here, takes the server's file and fields;
                // one changed here keeps its own until it is sent.
                if row == nil, incoming == nil { return }
                if !changedHere, let incoming {
                    _ = try FileManager.default.replaceItemAt(final, withItemAt: incoming)
                }
                switch (row, changedHere) {
                case (nil, _):
                    try attachment.insert(db)
                    try db.execute(sql: "UPDATE attachment SET syncAcknowledged = syncPending, syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                case (_, false):
                    try attachment.update(db)
                    try db.execute(sql: "UPDATE attachment SET syncAcknowledged = syncPending, syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                case (_, true):
                    try db.execute(sql: "UPDATE attachment SET syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                }
                // Its recognised text may have changed (#109).
                try Self.refreshImageText(referencing: attachment.id, db)
            }
            return nil
        case .note:
            guard let server = SyncMapping.note(from: record) else { return nil }
            let serverLabels = SyncMapping.labelIDs(from: record)
            return try writer.write { db -> Note? in
                guard try !Self.isTombstoned(record, db) else { return nil }
                let row = try Row.fetchOne(db, sql: """
                    SELECT syncPending, syncAcknowledged, syncSystemFields IS NOT NULL AND syncChangeTag = ? AS unchangedSince,
                        EXISTS (SELECT 1 FROM syncUpload WHERE noteID = note.id AND digest = ?) AS sentHere
                    FROM note WHERE id = ?
                    """, arguments: [changeTag, Note.contentHash(server.body), server.id])
                let changedHere = row.map { ($0["syncPending"] as Int) > ($0["syncAcknowledged"] as Int) } ?? false
                if changedHere, changeTag != nil, row?["unchangedSince"] == true {
                    // The server still holds what this device last sent: the
                    // edits here are newer, and stay pending to be sent.
                    return nil
                }
                if changedHere, row?["sentHere"] == true {
                    // This device's own upload, whose acknowledgement was lost
                    // or is still to come: the edits here are newer, and stay
                    // pending, to be sent over the server's record (#229).
                    try db.execute(sql: "UPDATE note SET syncSystemFields = ?, syncChangeTag = ? WHERE id = ?",
                                   arguments: [systemFields, changeTag, server.id])
                    return nil
                }
                // Anything else is the server's latest, past every body sent
                // from here.
                try Self.forgetUploads(of: server.id, db)
                guard changedHere, let local = try Note.fetchOne(db, key: server.id) else {
                    // New here, or unchanged here: the server's version wins.
                    // Its labels are kept as sent, also those whose label has
                    // not arrived yet.
                    try server.save(db)
                    try Self.setLabelIDs(serverLabels, of: server.id, db)
                    try Self.refreshImageText(of: server.id, body: server.body, db)
                    try db.execute(sql: "UPDATE note SET syncAcknowledged = syncPending, syncSystemFields = ?, syncChangeTag = ? WHERE id = ?",
                                   arguments: [systemFields, changeTag, server.id])
                    return nil
                }
                let outcome = SyncMerge.merge(local: local, server: server, localLabels: try Self.labelIDs(of: local.id, db),
                                              serverLabels: serverLabels, now: now)
                try outcome.note.save(db)
                try Self.setLabelIDs(outcome.labelIDs, of: outcome.note.id, db)
                try Self.refreshImageText(of: outcome.note.id, body: outcome.note.body, db)
                // Still different from the server's: a new version to send.
                // The same: in step.
                try db.execute(sql: outcome.stillPending
                                   ? "UPDATE note SET syncPending = syncPending + 1, syncSystemFields = ?, syncChangeTag = ? WHERE id = ?"
                                   : "UPDATE note SET syncAcknowledged = syncPending, syncSystemFields = ?, syncChangeTag = ? WHERE id = ?",
                               arguments: [systemFields, changeTag, server.id])
                if let copy = outcome.conflictCopy {
                    try copy.insert(db)
                    try Self.refreshImageText(of: copy.id, body: copy.body, db)
                }
                return outcome.conflictCopy
            }
        }
    }

    static func isTombstoned(_ record: SyncRecord, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncTombstone WHERE kind = ? AND name = ?)",
                          arguments: [record.kind.rawValue, record.name]) ?? false
    }

    /// The server deleted a record: it goes here too, without a tombstone,
    /// since there is nothing to tell the server. A record with changes not
    /// yet sent is kept instead, and sent again as new: another device's
    /// deletion must not silently discard an edit made here.
    public func applyServerDeletion(kind: SyncRecord.Kind, name: String) throws {
        guard let id = UUID(uuidString: name) else { return }
        // Check and delete in one transaction: an edit saved in between
        // would otherwise be deleted without a trace.
        let removed = try writer.write { db -> NoteAttachment? in
            let table = Self.table(kind)
            if try Bool.fetchOne(db, sql: "SELECT syncPending > syncAcknowledged FROM \(table) WHERE id = ?", arguments: [id]) == true {
                // Kept and sent again as new; the version moves on, so an
                // acknowledgement of the upload in flight cannot clear it.
                try db.execute(sql: """
                    UPDATE \(table) SET syncSystemFields = NULL, syncPending = syncPending + 1, syncStaleBelow = syncPending + 1
                    WHERE id = ?
                    """, arguments: [id])
                if kind == .note { try Self.forgetUploads(of: id, db) }
                return nil
            }
            switch kind {
            case .note:
                _ = try Note.deleteOne(db, key: id)
                return nil
            case .label:
                // Off every note here too; the device that deleted it sends
                // those notes without it.
                try db.execute(sql: "DELETE FROM noteLabel WHERE labelID = ?", arguments: [id])
                _ = try NoteLabel.deleteOne(db, key: id)
                return nil
            case .attachment:
                let attachment = try NoteAttachment.fetchOne(db, key: id)
                _ = try NoteAttachment.deleteOne(db, key: id)
                return attachment
            }
        }
        if let removed { try? FileManager.default.removeItem(at: fileURL(for: removed)) }
    }

    /// After a reset iCloud Keychain the server's copy cannot be read
    /// (ADR 0002): everything here is sent again as new.
    public func resetSyncForReupload() throws {
        try writer.write { db in
            for kind in SyncRecord.Kind.allCases {
                try db.execute(sql: "UPDATE \(Self.table(kind)) SET syncPending = syncPending + 1, syncSystemFields = NULL, syncStaleBelow = syncPending + 1")
            }
            try db.execute(sql: "DELETE FROM syncTombstone")
            try db.execute(sql: "DELETE FROM syncUpload")
            try db.execute(sql: "DELETE FROM syncState WHERE key != 'environment'")
        }
    }

    /// Readies the store for syncing with one iCloud environment
    /// (Development or Production): a store that last synced with another
    /// one, or with one not recorded, holds metadata and a change token
    /// that mean nothing there, so everything is sent again as new and the
    /// engine starts afresh. Returns whether it had to.
    @discardableResult
    public func prepareSync(environment: String) throws -> Bool {
        try writer.write { db in
            let recorded = try String.fetchOne(db, sql: "SELECT CAST(value AS TEXT) FROM syncState WHERE key = 'environment'")
            guard recorded != environment else { return false }
            let synced = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM syncState WHERE key = 'engine')
                    OR EXISTS (SELECT 1 FROM note WHERE syncSystemFields IS NOT NULL)
                    OR EXISTS (SELECT 1 FROM attachment WHERE syncSystemFields IS NOT NULL)
                    OR EXISTS (SELECT 1 FROM label WHERE syncSystemFields IS NOT NULL)
                """) ?? false
            if synced {
                for kind in SyncRecord.Kind.allCases {
                    try db.execute(sql: "UPDATE \(Self.table(kind)) SET syncPending = syncPending + 1, syncSystemFields = NULL, syncStaleBelow = syncPending + 1")
                }
                // Deletions the other environment never heard of are not this
                // one's business either.
                try db.execute(sql: "DELETE FROM syncTombstone")
                try db.execute(sql: "DELETE FROM syncState")
            }
            // Bodies built for the other environment, also before anything
            // there was acknowledged or the engine state saved.
            try db.execute(sql: "DELETE FROM syncUpload")
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES ('environment', ?)", arguments: [Data(environment.utf8)])
            return synced
        }
    }

    /// `CKSyncEngine`'s serialized state, kept between launches.
    public func syncEngineState() throws -> Data? {
        try writer.read { db in try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = 'engine'") }
    }

    public func setSyncEngineState(_ data: Data?) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO syncState (key, value) VALUES ('engine', ?)", arguments: [data])
        }
    }

    /// Records a deletion for the server. Always, even for a record the
    /// server may not have: its first upload can be on its way, and without
    /// a tombstone it would reappear from iCloud. Deleting a record the
    /// server never got is harmless (the adapter treats "unknown item" on a
    /// delete as done).
    static func recordTombstone(kind: SyncRecord.Kind, id: UUID, table: String, _ db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT syncSystemFields FROM \(table) WHERE id = ?", arguments: [id]) else { return }
        let systemFields = row["syncSystemFields"] as Data?
        try db.execute(sql: "INSERT OR REPLACE INTO syncTombstone (kind, name, systemFields) VALUES (?, ?, ?)",
                       arguments: [kind.rawValue, id.uuidString.lowercased(), systemFields])
    }

    static func table(_ kind: SyncRecord.Kind) -> String {
        switch kind {
        case .note: "note"
        case .attachment: "attachment"
        case .label: "label"
        }
    }

    // MARK: Labels

    /// The labels a note carries that are in the catalog: an ID whose label
    /// is not here (not arrived yet, or deleted) is ignored.
    static func labelIDs(of noteID: UUID, _ db: Database) throws -> Set<UUID> {
        try UUID.fetchSet(db, sql: "SELECT noteLabel.labelID FROM noteLabel JOIN label ON label.id = noteLabel.labelID WHERE noteLabel.noteID = ?",
                          arguments: [noteID])
    }

    /// Replaces the labels a note carries, as they are: IDs whose label is
    /// not here yet are kept, since sync does not order a note after its
    /// labels.
    static func setLabelIDs(_ ids: Set<UUID>, of noteID: UUID, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM noteLabel WHERE noteID = ?", arguments: [noteID])
        for id in ids {
            try db.execute(sql: "INSERT INTO noteLabel (noteID, labelID) VALUES (?, ?)", arguments: [noteID, id])
        }
    }

    /// Writes `label` into the catalog. A label with the same name under
    /// another ID becomes one with it (ADR 0011): the survivor is the
    /// later created (`NoteLabel.survivor`), so every device keeps the
    /// same one, and the other is folded into it. Returns the survivor's ID;
    /// when it is not `label`'s, `label` was not written. `systemFields`
    /// are `label`'s CloudKit metadata, for its tombstone if it loses.
    static func takeLabel(_ label: NoteLabel, systemFields: Data?, _ db: Database) throws -> UUID {
        if let other = try NoteLabel.fetchOne(db, sql: "SELECT * FROM label WHERE nameKey = ? AND id != ?",
                                              arguments: [NoteLabel.nameKey(label.name), label.id]) {
            if NoteLabel.survivor(label, other).id == other.id {
                try foldLabel(label.id, into: other.id, systemFields: systemFields, db)
                return other.id
            }
            try foldLabel(other.id, into: label.id, systemFields: nil, db)
        }
        try label.save(db)
        return label.id
    }

    /// Every note carrying `loser` carries `survivor` instead and is sent
    /// again; `loser` is deleted, and the deletion sent, whether or not it
    /// is in this store (`systemFields` stand in for its row's).
    static func foldLabel(_ loser: UUID, into survivor: UUID, systemFields: Data?, _ db: Database) throws {
        let notes = try UUID.fetchAll(db, sql: "SELECT noteID FROM noteLabel WHERE labelID = ?", arguments: [loser])
        for note in notes {
            try db.execute(sql: "INSERT OR IGNORE INTO noteLabel (noteID, labelID) VALUES (?, ?)", arguments: [note, survivor])
            try db.execute(sql: "UPDATE note SET syncPending = syncPending + 1 WHERE id = ?", arguments: [note])
        }
        try db.execute(sql: "DELETE FROM noteLabel WHERE labelID = ?", arguments: [loser])
        let here = try Row.fetchOne(db, sql: "SELECT syncSystemFields FROM label WHERE id = ?", arguments: [loser])
        let fields = systemFields ?? here?["syncSystemFields"]
        try db.execute(sql: "INSERT OR REPLACE INTO syncTombstone (kind, name, systemFields) VALUES (?, ?, ?)",
                       arguments: [SyncRecord.Kind.label.rawValue, loser.uuidString.lowercased(), fields])
        _ = try NoteLabel.deleteOne(db, key: loser)
    }
}
