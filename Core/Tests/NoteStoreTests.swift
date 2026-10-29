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
