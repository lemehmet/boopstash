import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Folding in the editor (#155): hidden lines leave layout, the text stays.
@MainActor
@Suite(.serialized)
struct FoldingTests {
    let json = """
        {
          "a": [
            1,
            2
          ],
          "b": 3
        }
        """

    func host(_ text: String) async throws -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text, syntax: .language(.json))
        try await eventually { !view.folding.regions.isEmpty }
        return (window, view)
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    /// Paragraphs laid out now, by enumerating the layout's fragments.
    func laidOutLines(_ view: BoopTextView) -> Int {
        guard let layout = view.textLayoutManager else { return 0 }
        layout.ensureLayout(for: layout.documentRange)
        var count = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { _ in
            count += 1
            return true
        }
        return count
    }

    @Test func foldingHidesTheBlockAndKeepsTheText() async throws {
        let (window, view) = try await host(json)
        defer { window.close() }
        #expect(laidOutLines(view) == 7)
        view.setSelectedRange(NSRange(location: 3, length: 0)) // in line 1
        #expect(view.perform(.fold))
        #expect(view.folding.folded == [1])
        #expect(laidOutLines(view) == 5, "lines 2 and 3 are hidden")
        #expect(view.string == json)
        #expect(view.perform(.unfoldAll))
        #expect(laidOutLines(view) == 7)
    }

    @Test func foldAllKeepsTheOuterBlocksFirstLine() async throws {
        let (window, view) = try await host(json)
        defer { window.close() }
        view.foldAll(nil)
        #expect(laidOutLines(view) == 2, "the opening and closing braces")
    }

    @Test func anEditAboveMovesTheFold() async throws {
        let (window, view) = try await host(json)
        defer { window.close() }
        view.folding.fold(at: 1)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        #expect(view.folding.folded == [2])
        #expect(laidOutLines(view) == 6)
        // The next parse agrees, and the fold stays.
        try await eventually { view.folding.regions.contains { $0.startLine == 2 && $0.hidden == 3...4 } }
        #expect(view.folding.folded == [2])
    }

    @Test func aSelectionIntoHiddenLinesOpensTheFold() async throws {
        let (window, view) = try await host(json)
        defer { window.close() }
        view.folding.fold(at: 1)
        let hidden = (json as NSString).range(of: "2").location
        view.setSelectedRange(NSRange(location: hidden, length: 0))
        #expect(view.folding.folded.isEmpty)
    }

    @Test func anotherNoteStartsUnfolded() async throws {
        let (window, view) = try await host(json)
        defer { window.close() }
        view.folding.foldAll()
        view.load("plain\n  indented\n")
        #expect(view.folding.folded.isEmpty)
        try await eventually { view.folding.regions == [FoldRegion(startLine: 0, hidden: 1...1)] }
    }
}
