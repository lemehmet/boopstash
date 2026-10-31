import BoopstashCore
import Foundation

/// Labels on the Mac (#183): the catalog the list and menus read, putting
/// labels on notes, filtering by them, and the Settings editor's changes.
/// Each change goes to the store; the catalog observation brings it back.
extension AppModel {
    func observeLabels() {
        labelObservation?.cancel()
        let values = store.labelCatalogs()
        labelObservation = Task { [weak self] in
            do {
                for try await catalog in values {
                    guard let self else { return }
                    self.labelCatalog = catalog
                    // A label deleted here, elsewhere or folded into a
                    // same-name one leaves the filter too.
                    let kept = catalog.pruned(self.query.labels)
                    if kept != self.query.labels { self.query.labels = kept }
                }
            } catch {
                self?.banner = "Could not read labels: \(error.localizedDescription)"
            }
        }
    }

    func labels(of noteID: UUID) -> [NoteLabel] {
        labelCatalog.labels(of: noteID)
    }

    func carries(_ labelID: UUID, _ noteID: UUID) -> Bool {
        labelCatalog.labelIDsByNote[noteID]?.contains(labelID) ?? false
    }

    /// Puts the label on the note, or takes it off.
    func toggleLabel(_ labelID: UUID, on noteID: UUID) {
        do {
            if carries(labelID, noteID) {
                try store.unassignLabel(labelID, from: noteID)
            } else {
                try store.assignLabel(labelID, to: noteID)
            }
        } catch {
            banner = "Could not change the note's labels: \(Self.describe(error))"
        }
    }

    /// The popover's "Create label": a new label with a preset colour, put
    /// on the note.
    @discardableResult
    func createLabel(named name: String, on noteID: UUID) -> NoteLabel? {
        do {
            let label = try store.createLabel(name: name, color: LabelColor.random())
            try store.assignLabel(label.id, to: noteID)
            return label
        } catch {
            banner = "Could not create the label: \(Self.describe(error))"
            return nil
        }
    }

    // MARK: Filter

    func isFiltering(by labelID: UUID) -> Bool {
        query.labels.contains(labelID)
    }

    func toggleLabelFilter(_ labelID: UUID) {
        if query.labels.contains(labelID) { query.labels.remove(labelID) } else { query.labels.insert(labelID) }
    }

    /// A chip clicked in a row: its label joins the filter.
    func addLabelFilter(_ labelID: UUID) {
        guard labelCatalog.label(id: labelID) != nil else { return }
        // A filter shows the list, not "similar to" (#157).
        similarTo = nil
        query.labels.insert(labelID)
    }

    // MARK: Settings ▸ Labels

    /// Saves the editor's label: a new one when `id` is nil. Returns why it
    /// could not, or nil.
    func saveLabel(id: UUID?, name: String, color: String, details: String) -> String? {
        if let problem = LabelName.problem(name, among: labelCatalog.labels, renaming: id) {
            return LabelName.message(problem)
        }
        guard let parsed = LabelColor.parse(color) else { return LabelName.message(.invalidColor(color)) }
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let id {
                try store.renameLabel(id: id, to: name)
                try store.setLabelColor(id: id, parsed)
                try store.setLabelDetails(id: id, details)
            } else {
                try store.createLabel(name: name, color: parsed, details: details)
            }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func deleteLabel(_ id: UUID) {
        do {
            try store.deleteLabel(id: id)
        } catch {
            banner = "Could not delete the label: \(Self.describe(error))"
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? LabelError { return LabelName.message(error) }
        return error.localizedDescription
    }
}
