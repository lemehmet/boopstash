import Foundation
import GRDB
import Testing
@testable import BoopstashCore

@Suite struct NoteStoreTests {
    /// A fixed clock and calendar, so "last N days" means the same thing on
    /// every machine and in every time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    static let now = ISO8601DateFormatter().date(from: "2026-10-28T15:00:00Z")! // 11:00 in New York

    static func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let today = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -days, to: today)!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    let store: NoteStore

    init() throws {
        store = try .inMemory()
    }

    @discardableResult
    func add(_ body: String, title: String = "", app: String? = nil, edited: Date = NoteStoreTests.now) throws -> Note {
        let note = Note(title: title, body: body, createdAt: edited, sourceAppName: app)
        try store.save(note)
        return note
    }

    func titles(_ query: NoteQuery) throws -> [String] {
        try store.notes(matching: query, now: Self.now, calendar: Self.calendar).map(\.title)
    }

    // MARK: Round trip

    @Test func savedNoteReadsBackUnchanged() throws {
        let note = try add("server {\n  listen 80;\n}", title: "nginx", app: "Terminal")
        #expect(try store.note(id: note.id) == note)
    }

    @Test func subMillisecondDatesRoundTrip() throws {
        let precise = Date(timeIntervalSinceReferenceDate: 783_000_000.123_456_7)
        var note = Note(title: "t", body: "b", createdAt: precise)
        note.updatedAt = precise.addingTimeInterval(0.000_9)
        try store.save(note)
        #expect(try store.note(id: note.id) == note)
        // And with whatever the clock says right now.
        let now = Note(title: "n", body: "b", createdAt: Date())
        try store.save(now)
        #expect(try store.note(id: now.id) == now)
    }

    @Test func listIsNewestEditedFirst() throws {
        try add("a", title: "old", edited: Self.daysAgo(3))
        try add("b", title: "new", edited: Self.daysAgo(0))
        try add("c", title: "middle", edited: Self.daysAgo(1))
        #expect(try titles(NoteQuery()) == ["new", "middle", "old"])
    }

    // MARK: Text filter

    @Test func matchesInsideWords() throws {
        try add("include /etc/nginx/nginx.conf;", title: "config")
        try add("unrelated", title: "other")
        #expect(try titles(NoteQuery(text: "ginx")) == ["config"])
    }

    @Test func everyTermMustMatch() throws {
        try add("docker compose up", title: "both")
        try add("docker build", title: "one")
        #expect(try titles(NoteQuery(text: "docker compose")) == ["both"])
    }

    @Test func matchingIgnoresCase() throws {
        try add("Kubernetes", title: "k8s")
        #expect(try titles(NoteQuery(text: "KUBER")) == ["k8s"])
    }

    @Test func scopeLimitsWhereTermsMatch() throws {
        try add("the body mentions postgres", title: "database notes")
        try add("nothing here", title: "postgres tuning")
        #expect(try titles(NoteQuery(text: "postgres", scope: .title)) == ["postgres tuning"])
        #expect(try titles(NoteQuery(text: "postgres", scope: .content)) == ["database notes"])
        #expect(Set(try titles(NoteQuery(text: "postgres"))) == ["database notes", "postgres tuning"])
    }

    /// Neither the title nor the body contains the term, so only the
    /// source-app column can match (#12).
    @Test func sourceAppIsSearchableEverywhereOnly() throws {
        try add("some output", title: "build log", app: "Terminal")
        #expect(try titles(NoteQuery(text: "termin")) == ["build log"])
        #expect(try titles(NoteQuery(text: "termin", scope: .title)).isEmpty)
        #expect(try titles(NoteQuery(text: "termin", scope: .content)).isEmpty)
    }

    /// Terms under three characters cannot use the trigram index and take
    /// the scan path; they must behave the same way.
    @Test func shortTermsStillMatchAsSubstrings() throws {
        try add("run go test ./...", title: "go")
        try add("cargo test", title: "rust")
        #expect(Set(try titles(NoteQuery(text: "go"))) == ["go", "rust"]) // "cargo" contains "go"
        #expect(try titles(NoteQuery(text: "go ./"))  == ["go"])
    }

    @Test func nonASCIICaseIsFoldedOnBothPaths() throws {
        try add("Élan vital", title: "french")
        #expect(try titles(NoteQuery(text: "é")) == ["french"], "short path")
        #expect(try titles(NoteQuery(text: "ÉL")) == ["french"], "short path, two letters")
        #expect(try titles(NoteQuery(text: "élan")) == ["french"], "trigram path")
    }

    @Test func likeWildcardsInTermsAreLiteral() throws {
        try add("100% done", title: "percent")
        try add("1000 items", title: "plain")
        try add("snake_case", title: "underscore")
        try add("snakeXcase", title: "x")
        #expect(try titles(NoteQuery(text: "0%")) == ["percent"])
        #expect(try titles(NoteQuery(text: "e_")) == ["underscore"])
    }

    @Test func querySyntaxInTermsIsLiteral() throws {
        try add(#"say "hello" (now) -- NEAR body:* x"#, title: "syntax")
        for text in [#""hello""#, "(now)", "--", "NEAR", "body:*", #"""#, "*"] {
            #expect(try titles(NoteQuery(text: text)) == ["syntax"], "query \(text)")
        }
    }

    // MARK: Age filter

    @Test func lastNDaysCountsTodayAsTheFirstDay() throws {
        try add("x", title: "today early", edited: Self.daysAgo(0, hour: 0))
        try add("x", title: "yesterday", edited: Self.daysAgo(1))
        try add("x", title: "six days ago", edited: Self.daysAgo(6, hour: 0))
        try add("x", title: "seven days ago", edited: Self.daysAgo(7, hour: 23))
        #expect(try titles(NoteQuery(days: 1)) == ["today early"])
        #expect(try titles(NoteQuery(days: 7)) == ["today early", "yesterday", "six days ago"])
        #expect(try titles(NoteQuery(days: nil)).count == 4)
    }

    @Test func ageAndTextCombine() throws {
        try add("deploy log", title: "recent", edited: Self.daysAgo(1))
        try add("deploy log", title: "stale", edited: Self.daysAgo(30))
        #expect(try titles(NoteQuery(text: "deploy", days: 7)) == ["recent"])
    }

    // MARK: Index stays in step

    @Test func indexFollowsEditsAndDeletes() throws {
        var note = try add("first draft", title: "draft")
        #expect(try titles(NoteQuery(text: "first")) == ["draft"])

        note.body = "second version"
        note.updatedAt = Self.now.addingTimeInterval(60)
        try store.save(note)
        #expect(try titles(NoteQuery(text: "first")).isEmpty)
        #expect(try titles(NoteQuery(text: "second")) == ["draft"])

        #expect(try store.delete(id: note.id))
        #expect(try titles(NoteQuery(text: "second")).isEmpty)
    }

    @Test func limitCapsResults() throws {
        for index in 0..<5 { try add("n", title: "\(index)", edited: Self.daysAgo(index)) }
        #expect(try titles(NoteQuery(limit: 2)) == ["0", "1"])
    }

    // MARK: Files

    @Test func reopeningAFileKeepsNotes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boopstash-tests-\(UUID().uuidString)")
            .appendingPathComponent("notes.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let note = Note(title: "kept", body: "survives", createdAt: Self.now)
        try NoteStore.open(at: url).save(note)
        let reopened = try NoteStore.open(at: url)
        #expect(try reopened.note(id: note.id) == note)
        #expect(try reopened.notes(matching: NoteQuery(text: "surviv"), now: Self.now).map(\.id) == [note.id])
    }
}

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date { lock.withLock { current } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

@Suite struct NoteStoreObservationTests {
    @Test func resultsStreamDeliversChanges() async throws {
        let store = try NoteStore.inMemory()
        var iterator = store.results(NoteQuery(text: "watched")).makeAsyncIterator()
        #expect(try await iterator.next() == [])
        let note = Note(title: "w", body: "a watched note", createdAt: Date())
        try store.save(note)
        #expect(try await iterator.next()?.map(\.id) == [note.id])
    }

    @Test func observedAgeFilterMovesOnWithTheClock() async throws {
        let store = try NoteStore.inMemory()
        let calendar = NoteStoreTests.calendar
        let today = NoteStoreTests.daysAgo(0, hour: 10)
        let clock = TestClock(NoteStoreTests.daysAgo(0, hour: 23))
        try store.save(Note(title: "today", body: "x", createdAt: today))

        var iterator = store.results(NoteQuery(days: 1), clock: { clock.now }, calendar: calendar).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.title) == ["today"])

        // Past midnight, "today" is yesterday: the next change re-fetches
        // with the new cutoff.
        let tomorrow = calendar.date(byAdding: .hour, value: 2, to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!)!
        clock.set(tomorrow)
        try store.save(Note(title: "tomorrow", body: "y", createdAt: tomorrow))
        #expect(try await iterator.next()?.map(\.title) == ["tomorrow"])
    }
}

