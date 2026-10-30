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
}
