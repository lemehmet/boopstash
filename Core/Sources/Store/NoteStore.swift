import CryptoKit
import Foundation
import GRDB

/// The note database: one SQLite file with a full-text index kept in step by
/// triggers (ADR 0002). Every read and write goes through here.
public final class NoteStore: Sendable {
    public let writer: any DatabaseWriter
    /// Where attachment files live: `Attachments/` beside the database.
    public let attachmentsDirectory: URL

    /// `writer` must have been made with `NoteStore.configuration`, which
    /// installs the SQL functions the queries use.
    init(_ writer: any DatabaseWriter, attachmentsDirectory: URL) throws {
        self.writer = writer
        self.attachmentsDirectory = attachmentsDirectory
        try Self.migrator.migrate(writer)
    }

    /// A store in memory, for tests and previews. Its attachments go in a
    /// fresh temporary folder.
    public static func inMemory() throws -> NoteStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boopstash-\(UUID().uuidString)", isDirectory: true)
        return try NoteStore(DatabaseQueue(configuration: configuration), attachmentsDirectory: folder)
    }

    /// The store at `url`, created if missing. A pool lets the list read
    /// while the editor writes. `shared` is for a store that another process
    /// writes too (the iOS app and its share extension, #66): writers wait
    /// for each other, and the database lets go of its locks while the app
    /// is suspended (post `Database.suspendNotification` then), or iOS would
    /// end it.
    public static func open(at url: URL, shared: Bool = false) throws -> NoteStore {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var configuration = configuration
        if shared {
            configuration.observesSuspensionNotifications = true
            configuration.busyMode = .timeout(5)
        }
        return try NoteStore(DatabasePool(path: url.path, configuration: configuration),
                             attachmentsDirectory: folder.appendingPathComponent("Attachments", isDirectory: true))
    }

    /// Lets every shared store give up its locks while the app is suspended,
    /// and take them again when it is back (see `open(at:shared:)`).
    public static func suspendSharedStores() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    public static func resumeSharedStores() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Moves a store's whole folder (the database, its WAL and SHM files,
    /// and Attachments) to `destination`, once: only when `source` holds a
    /// store and `destination` does not. One rename on the same volume, never
    /// a copy then a delete, so there is no moment with two stores or none.
    /// Returns whether it moved. For the iOS store's move into the App Group
    /// the share extension can reach (#66).
    @discardableResult
    public static func moveStoreFolder(from source: URL, to destination: URL, storeName: String = "notes.sqlite") throws -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: source.appendingPathComponent(storeName).path),
              !files.fileExists(atPath: destination.appendingPathComponent(storeName).path)
        else { return false }
        // An empty folder there (a launch that made it, then failed) would
        // stop the rename; anything in it means someone else's data.
        if files.fileExists(atPath: destination.path) {
            guard (try files.contentsOfDirectory(atPath: destination.path)).isEmpty else { return false }
            try files.removeItem(at: destination)
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: source, to: destination)
        return true
    }

    /// Where a store shared with an extension lives: moved into `group`
    /// when it can be (`moveStoreFolder`), and otherwise left at `own` while
    /// a store is there, so a refused move never opens a new, empty store
    /// in place of the notes. A new store goes in the group. With a store in
    /// both (builds with and without the group, alternating), the group's is
    /// used and the other's notes, images and unsent deletions are merged
    /// into it (`copyMissing`); the other folder is then renamed, kept as a
    /// backup, never deleted. `keepingAtHome` names items of `own` that are
    /// not the store (the Mac's Scripts folder and keybindings.json): they
    /// are moved back to `own` after it moves, every time, so an interrupted
    /// launch is repaired by the next (#171).
    /// Returns the folder, whether it is the group's, and how many notes
    /// came over.
    public static func sharedStoreFolder(own: URL, group: URL, storeName: String = "notes.sqlite", keepingAtHome: [String] = [],
                                         now: Date = Date()) throws -> (folder: URL, inGroup: Bool, merged: Int) {
        let files = FileManager.default
        /// Items that belong at `own`, moved back from where `own` went.
        func bringHome(from folder: URL) {
            for name in keepingAtHome {
                let there = folder.appendingPathComponent(name), here = own.appendingPathComponent(name)
                guard files.fileExists(atPath: there.path) else { continue }
                // An empty folder at home (the script watcher makes one) is
                // no reason to leave the real one away (#177). rmdir removes
                // only an empty folder, in one step: a script added meanwhile
                // keeps it.
                _ = rmdir(here.path)
                guard !files.fileExists(atPath: here.path) else { continue }
                try? files.createDirectory(at: own, withIntermediateDirectories: true)
                try? files.moveItem(at: there, to: here)
            }
        }
        // Where home-only items wait while `own` is renamed to a backup, so a
        // crash in between leaves them somewhere every launch looks (#174).
        let staging = own.deletingLastPathComponent().appendingPathComponent("\(own.lastPathComponent)-keep")
        defer {
            bringHome(from: group)
            bringHome(from: staging)
            // Only an empty one (rmdir refuses others): anything left in it
            // could not go home.
            _ = rmdir(staging.path)
        }
        do {
            try moveStoreFolder(from: own, to: group, storeName: storeName)
        } catch where files.fileExists(atPath: own.appendingPathComponent(storeName).path) {
            // A move that failed part-way (no space, permissions) leaves the
            // notes where they were: open them there rather than not at all.
            return (own, false, 0)
        }
        let ownStore = own.appendingPathComponent(storeName), groupStore = group.appendingPathComponent(storeName)
        switch (files.fileExists(atPath: groupStore.path), files.fileExists(atPath: ownStore.path)) {
        case (true, true):
            let merged = try open(at: groupStore).copyMissing(from: open(at: ownStore))
            let stamp = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
            let backup = own.deletingLastPathComponent().appendingPathComponent("\(own.lastPathComponent)-merged-\(stamp)")
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in keepingAtHome where files.fileExists(atPath: own.appendingPathComponent(name).path)
                && !files.fileExists(atPath: staging.appendingPathComponent(name).path) {
                try files.moveItem(at: own.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            try files.moveItem(at: own, to: backup)
            return (group, true, merged)
        case (true, false): return (group, true, 0)
        case (false, true): return (own, false, 0)
        case (false, false): return (group, true, 0)
        }
    }

    /// Brings `other`'s notes, images and unsent deletions into this store,
    /// as new local changes to send. A note only there is copied; a note in
    /// both keeps the newer edit, and if their text differs the other text
    /// is kept as a "(conflict)" copy, as sync does (#172). A deletion not
    /// yet sent from `other` is carried over and applied here, so iCloud
    /// cannot bring the note back (#173); nothing deleted here returns.
    /// Labels come over too, the newer edit of each winning; a note's labels
    /// are both stores' (union), and a name in both under two IDs becomes
    /// one label, as sync does (ADR 0011).
    /// Returns how many notes came over or changed.
    func copyMissing(from other: NoteStore, now: Date = Date()) throws -> Int {
        let tombstones = try other.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, name, systemFields FROM syncTombstone")
                .map { (kind: $0["kind"] as String, name: $0["name"] as String, systemFields: $0["systemFields"] as Data?) }
        }
        let deletedHere = try writer.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT kind, name FROM syncTombstone").map { "\($0["kind"] as String)/\($0["name"] as String)" })
        }
        let deletedThere = Set(tombstones.map { "\($0.kind)/\($0.name)" })
        func deleted(_ kind: SyncRecord.Kind, _ id: UUID) -> Bool {
            let key = "\(kind.rawValue)/\(id.uuidString.lowercased())"
            return deletedHere.contains(key) || deletedThere.contains(key)
        }
        // Labels first, so the notes' labels find theirs. `survivors` maps
        // each of `other`'s labels to the one that stands for it here.
        let (theirLabels, theirLabelFields) = try other.writer.read { db in
            (try NoteLabel.fetchAll(db),
             try Row.fetchAll(db, sql: "SELECT id, syncSystemFields FROM label")
                .reduce(into: [UUID: Data]()) { fields, row in fields[row["id"]] = row["syncSystemFields"] })
        }
        var survivors: [UUID: UUID] = [:]
        for label in theirLabels where !deleted(.label, label.id) {
            survivors[label.id] = try writer.write { db -> UUID in
                if let mine = try NoteLabel.fetchOne(db, key: label.id), mine.updatedAt >= label.updatedAt { return mine.id }
                let survivor = try Self.takeLabel(label, systemFields: theirLabelFields[label.id], db)
                if survivor == label.id {
                    try db.execute(sql: "UPDATE label SET syncPending = syncPending + 1 WHERE id = ?", arguments: [label.id])
                }
                return survivor
            }
        }
        let attachments = try other.writer.read { db in try NoteAttachment.fetchAll(db) }
        for attachment in attachments where try self.attachment(id: attachment.id) == nil && !deleted(.attachment, attachment.id) {
            guard let data = try? other.data(for: attachment) else { continue }
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: attachment), options: .atomic)
            try writer.write { db in try attachment.insert(db) }
        }
        var changed: Set<UUID> = []
        for note in try other.writer.read({ db in try Note.fetchAll(db) }) where !deleted(.note, note.id) {
            guard let mine = try self.note(id: note.id) else {
                try save(note)
                changed.insert(note.id)
                continue
            }
            guard mine != note else { continue }
            // The newer edit stays; the other text, if different, is a copy.
            let theirsIsNewer = note.updatedAt > mine.updatedAt
            let older = theirsIsNewer ? mine : note
            if mine.body != note.body {
                // Its ID comes from the note and the text, so a merge run again
                // (interrupted before the backup rename) replaces this copy
                // rather than adding another (#174).
                let digest = Array(SHA256.hash(data: Data("conflict \(note.id.uuidString) \(older.body)".utf8)))
                var copy = Note(id: UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                                                digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15])),
                                title: "\(older.title.isEmpty ? "Untitled" : older.title) (conflict)", titleIsUserSet: true,
                                body: older.body, createdAt: now, updatedAt: now,
                                sourceBundleID: older.sourceBundleID, sourceAppName: older.sourceAppName)
                copy.syntaxOverride = older.syntaxOverride
                try save(copy)
            }
            // After the copy: a crash between the two leaves the notes still
            // different, so the next merge makes the copy again (same ID).
            if theirsIsNewer { try save(note) }
            changed.insert(note.id)
        }
        // Each note's labels: both stores' (union). A label that went to
        // another here goes on as that one; one deleted in either is left off.
        let theirAssignments = try other.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT noteID, labelID FROM noteLabel").map { (note: $0["noteID"] as UUID, label: $0["labelID"] as UUID) }
        }
        try writer.write { db in
            for assignment in theirAssignments {
                let label = survivors[assignment.label] ?? assignment.label
                guard !deleted(.label, label), !deleted(.note, assignment.note),
                      try Note.exists(db, key: assignment.note) else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO noteLabel (noteID, labelID) VALUES (?, ?)", arguments: [assignment.note, label])
                guard db.changesCount > 0 else { continue }
                try db.execute(sql: "UPDATE note SET syncPending = syncPending + 1 WHERE id = ?", arguments: [assignment.note])
                changed.insert(assignment.note)
            }
        }
        // Deletions `other` had not sent yet: applied here and kept to send.
        for tombstone in tombstones {
            guard let kind = SyncRecord.Kind(rawValue: tombstone.kind), let id = UUID(uuidString: tombstone.name) else { continue }
            switch kind {
            case .note: if try note(id: id) != nil { _ = try delete(id: id) }
            case .attachment: if try attachment(id: id) != nil { try deleteAttachment(id: id) }
            case .label: if try label(id: id) != nil { try deleteLabel(id: id) }
            }
            try writer.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO syncTombstone (kind, name, systemFields) VALUES (?, ?, ?)",
                               arguments: [tombstone.kind, tombstone.name, tombstone.systemFields])
            }
        }
        return changed.count
    }

    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: containsIgnoringCase)
        }
        return configuration
    }

    /// Substring match with Unicode case folding, for terms too short for
    /// the trigram index. SQLite's own LIKE folds ASCII only, so "é" would
    /// miss "Élan". Diacritics still count, as they do in the index.
    static let containsIgnoringCase = DatabaseFunction("boopContainsIgnoringCase", argumentCount: 2, pure: true) { values in
        guard let haystack = String.fromDatabaseValue(values[0]),
              let needle = String.fromDatabaseValue(values[1])
        else { return false }
        return haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        // Never eraseDatabaseOnSchemaChange: debug builds and the app test
        // host share the installed app's container, so it erased real notes
        // whenever a branch's migrations differed from the store's.
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("titleIsUserSet", .boolean).notNull().defaults(to: false)
                t.column("body", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
                t.column("sourceBundleID", .text)
                t.column("sourceAppName", .text)
            }
            // Trigram tokens make every match a substring match: a filter box
            // over code and logs should find "ginx" in "nginx.conf", which a
            // word tokenizer cannot. The cost is an index roughly three times
            // the text, which a personal stash can afford.
            try db.create(virtualTable: "noteSearch", using: FTS5()) { t in
                t.synchronize(withTable: "note")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("title")
                t.column("body")
                t.column("sourceAppName")
            }
        }
        migrator.registerMigration("v2-model-titled-hash") { db in
            try db.alter(table: "note") { t in
                t.add(column: "modelTitledHash", .text)
            }
        }
        migrator.registerMigration("v3-syntax-override") { db in
            try db.alter(table: "note") { t in
                t.add(column: "syntaxOverride", .text)
            }
        }
        migrator.registerMigration("v4-attachments") { db in
            // No foreign key to the note: a reference copied into another
            // note keeps the file alive after its first note is deleted.
            try db.create(table: "attachment") { t in
                t.primaryKey("id", .blob)
                t.column("noteID", .blob).indexed()
                t.column("contentType", .text).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("recognizedText", .text)
            }
        }
        migrator.registerMigration("v5-image-text") { db in
            // Text recognised in a note's images, kept on the note so the
            // index can cover it. Not part of `Note`: an older draft saved
            // over the row must not erase text recognised since.
            try db.alter(table: "note") { t in
                t.add(column: "imageText", .text)
            }
            try db.dropFTS5SynchronizationTriggers(forTable: "noteSearch")
            try db.drop(table: "noteSearch")
            try db.create(virtualTable: "noteSearch", using: FTS5()) { t in
                t.synchronize(withTable: "note")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("title")
                t.column("body")
                t.column("sourceAppName")
                t.column("imageText")
            }
        }
        migrator.registerMigration("v6-sync") { db in
            // iCloud sync (#63). `syncPending` counts local changes not yet
            // acknowledged by the server (0 when in step); every existing
            // row starts pending, to be sent once. `syncSystemFields` holds
            // CloudKit's record metadata, opaque here.
            for table in ["note", "attachment"] {
                try db.alter(table: table) { t in
                    t.add(column: "syncPending", .integer).notNull().defaults(to: 1)
                    t.add(column: "syncSystemFields", .blob)
                }
            }
            // A deletion the server has not heard of yet.
            try db.create(table: "syncTombstone") { t in
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("systemFields", .blob)
                t.primaryKey(["kind", "name"])
            }
            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob)
            }
        }
        migrator.registerMigration("v7-sync-stale") { db in
            // Uploads built before a row had to go up as new (the server
            // deleted it, or the keychain was reset) carry a version below
            // this; their acknowledgements must not restore its metadata
            // (#106). Versions only grow (v8), so it is never cleared.
            for table in ["note", "attachment"] {
                try db.alter(table: table) { t in
                    t.add(column: "syncStaleBelow", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v8-sync-acknowledged") { db in
            // `syncPending` becomes a version that only grows; a row is
            // pending while it is above the last version the server
            // acknowledged. Rows in step today (0) stay in step.
            for table in ["note", "attachment"] {
                try db.alter(table: table) { t in
                    t.add(column: "syncAcknowledged", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v9-embeddings") { db in
            // Semantic search (#157): one unit-length vector per note, rebuilt
            // on this device and never synced. A note whose text has nothing
            // to embed has an empty one, so it is not tried again. A change to
            // the text deletes the row, so a note without one needs embedding.
            try db.create(table: "noteEmbedding") { t in
                t.primaryKey("noteID", .blob).references("note", onDelete: .cascade)
                t.column("vector", .blob).notNull()
            }
            try db.execute(sql: """
                CREATE TRIGGER noteEmbeddingStale AFTER UPDATE OF title, body, imageText ON note
                WHEN OLD.title IS NOT NEW.title OR OLD.body IS NOT NEW.body OR OLD.imageText IS NOT NEW.imageText
                BEGIN DELETE FROM noteEmbedding WHERE noteID = NEW.id; END
                """)
        }
        migrator.registerMigration("v10-labels") { db in
            // Labels (#182, ADR 0011): one catalog, synced as its own record
            // kind, with the sync columns the other kinds have. `nameKey` is
            // the case-folded name, folded in Swift since SQLite's lower()
            // folds ASCII only, so "Bug" and "bug" cannot both be here.
            try db.create(table: "label") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("nameKey", .text).notNull().unique()
                t.column("color", .text).notNull()
                t.column("details", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("syncPending", .integer).notNull().defaults(to: 1)
                t.column("syncSystemFields", .blob)
                t.column("syncStaleBelow", .integer).notNull().defaults(to: 0)
                t.column("syncAcknowledged", .integer).notNull().defaults(to: 0)
            }
            // Which notes carry which labels. No foreign key to the label: a
            // note can arrive from iCloud before its label does, and must
            // keep the ID until it comes; reads join the catalog instead.
            try db.create(table: "noteLabel") { t in
                t.column("noteID", .blob).notNull().references("note", onDelete: .cascade)
                t.column("labelID", .blob).notNull().indexed()
                t.primaryKey(["noteID", "labelID"])
            }
        }
        migrator.registerMigration("v11-sync-change-tag") { db in
            // The server's change tag of a note's record, kept with its
            // system fields: a fetched record with the same tag is this
            // device's own upload coming back, not an edit made elsewhere
            // (#215). Local only; the CloudKit schema is unchanged.
            try db.alter(table: "note") { t in
                t.add(column: "syncChangeTag", .text)
            }
        }
        migrator.registerMigration("v12-sync-uploads") { db in
            // The note records built for sending since the note was last in
            // step, as `SyncRecord.contentDigest`s: a record coming back with one of
            // them is this device's own upload, also when its acknowledgement
            // never arrived (#229). Local only; the CloudKit schema is
            // unchanged.
            try db.create(table: "syncUpload") { t in
                t.column("noteID", .blob).notNull().references("note", onDelete: .cascade)
                t.column("digest", .text).notNull()
                t.primaryKey(["noteID", "digest"])
            }
        }
        return migrator
    }

    // MARK: Reading and writing

    public func save(_ note: Note) throws {
        try writer.write { db in try Self.save(note, db) }
    }

    static func save(_ note: Note, _ db: Database) throws {
        try note.save(db)
        try refreshImageText(of: note.id, body: note.body, db)
        // Label IDs with no label here are dropped with the next save
        // (ADR 0011); the record sent now leaves them out anyway.
        try db.execute(sql: "DELETE FROM noteLabel WHERE noteID = ? AND labelID NOT IN (SELECT id FROM label)", arguments: [note.id])
        try db.execute(sql: "UPDATE note SET syncPending = syncPending + 1 WHERE id = ?", arguments: [note.id])
    }

    // MARK: Image text

    /// Stores the text recognised in an attachment (empty for none, so it
    /// is not recognised again) and updates every note showing it.
    public func setRecognizedText(_ text: String, for attachmentID: UUID) throws {
        try writer.write { db in
            guard var attachment = try NoteAttachment.fetchOne(db, key: attachmentID) else { return }
            attachment.recognizedText = text
            try attachment.update(db)
            // The text travels with the attachment, so it is a change to send
            // (#108).
            try db.execute(sql: "UPDATE attachment SET syncPending = syncPending + 1 WHERE id = ?", arguments: [attachmentID])
            try Self.refreshImageText(referencing: attachmentID, db)
        }
    }

    /// Updates the `imageText` of every note whose body mentions the
    /// attachment.
    static func refreshImageText(referencing attachmentID: UUID, _ db: Database) throws {
        let needle = attachmentID.uuidString.lowercased()
        let rows = try Row.fetchAll(db, sql: "SELECT id, body FROM note WHERE instr(lower(body), ?) > 0", arguments: [needle])
        for row in rows {
            try refreshImageText(of: row["id"], body: row["body"], db)
        }
    }

    /// Reads the text of every image still waiting, oldest first and one at
    /// a time, with `recognize` (Vision, in the app; on device). An image
    /// that cannot be read, or whose text cannot be, is recorded as having
    /// none, so it is not tried on every change. Returns when nothing is
    /// left. Run it off the main actor: files are up to 20 MB.
    public func recognizePendingImages(with recognize: @Sendable (Data) async -> String?) async {
        while let next = try? attachmentsAwaitingRecognition(limit: 1).first {
            let data = try? self.data(for: next)
            let text = if let data { await recognize(data) ?? "" } else { "" }
            // Deleted while it was read.
            guard (try? attachment(id: next.id)) != nil else { continue }
            do {
                try setRecognizedText(text, for: next.id)
            } catch {
                return
            }
        }
    }

    /// Attachments not yet through text recognition, oldest first.
    public func attachmentsAwaitingRecognition(limit: Int = 50) throws -> [NoteAttachment] {
        try writer.read { db in
            try NoteAttachment.filter(Column("recognizedText") == nil).order(Column("createdAt")).limit(limit).fetchAll(db)
        }
    }

    /// The recognised text of a note's images, as the index holds it.
    public func imageText(of noteID: UUID) throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT imageText FROM note WHERE id = ?", arguments: [noteID]) }
    }

    /// The note's `imageText`: the recognised text of the attachments its
    /// body refers to, so removing an image from the text removes its words
    /// from search.
    static func refreshImageText(of noteID: UUID, body: String, _ db: Database) throws {
        let ids = AttachmentReference.ids(in: body)
        let texts = ids.isEmpty ? [] : try NoteAttachment.fetchAll(db, keys: Array(ids))
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap(\.recognizedText).filter { !$0.isEmpty }
        let joined = texts.isEmpty ? nil : texts.joined(separator: "\n")
        try db.execute(sql: "UPDATE note SET imageText = ? WHERE id = ? AND imageText IS NOT ?", arguments: [joined, noteID, joined])
    }

    /// Deletes a note, and the attachments it owned that no other saved
    /// note refers to. A caller holding unsaved edits that may refer to them
    /// passes false and leaves them to `removeUnreferencedAttachments`.
    @discardableResult
    public func delete(id: UUID, removingOrphanedAttachments: Bool = true) throws -> Bool {
        let (deleted, orphans) = try writer.write { db -> (Bool, [NoteAttachment]) in
            try Self.recordTombstone(kind: .note, id: id, table: "note", db)
            guard try Note.deleteOne(db, key: id) else { return (false, []) }
            guard removingOrphanedAttachments else { return (true, []) }
            let owned = try NoteAttachment.filter(Column("noteID") == id).fetchAll(db)
            guard !owned.isEmpty else { return (true, []) }
            let referenced = try Self.referencedAttachmentIDs(db)
            let orphans = owned.filter { !referenced.contains($0.id) }
            for orphan in orphans { try Self.recordTombstone(kind: .attachment, id: orphan.id, table: "attachment", db) }
            try NoteAttachment.deleteAll(db, keys: orphans.map(\.id))
            return (true, orphans)
        }
        removeFiles(of: orphans)
        return deleted
    }

    // MARK: Attachments

    /// Stores `data` as a new attachment of `noteID` and returns it. The file
    /// is written before the row, so a row never points at nothing.
    public func addAttachment(_ data: Data, contentType: String, noteID: UUID?, now: Date = Date()) throws -> NoteAttachment {
        let attachment = NoteAttachment(noteID: noteID, contentType: contentType, byteSize: data.count, createdAt: now)
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let url = fileURL(for: attachment)
        try data.write(to: url, options: .atomic)
        do {
            try writer.write { db in try attachment.insert(db) }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return attachment
    }

    /// Removes an attachment and its file, for one whose note was never
    /// saved.
    public func deleteAttachment(id: UUID) throws {
        let removed = try writer.write { db -> NoteAttachment? in
            let attachment = try NoteAttachment.fetchOne(db, key: id)
            try Self.recordTombstone(kind: .attachment, id: id, table: "attachment", db)
            _ = try NoteAttachment.deleteOne(db, key: id)
            return attachment
        }
        if let removed { removeFiles(of: [removed]) }
    }

    public func attachment(id: UUID) throws -> NoteAttachment? {
        try writer.read { db in try NoteAttachment.fetchOne(db, key: id) }
    }

    /// The attachments a body refers to that exist, in no particular order.
    public func attachments(referencedBy body: String) throws -> [NoteAttachment] {
        let ids = AttachmentReference.ids(in: body)
        guard !ids.isEmpty else { return [] }
        return try writer.read { db in try NoteAttachment.fetchAll(db, keys: Array(ids)) }
    }

    public func fileURL(for attachment: NoteAttachment) -> URL {
        attachmentsDirectory.appendingPathComponent(attachment.fileName)
    }

    public func data(for attachment: NoteAttachment) throws -> Data {
        try Data(contentsOf: fileURL(for: attachment))
    }

    /// Removes attachments no note refers to that are older than `grace`,
    /// and files in the attachments folder that have no row (left by a crash
    /// between writing a file and recording it, or by a failed removal).
    /// The grace period covers an image pasted into a note whose edit is
    /// not saved yet, and a reference that undo can still bring back; run
    /// this at launch, not while editing. Returns how many attachments and
    /// stray files were removed.
    ///
    /// Attachments already in iCloud are swept only with `includingSynced`:
    /// another device may refer to one in a note not fetched yet, and the
    /// tombstone would delete it there too (#107). Sync passes it once a
    /// fetch has completed since launch; with sync off, nothing can arrive.
    @discardableResult
    public func removeUnreferencedAttachments(olderThan grace: TimeInterval = 24 * 60 * 60, now: Date = Date(),
                                              includingSynced: Bool = false) throws -> Int {
        let cutoff = now.addingTimeInterval(-grace)
        let (orphans, known) = try writer.write { db -> ([NoteAttachment], Set<UUID>) in
            let referenced = try Self.referencedAttachmentIDs(db)
            // An attachment that came from iCloud before its note did is
            // not an orphan yet: its note is still on its way.
            let waiting = try UUID.fetchSet(db, sql: """
                SELECT id FROM attachment WHERE syncSystemFields IS NOT NULL AND noteID IS NOT NULL
                    AND noteID NOT IN (SELECT id FROM note)
                """)
            let synced = includingSynced ? [] : try UUID.fetchSet(db, sql: "SELECT id FROM attachment WHERE syncSystemFields IS NOT NULL")
            let orphans = try NoteAttachment.filter(Column("createdAt") < cutoff).fetchAll(db)
                .filter { !referenced.contains($0.id) && !waiting.contains($0.id) && !synced.contains($0.id) }
            for orphan in orphans { try Self.recordTombstone(kind: .attachment, id: orphan.id, table: "attachment", db) }
            try NoteAttachment.deleteAll(db, keys: orphans.map(\.id))
            let known = try UUID.fetchSet(db, sql: "SELECT id FROM attachment")
            return (orphans, known)
        }
        removeFiles(of: orphans)
        return orphans.count + removeStrayFiles(keeping: known, modifiedBefore: cutoff)
    }

    /// Files named `<uuid>.<ext>` whose ID has no row, older than `cutoff`
    /// (a file being added right now has no row for a moment).
    private func removeStrayFiles(keeping known: Set<UUID>, modifiedBefore cutoff: Date) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: attachmentsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !known.contains(id),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff
            else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// Every attachment ID any note body refers to. Only bodies that mention
    /// the scheme are read.
    static func referencedAttachmentIDs(_ db: Database) throws -> Set<UUID> {
        let bodies = try String.fetchAll(db, sql: "SELECT body FROM note WHERE instr(lower(body), ?) > 0", arguments: [AttachmentReference.scheme])
        return bodies.reduce(into: Set<UUID>()) { $0.formUnion(AttachmentReference.ids(in: $1)) }
    }

    /// After the rows are gone; a file left behind by a failure here is
    /// harmless, a row without its file is not.
    private func removeFiles(of attachments: [NoteAttachment]) {
        for attachment in attachments { try? FileManager.default.removeItem(at: fileURL(for: attachment)) }
    }

    public func note(id: UUID) throws -> Note? {
        try writer.read { db in try Note.fetchOne(db, key: id) }
    }

    public func notes(matching query: NoteQuery, now: Date = Date(), calendar: Calendar = .current) throws -> [Note] {
        let (sql, arguments) = Self.sql(for: query, now: now, calendar: calendar)
        return try writer.read { db in try Note.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// The query's results, re-delivered whenever a note changes. The age
    /// cutoff is recomputed from `clock` on every fetch, so "today" moves on
    /// at midnight with the next change. With no change at all nothing
    /// re-fetches; the app restarts its observation when the day changes.
    public func observe(
        _ query: NoteQuery,
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) -> ValueObservation<ValueReducers.Fetch<[Note]>> {
        ValueObservation.tracking { db in
            let (sql, arguments) = Self.sql(for: query, now: clock(), calendar: calendar)
            return try Note.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    /// The same, as a plain stream, so the app never imports GRDB. Ends when
    /// the consuming task is cancelled.
    public func results(
        _ query: NoteQuery,
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) -> AsyncThrowingStream<[Note], any Error> {
        let values = observe(query, clock: clock, calendar: calendar).values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await notes in values { continuation.yield(notes) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }


    // MARK: Query building

    /// Trigram matching needs at least three characters; shorter terms fall
    /// back to a scan with `boopContainsIgnoringCase`, which is slower but
    /// only ever narrows a query that the index, the age limit or the row
    /// limit already bounds.
    static let shortestIndexedTerm = 3

    static func columns(for scope: NoteQuery.Scope) -> [String] {
        switch scope {
        case .everywhere: ["title", "body", "sourceAppName", "imageText"]
        case .title: ["title"]
        case .content: ["body", "imageText"]
        }
    }

    static func sql(for query: NoteQuery, now: Date, calendar: Calendar) -> (String, StatementArguments) {
        let columns = columns(for: query.scope)
        let indexed = query.terms.filter { $0.unicodeScalars.count >= shortestIndexedTerm }
        let short = query.terms.filter { $0.unicodeScalars.count < shortestIndexedTerm }

        var sql = "SELECT note.* FROM note"
        var conditions: [String] = []
        var arguments: [any DatabaseValueConvertible] = []

        if !indexed.isEmpty {
            sql += " JOIN noteSearch ON noteSearch.rowid = note.rowid"
            conditions.append("noteSearch MATCH ?")
            arguments.append(ftsPattern(indexed, columns: columns))
        }
        for term in short {
            conditions.append("(" + columns.map { "boopContainsIgnoringCase(note.\($0), ?)" }.joined(separator: " OR ") + ")")
            arguments.append(contentsOf: Array(repeating: term, count: columns.count))
        }
        if let cutoff = query.cutoff(now: now, calendar: calendar) {
            conditions.append("note.updatedAt >= ?")
            arguments.append(cutoff)
        }
        if let (condition, labelArguments) = labelCondition(query.labels) {
            conditions.append(condition)
            arguments.append(contentsOf: labelArguments)
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY note.updatedAt DESC, note.rowid DESC LIMIT ?"
        arguments.append(query.limit)
        return (sql, StatementArguments(arguments))
    }

    /// Notes carrying every one of `labels` (AND), counting only labels in
    /// the catalog; nil for no labels. Shared by the list and "similar in
    /// meaning", so both honour the same filter.
    static func labelCondition(_ labels: Set<UUID>) -> (String, [any DatabaseValueConvertible])? {
        guard !labels.isEmpty else { return nil }
        let sorted = labels.sorted { $0.uuidString < $1.uuidString }
        let condition = """
            note.id IN (SELECT noteLabel.noteID FROM noteLabel JOIN label ON label.id = noteLabel.labelID
                WHERE noteLabel.labelID IN (\(sorted.map { _ in "?" }.joined(separator: ", ")))
                GROUP BY noteLabel.noteID HAVING COUNT(DISTINCT noteLabel.labelID) = ?)
            """
        return (condition, sorted as [any DatabaseValueConvertible] + [sorted.count])
    }

    /// Each term becomes a quoted FTS5 string, so nothing the user types is
    /// read as query syntax (`*`, `-`, `NEAR`, parentheses, column names).
    /// Adjacent strings are ANDed; the column filter limits the scope.
    static func ftsPattern(_ terms: [String], columns: [String]) -> String {
        let quoted = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return "{" + columns.joined(separator: " ") + "} : (" + quoted.joined(separator: " ") + ")"
    }

}