/// The iOS store's one-time move into the App Group (#66).
@Suite struct StoreMoveTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
    var old: URL { root.appendingPathComponent("app/Boopstash", isDirectory: true) }
    var group: URL { root.appendingPathComponent("group/Boopstash", isDirectory: true) }

    func makeStore(in folder: URL, body: String) throws {
        let store = try NoteStore.open(at: folder.appendingPathComponent("notes.sqlite"))
        try store.save(Note(title: "t", body: body, createdAt: Date(), updatedAt: Date()))
        _ = try store.addAttachment(Data([1, 2, 3]), contentType: "public.png", noteID: nil)
    }

    @Test func theWholeFolderMovesOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(in: old, body: "kept")
        #expect(try NoteStore.moveStoreFolder(from: old, to: group))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let moved = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite"))
        #expect(try moved.notes(matching: NoteQuery()).map(\.body) == ["kept"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: group.appendingPathComponent("Attachments").path).count == 1)
        #expect(try NoteStore.moveStoreFolder(from: old, to: group) == false, "nothing left to move")
    }

    @Test func aStoreAlreadyThereIsNeverReplaced() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(in: old, body: "old")
        try makeStore(in: group, body: "group")
        #expect(try NoteStore.moveStoreFolder(from: old, to: group) == false)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("notes.sqlite").path), "left where it was")
        let there = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite"))
        #expect(try there.notes(matching: NoteQuery()).map(\.body) == ["group"])
    }

    @Test func anEmptyFolderThereIsReplaced() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(in: old, body: "kept")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        #expect(try NoteStore.moveStoreFolder(from: old, to: group))
    }

    @Test func otherFilesThereStopTheMove() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(in: old, body: "kept")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try Data([1]).write(to: group.appendingPathComponent("something"))
        #expect(try NoteStore.moveStoreFolder(from: old, to: group) == false)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("notes.sqlite").path))
    }

    /// A refused move keeps the notes where they are, rather than a new,
    /// empty store in the group.
    @Test func aRefusedMoveKeepsTheOldStore() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(in: old, body: "kept")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try Data([1]).write(to: group.appendingPathComponent("something"))
        let place = try NoteStore.sharedStoreFolder(own: old, group: group)
        #expect(place.folder == old && !place.inGroup)
    }

    @Test func theStoreGoesToTheGroup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(in: old, body: "kept")
        #expect(try NoteStore.sharedStoreFolder(own: old, group: group) == (group, true, 0))
        #expect(try NoteStore.sharedStoreFolder(own: old, group: group) == (group, true, 0), "already there")
    }

    @Test func aNewStoreStartsInTheGroup() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try NoteStore.sharedStoreFolder(own: old, group: group) == (group, true, 0))
    }

    /// A store in both places: the group's is used, what only the other
    /// has is copied in, and the other is kept as a backup.
    @Test func twoStoresMerge() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeStore(in: old, body: "only here")
        try makeStore(in: group, body: "in the group")
        let place = try NoteStore.sharedStoreFolder(own: old, group: group, now: Date(timeIntervalSince1970: 0))
        #expect(place.folder == group && place.inGroup && place.merged == 1)
        let merged = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite"))
        #expect(Set(try merged.notes(matching: NoteQuery()).map(\.body)) == ["only here", "in the group"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: group.appendingPathComponent("Attachments").path).count == 2)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: old.deletingLastPathComponent().path).filter { $0.hasPrefix("Boopstash-merged-") }
        #expect(backups.count == 1, "kept, renamed")
        #expect(try NoteStore.sharedStoreFolder(own: old, group: group).merged == 0, "once")
    }

    @Test func nothingToMove() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try NoteStore.moveStoreFolder(from: old, to: group) == false)
    }
}

