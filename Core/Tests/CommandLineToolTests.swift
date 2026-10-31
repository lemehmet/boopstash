import Foundation
import Testing
@testable import BoopstashCore

/// The `boopstash` command (#156).
@Suite struct CommandLineToolTests {
    typealias Tool = CommandLineTool

    func parse(_ line: String, terminal: Bool = true) throws -> Tool.Command {
        try Tool.parse(line.split(separator: " ").map(String.init), standardInputIsTerminal: terminal)
    }

    @Test func parsing() throws {
        #expect(try parse("", terminal: false) == .capture(title: nil))
        #expect(try parse("") == .help)
        #expect(try parse("--title Logs", terminal: false) == .capture(title: "Logs"))
        #expect(try parse("list --days 7 --json") == .list(days: 7, limit: 20, json: true))
        #expect(try parse("search retry backoff -n 5") == .search("retry backoff", days: nil, limit: 5, json: false))
        #expect(try parse("show 1a2b") == .show("1a2b", json: false))
        #expect(try parse("search -- --flag") == .search("--flag", days: nil, limit: 20, json: false))
        #expect(throws: Tool.UsageError.self) { try parse("list --days zero") }
        #expect(throws: Tool.UsageError.self) { try parse("search") }
        #expect(throws: Tool.UsageError.self) { try parse("frobnicate") }
        #expect(throws: Tool.UsageError.self) { try parse("--wat") }
    }

    @Test func captureKeepsInputWithARuleTitle() throws {
        let store = try NoteStore.inMemory()
        let output = Tool.run(.capture(title: nil), store: store, input: { Data("{\"a\": 1}\n".utf8) }, version: "1")
        #expect(output.status == 0 && output.wrote)
        let note = try #require(try store.notes(matching: NoteQuery()).first)
        #expect(note.body == "{\"a\": 1}\n" && !note.titleIsUserSet && !note.title.isEmpty)
        #expect(output.standardOutput == Tool.shortID(note.id) + "\n")
        #expect(note.sourceAppName == "Terminal")
    }

    @Test func inputOverTheLimitIsRefused() throws {
        let store = try NoteStore.inMemory()
        let big = Data(repeating: UInt8(ascii: "a"), count: Tool.inputLimit + 1)
        let output = Tool.run(.capture(title: nil), store: store, input: { big }, version: "1")
        #expect(output.status == 1 && !output.wrote && output.standardError.contains("5 MB"))
        #expect(try store.notes(matching: NoteQuery()).isEmpty)
    }

    @Test func aReadErrorKeepsNothing() throws {
        struct Broken: Error {}
        let store = try NoteStore.inMemory()
        let output = Tool.run(.capture(title: nil), store: store, input: { throw Broken() }, version: "1")
        #expect(output.status == 1 && !output.wrote && output.standardError.contains("could not read"))
        #expect(try store.notes(matching: NoteQuery()).isEmpty)
    }

    @Test func emptyOrBinaryInputIsRefused() throws {
        let store = try NoteStore.inMemory()
        #expect(Tool.run(.capture(title: nil), store: store, input: { Data(" \n".utf8) }, version: "1").status == 1)
        #expect(Tool.run(.capture(title: nil), store: store, input: { Data([0xff, 0xfe, 0x00]) }, version: "1").status == 1)
        #expect(try store.notes(matching: NoteQuery()).isEmpty)
    }

    @Test func listSearchAndShow() throws {
        let store = try NoteStore.inMemory()
        let now = Date()
        let retry = Note(title: "Retry", titleIsUserSet: true, body: "retry with backoff", createdAt: now)
        let other = Note(title: "Other", titleIsUserSet: true, body: "unrelated", createdAt: now.addingTimeInterval(-10 * 86400))
        try store.save(retry)
        try store.save(other)
        let list = Tool.run(.list(days: 7, limit: 20, json: false), store: store, input: { Data() }, version: "1", now: now)
        #expect(list.standardOutput.contains(Tool.shortID(retry.id)) && !list.standardOutput.contains("Other"))
        let found = Tool.run(.search("backoff", days: nil, limit: 20, json: true), store: store, input: { Data() }, version: "1", now: now)
        let decoded = try JSONSerialization.jsonObject(with: Data(found.standardOutput.utf8)) as? [[String: Any]]
        #expect(decoded?.map { $0["title"] as? String } == ["Retry"])
        #expect(Tool.run(.search("nothing-like-this", days: nil, limit: 20, json: false), store: store, input: { Data() }, version: "1").status == 1)
        let shown = Tool.run(.show(Tool.shortID(retry.id).uppercased(), json: false), store: store, input: { Data() }, version: "1")
        #expect(shown.standardOutput == "retry with backoff\n" && !shown.wrote)
        #expect(Tool.run(.show("zz", json: false), store: store, input: { Data() }, version: "1").status == 1)
    }

    // MARK: Labels (#184)

