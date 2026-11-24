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
}
