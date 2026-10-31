import Foundation
import GRDB

/// The whole label catalog and which notes carry which labels, read in one
/// go (#183): the note list draws every row's chips from this, so chips
/// cost no database read per row.
public struct LabelCatalog: Equatable, Sendable {
    /// Every label, by name.
    public var labels: [NoteLabel]
    /// Each note's label IDs, in the catalog's order. Only labels in the
    /// catalog; a note without labels is absent.
    public var labelIDsByNote: [UUID: [UUID]]

    public init(labels: [NoteLabel] = [], labelIDsByNote: [UUID: [UUID]] = [:]) {
        self.labels = labels
        self.labelIDsByNote = labelIDsByNote
    }

    public func label(id: UUID) -> NoteLabel? {
        labels.first { $0.id == id }
    }

    /// A note's labels, by name.
    public func labels(of noteID: UUID) -> [NoteLabel] {
        guard let ids = labelIDsByNote[noteID] else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// How many notes carry each label; a label on none is absent.
    public var useCounts: [UUID: Int] {
        labelIDsByNote.values.reduce(into: [:]) { counts, ids in
            for id in ids { counts[id, default: 0] += 1 }
        }
    }

    /// The IDs of `filter` still in the catalog: a label deleted (or folded
    /// into a same-name one by sync) leaves the filter too.
    public func pruned(_ filter: Set<UUID>) -> Set<UUID> {
        filter.intersection(labels.map(\.id))
    }
}

extension NoteStore {
    public func labelCatalog() throws -> LabelCatalog {
        try writer.read(Self.fetchCatalog)
    }

    /// The catalog, re-delivered whenever a label or a note's labels change.
    /// Ends when the consuming task is cancelled.
    public func labelCatalogs() -> AsyncThrowingStream<LabelCatalog, any Error> {
        let values = ValueObservation.tracking(Self.fetchCatalog).removeDuplicates().values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await catalog in values { continuation.yield(catalog) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @Sendable static func fetchCatalog(_ db: Database) throws -> LabelCatalog {
        let labels = try NoteLabel.fetchAll(db, sql: "SELECT * FROM label ORDER BY nameKey, id")
        var byNote: [UUID: [UUID]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT noteLabel.noteID, noteLabel.labelID FROM noteLabel JOIN label ON label.id = noteLabel.labelID
            ORDER BY label.nameKey, label.id
            """) {
            byNote[row["noteID"], default: []].append(row["labelID"])
        }
        return LabelCatalog(labels: labels, labelIDsByNote: byNote)
    }
}

/// Checking a label name as it is typed (#183), with the store's rules
/// (ADR 0011): trimmed, not empty, and no other label with the same name
/// in any case. The store checks again on save, since sync can add a label
/// meanwhile.
public enum LabelName {
    /// Why `name` cannot be used, or nil. `renaming` is the label being
    /// renamed, which may keep its own name in another case.
    public static func problem(_ name: String, among labels: [NoteLabel], renaming: UUID? = nil) -> LabelError? {
        let key = NoteLabel.nameKey(name)
        guard !key.isEmpty else { return .emptyName }
        if let other = labels.first(where: { $0.id != renaming && NoteLabel.nameKey($0.name) == key }) {
            return .duplicateName(other.name)
        }
        return nil
    }

    /// The problem as a sentence for the editor.
    public static func message(_ problem: LabelError) -> String {
        switch problem {
        case .emptyName: "A label needs a name."
        case .duplicateName(let other): "There is already a label named “\(other)”."
        case .invalidColor(let color): "“\(color)” is not a colour like #1d76db."
        case .notFound: "The label is gone."
        }
    }
}

/// What a note's Labels popover lists for what is typed (#183): the labels
/// whose names contain it, then an offer to create it when no label has
/// that name.
public struct LabelPicker: Equatable, Sendable {
    public enum Row: Hashable, Sendable {
        case label(NoteLabel)
        /// Create a label with this (trimmed) name and put it on the note.
        case create(String)
    }

    public let rows: [Row]

    public init(labels: [NoteLabel], typed text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty ? labels : labels.filter {
            $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var rows = matches.map(Row.label)
        if LabelName.problem(trimmed, among: labels) == nil { rows.append(.create(trimmed)) }
        self.rows = rows
    }

    /// What Return acts on with `highlighted` (an index into `rows`): that
    /// row, else the first. An exact name match is first among equals, so
    /// typing a whole name and Return toggles that label.
    public func target(highlighted: Int?) -> Row? {
        if let highlighted, rows.indices.contains(highlighted) { return rows[highlighted] }
        return rows.first
    }

    /// The row to highlight when the typed text changes: one whose name is
    /// exactly what was typed, else the first.
    public func initialHighlight(typed text: String) -> Int? {
        let key = NoteLabel.nameKey(text)
        if !key.isEmpty, let exact = rows.firstIndex(where: {
            if case .label(let label) = $0 { return NoteLabel.nameKey(label.name) == key }
            return false
        }) { return exact }
        return rows.isEmpty ? nil : 0
    }

    /// The highlight moved by `step` (↑ is -1, ↓ is 1), kept in the rows.
    public func move(_ highlighted: Int?, by step: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        return max(0, min(rows.count - 1, (highlighted ?? -1) + step))
    }
}

extension LabelColor {
    /// WCAG contrast ratio between two colours, 1 to 21.
    public static func contrastRatio(_ first: String, _ second: String) -> Double? {
        guard let a = relativeLuminance(first), let b = relativeLuminance(second) else { return nil }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The text colour a chip of `background` uses: black or white.
    public static func textColor(on background: String) -> String {
        prefersDarkText(on: background) ? "#000000" : "#ffffff"
    }

    /// A palette colour other than `current`, for the editor's shuffle.
    public static func random<Generator: RandomNumberGenerator>(otherThan current: String, using generator: inout Generator) -> String {
        let others = palette.filter { $0 != parse(current) }
        return others.randomElement(using: &generator) ?? palette[0]
    }

    public static func random(otherThan current: String) -> String {
        var generator = SystemRandomNumberGenerator()
        return random(otherThan: current, using: &generator)
    }
}
