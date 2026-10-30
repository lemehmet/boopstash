import Foundation

/// What the note list shows: an optional text filter, where it looks, an
/// optional age limit and labels. Results are always newest-edited first.
public struct NoteQuery: Hashable, Sendable {
    public enum Scope: String, CaseIterable, Sendable {
        case everywhere
        case title
        case content
    }

    public var text: String
    public var scope: Scope
    /// Notes edited within the last `days` calendar days, counting today as
    /// the first: 1 is "today", 7 is "today and the six days before". Nil is
    /// no limit.
    public var days: Int?
    /// Label IDs: a note matches only if it carries all of them. Empty is
    /// no label filter.
    public var labels: Set<UUID>
    public var limit: Int

    public init(text: String = "", scope: Scope = .everywhere, days: Int? = nil, labels: Set<UUID> = [], limit: Int = 500) {
        self.text = text
        self.scope = scope
        self.days = days
        self.labels = labels
        self.limit = limit
    }

    /// The earliest `updatedAt` the age limit admits, or nil without one.
    public func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        guard let days, days > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }

    /// Whether `note` matches this query's text without its image text: a
    /// note in the results that does not was found through an image, which
    /// the list says.
    public func matchesWithoutImages(_ note: Note) -> Bool {
        let fields: [String?] = switch scope {
        case .everywhere: [note.title, note.body, note.sourceAppName]
        case .title: [note.title]
        case .content: [note.body]
        }
        return terms.allSatisfy { term in
            fields.contains { $0?.range(of: term, options: .caseInsensitive) != nil }
        }
    }

    /// The filter split into terms. Every term must match (AND), anywhere
    /// inside a word: "ginx" finds "nginx.conf".
    public var terms: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
