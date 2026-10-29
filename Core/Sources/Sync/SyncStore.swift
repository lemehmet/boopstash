import Foundation
import GRDB

/// The store's side of iCloud sync (#63): which local changes are waiting,
/// marking them sent, and applying the server's changes without marking
/// them as local ones. The local store stays the source of truth (ADR 0002).
extension NoteStore {
    /// Local changes not yet acknowledged: saves of notes and attachments,
    /// then deletions.
    public func pendingSyncChanges(limit: Int = 200) throws -> [SyncChange] {
        try writer.read { db in
            var changes: [SyncChange] = []
            let notes = try Row.fetchAll(db, sql: "SELECT * FROM note WHERE syncPending > syncAcknowledged LIMIT ?", arguments: [limit])
            for row in notes {
                let note = try Note(row: row)
                changes.append(.save(SyncMapping.record(for: note), systemFields: row["syncSystemFields"], version: row["syncPending"]))
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

    /// The server saved what was sent at `version`; the row stays pending
    /// if it changed since. The record's metadata is kept, also when the
    /// row changed since (a first upload edited in flight, #106), unless the
    /// upload was built before the row had to go up again as new, or a
    /// newer upload was acknowledged first. Versions only grow, so neither
    /// check is ever undone.
    public func acknowledgeSave(kind: SyncRecord.Kind, name: String, version: Int, systemFields: Data) throws {
        guard let id = UUID(uuidString: name) else { return }
        try writer.write { db in
            // SQLite evaluates every right-hand side with the old values.
            try db.execute(sql: """
                UPDATE \(Self.table(kind)) SET
                    syncSystemFields = CASE WHEN ? >= MAX(syncStaleBelow, syncAcknowledged) THEN ? ELSE syncSystemFields END,
                    syncAcknowledged = MAX(syncAcknowledged, ?)
                WHERE id = ?
                """, arguments: [version, systemFields, version, id])
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
    /// an attachment's file, written before its row.
    @discardableResult
    public func applyServerRecord(_ record: SyncRecord, systemFields: Data, assetData: Data? = nil, now: Date = Date()) throws -> Note? {
        // Deleted here, deletion not yet sent: a stale save from the server
        // must not bring the record back. Checked again inside each write,
        // where a local delete cannot slip in between (#110).
        guard try !writer.read({ db in try Self.isTombstoned(record, db) }) else { return nil }
        switch record.kind {
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
            return try writer.write { db -> Note? in
                guard try !Self.isTombstoned(record, db) else { return nil }
                let row = try Row.fetchOne(db, sql: "SELECT syncPending, syncAcknowledged FROM note WHERE id = ?", arguments: [server.id])
                let changedHere = row.map { ($0["syncPending"] as Int) > ($0["syncAcknowledged"] as Int) } ?? false
                guard changedHere, let local = try Note.fetchOne(db, key: server.id) else {
                    // New here, or unchanged here: the server's version wins.
                    try server.save(db)
                    try Self.refreshImageText(of: server.id, body: server.body, db)
                    try db.execute(sql: "UPDATE note SET syncAcknowledged = syncPending, syncSystemFields = ? WHERE id = ?", arguments: [systemFields, server.id])
                    return nil
                }
                let outcome = SyncMerge.merge(local: local, server: server, now: now)
                try outcome.note.save(db)
                try Self.refreshImageText(of: outcome.note.id, body: outcome.note.body, db)
                // Still different from the server's: a new version to send.
                // The same: in step.
                try db.execute(sql: outcome.stillPending
                                   ? "UPDATE note SET syncPending = syncPending + 1, syncSystemFields = ? WHERE id = ?"
                                   : "UPDATE note SET syncAcknowledged = syncPending, syncSystemFields = ? WHERE id = ?",
                               arguments: [systemFields, server.id])
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
                return nil
            }
            switch kind {
            case .note:
                _ = try Note.deleteOne(db, key: id)
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
            for table in ["note", "attachment"] {
                try db.execute(sql: "UPDATE \(table) SET syncPending = syncPending + 1, syncSystemFields = NULL, syncStaleBelow = syncPending + 1")
            }
            try db.execute(sql: "DELETE FROM syncTombstone")
            try db.execute(sql: "DELETE FROM syncState")
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
        kind == .note ? "note" : "attachment"
    }
}
