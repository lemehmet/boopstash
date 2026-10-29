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
            let notes = try Row.fetchAll(db, sql: "SELECT * FROM note WHERE syncPending > 0 LIMIT ?", arguments: [limit])
            for row in notes {
                let note = try Note(row: row)
                changes.append(.save(SyncMapping.record(for: note), systemFields: row["syncSystemFields"], version: row["syncPending"]))
            }
            let attachments = try Row.fetchAll(db, sql: "SELECT * FROM attachment WHERE syncPending > 0 LIMIT ?", arguments: [limit])
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

    /// The server saved what was sent at `version`. The record's metadata is
    /// kept, also when the row changed since (a first upload edited in
    /// flight, #106), unless the upload was built before the row had to go
    /// up again as new; the row stays pending if it changed since.
    public func acknowledgeSave(kind: SyncRecord.Kind, name: String, version: Int, systemFields: Data) throws {
        guard let id = UUID(uuidString: name) else { return }
        try writer.write { db in
            // SQLite evaluates every right-hand side with the old values.
            try db.execute(sql: """
                UPDATE \(Self.table(kind)) SET
                    syncSystemFields = CASE WHEN ? >= syncStaleBelow THEN ? ELSE syncSystemFields END,
                    syncStaleBelow = CASE WHEN ? >= syncStaleBelow THEN 0 ELSE syncStaleBelow END,
                    syncPending = CASE WHEN syncPending = ? THEN 0 ELSE syncPending END
                WHERE id = ?
                """, arguments: [version, systemFields, version, version, id])
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
            let pending = try writer.read { db in
                try Int.fetchOne(db, sql: "SELECT syncPending FROM attachment WHERE id = ?", arguments: [attachment.id])
            }
            // A row is written only after its file (the store's rule): a new
            // attachment without its asset waits for one.
            if pending == nil, assetData == nil { return nil }
            // A new image, or one unchanged here, takes the server's file and
            // fields; one changed here keeps its own until it is sent.
            let writesFile = assetData != nil && (pending ?? 0) == 0
            if writesFile, let assetData {
                try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                try assetData.write(to: fileURL(for: attachment), options: .atomic)
            }
            let applied = try writer.write { db -> Bool in
                guard try !Self.isTombstoned(record, db) else { return false }
                // Read again: a local change may have landed since.
                switch try Int.fetchOne(db, sql: "SELECT syncPending FROM attachment WHERE id = ?", arguments: [attachment.id]) {
                case nil:
                    try attachment.insert(db)
                    try db.execute(sql: "UPDATE attachment SET syncPending = 0, syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                case 0?:
                    try attachment.update(db)
                    try db.execute(sql: "UPDATE attachment SET syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                default:
                    try db.execute(sql: "UPDATE attachment SET syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                }
                // Its recognised text may have changed (#109).
                try Self.refreshImageText(referencing: attachment.id, db)
                return true
            }
            // Deleted here meanwhile: the file written for it goes too.
            if !applied, writesFile, pending == nil { try? FileManager.default.removeItem(at: fileURL(for: attachment)) }
            return nil
        case .note:
            guard let server = SyncMapping.note(from: record) else { return nil }
            return try writer.write { db -> Note? in
                guard try !Self.isTombstoned(record, db) else { return nil }
                let pending = try Int.fetchOne(db, sql: "SELECT syncPending FROM note WHERE id = ?", arguments: [server.id])
                guard let pending, pending > 0, let local = try Note.fetchOne(db, key: server.id) else {
                    // New here, or unchanged here: the server's version wins.
                    try server.save(db)
                    try Self.refreshImageText(of: server.id, body: server.body, db)
                    try db.execute(sql: "UPDATE note SET syncPending = 0, syncSystemFields = ? WHERE id = ?", arguments: [systemFields, server.id])
                    return nil
                }
                let outcome = SyncMerge.merge(local: local, server: server, now: now)
                try outcome.note.save(db)
                try Self.refreshImageText(of: outcome.note.id, body: outcome.note.body, db)
                try db.execute(sql: "UPDATE note SET syncPending = ?, syncSystemFields = ? WHERE id = ?",
                               arguments: [outcome.stillPending ? pending + 1 : 0, systemFields, server.id])
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
            if let pending = try Int.fetchOne(db, sql: "SELECT syncPending FROM \(table) WHERE id = ?", arguments: [id]), pending > 0 {
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
