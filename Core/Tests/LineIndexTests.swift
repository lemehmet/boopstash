import Foundation
import Testing
@testable import BoopstashCore

/// The editor's line index, updated edit by edit (#168).
@Suite struct LineIndexTests {
    @Test func linesAndStarts() {
        let index = LineIndex("ab\ncd\n\nef")
        #expect(index.starts == [0, 3, 6, 7])
        #expect(index.line(at: 0) == 0 && index.line(at: 3) == 1 && index.line(at: 6) == 2 && index.line(at: 99) == 3)
        #expect(index.start(of: 2) == 6)
    }

    /// Random edits, each applied incrementally, agree with indexing the
    /// result from scratch.
    @Test func incrementalEditsMatchARescan() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["", "a", "\n", "xy\nz", "\n\n", "é\n🙂", "line\n"]
        var text = "start\nof\nthe text\n"
        var index = LineIndex(text)
        for _ in 0..<2000 {
            let ns = text as NSString
            let location = Int.random(in: 0...ns.length, using: &generator)
            let length = Int.random(in: 0...min(6, ns.length - location), using: &generator)
            let replacement = pieces.randomElement(using: &generator)!
            let updated = ns.replacingCharacters(in: NSRange(location: location, length: length), with: replacement)
            let inserted = (replacement as NSString).length
            index.apply(edited: NSRange(location: location, length: inserted), delta: inserted - length, in: updated as NSString)
            text = updated
            #expect(index == LineIndex(text), "after replacing \(length) at \(location) with \(replacement.debugDescription)")
            if index != LineIndex(text) { return }
        }
    }
}
