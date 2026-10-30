import Foundation
import GRDB
import Testing
@testable import BoopstashCore

/// Labels (#182, ADR 0011): the catalog, note labels, the query filter,
/// and how both sync. All stores are in memory.
@Suite struct LabelTests {
    let store: NoteStore
    static let start = Date(timeIntervalSince1970: 1_000_000)

    init() throws {
        store = try .inMemory()
    }

    @discardableResult
    func add(_ body: String, to store: NoteStore? = nil, edited: Date = LabelTests.start) throws -> Note {
        let note = Note(title: body, body: body, createdAt: edited)
        try (store ?? self.store).save(note)
        return note
    }

    func names(_ labels: [NoteLabel]) -> [String] { labels.map(\.name) }

    func pending(_ store: NoteStore) throws -> Set<String> {
        Set(try store.pendingSyncChanges().map { change in
            switch change {
            case .save(let record, _, _): "save \(record.kind.rawValue) \(record.name)"
            case .delete(let kind, let name, _): "delete \(kind.rawValue) \(name)"
            }
        })
    }

    func acknowledgeAll(_ store: NoteStore) throws {
        for change in try store.pendingSyncChanges() {
            switch change {
            case .save(let record, _, let version):
                try store.acknowledgeSave(kind: record.kind, name: record.name, version: version, systemFields: Data("f".utf8))
            case .delete(let kind, let name, _):
                try store.acknowledgeDelete(kind: kind, name: name)
            }
        }
    }

    // MARK: Colours

    @Test func coloursParseOnlyTheLongHexForm() {
        #expect(LabelColor.parse("#1D76DB") == "#1d76db", "uppercase is lowered")
        #expect(LabelColor.parse(" #0e8a16 ") == "#0e8a16")
        #expect(LabelColor.parse("#abc") == nil, "short form")
        #expect(LabelColor.parse("1d76db") == nil, "missing #")
        #expect(LabelColor.parse("#1d76dg") == nil, "not hex")
        #expect(LabelColor.parse("#1d76db00") == nil)
        #expect(LabelColor.parse("junk") == nil)
        #expect(LabelColor.parse("") == nil)
        #expect(LabelColor.parse("#１２３４５６") == nil, "full-width digits are not hex")
        #expect(LabelColor.format(red: 29, green: 118, blue: 219) == "#1d76db")
        #expect(LabelColor.format(red: 300, green: -1, blue: 0) == "#ff0000")
    }

