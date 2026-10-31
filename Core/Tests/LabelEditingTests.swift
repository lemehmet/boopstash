import Foundation
import Testing
@testable import BoopstashCore

/// The pure logic behind the Mac's label UI (#183): name checks, the
/// Labels popover, the catalog the list reads chips from, chip contrast
/// and overflow. All stores are in memory.
@Suite struct LabelEditingTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)

    func label(_ name: String, id: UUID = UUID()) -> NoteLabel {
        NoteLabel(id: id, name: name, color: "#1d76db", createdAt: Self.start)
    }

    // MARK: Names

    @Test func emptyAndWhitespaceNamesAreRefused() {
        #expect(LabelName.problem("", among: []) == .emptyName)
        #expect(LabelName.problem("  \n\t ", among: []) == .emptyName)
        #expect(LabelName.problem(" bug ", among: []) == nil)
    }

    @Test func aNameDifferingOnlyInCaseIsADuplicate() {
        let labels = [label("Needs Review")]
        #expect(LabelName.problem("needs review", among: labels) == .duplicateName("Needs Review"))
        #expect(LabelName.problem("  NEEDS REVIEW ", among: labels) == .duplicateName("Needs Review"))
        #expect(LabelName.problem("needs reviews", among: labels) == nil)
    }

    @Test func aLabelMayBeRenamedToItsOwnNameInAnotherCase() {
        let bug = label("bug")
        let labels = [bug, label("Work")]
        #expect(LabelName.problem("BUG", among: labels, renaming: bug.id) == nil)
        #expect(LabelName.problem("work", among: labels, renaming: bug.id) == .duplicateName("Work"))
    }

    @Test func theStoreAgreesWithTheCheck() throws {
        let store = try NoteStore.inMemory()
        let bug = try store.createLabel(name: "bug", now: Self.start)
        #expect(LabelName.problem("Bug", among: try store.labels()) == .duplicateName("bug"))
        #expect(throws: LabelError.duplicateName("bug")) { try store.createLabel(name: "Bug", now: Self.start) }
        #expect(LabelName.problem("Bug", among: try store.labels(), renaming: bug.id) == nil)
        try store.renameLabel(id: bug.id, to: "Bug", now: Self.start.addingTimeInterval(1))
        #expect(try store.label(id: bug.id)?.name == "Bug")
    }

    // MARK: Store operations the Mac UI uses

    @Test func toggleDecidesInTheStoreSoTwoTogglesUndoEachOther() throws {
        let store = try NoteStore.inMemory()
        let note = Note(title: "a", body: "a", createdAt: Self.start)
        try store.save(note)
        let work = try store.createLabel(name: "work", now: Self.start)
        #expect(try store.toggleLabel(work.id, on: note.id))
        #expect(try store.toggleLabel(work.id, on: note.id) == false)
        #expect(try store.labels(of: note.id).isEmpty)
        #expect(try store.toggleLabel(work.id, on: note.id))
        #expect(try store.labels(of: note.id) == [work])
        #expect(throws: LabelError.notFound) { try store.toggleLabel(UUID(), on: note.id) }
        #expect(throws: LabelError.notFound) { try store.toggleLabel(work.id, on: UUID()) }
    }

    @Test func creatingALabelOnAMissingNoteMakesNoLabel() throws {
        let store = try NoteStore.inMemory()
        #expect(throws: LabelError.notFound) { try store.createLabel(name: "work", color: "#1d76db", on: UUID(), now: Self.start) }
        #expect(try store.labels().isEmpty)

        let note = Note(title: "a", body: "a", createdAt: Self.start)
        try store.save(note)
        let work = try store.createLabel(name: " work ", color: "#1D76DB", details: "office", on: note.id, now: Self.start)
        #expect(work.name == "work" && work.color == "#1d76db")
        #expect(try store.labels(of: note.id) == [work])
        #expect(throws: LabelError.duplicateName("work")) { try store.createLabel(name: "Work", color: "#1d76db", on: note.id) }
    }

    @Test func anEditSavesEveryFieldOrNone() throws {
        let store = try NoteStore.inMemory()
        let work = try store.createLabel(name: "work", color: "#0e8a16", now: Self.start)
        let bug = try store.createLabel(name: "bug", now: Self.start)
        #expect(throws: LabelError.duplicateName("bug")) {
            try store.updateLabel(id: work.id, name: "BUG", color: "#5319e7", details: "x", now: Self.start.addingTimeInterval(1))
        }
        #expect(try store.label(id: work.id) == work, "nothing changed")
        #expect(throws: LabelError.invalidColor("blue")) {
            try store.updateLabel(id: work.id, name: "office", color: "blue", details: "x")
        }
        #expect(try store.label(id: work.id) == work)
        #expect(throws: LabelError.notFound) { try store.updateLabel(id: UUID(), name: "x", color: "#000000", details: "") }

        try store.updateLabel(id: work.id, name: " office ", color: "#5319E7", details: "desk", now: Self.start.addingTimeInterval(2))
        let edited = try #require(try store.label(id: work.id))
        #expect(edited.name == "office" && edited.color == "#5319e7" && edited.details == "desk")
        #expect(edited.updatedAt == Self.start.addingTimeInterval(2))
        #expect(try store.label(id: bug.id) == bug)
    }

    @Test func problemsReadAsSentences() {
        #expect(LabelName.message(.emptyName) == "A label needs a name.")
        #expect(LabelName.message(.duplicateName("bug")).contains("“bug”"))
    }

    // MARK: Popover

    @Test func nothingTypedListsEveryLabelAndOffersNothing() {
        let labels = [label("bug"), label("work")]
        #expect(LabelPicker(labels: labels, typed: "").rows == labels.map(LabelPicker.Row.label))
        #expect(LabelPicker(labels: labels, typed: "   ").rows == labels.map(LabelPicker.Row.label))
    }

    @Test func typingFiltersByNameAnywhereIgnoringCase() {
        let review = label("Needs Review"), bug = label("bug"), view = label("Preview")
        let picker = LabelPicker(labels: [bug, review, view], typed: "VIEW")
        #expect(picker.rows == [.label(review), .label(view), .create("VIEW")])
    }

    @Test func aNewNameIsOfferedTrimmed() {
        let picker = LabelPicker(labels: [], typed: "  needs review ")
        #expect(picker.rows == [.create("needs review")])
        #expect(picker.target(highlighted: nil) == .create("needs review"))
    }

    @Test func anExistingNameInAnyCaseIsNotOffered() {
        let bug = label("Bug"), bugs = label("bugs")
        let picker = LabelPicker(labels: [bug, bugs], typed: "bug")
        #expect(picker.rows == [.label(bug), .label(bugs)])
        let shouted = LabelPicker(labels: [bugs, bug], typed: "BUG")
        // The exact name is highlighted, so Return toggles it, not "bugs".
        #expect(shouted.initialHighlight(typed: "BUG") == 1)
        #expect(shouted.target(highlighted: shouted.initialHighlight(typed: "BUG")) == .label(bug))
    }

    @Test func theHighlightMovesWithinTheRows() {
        let picker = LabelPicker(labels: [label("a"), label("ab")], typed: "a")
        #expect(picker.rows.count == 2)
        #expect(picker.move(nil, by: 1) == 0)
        #expect(picker.move(0, by: 1) == 1)
        #expect(picker.move(1, by: 1) == 1)
        #expect(picker.move(0, by: -1) == 0)
        #expect(picker.target(highlighted: 7) == picker.rows.first, "a stale highlight falls back to the first row")
        #expect(LabelPicker(labels: [], typed: "").rows.isEmpty)
        #expect(LabelPicker(labels: [], typed: "").move(nil, by: 1) == nil)
        #expect(LabelPicker(labels: [], typed: "").initialHighlight(typed: "") == nil)
    }

    // MARK: Catalog

    @Test func theCatalogHoldsEveryNotesLabelsInOneRead() throws {
        let store = try NoteStore.inMemory()
        let first = Note(title: "a", body: "a", createdAt: Self.start)
        let second = Note(title: "b", body: "b", createdAt: Self.start)
        let bare = Note(title: "c", body: "c", createdAt: Self.start)
        for note in [first, second, bare] { try store.save(note) }
        let work = try store.createLabel(name: "work", now: Self.start)
        let bug = try store.createLabel(name: "Bug", now: Self.start)
        try store.assignLabel(work.id, to: first.id)
        try store.assignLabel(bug.id, to: first.id)
        try store.assignLabel(work.id, to: second.id)

        let catalog = try store.labelCatalog()
        #expect(catalog.labels.map(\.name) == ["Bug", "work"])
        #expect(catalog.labels(of: first.id).map(\.name) == ["Bug", "work"], "by name, as the store lists them")
        #expect(catalog.labels(of: second.id) == [work])
        #expect(catalog.labels(of: bare.id).isEmpty)
        #expect(catalog.useCounts == [work.id: 2, bug.id: 1])
        #expect(catalog.useCounts == (try store.labelUseCounts()))
        #expect(catalog.label(id: bug.id) == bug)
    }

    @Test func aDeletedLabelLeavesTheCatalogAndTheFilter() throws {
        let store = try NoteStore.inMemory()
        let note = Note(title: "a", body: "a", createdAt: Self.start)
        try store.save(note)
        let work = try store.createLabel(name: "work", now: Self.start)
        let bug = try store.createLabel(name: "bug", now: Self.start)
        try store.assignLabel(work.id, to: note.id)
        try store.assignLabel(bug.id, to: note.id)
        try store.deleteLabel(id: work.id)

        let catalog = try store.labelCatalog()
        #expect(catalog.labels(of: note.id) == [bug])
        #expect(catalog.pruned([work.id, bug.id]) == [bug.id])
        #expect(catalog.pruned([]) == [])
    }

    @Test func anIDWithoutItsLabelIsLeftOut() throws {
        let store = try NoteStore.inMemory()
        let note = Note(title: "a", body: "a", createdAt: Self.start)
        try store.save(note)
        // As a note from iCloud can carry a label that has not arrived yet.
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO noteLabel (noteID, labelID) VALUES (?, ?)", arguments: [note.id, UUID()])
        }
        let catalog = try store.labelCatalog()
        #expect(catalog.labelIDsByNote.isEmpty)
        #expect(catalog.useCounts.isEmpty)
    }

    @Test func theCatalogIsDeliveredAgainOnEachChange() async throws {
        let store = try NoteStore.inMemory()
        let note = Note(title: "a", body: "a", createdAt: Self.start)
        try store.save(note)
        var iterator = store.labelCatalogs().makeAsyncIterator()
        #expect(try await iterator.next()?.labels.isEmpty == true)

        let work = try store.createLabel(name: "work", now: Self.start)
        #expect(try await iterator.next()?.labels == [work])
        try store.assignLabel(work.id, to: note.id)
        #expect(try await iterator.next()?.labels(of: note.id) == [work])
        try store.renameLabel(id: work.id, to: "Work", now: Self.start.addingTimeInterval(1))
        #expect(try await iterator.next()?.labels(of: note.id).map(\.name) == ["Work"])
    }

    // MARK: Colours

    @Test func chipTextMeetsContrastOnEveryPresetColour() throws {
        for color in LabelColor.palette {
            let text = LabelColor.textColor(on: color)
            let ratio = try #require(LabelColor.contrastRatio(text, color))
            #expect(ratio >= 4.5, "\(text) on \(color): \(ratio)")
        }
    }

    @Test func contrastRatiosMatchWCAG() throws {
        #expect(try #require(LabelColor.contrastRatio("#000000", "#ffffff")) == 21)
        #expect(try #require(LabelColor.contrastRatio("#777777", "#777777")) == 1)
        #expect(LabelColor.contrastRatio("#000", "#ffffff") == nil)
        #expect(LabelColor.textColor(on: "#fef2c0") == "#000000")
        #expect(LabelColor.textColor(on: "#5319e7") == "#ffffff")
    }

    @Test func shuffleNeverRepeatsTheCurrentColour() {
        var generator = SystemRandomNumberGenerator()
        for color in LabelColor.palette {
            for _ in 0..<20 {
                let next = LabelColor.random(otherThan: color, using: &generator)
                #expect(next != color)
                #expect(LabelColor.palette.contains(next))
            }
        }
        #expect(LabelColor.palette.contains(LabelColor.random(otherThan: "#123456")))
        #expect(LabelColor.random(otherThan: "#B60205", using: &generator) != "#b60205", "compared parsed")
    }

    // MARK: Saving a note with labels by name (#184)

    @Test func savingWithLabelNamesIsOneTransaction() throws {
        let store = try NoteStore.inMemory()
        let note = Note(body: "log", createdAt: Self.start)
        // A bad colour fails before anything is written: no note, no label.
        #expect(throws: LabelError.invalidColor("blue")) {
            try store.save(note, labelNames: ["new"], color: { "blue" })
        }
        #expect(try store.notes(matching: NoteQuery()).isEmpty && store.labels().isEmpty)
        #expect(throws: LabelError.emptyName) { try store.save(note, labelNames: [" "]) }
        #expect(try store.notes(matching: NoteQuery()).isEmpty)

        let saved = try store.save(note, labelNames: [" new ", "NEW"], color: { "#5319E7" }, now: Self.start)
        #expect(saved.map(\.name) == ["new"] && saved.first?.color == "#5319e7")
        #expect(try store.labels(of: note.id) == saved)
    }

    #if DEBUG
    @Test func demoNotesCarryLabels() throws {
        let store = try DemoNotes.store()
        let catalog = try store.labelCatalog()
        #expect(Set(catalog.labels.map(\.name)) == Set(DemoNotes.labels.map(\.name)))
        #expect(catalog.labelIDsByNote.count >= 3)
    }
    #endif
}

