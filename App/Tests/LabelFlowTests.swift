import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// Labels on the Mac (#183): the model behind the popover, the chips, the
/// Filter menu and Settings ▸ Labels, against an in-memory store.
@MainActor
@Suite(.serialized)
struct LabelFlowTests {
    let model: AppModel
    let notes: [Note]

    init() throws {
        let store = try NoteStore.inMemory()
        let start = Date().addingTimeInterval(-60)
        notes = try (0..<3).map { index in
            let note = Note(title: "note \(index)", body: "body \(index)", createdAt: start.addingTimeInterval(Double(index)))
            try store.save(note)
            return note
        }
        model = AppModel(store: store)
    }

    /// Waits until the observed catalog and list show what `ready` asks for.
    func settle(_ ready: () -> Bool) async throws {
        #expect(try await eventually(ready))
    }

    @Test func creatingFromThePopoverAssignsANewPresetColouredLabel() async throws {
        let note = notes[0]
        let label = try #require(model.createLabel(named: "needs review", on: note.id))
        #expect(LabelColor.palette.contains(label.color))
        try await settle { model.labels(of: note.id) == [label] }
        #expect(model.labelCatalog.labels == [label])
    }

    @Test func togglingPutsALabelOnAndTakesItOff() async throws {
        let note = notes[1]
        let work = try model.store.createLabel(name: "work")
        try await settle { model.labelCatalog.labels == [work] }
        model.toggleLabel(work.id, on: note.id)
        try await settle { model.carries(work.id, note.id) }
        model.toggleLabel(work.id, on: note.id)
        try await settle { !model.carries(work.id, note.id) }
        #expect(try model.store.labels(of: note.id).isEmpty)
    }

    @Test func twoQuickTogglesUndoEachOther() async throws {
        let note = notes[1]
        let work = try model.store.createLabel(name: "work")
        try await settle { model.labelCatalog.labels == [work] }
        // No wait between them: the catalog has not caught up with the first.
        model.toggleLabel(work.id, on: note.id)
        model.toggleLabel(work.id, on: note.id)
        #expect(try model.store.labels(of: note.id).isEmpty)
        #expect(model.banner == nil)
    }

    @Test func creatingOnAGoneNoteLeavesNoLabel() async throws {
        #expect(model.createLabel(named: "orphan", on: UUID()) == nil)
        #expect(model.banner != nil)
        #expect(try model.store.labels().isEmpty)
        // So the same name can be made afterwards.
        #expect(model.createLabel(named: "orphan", on: notes[0].id) != nil)
    }

    @Test func renamingAndRecolouringReachesEveryRow() async throws {
        let work = try model.store.createLabel(name: "work", color: "#0e8a16")
        for note in notes { try model.store.assignLabel(work.id, to: note.id) }
        try await settle { model.labelCatalog.useCounts[work.id] == 3 }
        #expect(model.saveLabel(id: work.id, name: "Work stuff", color: "#5319E7", details: " office ") == nil)
        try await settle { notes.allSatisfy { model.labels(of: $0.id).first?.name == "Work stuff" } }
        for note in notes {
            #expect(model.labels(of: note.id).first?.color == "#5319e7")
            #expect(model.labels(of: note.id).first?.details == "office")
        }
    }

    @Test func theEditorRefusesBadNamesAndColours() async throws {
        let bug = try model.store.createLabel(name: "bug")
        try await settle { model.labelCatalog.labels == [bug] }
        #expect(model.saveLabel(id: nil, name: "  ", color: "#000000", details: "") == "A label needs a name.")
        #expect(model.saveLabel(id: nil, name: "BUG", color: "#000000", details: "")?.contains("“bug”") == true)
        #expect(model.saveLabel(id: nil, name: "new", color: "#abc", details: "")?.contains("#abc") == true)
        #expect(model.saveLabel(id: bug.id, name: "Bug", color: bug.color, details: "") == nil, "its own name in another case")
        #expect(model.saveLabel(id: nil, name: "feature", color: "#1d76db", details: "") == nil)
        try await settle { model.labelCatalog.labels.map(\.name) == ["Bug", "feature"] }
    }

    @Test func checkedLabelsFilterToNotesCarryingAllOfThem() async throws {
        let a = try model.store.createLabel(name: "a")
        let b = try model.store.createLabel(name: "b")
        try model.store.assignLabel(a.id, to: notes[0].id)
        try model.store.assignLabel(b.id, to: notes[0].id)
        try model.store.assignLabel(a.id, to: notes[1].id)
        try model.store.assignLabel(b.id, to: notes[2].id)
        try await settle { model.labelCatalog.labels.count == 2 && model.notes.count == 3 }

        model.toggleLabelFilter(a.id)
        model.toggleLabelFilter(b.id)
        #expect(model.isFiltering(by: a.id) && model.isFiltering(by: b.id))
        try await settle { model.notes.map(\.id) == [notes[0].id] }
        // With the text and Edited filters too.
        model.query.text = "body 1"
        try await settle { model.notes.isEmpty }
        model.query.text = "body 0"
        model.query.days = 7
        try await settle { model.notes.map(\.id) == [notes[0].id] }
        model.toggleLabelFilter(b.id)
        #expect(model.query.labels == [a.id])
        // The Filter menu, like a chip, shows the list rather than "similar to".
        model.similarTo = notes[0].id
        model.toggleLabelFilter(b.id)
        #expect(model.similarTo == nil)
    }

    @Test func clickingAChipAddsItsLabelToTheFilter() async throws {
        let work = try model.store.createLabel(name: "work")
        try model.store.assignLabel(work.id, to: notes[2].id)
        try await settle { model.labelCatalog.labels == [work] }
        model.similarTo = notes[0].id
        model.addLabelFilter(work.id)
        #expect(model.query.labels == [work.id])
        #expect(model.similarTo == nil)
        try await settle { model.notes.map(\.id) == [notes[2].id] }
        model.addLabelFilter(UUID())
        #expect(model.query.labels == [work.id], "a label not in the catalog is not added")
    }

    @Test func deletingALabelTakesItOffNotesAndTheFilter() async throws {
        let work = try model.store.createLabel(name: "work")
        let bug = try model.store.createLabel(name: "bug")
        for note in notes { try model.store.assignLabel(work.id, to: note.id) }
        try await settle { model.labelCatalog.useCounts[work.id] == 3 }
        model.query.labels = [work.id, bug.id]
        model.deleteLabel(work.id)
        try await settle { model.query.labels == [bug.id] }
        #expect(notes.allSatisfy { model.labels(of: $0.id).isEmpty })
        #expect(model.labelCatalog.labels == [bug])
    }

    @Test func aNewNoteClearsALabelFilterThatWouldHideIt() async throws {
        let work = try model.store.createLabel(name: "work")
        try await settle { model.labelCatalog.labels == [work] }
        model.query.labels = [work.id]
        model.newNote()
        #expect(model.query.labels.isEmpty)
        let selected = try #require(model.selection)
        try await settle { model.notes.contains { $0.id == selected } }
    }
}