    @Test func parsingLabels() throws {
        #expect(try parse("list --label bug -l needs-review --json") == .list(days: nil, limit: 20, labels: ["bug", "needs-review"], json: true))
        #expect(try parse("search retry -l bug") == .search("retry", days: nil, limit: 20, labels: ["bug"], json: false))
        #expect(try parse("--label build-log", terminal: false) == .capture(title: nil, labels: ["build-log"]))
        #expect(try parse("capture -t Logs -l a -l b") == .capture(title: "Logs", labels: ["a", "b"]))
        // A name with a space, as a shell passes one argument.
        #expect(try Tool.parse(["list", "--label", "needs review"], standardInputIsTerminal: true)
                == .list(days: nil, limit: 20, labels: ["needs review"], json: false))
        #expect(throws: Tool.UsageError(message: "--label needs a value")) { try parse("list --label") }
        #expect(throws: Tool.UsageError(message: "-l needs a label name")) {
            try Tool.parse(["list", "-l", "  "], standardInputIsTerminal: true)
        }
        #expect(throws: Tool.UsageError.self) { try parse("show 1a2b --label bug") }
    }

    func labelledStore() throws -> (NoteStore, both: Note, bugOnly: Note, none: Note) {
        let store = try NoteStore.inMemory()
        let now = Date()
        let both = Note(title: "Both", titleIsUserSet: true, body: "both", createdAt: now)
        let bugOnly = Note(title: "Bug only", titleIsUserSet: true, body: "bug only", createdAt: now.addingTimeInterval(-60))
        let none = Note(title: "None", titleIsUserSet: true, body: "none", createdAt: now.addingTimeInterval(-120))
        for note in [both, bugOnly, none] { try store.save(note) }
        let bug = try store.createLabel(name: "bug", color: "#d73a4a")
        let review = try store.createLabel(name: "needs-review", color: "#fbca04")
        try store.assignLabel(bug.id, to: both.id)
        try store.assignLabel(review.id, to: both.id)
        try store.assignLabel(bug.id, to: bugOnly.id)
        return (store, both, bugOnly, none)
    }

    @Test func listByLabelsIsAnAndIgnoringCase() throws {
        let (store, both, bugOnly, _) = try labelledStore()
        let output = Tool.run(.list(days: nil, limit: 20, labels: ["BUG", "Needs-Review"], json: true), store: store,
                              input: { Data() }, version: "1")
        #expect(output.status == 0)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8)) as? [[String: Any]])
        #expect(decoded.map { $0["id"] as? String } == [both.id.uuidString.lowercased()])
        let labels = try #require(decoded.first?["labels"] as? [[String: String]])
        #expect(labels == [["name": "bug", "color": "#d73a4a"], ["name": "needs-review", "color": "#fbca04"]])

        let bugs = Tool.run(.list(days: nil, limit: 20, labels: ["bug"], json: false), store: store, input: { Data() }, version: "1")
        #expect(bugs.standardOutput.contains(Tool.shortID(both.id)) && bugs.standardOutput.contains(Tool.shortID(bugOnly.id)))
        #expect(!bugs.standardOutput.contains("None"))
        #expect(bugs.standardOutput.contains("  Both  [bug, needs-review]\n"))
        #expect(bugs.standardOutput.contains("  Bug only  [bug]\n"))

        let found = Tool.run(.search("o", days: nil, limit: 20, labels: ["needs-review"], json: false), store: store,
                             input: { Data() }, version: "1")
        #expect(found.status == 0 && found.standardOutput.contains(Tool.shortID(both.id)) && !found.standardOutput.contains("Bug only"))
    }

    @Test func anUnknownLabelIsAnError() throws {
        let (store, _, _, _) = try labelledStore()
        for command: Tool.Command in [.list(days: nil, limit: 20, labels: ["bug", "nosuch"], json: true),
                                      .search("bug", days: nil, limit: 20, labels: ["nosuch"], json: false)] {
            let output = Tool.run(command, store: store, input: { Data() }, version: "1")
            #expect(output.status != 0 && output.standardOutput.isEmpty)
            #expect(output.standardError == "boopstash: no label named nosuch\n")
        }
    }

    @Test func jsonAlwaysCarriesLabels() throws {
        let (store, _, _, none) = try labelledStore()
        let list = Tool.run(.list(days: nil, limit: 20, json: true), store: store, input: { Data() }, version: "1")
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(list.standardOutput.utf8)) as? [[String: Any]])
        let plain = try #require(decoded.first { $0["id"] as? String == none.id.uuidString.lowercased() })
        #expect((plain["labels"] as? [Any])?.isEmpty == true)
        let shown = Tool.run(.show(Tool.shortID(none.id), json: true), store: store, input: { Data() }, version: "1")
        let single = try #require(try JSONSerialization.jsonObject(with: Data(shown.standardOutput.utf8)) as? [String: Any])
        #expect((single["labels"] as? [Any])?.isEmpty == true && single["body"] as? String == "none")
    }

    @Test func captureLabelsTheNoteMakingMissingLabels() throws {
        let store = try NoteStore.inMemory()
        let existing = try store.createLabel(name: "Build-Log", color: "#0e8a16")
        let output = Tool.run(.capture(title: nil, labels: ["build-log", "ci", "CI"]), store: store,
                              input: { Data("error: linker failed\n".utf8) }, version: "1")
        #expect(output.status == 0 && output.wrote)
        let note = try #require(try store.notes(matching: NoteQuery()).first)
        let labels = try store.labels(of: note.id)
        // The existing label in its own case; the new one made once, with a preset colour.
        #expect(labels.map(\.name) == ["Build-Log", "ci"])
        #expect(labels.first?.id == existing.id)
        let made = try #require(labels.last)
        #expect(LabelColor.palette.contains(made.color))
        #expect(try store.labels().count == 2)
    }

    @Test func aRefusedCaptureMakesNoLabel() throws {
        let store = try NoteStore.inMemory()
        let output = Tool.run(.capture(title: nil, labels: ["build-log"]), store: store, input: { Data(" \n".utf8) }, version: "1")
        #expect(output.status == 1 && !output.wrote)
        #expect(try store.labels().isEmpty)
    }

    @Test func helpDocumentsTheLabelFlag() {
        #expect(Tool.usage.contains("--label NAME, -l NAME"))
    }
}
