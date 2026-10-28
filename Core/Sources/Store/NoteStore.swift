import Foundation
import GRDB

/// The note database: one SQLite file with a full-text index kept in step by
/// triggers (ADR 0002). Every read and write goes through here.
public final class NoteStore: Sendable {
    public let writer: any DatabaseWriter

    /// `writer` must have been made with `NoteStore.configuration`, which
    /// installs the SQL functions the queries use.
    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// A store in memory, for tests and previews.
    public static func inMemory() throws -> NoteStore {
        try NoteStore(DatabaseQueue(configuration: configuration))
    }

    /// The store at `url`, created if missing. A pool lets the list read
    /// while the editor writes.
    public static func open(at url: URL) throws -> NoteStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try NoteStore(DatabasePool(path: url.path, configuration: configuration))
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
        return migrator
    }

    // MARK: Reading and writing

    public func save(_ note: Note) throws {
        try writer.write { db in try note.save(db) }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try writer.write { db in try Note.deleteOne(db, key: id) }
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
