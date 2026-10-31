import Foundation
import Testing
@testable import BoopstashCore

@Suite struct ExportTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let day = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!

    func note(_ title: String, _ body: String = "body", at date: Date = day, app: String? = nil) -> Note {
        Note(title: title, body: body, createdAt: date, sourceAppName: app)
    }

    @Test func filesAreDatedAndTitled() {
        let files = NoteExport.files(for: [note("Deploy checklist")], timeZone: Self.utc)
        #expect(files.map(\.name) == ["2026-10-28 Deploy checklist.md"])
    }

    @Test func namesAreUniqueIgnoringCase() {
        let files = NoteExport.files(for: [note("Same"), note("same"), note("SAME")], timeZone: Self.utc)
        #expect(files.map(\.name) == ["2026-10-28 Same.md", "2026-10-28 same 2.md", "2026-10-28 SAME 3.md"])
    }

    @Test func unsafeCharactersAreReplaced() {
        #expect(NoteExport.safeName("a/b\\c:d*e?f\"g<h>i|j") == "a-b-c-d-e-f-g-h-i-j")
        #expect(NoteExport.safeName("  ..hidden  ") == "hidden")
        #expect(NoteExport.safeName("line\nbreak") == "line-break")
        #expect(NoteExport.safeName("///") == "Untitled")
        #expect(NoteExport.safeName(String(repeating: "x", count: 200)).count == 80)
    }

    @Test func namesFitTheFileSystemByteLimit() throws {
        let file = try #require(NoteExport.files(for: [note(String(repeating: "🙂", count: 80))], timeZone: Self.utc).first)
        #expect(file.name.utf8.count <= 255 - 4, "room for a collision counter")
        #expect(file.name.hasSuffix(".md"))
        #expect(!file.name.contains("\u{FFFD}"), "no split characters")
    }

    /// Pins behaviour that comes from String equality being canonical
    /// equivalence, not from the key: a key that broke it (raw scalars,
    /// for instance) would fail here.
    @Test func canonicallyEquivalentTitlesCollideLikeAPFS() {
        let files = NoteExport.files(for: [note("caf\u{E9}"), note("cafe\u{301}")], timeZone: Self.utc)
        #expect(Set(files.map(\.name)).count == 2)
        #expect(files[1].name.hasSuffix(" 2.md"), "got \(files.map(\.name))")
    }

    @Test func finalSigmaCollidesLikeAPFS() {
        let files = NoteExport.files(for: [note("οσ"), note("ος")], timeZone: Self.utc)
        #expect(Set(files.map(\.name)).count == 2)
        #expect(files[1].name.hasSuffix(" 2.md"), "got \(files.map(\.name))")
    }

    @Test func yamlEscapesLineBreaksAndControls() {
        #expect(NoteExport.quoted("a\nb") == #""a\nb""#)
        #expect(NoteExport.quoted("tab\there") == #""tab\there""#)
        #expect(NoteExport.quoted("nul\u{0}x\u{1}") == #""nul\0x\x01""#)
        #expect(NoteExport.quoted("sep\u{2028}\u{2029}\u{85}") == #""sep\L\P\N""#)
        #expect(NoteExport.quoted("non\u{FFFE}\u{FFFF}\u{FEFF}") == #""non\uFFFE\uFFFF\uFEFF""#)
        #expect(NoteExport.quoted("del\u{7F}c1\u{9F}") == #""del\x7Fc1\x9F""#)
        #expect(NoteExport.quoted("astral 𝄞 \u{1FFFE}") == #""astral 𝄞 \#u{1FFFE}""#, "astral scalars are printable in YAML")
        #expect(NoteExport.quoted("café 🙂") == #""café 🙂""#)
    }

    @Test func untitledNotesGetAName() {
        #expect(NoteExport.files(for: [note("")], timeZone: Self.utc).first?.name == "2026-10-28 Untitled.md")
    }

    @Test func frontMatterQuotesValuesAndKeepsTheBody() {
        let n = note(#"Title: with "quotes""#, "line one\nline two", app: "Terminal")
        let document = NoteExport.document(for: n)
        #expect(document.hasPrefix("---\ntitle: \"Title: with \\\"quotes\\\"\"\n"))
        #expect(document.contains("source: \"Terminal\"\n"))
        #expect(document.contains("id: \(n.id.uuidString)\n"))
        #expect(document.hasSuffix("---\n\nline one\nline two\n"))
    }

    @Test func filesAreInCreationOrder() {
        let older = note("old", at: Self.day.addingTimeInterval(-86_400))
        let files = NoteExport.files(for: [note("new"), older], timeZone: Self.utc)
        #expect(files.map(\.name) == ["2026-10-27 old.md", "2026-10-28 new.md"])
    }

    // MARK: Labels (#184)

    @Test func noLabelsNoLabelsLine() {
        #expect(!NoteExport.document(for: note("t")).contains("labels:"))
        #expect(!NoteExport.document(for: note("t"), labels: []).contains("labels:"))
    }

    @Test func labelsAreAFlowSequenceQuotedWhereYAMLNeedsIt() {
        let n = note("t", app: "Terminal")
        #expect(NoteExport.document(for: n, labels: ["bug"]).contains("source: \"Terminal\"\nlabels: [bug]\nid: "))
        #expect(NoteExport.document(for: n, labels: ["bug", "needs review"]).contains("\nlabels: [bug, \"needs review\"]\n"))
        #expect(NoteExport.flowScalar("build-log") == "build-log")
        #expect(NoteExport.flowScalar("v2.4") == "v2.4")
        #expect(NoteExport.flowScalar("a: b") == #""a: b""#)
        #expect(NoteExport.flowScalar("#triage") == ##""#triage""##)
        #expect(NoteExport.flowScalar(#"say "hi""#) == #""say \"hi\"""#)
        #expect(NoteExport.flowScalar("a,b") == #""a,b""#)
        #expect(NoteExport.flowScalar("[x]") == #""[x]""#)
        // Read as a boolean, null or number when bare.
        #expect(NoteExport.flowScalar("Yes") == #""Yes""#)
        #expect(NoteExport.flowScalar("null") == #""null""#)
        #expect(NoteExport.flowScalar("123") == #""123""#)
        #expect(NoteExport.flowScalar("-1") == #""-1""#)
        #expect(NoteExport.flowScalar("café") == #""café""#)
    }

    @Test func filesTakeEachNotesLabelsFromTheCatalog() throws {
        let store = try NoteStore.inMemory()
        let labelled = note("labelled"), plain = note("plain")
        try store.save(labelled)
        try store.save(plain)
        let review = try store.createLabel(name: "needs review", color: "#fbca04")
        let bug = try store.createLabel(name: "bug", color: "#d73a4a")
        try store.assignLabel(review.id, to: labelled.id)
        try store.assignLabel(bug.id, to: labelled.id)
        let files = NoteExport.files(for: [labelled, plain], labels: try store.labelCatalog(), timeZone: Self.utc)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.contents) })
        #expect(byName["2026-10-28 labelled.md"]?.contains("\nlabels: [bug, \"needs review\"]\n") == true)
        #expect(byName["2026-10-28 plain.md"]?.contains("labels:") == false)
    }
}
