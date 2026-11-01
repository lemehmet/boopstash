import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// How model titles reach notes, with a stand-in for Apple Intelligence.
@MainActor
@Suite(.serialized)
struct ModelTitleFlowTests {
    let model: AppModel

    init() throws {
        model = AppModel(store: try .inMemory())
        model.modelTitlesEnabled = { true }
        model.modelTitlesAvailable = { true }
    }

    func onlyNote() throws -> Note? {
        try model.store.notes(matching: NoteQuery()).first
    }

    @Test func aModelReplyBecomesTheTitle() async throws {
        model.modelTitler = { _, _ in "Deploy checklist" }
        model.save("step one\nstep two", origin: .menu)
        #expect(try await eventually { try onlyNote()?.title == "Deploy checklist" })
        #expect(try onlyNote()?.hasCurrentModelTitle == true)
    }

    /// #15: a failure is not a title, and the text is asked about again.
    @Test func aFailedReplyIsNotRecordedAndIsRetried() async throws {
        var calls = 0
        model.modelTitler = { _, _ in calls += 1; return nil }
        model.save("step one\nstep two", origin: .menu)
        #expect(try await eventually { calls == 1 })
        try await Task.sleep(for: .milliseconds(100))
        let note = try #require(try onlyNote())
        #expect(note.title == "step one", "the rule title stays")
        #expect(note.modelTitledHash == nil, "a failure is not recorded as a model title")
        model.requestModelTitle(for: note)
        #expect(try await eventually { calls == 2 }, "the same text is asked about again")
    }

    /// #16: switching the setting off discards a reply already on its way.
    @Test func turningTitlesOffDiscardsAPendingReply() async throws {
        var release: CheckedContinuation<Void, Never>?
        var asked = false
        model.modelTitler = { _, _ in
            asked = true
            await withCheckedContinuation { release = $0 }
            return "Late title"
        }
        model.save("step one\nstep two", origin: .menu)
        #expect(try await eventually { asked })
        model.modelTitlesEnabled = { false }
        release?.resume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try onlyNote()?.title == "step one")
    }
}
