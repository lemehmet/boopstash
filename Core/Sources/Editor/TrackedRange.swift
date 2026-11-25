import Foundation

/// A range of text followed through later edits, for work that comes back
/// after a moment and must find the place it was started on (#243).
public enum TrackedRange {
    /// Where `range` is after one edit, or nil when the edit touched it.
    /// `editedRange` and `delta` are what `NSTextStorage` reports: the
    /// range the edit left behind in the new text, and the change in length.
    public static func adjusted(_ range: NSRange, editedRange: NSRange, delta: Int) -> NSRange? {
        let oldEnd = editedRange.location + editedRange.length - delta
        if oldEnd <= range.location {
            return NSRange(location: range.location + delta, length: range.length)
        }
        if editedRange.location >= NSMaxRange(range) { return range }
        return nil
    }

    /// Where a followed range is after the whole text was replaced by
    /// another version of the same document (#255).
    public enum Reloaded: Equatable, Sendable {
        case found(NSRange)
        /// The new text has nothing like it.
        case gone
        /// Which place in the new text it is cannot be told.
        case ambiguous
    }

    /// A replaced text keeps no offsets, so the range is found again by
    /// what it held: `before` is how many places in the old text held the
    /// same thing, `candidates` are the places in the new text that do.
    /// Only one place before and one after can be told to be the same:
    /// with several before, the one left may be another of them.
    public static func reloaded(before: Int, among candidates: [NSRange]) -> Reloaded {
        if candidates.isEmpty { return .gone }
        return before == 1 && candidates.count == 1 ? .found(candidates[0]) : .ambiguous
    }
}
