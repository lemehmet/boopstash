import AppKit
import BoopstashCore

/// Folding (#155): blocks Core finds (`FoldRegions`) can be collapsed to
/// their first line. Folds are the view's alone: the note's text never
/// changes, so saving, search, copy, undo and export always see all of it.
/// Hidden lines are left out of layout by the content manager's delegate.
@MainActor
final class Folding: NSObject, NSTextContentManagerDelegate {
    weak var view: BoopTextView?
    /// What can fold, for the current text.
    private(set) var regions: [FoldRegion] = []
    /// The first lines of folded regions.
    private(set) var folded: Set<Int> = []
    /// Where each line starts (UTF-16), for finding a paragraph's line.
    private var lines = LineIndex()
    /// Lines left out of layout.
    private var hiddenLines = IndexSet()
    var onChange: () -> Void = {}

    // MARK: State

    /// A new document: no folds, and its lines.
    func load(_ text: String) {
        lines = LineIndex(text)
        regions = []
        setFolded([])
    }

    /// Blocks from the latest parse. A fold whose block went away opens.
    func setRegions(_ new: [FoldRegion]) {
        regions = new
        let kept = folded.intersection(new.map(\.startLine))
        setFolded(kept)
    }

    /// After an edit (`edited` in the new text, `delta` longer): folds below
    /// move with their lines, one the edit touches opens. The regions move
    /// too, until the next parse replaces them.
    func edited(_ edited: NSRange, delta: Int, text: String) {
        let oldLocation = edited.location
        let oldEnd = NSMaxRange(edited) - delta
        let first = line(at: oldLocation)
        let last = line(at: oldEnd)
        let removed = last - first
        let added = (text as NSString).substring(with: edited).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        let shift = added - removed
        // Incremental: a keystroke must not rescan a large note (#168).
        lines.apply(edited: edited, delta: delta, in: text as NSString)
        regions = regions.compactMap { region in
            if region.hidden.upperBound < first { return region }
            guard region.startLine > last else { return nil }
            return region.shifted(by: shift)
        }
        let starts = Set(regions.map(\.startLine))
        setFolded(Set(folded.compactMap { start -> Int? in
            if start < first { return starts.contains(start) ? start : nil }
            if start > last { return start + shift }
            return nil
        }))
    }

    // MARK: Commands

    func line(at offset: Int) -> Int { lines.line(at: offset) }

    func isFolded(_ region: FoldRegion) -> Bool { folded.contains(region.startLine) }

    func toggle(_ region: FoldRegion) {
        var next = folded
        if next.contains(region.startLine) { next.remove(region.startLine) } else { next.insert(region.startLine) }
        setFolded(next)
    }

    func fold(at line: Int) {
        // The innermost open region around the line.
        guard let region = regions.filter({ $0.lines.contains(line) && !folded.contains($0.startLine) })
            .max(by: { $0.startLine < $1.startLine }) else { return }
        setFolded(folded.union([region.startLine]))
    }

    /// Opens the folds around the line, its visible closing line included.
    func unfold(at line: Int) {
        let opened = folded.filter { start in
            regions.first { $0.startLine == start }?.lines.contains(line) == true
        }
        if !opened.isEmpty { setFolded(folded.subtracting(opened)) }
    }

    func foldAll() { setFolded(Set(regions.map(\.startLine))) }
    func unfoldAll() { setFolded([]) }

    func isHidden(_ line: Int) -> Bool { hiddenLines.contains(line) }

    /// A selection that starts or ends in hidden lines opens their folds, so
    /// the caret is never somewhere unseen (Find, an undo). One that spans a
    /// fold leaves it folded.
    func reveal(_ range: NSRange) {
        guard !hiddenLines.isEmpty else { return }
        let ends = [line(at: range.location), line(at: NSMaxRange(range))].filter(hiddenLines.contains)
        guard !ends.isEmpty else { return }
        let opened = folded.filter { start in
            guard let region = regions.first(where: { $0.startLine == start }) else { return false }
            return ends.contains { region.hidden.contains($0) }
        }
        if !opened.isEmpty { setFolded(folded.subtracting(opened)) }
    }

    private func setFolded(_ next: Set<Int>) {
        folded = next
        var hidden = IndexSet()
        for region in regions where folded.contains(region.startLine) {
            hidden.insert(integersIn: region.hidden.lowerBound..<(region.hidden.upperBound + 1))
        }
        if hidden != hiddenLines {
            hiddenLines = hidden
            moveSelectionOutOfHiddenLines()
            if let view, let layout = view.textLayoutManager {
                layout.invalidateLayout(for: layout.documentRange)
                layout.textViewportLayoutController.layoutViewport()
                view.needsDisplay = true
            }
        }
        onChange()
    }

