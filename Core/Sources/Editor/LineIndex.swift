import Foundation

/// Where each line of a text starts, in UTF-16 offsets, kept up to date
/// edit by edit: an edit costs its own length plus moving the starts after
/// it, not a scan of the whole text (#168). Lines are counted at "\n".
public struct LineIndex: Equatable, Sendable {
    public private(set) var starts: [Int] = [0]

    public init(_ text: String = "") {
        starts = [0] + Self.newlineStarts(in: text as NSString, range: NSRange(location: 0, length: (text as NSString).length))
    }

    public var count: Int { starts.count }

    /// The line holding `offset`: the last start at or before it.
    public func line(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    public func start(of line: Int) -> Int { starts[min(max(line, 0), starts.count - 1)] }

    /// After `edited` (in the new text) replaced `edited.length - delta`
    /// characters: the starts inside the old range go, the new range's are
    /// found, and the later ones move by `delta`.
    public mutating func apply(edited: NSRange, delta: Int, in text: NSString) {
        let location = edited.location
        let oldEnd = NSMaxRange(edited) - delta
        // Starts in (location, oldEnd] followed newlines the edit replaced.
        let firstRemoved = line(at: location) + 1
        var afterRemoved = firstRemoved
        while afterRemoved < starts.count, starts[afterRemoved] <= oldEnd { afterRemoved += 1 }
        let added = Self.newlineStarts(in: text, range: edited)
        let moved = starts[afterRemoved...].map { $0 + delta }
        starts.replaceSubrange(firstRemoved..., with: added + moved)
    }

    static func newlineStarts(in text: NSString, range: NSRange) -> [Int] {
        var result: [Int] = []
        var search = range
        while search.length > 0 {
            let found = text.range(of: "\n", options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            result.append(found.location + 1)
            search = NSRange(location: found.location + 1, length: NSMaxRange(range) - found.location - 1)
        }
        return result
    }
}