    @Test func thePaletteIsValidAndRandomPicksFromIt() {
        #expect(LabelColor.palette.allSatisfy { LabelColor.parse($0) == $0 })
        for _ in 0..<20 { #expect(LabelColor.palette.contains(LabelColor.random())) }
    }

    @Test func textContrastFollowsLuminance() {
        #expect(LabelColor.prefersDarkText(on: "#ffffff"))
        #expect(LabelColor.prefersDarkText(on: "#fbca04"), "yellow")
        #expect(!LabelColor.prefersDarkText(on: "#000000"))
        #expect(!LabelColor.prefersDarkText(on: "#5319e7"), "purple")
        #expect(LabelColor.prefersDarkText(on: "#808080"), "mid grey reads better in black")
        #expect(!LabelColor.prefersDarkText(on: "#595959"))
        #expect(LabelColor.relativeLuminance("#ffffff") == 1)
        #expect(LabelColor.relativeLuminance("nope") == nil)
    }

    // MARK: Catalog

    @Test func namesAreTrimmedAndUniqueRegardlessOfCase() throws {
        let bug = try store.createLabel(name: "  Bug ", color: "#B60205", details: "Something broke")
        #expect(bug.name == "Bug" && bug.color == "#b60205")
        #expect(throws: LabelError.duplicateName("Bug")) { try store.createLabel(name: "bug") }
        #expect(throws: LabelError.duplicateName("Bug")) { try store.createLabel(name: "BUG ") }
        #expect(throws: LabelError.emptyName) { try store.createLabel(name: "  ") }
        #expect(throws: LabelError.invalidColor("#abc")) { try store.createLabel(name: "x", color: "#abc") }
        let docs = try store.createLabel(name: "docs")
        #expect(throws: LabelError.duplicateName("Bug")) { try store.renameLabel(id: docs.id, to: "bUg") }
        try store.renameLabel(id: bug.id, to: "BUG")
        #expect(names(try store.labels()) == ["BUG", "docs"], "by name, case aside")
    }

    @Test func editingALabelSendsIt() throws {
        let label = try store.createLabel(name: "ops", color: "#0e8a16", now: Self.start)
        try acknowledgeAll(store)
        let later = Self.start.addingTimeInterval(60)
        try store.renameLabel(id: label.id, to: "infra", now: later)
        try store.setLabelColor(id: label.id, "#FBCA04", now: later)
        try store.setLabelDetails(id: label.id, "Servers", now: later)
        #expect(throws: LabelError.invalidColor("red")) { try store.setLabelColor(id: label.id, "red") }
        #expect(throws: LabelError.notFound) { try store.renameLabel(id: UUID(), to: "x") }
        let stored = try #require(try store.label(id: label.id))
        #expect(stored.name == "infra" && stored.color == "#fbca04" && stored.details == "Servers" && stored.updatedAt == later)
        #expect(try pending(store) == ["save Label \(label.id.uuidString.lowercased())"])
    }

    @Test func labellingNeverMovesTheNoteButSendsIt() throws {
        let note = try add("a note")
        let label = try store.createLabel(name: "keep")
        try acknowledgeAll(store)
        try store.assignLabel(label.id, to: note.id)
        #expect(try store.note(id: note.id)?.updatedAt == note.updatedAt)
        let name = note.id.uuidString.lowercased()
        #expect(try pending(store) == ["save Note \(name)"])
        guard case .save(let record, _, _)? = try store.pendingSave(kind: .note, name: name) else {
            Issue.record("not pending")
            return
        }
        #expect(SyncMapping.labelIDs(from: record) == [label.id])
        try acknowledgeAll(store)
        try store.assignLabel(label.id, to: note.id)
        #expect(try pending(store).isEmpty, "already there: nothing changed")
        try store.unassignLabel(label.id, from: note.id)
        #expect(try store.note(id: note.id)?.updatedAt == note.updatedAt)
        #expect(try pending(store) == ["save Note \(name)"])
        #expect(throws: LabelError.notFound) { try store.assignLabel(UUID(), to: note.id) }
    }

    @Test func labelsOfANoteAndUseCounts() throws {
        let one = try add("one"), two = try add("two")
        let red = try store.createLabel(name: "red"), blue = try store.createLabel(name: "Blue"), idle = try store.createLabel(name: "idle")
        try store.assignLabel(red.id, to: one.id)
        try store.assignLabel(blue.id, to: one.id)
        try store.assignLabel(red.id, to: two.id)
        #expect(names(try store.labels(of: one.id)) == ["Blue", "red"])
        #expect(try store.labelUseCounts() == [red.id: 2, blue.id: 1])
        #expect(try store.labelUseCounts()[idle.id] == nil)
    }

    @Test func deletingALabelTakesItOffEveryNote() throws {
        let one = try add("one"), two = try add("two"), other = try add("other")
        let label = try store.createLabel(name: "gone")
        try store.assignLabel(label.id, to: one.id)
        try store.assignLabel(label.id, to: two.id)
        try acknowledgeAll(store)
        try store.deleteLabel(id: label.id)
        #expect(try store.labels().isEmpty)
        #expect(try store.labels(of: one.id).isEmpty)
        let count = try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM noteLabel") }
        #expect(count == 0)
        #expect(try pending(store) == [
            "delete Label \(label.id.uuidString.lowercased())",
            "save Note \(one.id.uuidString.lowercased())",
            "save Note \(two.id.uuidString.lowercased())",
        ], "\(other.title) is untouched")
    }

    @Test func deletingANoteDropsItsLabels() throws {
        let note = try add("note")
        let label = try store.createLabel(name: "x")
        try store.assignLabel(label.id, to: note.id)
        try store.delete(id: note.id)
        #expect(try store.labelUseCounts().isEmpty)
        #expect(try store.label(id: label.id) != nil, "the label stays")
    }

    // MARK: Query

    @Test func theLabelFilterNeedsEveryLabel() throws {
        let both = try add("both deploy", edited: Self.start)
        let onlyA = try add("only a deploy", edited: Self.start.addingTimeInterval(-1))
        let neither = try add("neither", edited: Self.start.addingTimeInterval(-2))
        let old = try add("old both deploy", edited: Self.start.addingTimeInterval(-30 * 86400))
        let a = try store.createLabel(name: "a"), b = try store.createLabel(name: "b")
        for note in [both, onlyA, old] { try store.assignLabel(a.id, to: note.id) }
        for note in [both, old] { try store.assignLabel(b.id, to: note.id) }
        func titles(_ query: NoteQuery) throws -> [String] {
            try store.notes(matching: query, now: Self.start).map(\.title)
        }
        #expect(try titles(NoteQuery(labels: [a.id])) == ["both deploy", "only a deploy", "old both deploy"])
        #expect(try titles(NoteQuery(labels: [a.id, b.id])) == ["both deploy", "old both deploy"])
        #expect(try titles(NoteQuery(text: "deploy", labels: [a.id, b.id])) == ["both deploy", "old both deploy"])
        #expect(try titles(NoteQuery(text: "only", labels: [a.id, b.id])).isEmpty)
        #expect(try titles(NoteQuery(text: "de", labels: [a.id])) == ["both deploy", "only a deploy", "old both deploy"], "short terms too")
        #expect(try titles(NoteQuery(days: 7, labels: [a.id, b.id])) == ["both deploy"])
        #expect(try titles(NoteQuery(text: "old", scope: .title, labels: [b.id])) == ["old both deploy"])
        #expect(try titles(NoteQuery(text: "neither", scope: .content, labels: [a.id])).isEmpty, "\(neither.title) has no label")
        #expect(try titles(NoteQuery(labels: [UUID()])).isEmpty)
    }

    @Test func theObservedFilterFollowsLabelling() async throws {
        let note = try add("watched")
        let label = try store.createLabel(name: "w")
        var iterator = store.results(NoteQuery(labels: [label.id])).makeAsyncIterator()
        #expect(try await iterator.next() == [])
        try store.assignLabel(label.id, to: note.id)
        #expect(try await iterator.next()?.map(\.id) == [note.id])
        try store.deleteLabel(id: label.id)
        #expect(try await iterator.next() == [])
    }

    // MARK: Migration

    /// A store from 0.4.1 (v9) keeps its notes, images and sync state.
    @Test func aV9StoreMigratesWithNothingLost() throws {
        let queue = try DatabaseQueue(configuration: NoteStore.configuration)
        try NoteStore.migrator.migrate(queue, upTo: "v9-embeddings")
        let note = Note(title: "kept", body: "old body", createdAt: Self.start)
        let attachment = NoteAttachment(noteID: note.id, contentType: "public.png", byteSize: 1, createdAt: Self.start, recognizedText: "text")
        try queue.write { db in
            try note.insert(db)
            try attachment.insert(db)
            try db.execute(sql: "UPDATE note SET syncAcknowledged = syncPending, syncSystemFields = ?", arguments: [Data("f".utf8)])
            try db.execute(sql: "UPDATE attachment SET syncAcknowledged = syncPending")
        }
        let migrated = try NoteStore(queue, attachmentsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(try migrated.note(id: note.id) == note)
        #expect(try migrated.attachment(id: attachment.id) == attachment)
        #expect(try migrated.pendingSyncChanges().isEmpty, "nothing to send again")
        #expect(try migrated.labels().isEmpty && migrated.labels(of: note.id).isEmpty)
        let label = try migrated.createLabel(name: "new")
        try migrated.assignLabel(label.id, to: note.id)
        #expect(try migrated.notes(matching: NoteQuery(labels: [label.id])).map(\.id) == [note.id])
    }

    // MARK: Mapping

    @Test func aLabelRoundTripsEncrypted() throws {
        let label = NoteLabel(name: "Bug", color: "#b60205", details: "Broken", createdAt: Self.start, updatedAt: Self.start.addingTimeInterval(5))
        let record = SyncMapping.record(for: label)
        #expect(record.kind == .label && record.parent == nil && record.assetFile == nil)
        #expect(Set(record.encrypted.keys) == SyncMapping.schemaFields[.label])
        #expect(SyncMapping.label(from: record) == label)
        var odd = record
        odd.encrypted["name"] = .string("  ")
        #expect(SyncMapping.label(from: odd) == nil, "no name")
        odd = record
        odd.encrypted["color"] = .string("#abc")
        #expect(SyncMapping.label(from: odd)?.color == LabelColor.palette[0])
    }

    @Test func aNoteCarriesLabelIDsOnlyWhenItHasSome() throws {
        let note = Note(title: "t", body: "b", createdAt: Self.start)
        let bare = SyncMapping.record(for: note)
        #expect(bare.encrypted["labelIDs"] == nil)
        #expect(SyncMapping.labelIDs(from: bare).isEmpty)
        let ids: Set<UUID> = [UUID(), UUID()]
        let labelled = SyncMapping.record(for: note, labelIDs: ids)
        #expect(labelled.encrypted["labelIDs"] == .strings(ids.map { $0.uuidString.lowercased() }.sorted()))
        #expect(SyncMapping.labelIDs(from: labelled) == ids)
        #expect(SyncMapping.note(from: labelled) == note)
    }

    /// A record from a newer app, with fields this one does not know, is
    /// still read; the unknown fields are ignored.
    @Test func aNewerAppsRecordIsRead() throws {
        let note = Note(title: "t", body: "b", createdAt: Self.start)
        let id = UUID()
        var record = SyncMapping.record(for: note, labelIDs: [id])
        record.encrypted["pinned"] = .bool(true)
        record.encrypted["labelIDs"] = .strings([id.uuidString.lowercased(), "not-an-id"])
        #expect(SyncMapping.note(from: record) == note)
        #expect(SyncMapping.labelIDs(from: record) == [id])
        var label = SyncMapping.record(for: NoteLabel(name: "x", color: "#ffffff", createdAt: Self.start))
        label.encrypted["emoji"] = .string("🐞")
        #expect(SyncMapping.label(from: label)?.name == "x")
    }

    @Test func mergeUnitesLabels() {
        let a = UUID(), b = UUID()
        let server = Note(title: "t", body: "same", createdAt: Self.start, updatedAt: Self.start)
        let local = server
        let outcome = SyncMerge.merge(local: local, server: server, localLabels: [a], serverLabels: [b])
        #expect(outcome.labelIDs == [a, b])
        #expect(outcome.stillPending, "the server lacks a")
        let same = SyncMerge.merge(local: local, server: server, localLabels: [b], serverLabels: [a, b])
        #expect(same.labelIDs == [a, b] && !same.stillPending)
    }

    // MARK: Applying the server's changes

    @Test func aLabelAndItsNoteArrive() throws {
        let label = NoteLabel(name: "Bug", color: "#b60205", details: "d", createdAt: Self.start)
        let note = Note(title: "t", body: "b", createdAt: Self.start)
        try store.applyServerRecord(SyncMapping.record(for: label), systemFields: Data())
        try store.applyServerRecord(SyncMapping.record(for: note, labelIDs: [label.id]), systemFields: Data())
        #expect(try store.labels(of: note.id) == [label])
        #expect(try pending(store).isEmpty)
    }

    /// Labelled on two devices before either synced: both labels stay.
    @Test func aNoteLabelledOnBothSidesKeepsBoth() throws {
        let a = try store.createLabel(name: "a"), b = NoteLabel(name: "b", color: "#ffffff", createdAt: Self.start)
        try store.applyServerRecord(SyncMapping.record(for: b), systemFields: Data())
        let note = try add("shared")
        try acknowledgeAll(store)
        try store.assignLabel(a.id, to: note.id)
        try store.applyServerRecord(SyncMapping.record(for: note, labelIDs: [b.id]), systemFields: Data())
        #expect(Set(try store.labels(of: note.id).map(\.id)) == [a.id, b.id])
        guard case .save(let record, _, _)? = try store.pendingSave(kind: .note, name: note.id.uuidString.lowercased()) else {
            Issue.record("the union is not sent")
            return
        }
        #expect(SyncMapping.labelIDs(from: record) == [a.id, b.id])
        #expect(try store.note(id: note.id)?.updatedAt == note.updatedAt)
    }

    @Test func theNewerEditOfALabelWins() throws {
        let label = try store.createLabel(name: "old", color: "#000000", now: Self.start)
        try acknowledgeAll(store)
        try store.renameLabel(id: label.id, to: "mine", now: Self.start.addingTimeInterval(10))
        var older = label
        older.name = "theirs older"
        older.updatedAt = Self.start.addingTimeInterval(5)
        try store.applyServerRecord(SyncMapping.record(for: older), systemFields: Data())
        #expect(try store.label(id: label.id)?.name == "mine")
        #expect(try pending(store) == ["save Label \(label.id.uuidString.lowercased())"])
        var newer = label
        newer.name = "theirs newer"
        newer.updatedAt = Self.start.addingTimeInterval(20)
        try store.applyServerRecord(SyncMapping.record(for: newer), systemFields: Data())
        #expect(try store.label(id: label.id)?.name == "theirs newer")
        #expect(try pending(store).isEmpty)
    }

    @Test func aLabelDeletedElsewhereLeavesEveryNote() throws {
        let label = NoteLabel(name: "x", color: "#ffffff", createdAt: Self.start)
        try store.applyServerRecord(SyncMapping.record(for: label), systemFields: Data())
        let note = Note(title: "t", body: "b", createdAt: Self.start)
        try store.applyServerRecord(SyncMapping.record(for: note, labelIDs: [label.id]), systemFields: Data())
        try store.applyServerDeletion(kind: .label, name: label.id.uuidString.lowercased())
        #expect(try store.labels().isEmpty)
        #expect(try store.labels(of: note.id).isEmpty)
        #expect(try store.notes(matching: NoteQuery(labels: [label.id])).isEmpty)
    }

    /// A tombstoned label is not brought back by a stale save.
    @Test func aDeletedLabelStaysDeleted() throws {
        let label = try store.createLabel(name: "x")
        try store.deleteLabel(id: label.id)
        try store.applyServerRecord(SyncMapping.record(for: label), systemFields: Data())
        #expect(try store.labels().isEmpty)
    }

    /// A note's label that is not here is ignored, kept until it arrives,
    /// and dropped by the next local save.
    @Test func aDanglingLabelIsIgnoredThenDropped() throws {
        let late = NoteLabel(name: "late", color: "#ffffff", createdAt: Self.start)
        let note = Note(title: "t", body: "b", createdAt: Self.start)
        try store.applyServerRecord(SyncMapping.record(for: note, labelIDs: [late.id]), systemFields: Data())
        #expect(try store.labels(of: note.id).isEmpty)
        #expect(try store.labelUseCounts().isEmpty)
        #expect(try store.notes(matching: NoteQuery(labels: [late.id])).isEmpty)
        try store.applyServerRecord(SyncMapping.record(for: late), systemFields: Data())
        #expect(try store.labels(of: note.id) == [late], "arrived after its note")

        let gone = UUID()
        try store.applyServerRecord(SyncMapping.record(for: note, labelIDs: [late.id, gone]), systemFields: Data())
        var edited = note
        edited.body = "edited"
        try store.save(edited)
        guard case .save(let record, _, _)? = try store.pendingSave(kind: .note, name: note.id.uuidString.lowercased()) else {
            Issue.record("not pending")
            return
        }
        #expect(SyncMapping.labelIDs(from: record) == [late.id])
        let stored = try store.writer.read { db in try UUID.fetchSet(db, sql: "SELECT labelID FROM noteLabel") }
        #expect(stored == [late.id])
    }

    @Test func labelsTakePartInResetsAndPendingNames() throws {
        let label = try store.createLabel(name: "x")
        #expect(try store.currentPendingSyncNames().saves == [SyncPending.Name(kind: .label, name: label.id.uuidString.lowercased())])
        try acknowledgeAll(store)
        #expect(try pending(store).isEmpty)
        try store.resetSyncForReupload()
        #expect(try pending(store) == ["save Label \(label.id.uuidString.lowercased())"])
    }

    // MARK: Two devices

    /// A stand-in for the private database: last write wins, which is
    /// enough when every device fetches before it sends.
    final class Server {
        var records: [String: SyncRecord] = [:]
        var deletions: [SyncPending.Name] = []

        func fetch(into store: NoteStore) throws {
            let ordered = records.values.sorted { ($0.kind == .label ? 0 : 1, $0.name) < ($1.kind == .label ? 0 : 1, $1.name) }
            for record in ordered { try store.applyServerRecord(record, systemFields: Data("f".utf8)) }
            for deletion in deletions { try store.applyServerDeletion(kind: deletion.kind, name: deletion.name) }
        }

        func send(from store: NoteStore) throws {
            for change in try store.pendingSyncChanges() {
                switch change {
                case .save(let record, _, let version):
                    records[record.name] = record
                    try store.acknowledgeSave(kind: record.kind, name: record.name, version: version, systemFields: Data("f".utf8))
                case .delete(let kind, let name, _):
                    records[name] = nil
                    deletions.append(SyncPending.Name(kind: kind, name: name))
                    try store.acknowledgeDelete(kind: kind, name: name)
                }
            }
        }

        func sync(_ stores: [NoteStore], rounds: Int = 3) throws {
            for _ in 0..<rounds {
                for store in stores {
                    try fetch(into: store)
                    try send(from: store)
                }
            }
        }
    }

    func snapshot(_ store: NoteStore, _ notes: [Note]) throws -> [String] {
        try store.labels().map { "\($0.id) \($0.name)" } + notes.map { note in
            "\(note.id): " + (try store.labels(of: note.id).map(\.id.uuidString).joined(separator: ","))
        }
    }

    @Test func aLabelSyncsToTheOtherDevice() throws {
        let mac = try NoteStore.inMemory(), phone = try NoteStore.inMemory()
        let note = try add("shared", to: mac)
        let label = try mac.createLabel(name: "Bug", color: "#b60205", details: "Broken")
        try mac.assignLabel(label.id, to: note.id)
        try Server().sync([mac, phone])
        #expect(try phone.labels(of: note.id) == [label])
        #expect(try pending(mac).isEmpty && pending(phone).isEmpty)
    }

    /// Both devices made "Bug" / "bug" before syncing: each ends with the
    /// earlier one, on every note that had either, whichever arrived first.
    @Test func sameNameLabelsBecomeOneMacFirst() throws { try sameNameLabelsBecomeOne(phoneFirst: false) }
    @Test func sameNameLabelsBecomeOnePhoneFirst() throws { try sameNameLabelsBecomeOne(phoneFirst: true) }

    func sameNameLabelsBecomeOne(phoneFirst: Bool) throws {
        let mac = try NoteStore.inMemory(), phone = try NoteStore.inMemory()
        let macNote = try add("on the mac", to: mac), phoneNote = try add("on the phone", to: phone)
        let earlier = try mac.createLabel(name: "Bug", color: "#b60205", now: Self.start)
        let later = try phone.createLabel(name: "bug", color: "#0e8a16", now: Self.start.addingTimeInterval(1))
        try mac.assignLabel(earlier.id, to: macNote.id)
        try phone.assignLabel(later.id, to: phoneNote.id)
        try Server().sync(phoneFirst ? [phone, mac] : [mac, phone])
        for store in [mac, phone] {
            #expect(try store.labels().map(\.id) == [earlier.id])
            #expect(try store.labels(of: macNote.id).map(\.id) == [earlier.id])
            #expect(try store.labels(of: phoneNote.id).map(\.id) == [earlier.id])
        }
        #expect(try snapshot(mac, [macNote, phoneNote]) == snapshot(phone, [macNote, phoneNote]))
        #expect(try pending(mac).isEmpty && pending(phone).isEmpty)
    }

    @Test func aLabelDeletedOnOneDeviceLeavesBoth() throws {
        let mac = try NoteStore.inMemory(), phone = try NoteStore.inMemory()
        let server = Server()
        let note = try add("shared", to: mac)
        let label = try mac.createLabel(name: "x")
        try mac.assignLabel(label.id, to: note.id)
        try server.sync([mac, phone])
        try phone.deleteLabel(id: label.id)
        try server.sync([phone, mac])
        for store in [mac, phone] {
            #expect(try store.labels().isEmpty)
            #expect(try store.labels(of: note.id).isEmpty)
        }
    }

    // MARK: Merging two stores (App Group)

    @Test func copyMissingUnitesLabels() throws {
        let here = try NoteStore.inMemory(), there = try NoteStore.inMemory()
        let note = try add("both", to: here)
        try there.save(note)
        let mine = try here.createLabel(name: "mine"), theirs = try there.createLabel(name: "theirs")
        try here.assignLabel(mine.id, to: note.id)
        try there.assignLabel(theirs.id, to: note.id)
        let onlyThere = try add("only there", to: there)
        try there.assignLabel(theirs.id, to: onlyThere.id)
        try acknowledgeAll(here)
        _ = try here.copyMissing(from: there)
        #expect(Set(try here.labels(of: note.id).map(\.name)) == ["mine", "theirs"])
        #expect(try here.labels(of: onlyThere.id).map(\.name) == ["theirs"])
        #expect(try pending(here).contains("save Note \(note.id.uuidString.lowercased())"))
        #expect(try pending(here).contains("save Label \(theirs.id.uuidString.lowercased())"))
        #expect(try here.note(id: note.id)?.updatedAt == note.updatedAt)
    }

    @Test func copyMissingKeepsALabelDeletedHereDeleted() throws {
        let here = try NoteStore.inMemory(), there = try NoteStore.inMemory()
        let note = try add("both", to: here)
        try there.save(note)
        let label = try here.createLabel(name: "x")
        try there.applyServerRecord(SyncMapping.record(for: label), systemFields: Data())
        try there.assignLabel(label.id, to: note.id)
        try here.deleteLabel(id: label.id)
        _ = try here.copyMissing(from: there)
        #expect(try here.labels().isEmpty)
        #expect(try here.labels(of: note.id).isEmpty)
        #expect(try pending(here).contains("delete Label \(label.id.uuidString.lowercased())"))
    }

    @Test func copyMissingCarriesALabelDeletedThere() throws {
        let here = try NoteStore.inMemory(), there = try NoteStore.inMemory()
        let note = try add("both", to: here)
        try there.save(note)
        let label = try here.createLabel(name: "x")
        try here.assignLabel(label.id, to: note.id)
        try there.applyServerRecord(SyncMapping.record(for: label), systemFields: Data())
        try there.deleteLabel(id: label.id)
        _ = try here.copyMissing(from: there)
        #expect(try here.labels().isEmpty)
        #expect(try here.labels(of: note.id).isEmpty)
        #expect(try pending(here).contains("delete Label \(label.id.uuidString.lowercased())"))
    }

    @Test func copyMissingMergesSameNameLabels() throws {
        let here = try NoteStore.inMemory(), there = try NoteStore.inMemory()
        let hereNote = try add("here", to: here), thereNote = try add("there", to: there)
        let later = try here.createLabel(name: "Bug", now: Self.start.addingTimeInterval(1))
        let earlier = try there.createLabel(name: "bug", now: Self.start)
        try here.assignLabel(later.id, to: hereNote.id)
        try there.assignLabel(earlier.id, to: thereNote.id)
        _ = try here.copyMissing(from: there)
        #expect(try here.labels().map(\.id) == [earlier.id])
        #expect(try here.labels(of: hereNote.id).map(\.id) == [earlier.id])
        #expect(try here.labels(of: thereNote.id).map(\.id) == [earlier.id])
        #expect(try pending(here).contains("delete Label \(later.id.uuidString.lowercased())"))

        // The other way round: the label here is the earlier one.
        let first = try NoteStore.inMemory(), second = try NoteStore.inMemory()
        let a = try add("a", to: first), b = try add("b", to: second)
        let keep = try first.createLabel(name: "Bug", now: Self.start)
        let drop = try second.createLabel(name: "BUG", now: Self.start.addingTimeInterval(1))
        try first.assignLabel(keep.id, to: a.id)
        try second.assignLabel(drop.id, to: b.id)
        _ = try first.copyMissing(from: second)
        #expect(try first.labels().map(\.id) == [keep.id])
        #expect(try first.labels(of: b.id).map(\.id) == [keep.id])
        #expect(try pending(first).contains("delete Label \(drop.id.uuidString.lowercased())"))
    }
}
