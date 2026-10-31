import Foundation
import GRDB

/// The label catalog and which notes carry which labels (#182, ADR 0011).
/// Every change is a local change to send. Labelling a note never touches
/// its `updatedAt`, so it keeps its place in the list, but the note is sent
/// again, since its record carries its label IDs.
extension NoteStore {
    /// Every label, by name.
    public func labels() throws -> [NoteLabel] {
        try writer.read { db in try NoteLabel.fetchAll(db, sql: "SELECT * FROM label ORDER BY nameKey, id") }
    }

    public func label(id: UUID) throws -> NoteLabel? {
        try writer.read { db in try NoteLabel.fetchOne(db, key: id) }
    }

    /// The label with this name, in any case.
    public func label(named name: String) throws -> NoteLabel? {
        try writer.read { db in
            try NoteLabel.fetchOne(db, sql: "SELECT * FROM label WHERE nameKey = ?", arguments: [NoteLabel.nameKey(name)])
        }
    }

    /// The label with this name, made with `color` if the catalog has none
    /// (a report's `bug`, #185). Looked up each time, so a label deleted
    /// since is made again.
    public func labelCreatingIfMissing(named name: String, color: String, now: Date = Date()) throws -> NoteLabel {
        if let existing = try label(named: name) { return existing }
        do {
            return try createLabel(name: name, color: color, now: now)
        } catch LabelError.duplicateName {
            // Made meanwhile (sync, another window): use that one.
            guard let existing = try label(named: name) else { throw LabelError.notFound }
            return existing
        }
    }

    /// A new label. The name is trimmed and must be new regardless of case;
    /// the colour must be `#rrggbb`.
    @discardableResult
    public func createLabel(name: String, color: String = LabelColor.random(), details: String = "", now: Date = Date()) throws -> NoteLabel {
        guard let parsed = LabelColor.parse(color) else { throw LabelError.invalidColor(color) }
        let label = NoteLabel(name: try Self.checkedName(name), color: parsed, details: details, createdAt: now)
        try writer.write { db in
            try Self.checkUnique(label, db)
            try label.insert(db)
        }
        return label
    }

    /// A new label put on a note, in one transaction: if the note is gone,
    /// no label is made (#183's popover "Create label").
    @discardableResult
    public func createLabel(name: String, color: String, details: String = "", on noteID: UUID, now: Date = Date()) throws -> NoteLabel {
        guard let parsed = LabelColor.parse(color) else { throw LabelError.invalidColor(color) }
        let label = NoteLabel(name: try Self.checkedName(name), color: parsed, details: details, createdAt: now)
        try writer.write { db in
            guard try Note.exists(db, key: noteID) else { throw LabelError.notFound }
            try Self.checkUnique(label, db)
            try label.insert(db)
            try db.execute(sql: "INSERT INTO noteLabel (noteID, labelID) VALUES (?, ?)", arguments: [noteID, label.id])
            try Self.markLabelsChanged(of: noteID, db)
        }
        return label
    }

    /// Changes a label's name, colour and description together, in one
    /// transaction: all of them or none (Settings ▸ Labels' Save).
    public func updateLabel(id: UUID, name: String, color: String, details: String, now: Date = Date()) throws {
        let name = try Self.checkedName(name)
        guard let parsed = LabelColor.parse(color) else { throw LabelError.invalidColor(color) }
        try updateLabel(id: id, now: now) {
            $0.name = name
            $0.color = parsed
            $0.details = details
        }
    }

    public func renameLabel(id: UUID, to name: String, now: Date = Date()) throws {
        let name = try Self.checkedName(name)
        try updateLabel(id: id, now: now) { $0.name = name }
    }

    public func setLabelColor(id: UUID, _ color: String, now: Date = Date()) throws {
        guard let parsed = LabelColor.parse(color) else { throw LabelError.invalidColor(color) }
        try updateLabel(id: id, now: now) { $0.color = parsed }
    }

    public func setLabelDetails(id: UUID, _ details: String, now: Date = Date()) throws {
        try updateLabel(id: id, now: now) { $0.details = details }
    }

