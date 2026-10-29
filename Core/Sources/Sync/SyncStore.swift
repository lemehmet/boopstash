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
    /// kept either way; the row stays pending if it changed since.
    public func acknowledgeSave(kind: SyncRecord.Kind, name: String, version: Int, systemFields: Data) throws {
        guard let id = UUID(uuidString: name) else { return }
        try writer.write { db in
            try db.execute(sql: """
                UPDATE \(Self.table(kind)) SET syncSystemFields = ?,
                    syncPending = CASE WHEN syncPending = ? THEN 0 ELSE syncPending END
                WHERE id = ?
                """, arguments: [systemFields, version, id])
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
        switch record.kind {
        case .attachment:
            guard let attachment = SyncMapping.attachment(from: record) else { return nil }
            if let assetData, (try? self.attachment(id: attachment.id)) == nil {
                try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                try assetData.write(to: fileURL(for: attachment), options: .atomic)
            }
            try writer.write { db in
                if try NoteAttachment.exists(db, key: attachment.id) {
                    try db.execute(sql: "UPDATE attachment SET syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                } else {
                    try attachment.insert(db)
                    try db.execute(sql: "UPDATE attachment SET syncPending = 0, syncSystemFields = ? WHERE id = ?", arguments: [systemFields, attachment.id])
                }
            }
            return nil
        case .note:
            guard let server = SyncMapping.note(from: record) else { return nil }
            return try writer.write { db -> Note? in
                let pending = try Int.fetchOne(db, sql: "SELECT syncPending FROM note WHERE id = ?", arguments: [server.id])
                guard let pending, pending > 0, let local = try Note.fetchOne(db, key: server.id) else {
                    // New here, or unchanged here: the server's version wins.
                    try server.save(db)
                    try db.execute(sql: "UPDATE note SET syncPending = 0, syncSystemFields = ? WHERE id = ?", arguments: [systemFields, server.id])
                    return nil
                }
                let outcome = SyncMerge.merge(local: local, server: server, now: now)
                try outcome.note.save(db)
                try db.execute(sql: "UPDATE note SET syncPending = ?, syncSystemFields = ? WHERE id = ?",
                               arguments: [outcome.stillPending ? pending + 1 : 0, systemFields, server.id])
                if let copy = outcome.conflictCopy { try copy.insert(db) }
                return outcome.conflictCopy
            }
        }
    }

    /// The server deleted a record: it goes here too, without a tombstone,
    /// since there is nothing to tell the server.
    public func applyServerDeletion(kind: SyncRecord.Kind, name: String) throws {
        guard let id = UUID(uuidString: name) else { return }
        let removed = try writer.write { db -> NoteAttachment? in
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
                try db.execute(sql: "UPDATE \(table) SET syncPending = syncPending + 1, syncSystemFields = NULL")
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

    /// Records a deletion for the server, if the server has the record.
    static func recordTombstone(kind: SyncRecord.Kind, id: UUID, table: String, _ db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT syncSystemFields FROM \(table) WHERE id = ?", arguments: [id]),
              let systemFields = row["syncSystemFields"] as Data?
        else { return }
        try db.execute(sql: "INSERT OR REPLACE INTO syncTombstone (kind, name, systemFields) VALUES (?, ?, ?)",
                       arguments: [kind.rawValue, id.uuidString.lowercased(), systemFields])
    }

    static func table(_ kind: SyncRecord.Kind) -> String {
        kind == .note ? "note" : "attachment"
    }
}
