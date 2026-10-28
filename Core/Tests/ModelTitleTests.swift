import Foundation
import Testing
@testable import BoopstashCore

@Suite struct ModelTitleTests {
    @Test(arguments: [
        ("Nginx reverse proxy config", "Nginx reverse proxy config"),
        ("Title: Nginx reverse proxy config.", "Nginx reverse proxy config"),
        ("\"Kubernetes pod crash loop\"", "Kubernetes pod crash loop"),
        ("**Deploy checklist**", "Deploy checklist"),
        ("# Release notes for 2.1", "Release notes for 2.1"),
        ("“Smart quoted”", "Smart quoted"),
        ("\n\n  Two lines\nsecond line ignored", "Two lines"),
        ("Spaces    collapse   here", "Spaces collapse here"),
        ("**Title: Deploy checklist**", "Deploy checklist"),
        ("Title: **Deploy checklist**", "Deploy checklist"),
        ("## \"Title: x\"", "x"),
    ])
    func cleans(_ output: String, _ expected: String) {
        #expect(ModelTitle.clean(output) == expected)
    }

    @Test(arguments: ["", "   \n", "\"\"", "...", "**"])
    func emptyRepliesGiveNil(_ output: String) {
        #expect(ModelTitle.clean(output) == nil)
    }

    @Test func longRepliesAreCut() throws {
        let title = try #require(ModelTitle.clean(String(repeating: "word ", count: 40)))
        #expect(title.count <= RuleTitler.maxLength)
    }

    @Test func promptCarriesTheKindAndOnlyTheHead() {
        let body = String(repeating: "x", count: ModelTitle.excerptLimit) + "TAIL"
        let prompt = ModelTitle.prompt(for: body, kind: .json)
        #expect(prompt.contains("JSON"))
        #expect(!prompt.contains("TAIL"))
        #expect(prompt.hasSuffix("[…]"))
        #expect(!ModelTitle.prompt(for: "short", kind: .plain).contains("[…]"))
    }
}

@Suite struct ModelTitledHashTests {
    @Test func hashIsStableAndTracksTheBody() throws {
        #expect(Note.contentHash("abc") == Note.contentHash("abc"))
        #expect(Note.contentHash("abc") != Note.contentHash("abd"))
        var note = Note(body: "text", createdAt: Date())
        #expect(!note.hasCurrentModelTitle)
        note.modelTitledHash = Note.contentHash(note.body)
        #expect(note.hasCurrentModelTitle)
        note.body += "!"
        #expect(!note.hasCurrentModelTitle)
    }

    @Test func hashSurvivesTheStore() throws {
        let store = try NoteStore.inMemory()
        var note = Note(title: "t", body: "b", createdAt: Date())
        note.modelTitledHash = Note.contentHash("b")
        try store.save(note)
        #expect(try store.note(id: note.id)?.hasCurrentModelTitle == true)
    }
}