    /// Deletes a label and takes it off every note; those notes are sent
    /// again without it.
    public func deleteLabel(id: UUID) throws {
        try writer.write { db in
            try Self.recordTombstone(kind: .label, id: id, table: "label", db)
            try db.execute(sql: """
                UPDATE note SET syncPending = syncPending + 1 WHERE id IN (SELECT noteID FROM noteLabel WHERE labelID = ?)
                """, arguments: [id])
            try db.execute(sql: "DELETE FROM noteLabel WHERE labelID = ?", arguments: [id])
            _ = try NoteLabel.deleteOne(db, key: id)
        }
    }

    public func assignLabel(_ labelID: UUID, to noteID: UUID) throws {
        try writer.write { db in
            guard try NoteLabel.exists(db, key: labelID), try Note.exists(db, key: noteID) else { throw LabelError.notFound }
            try db.execute(sql: "INSERT OR IGNORE INTO noteLabel (noteID, labelID) VALUES (?, ?)", arguments: [noteID, labelID])
            if db.changesCount > 0 { try Self.markLabelsChanged(of: noteID, db) }
        }
    }

    /// Puts the label on the note if it is not there, else takes it off,
    /// deciding inside the transaction, so two quick toggles always undo
    /// each other. Returns whether the note carries it afterwards.
    @discardableResult
    public func toggleLabel(_ labelID: UUID, on noteID: UUID) throws -> Bool {
        try writer.write { db in
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM noteLabel WHERE noteID = ? AND labelID = ?",
                                 arguments: [noteID, labelID]) == true {
                try db.execute(sql: "DELETE FROM noteLabel WHERE noteID = ? AND labelID = ?", arguments: [noteID, labelID])
                try Self.markLabelsChanged(of: noteID, db)
                return false
            }
            guard try NoteLabel.exists(db, key: labelID), try Note.exists(db, key: noteID) else { throw LabelError.notFound }
            try db.execute(sql: "INSERT INTO noteLabel (noteID, labelID) VALUES (?, ?)", arguments: [noteID, labelID])
            try Self.markLabelsChanged(of: noteID, db)
            return true
        }
    }

    public func unassignLabel(_ labelID: UUID, from noteID: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM noteLabel WHERE noteID = ? AND labelID = ?", arguments: [noteID, labelID])
            if db.changesCount > 0 { try Self.markLabelsChanged(of: noteID, db) }
        }
    }

    /// The labels a note carries, by name. An ID whose label is not here
    /// is left out.
    public func labels(of noteID: UUID) throws -> [NoteLabel] {
        try writer.read { db in
            try NoteLabel.fetchAll(db, sql: """
                SELECT label.* FROM label JOIN noteLabel ON noteLabel.labelID = label.id
                WHERE noteLabel.noteID = ? ORDER BY label.nameKey, label.id
                """, arguments: [noteID])
        }
    }

    /// How many notes carry each label; a label on none is absent.
    public func labelUseCounts() throws -> [UUID: Int] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT noteLabel.labelID, COUNT(*) AS uses FROM noteLabel JOIN label ON label.id = noteLabel.labelID
                GROUP BY noteLabel.labelID
                """).reduce(into: [UUID: Int]()) { counts, row in counts[row["labelID"]] = row["uses"] }
        }
    }

    // MARK: Helpers

    private func updateLabel(id: UUID, now: Date, _ change: @Sendable (inout NoteLabel) -> Void) throws {
        try writer.write { db in
            guard var label = try NoteLabel.fetchOne(db, key: id) else { throw LabelError.notFound }
            let before = label
            change(&label)
            guard label != before else { return }
            label.updatedAt = now
            try Self.checkUnique(label, db)
            try label.update(db)
            try db.execute(sql: "UPDATE label SET syncPending = syncPending + 1 WHERE id = ?", arguments: [id])
        }
    }

    static func checkedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LabelError.emptyName }
        return trimmed
    }

    static func checkUnique(_ label: NoteLabel, _ db: Database) throws {
        if let other = try String.fetchOne(db, sql: "SELECT name FROM label WHERE nameKey = ? AND id != ?",
                                           arguments: [NoteLabel.nameKey(label.name), label.id]) {
            throw LabelError.duplicateName(other)
        }
    }

    /// The note is sent again; its `updatedAt` stays as it is.
    static func markLabelsChanged(of noteID: UUID, _ db: Database) throws {
        try db.execute(sql: "UPDATE note SET syncPending = syncPending + 1 WHERE id = ?", arguments: [noteID])
    }
}