/// A store move that fails part-way opens the notes at home (#162).
@Suite struct StoreMoveFailureTests {
    @Test func aFailedMoveLeavesTheStoreAtHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("own"), blocker = root.appendingPathComponent("blocker")
        let store = try NoteStore.open(at: own.appendingPathComponent("notes.sqlite"))
        try store.save(Note(body: "kept", createdAt: Date()))
        // The group's parent is a file: creating the folder throws.
        try Data("x".utf8).write(to: blocker)
        let result = try NoteStore.sharedStoreFolder(own: own, group: blocker.appendingPathComponent("group"))
        #expect(result.folder == own && !result.inGroup && result.merged == 0)
        #expect(try NoteStore.open(at: own.appendingPathComponent("notes.sqlite")).notes(matching: NoteQuery()).map(\.body) == ["kept"])
    }
}

/// Merging two stores (#171, #172, #173): what is not the store stays home,
/// a note in both keeps the newer edit and a copy, unsent deletions hold.
@Suite struct StoreMergeTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
    var own: URL { root.appendingPathComponent("own") }
    var group: URL { root.appendingPathComponent("group") }

    @Test func scriptsAndKeyBindingsStayHomeWhenTheStoreMoves() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try NoteStore.open(at: own.appendingPathComponent("notes.sqlite")).save(Note(body: "n", createdAt: Date()))
        try FileManager.default.createDirectory(at: own.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try Data("/**{}**/".utf8).write(to: own.appendingPathComponent("Scripts/mine.js"))
        try Data("[]".utf8).write(to: own.appendingPathComponent("keybindings.json"))
        let result = try NoteStore.sharedStoreFolder(own: own, group: group, keepingAtHome: ["Scripts", "keybindings.json"])
        #expect(result.inGroup)
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent("Scripts/mine.js").path))
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent("keybindings.json").path))
        #expect(!FileManager.default.fileExists(atPath: group.appendingPathComponent("Scripts").path))
        #expect(!FileManager.default.fileExists(atPath: own.appendingPathComponent("notes.sqlite").path))
        // A launch interrupted after the move is repaired by the next.
        try FileManager.default.moveItem(at: own.appendingPathComponent("keybindings.json"), to: group.appendingPathComponent("keybindings.json"))
        _ = try NoteStore.sharedStoreFolder(own: own, group: group, keepingAtHome: ["Scripts", "keybindings.json"])
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent("keybindings.json").path))
    }

    @Test func aMergeKeepsTheNewerEditAndTheOtherAsACopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = Note(title: "t", titleIsUserSet: true, body: "old", createdAt: Date(timeIntervalSince1970: 1000))
        var edited = shared
        edited.body = "newer at home"
        edited.updatedAt = Date(timeIntervalSince1970: 2000)
        try NoteStore.open(at: group.appendingPathComponent("notes.sqlite")).save(shared)
        try NoteStore.open(at: own.appendingPathComponent("notes.sqlite")).save(edited)
        try FileManager.default.createDirectory(at: own.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        let result = try NoteStore.sharedStoreFolder(own: own, group: group, keepingAtHome: ["Scripts"])
        #expect(result.inGroup && result.merged == 1)
        let notes = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite")).notes(matching: NoteQuery())
        #expect(notes.first { $0.id == shared.id }?.body == "newer at home")
        #expect(notes.contains { $0.title == "t (conflict)" && $0.body == "old" })
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent("Scripts").path), "scripts back from the backup")
    }

    /// A crash after the home folder became a backup leaves the scripts in
    /// the staging folder, and the next launch brings them home.
    @Test func scriptsSurviveACrashDuringTheBackupRename() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try NoteStore.open(at: group.appendingPathComponent("notes.sqlite")).save(Note(body: "g", createdAt: Date()))
        let staging = root.appendingPathComponent("own-keep")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staging.appendingPathComponent("Scripts/mine.js"))
        _ = try NoteStore.sharedStoreFolder(own: own, group: group, keepingAtHome: ["Scripts"])
        #expect(FileManager.default.fileExists(atPath: own.appendingPathComponent("Scripts/mine.js").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    /// A merge run twice (interrupted before the rename) leaves one copy,
    /// when the group's note is the newer one.
    @Test func aRepeatedMergeMakesOneConflictCopy() throws {
        let groupStore = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite"))
        let home = try NoteStore.open(at: own.appendingPathComponent("notes.sqlite"))
        let base = Note(title: "t", titleIsUserSet: true, body: "home text", createdAt: Date(timeIntervalSince1970: 1000))
        var newer = base
        newer.body = "group text"
        newer.updatedAt = Date(timeIntervalSince1970: 2000)
        try home.save(base)
        try groupStore.save(newer)
        _ = try groupStore.copyMissing(from: home)
        _ = try groupStore.copyMissing(from: home)
        let notes = try groupStore.notes(matching: NoteQuery())
        #expect(notes.filter { $0.title == "t (conflict)" }.map(\.body) == ["home text"])
        #expect(notes.first { $0.id == base.id }?.body == "group text")
        try? FileManager.default.removeItem(at: root)
    }

    /// The copy is saved before the newer note replaces the older, so a
    /// merge stopped between the two still ends with the copy when run
    /// again (the home note newer).
    @Test func aMergeStoppedAfterTheCopyCompletesOnRetry() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let groupStore = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite"))
        let home = try NoteStore.open(at: own.appendingPathComponent("notes.sqlite"))
        let base = Note(title: "t", titleIsUserSet: true, body: "group text", createdAt: Date(timeIntervalSince1970: 1000))
        var newer = base
        newer.body = "home text"
        newer.updatedAt = Date(timeIntervalSince1970: 2000)
        try groupStore.save(base)
        try home.save(newer)
        _ = try groupStore.copyMissing(from: home)
        // Stopped after the copy, before the note: the group's note as it was.
        try groupStore.save(base)
        _ = try groupStore.copyMissing(from: home)
        let notes = try groupStore.notes(matching: NoteQuery())
        #expect(notes.filter { $0.title == "t (conflict)" }.map(\.body) == ["group text"])
        #expect(notes.first { $0.id == base.id }?.body == "home text")
    }

    func deletions(_ store: NoteStore) throws -> [String] {
        try store.pendingSyncChanges().compactMap { if case .delete(.note, let name, _) = $0 { name } else { nil } }
    }

    @Test func anUnsentDeletionSurvivesTheMerge() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let doomed = Note(body: "deleted at home", createdAt: Date())
        let groupStore = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite"))
        try groupStore.save(doomed)
        let home = try NoteStore.open(at: own.appendingPathComponent("notes.sqlite"))
        try home.save(doomed)
        _ = try home.delete(id: doomed.id)
        #expect(try deletions(home) == [doomed.id.uuidString.lowercased()])
        _ = try NoteStore.sharedStoreFolder(own: own, group: group)
        let merged = try NoteStore.open(at: group.appendingPathComponent("notes.sqlite"))
        #expect(try merged.note(id: doomed.id) == nil)
        #expect(try deletions(merged) == [doomed.id.uuidString.lowercased()])
    }
}