    /// A fold never hides the caret: an end of the selection in hidden
    /// lines moves to the end of the fold's first line, so typing never
    /// edits text that cannot be seen.
    private func moveSelectionOutOfHiddenLines() {
        guard let view, !hiddenLines.isEmpty else { return }
        let ranges = view.selectedRanges.map(\.rangeValue)
        let moved = ranges.map { range -> NSRange in
            let ends = [range.location, NSMaxRange(range)].map(visibleOffset)
            return NSRange(location: ends[0], length: max(ends[1] - ends[0], 0))
        }
        guard moved != ranges else { return }
        view.setSelectedRanges(moved.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
    }

    /// `offset`, or the end of the visible line before it when hidden.
    private func visibleOffset(_ offset: Int) -> Int {
        var line = line(at: offset)
        guard hiddenLines.contains(line) else { return offset }
        while line > 0, hiddenLines.contains(line) { line -= 1 }
        // The end of that line, before its "\n".
        return start(of: line + 1) - 1
    }

    // MARK: NSTextContentManagerDelegate

    nonisolated func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                                        options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard let range = textElement.elementRange else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        return MainActor.assumeIsolated { !hiddenLines.contains(line(at: offset)) }
    }
}

/// The gutter: a disclosure arrow beside each line that starts a block.
final class FoldGutter: NSRulerView {
    weak var editor: BoopTextView?

    init(scrollView: NSScrollView, editor: BoopTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 14
        clientView = editor
        // Views no longer clip to their bounds by default: the gutter's fill
        // would paint over the text beside it.
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    /// Each visible block start: its region and the line's frame here.
    private func visibleStarts() -> [(FoldRegion, NSRect)] {
        guard let editor, let layout = editor.textLayoutManager, let content = layout.textContentManager else { return [] }
        let visible = editor.visibleRect
        // Only blocks starting in the lines on screen: the fragments at the
        // top and bottom of the view give their range.
        let origin = editor.textContainerOrigin
        func offset(atY y: CGFloat) -> Int? {
            layout.textLayoutFragment(for: CGPoint(x: 0, y: y - origin.y)).map {
                content.offset(from: content.documentRange.location, to: $0.rangeInElement.location)
            }
        }
        let first = editor.folding.line(at: offset(atY: visible.minY) ?? 0)
        let last = offset(atY: visible.maxY).map { editor.folding.line(at: $0) } ?? editor.folding.lineCount - 1
        var found: [(FoldRegion, NSRect)] = []
        for region in editor.folding.regions(startingIn: first...last) {
            guard region.startLine < editor.folding.lineCount, !editor.folding.isHidden(region.startLine),
                  let location = content.location(content.documentRange.location, offsetBy: editor.folding.start(of: region.startLine)),
                  let fragment = layout.textLayoutFragment(for: location)
            else { continue }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: editor.textContainerOrigin.y)
            guard frame.maxY >= visible.minY, frame.minY <= visible.maxY else { continue }
            let firstLine = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            found.append((region, NSRect(x: 0, y: convert(NSPoint(x: 0, y: frame.minY), from: editor).y, width: ruleThickness, height: firstLine)))
        }
        return found
    }

    /// The editor's own background, not a ruler's, with no edge line.
    override func draw(_ dirtyRect: NSRect) {
        guard let editor else { return }
        (editor.drawsBackground ? editor.backgroundColor : NSColor.textBackgroundColor).setFill()
        dirtyRect.intersection(bounds).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        for (region, frame) in visibleStarts() {
            let arrow = editor.folding.isFolded(region) ? "▸" : "▾"
            let size = arrow.size(withAttributes: attributes)
            arrow.draw(at: NSPoint(x: (ruleThickness - size.width) / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (region, _) = visibleStarts().first(where: { $0.1.insetBy(dx: 0, dy: -2).contains(NSPoint(x: $0.1.midX, y: point.y)) }) else { return }
        editor?.folding.toggle(region)
    }
}

extension Folding {
    /// Regions are sorted by first line: a binary search finds the first.
    func regions(startingIn lines: ClosedRange<Int>) -> ArraySlice<FoldRegion> {
        var low = 0, high = regions.count
        while low < high {
            let middle = (low + high) / 2
            if regions[middle].startLine < lines.lowerBound { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < regions.count, regions[end].startLine <= lines.upperBound { end += 1 }
        return regions[low..<end]
    }

    var lineCount: Int { lines.count }
    func start(of line: Int) -> Int { lines.start(of: line) }
}
