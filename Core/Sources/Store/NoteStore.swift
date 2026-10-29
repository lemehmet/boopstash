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
    /// while the editor writes.
    public static func open(at url: URL) throws -> NoteStore {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try NoteStore(DatabasePool(path: url.path, configuration: configuration),
                             attachmentsDirectory: folder.appendingPathComponent("Attachments", isDirectory: true))
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
        var migrator = DatabaseMigrator()
        #if DEBUG
        // A migration edited after it shipped would leave existing databases
        // behind silently; in debug builds, rebuild instead so it shows.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
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
        return migrator
    }

    // MARK: Reading and writing

    public func save(_ note: Note) throws {
        try writer.write { db in
            try note.save(db)
            try db.execute(sql: "UPDATE note SET syncPending = syncPending + 1 WHERE id = ?", arguments: [note.id])
        }
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
    @discardableResult
    public func removeUnreferencedAttachments(olderThan grace: TimeInterval = 24 * 60 * 60, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-grace)
        let (orphans, known) = try writer.write { db -> ([NoteAttachment], Set<UUID>) in
            let referenced = try Self.referencedAttachmentIDs(db)
            let orphans = try NoteAttachment.filter(Column("createdAt") < cutoff).fetchAll(db)
                .filter { !referenced.contains($0.id) }
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
        let bodies = try String.fetchAll(db, sql: "SELECT body FROM note WHERE instr(body, ?) > 0", arguments: [AttachmentReference.scheme])
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
        case .everywhere: ["title", "body", "sourceAppName"]
        case .title: ["title"]
        case .content: ["body"]
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
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY note.updatedAt DESC, note.rowid DESC LIMIT ?"
        arguments.append(query.limit)
        return (sql, StatementArguments(arguments))
    }

    /// Each term becomes a quoted FTS5 string, so nothing the user types is
    /// read as query syntax (`*`, `-`, `NEAR`, parentheses, column names).
    /// Adjacent strings are ANDed; the column filter limits the scope.
    static func ftsPattern(_ terms: [String], columns: [String]) -> String {
        let quoted = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return "{" + columns.joined(separator: " ") + "} : (" + quoted.joined(separator: " ") + ")"
    }

}
