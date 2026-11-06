import AppKit
import BoopstashCore

/// Find and replace in the open note, after VS Code: a widget floating at
/// the editor's top right with the query, Match Case / Whole Word / Regex,
/// "3 of 12", previous and next, and a replace row that unfolds under it.
/// Every match is highlighted; the current one is the editor's selection,
/// so Replace works on what is seen. The logic is Core's `TextFind`; this
/// owns the state, the widget and the editor's part. It replaces AppKit's
/// find bar, which has no regex, no count and other Replace semantics.
@MainActor
final class FindController {
    weak var view: BoopTextView?
    private weak var scroll: NSScrollView?
    private(set) var panel: FindPanel?

    /// The query and replacement last used in any editor in this run, so
    /// ⌘F in the next note starts from them, as VS Code's shared find state
    /// does.
    static var lastQuery = FindQuery()
    static var lastReplacement = ""

    private(set) var query = FindQuery() {
        didSet { Self.lastQuery = query }
    }
    private(set) var replacement = "" {
        didSet { Self.lastReplacement = replacement }
    }
    private(set) var matches: [NSRange] = []
    /// Why there are no matches, when the query is at fault.
    private(set) var error: String?
    private(set) var isShown = false
    private(set) var replaceShown = false

    /// What to select once a search delivers.
    enum Pending {
        case keep
        case first(from: NSRange)
        /// `steps` presses, queued while the search was in flight.
        case next(after: NSRange, steps: Int)
        case previous(before: NSRange, steps: Int)

        /// The selection the step is relative to.
        var origin: NSRange? {
            switch self {
            case .keep: nil
            case .first(let from): from
            case .next(let after, _): after
            case .previous(let before, _): before
            }
        }
    }

    /// Applied when the search delivers; dropped if the selection moves
    /// elsewhere meanwhile (a click), so a slow search never yanks a
    /// caret the user has since placed.
    private var pending: Pending = .keep
    /// Set while this controller moves the selection itself, so its own
    /// moves do not drop what is pending.
    private var selecting = false
    /// Set before an edit of the editor's own, for the search that edit
    /// triggers.
    private var pendingAfterEdit: Pending?
    /// The text changed under the matches and the search for the new text
    /// has not delivered: the ranges may not fit the text any more, so
    /// nothing is selected or drawn from them until it has.
    private var stale = false
    private var generation = 0
    private var searching: Task<Void, Never>?
    private var frameObserver: NSObjectProtocol?

    isolated deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    func attach(to scroll: NSScrollView, view: BoopTextView) {
        self.scroll = scroll
        self.view = view
        query = Self.lastQuery
        replacement = Self.lastReplacement
    }

    /// The widget, made when first needed and kept.
    private func makePanel() -> FindPanel? {
        if let panel { return panel }
        guard let scroll else { return nil }
        let panel = FindPanel(controller: self)
        scroll.addSubview(panel)
        self.panel = panel
        // Placed by frame, not constraints: SwiftUI sets the scroll view's
        // frame itself, and a constraint pass does not reliably follow
        // (seen hands-on: the widget sat over the title and the sidebar).
        scroll.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel() }
        }
        layoutPanel()
        return panel
    }

    /// Top right of the editor, clear of the vertical scroller, at the
    /// size the widget's rows want.
    func layoutPanel() {
        guard let panel, let scroll else { return }
        let bounds = scroll.bounds
        // A narrow editor (beside the preview) gets the toggles on a row of
        // their own rather than a row cut off at the close button.
        panel.setCompact(false)
        var fitting = panel.fittingSize
        if fitting.width > bounds.width - 28 {
            panel.setCompact(true)
            fitting = panel.fittingSize
        }
        let width = min(fitting.width, bounds.width - 28)
        let x = bounds.maxX - 20 - width
        let y = scroll.isFlipped ? bounds.minY + 4 : bounds.maxY - 4 - fitting.height
        let frame = NSRect(x: x, y: y, width: width, height: fitting.height)
        if panel.frame != frame { panel.frame = frame }
        // Room above the text for the first lines to scroll out from
        // under the widget (VS Code's extra space on top).
        let inset = panel.isHidden ? 0 : fitting.height + 8
        if scroll.contentInsets.top != inset {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets.top = inset
        }
    }

    // MARK: Showing

    /// ⌘F / ⌥⌘F: shows the widget, seeded from the selection or the word
    /// at the caret as VS Code does, and focuses the query (or, with the
    /// replace row asked for and a query to replace, the replacement).
    func show(replace: Bool, focus: Bool = true) {
        guard let view, let panel = makePanel() else { return }
        if replace { replaceShown = true }
        // Seeded when opening, or when the editor's selection is something
        // other than the current match: with the widget in use, ⌘F and ⌥⌘F
        // keep the query (a regex would otherwise become its own match).
        let onMatch = isShown && TextFind.index(of: view.selectedRange(), in: matches) != nil
        if !isShown || (!panel.hasFocus && !onMatch), let seed = seedText(wordAtCaret: focus) {
            query.text = TextFind.seed(seed, isRegex: query.isRegex)
        }
        isShown = true
        panel.isHidden = false
        panel.update()
        search(then: .first(from: view.selectedRange()))
        if focus { panel.focus(replace && !query.isEmpty ? .replacement : .query) }
    }

    /// Escape or the close button: the widget goes, the selection stays
    /// on the current match, and the editor has the keyboard again.
    func hide() {
        guard isShown else { return }
        isShown = false
        searching?.cancel()
        matches = []
        error = nil
        let hadFocus = panel?.hasFocus ?? false
        panel?.isHidden = true
        layoutPanel()
        if let view {
            view.needsDisplay = true
            if hadFocus { view.window?.makeFirstResponder(view) }
        }
    }

    /// The selected text, on one line; or, when asked, the word the caret
    /// is in. Nil leaves the query as it is.
    private func seedText(wordAtCaret: Bool) -> String? {
        guard let view else { return nil }
        let ns = view.string as NSString
        var range = view.selectedRange()
        if range.length == 0, wordAtCaret {
            range = view.selectionRange(forProposedRange: range, granularity: .selectByWord)
        }
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return nil }
        let text = ns.substring(with: range)
        guard !text.contains(where: \.isNewline), !text.allSatisfy(\.isWhitespace) else { return nil }
        // Beside a word the caret sits on punctuation, which is no word
        // (seen hands-on: a query of ".").
        if wordAtCaret, view.selectedRange().length == 0, !text.contains(where: { $0.isLetter || $0.isNumber }) { return nil }
        return text
    }

    // MARK: The query

    /// Typed in the widget: searched at once, and the first match from
    /// where the search started is selected, so the text follows the typing.
    func setQueryText(_ text: String) {
        guard query.text != text else { return }
        query.text = text
        panel?.update()
        guard let view else { return }
        search(then: .first(from: view.selectedRange()))
    }

    func setReplacement(_ text: String) {
        replacement = text
    }

    func toggleMatchCase() { setOptions { $0.matchCase.toggle() } }
    func toggleWholeWord() { setOptions { $0.wholeWord.toggle() } }
    func toggleRegex() { setOptions { $0.isRegex.toggle() } }

    /// The toggles, like Replace, only act with the widget shown (VS Code
    /// gates them on the widget too): a hidden query is nothing the user
    /// can see.
    private func setOptions(_ change: (inout FindQuery) -> Void) {
        guard isShown, let view else { return }
        change(&query)
        panel?.update()
        search(then: .first(from: view.selectedRange()))
    }

    /// ⌘E: the selection becomes the query, with the widget as it is.
    func useSelection() {
        guard let seed = seedText(wordAtCaret: false) else {
            NSSound.beep()
            return
        }
        query.text = TextFind.seed(seed, isRegex: query.isRegex)
        panel?.update()
        if isShown { search(then: .keep) }
    }

    func toggleReplaceRow() {
        replaceShown.toggle()
        panel?.update()
    }

    // MARK: Navigation

    /// ⌘G or Enter. With the widget closed it opens, without taking the
    /// keyboard, on the selection's text if there is one (VS Code's Find
    /// Next does the same).
    func next() {
        guard let view else { return }
        guard isShown, !stale else {
            // Opened or edited: the step is applied when the search
            // delivers; presses meanwhile add up.
            if !isShown { show(replace: false, focus: false) }
            if case .next(let after, let steps) = pending {
                pending = .next(after: after, steps: steps + 1)
            } else {
                pending = .next(after: view.selectedRange(), steps: 1)
            }
            return
        }
        guard let index = TextFind.next(after: view.selectedRange(), in: matches) else {
            NSSound.beep()
            return
        }
        select(index)
    }

    func previous() {
        guard let view else { return }
        guard isShown, !stale else {
            if !isShown { show(replace: false, focus: false) }
            if case .previous(let before, let steps) = pending {
                pending = .previous(before: before, steps: steps + 1)
            } else {
                pending = .previous(before: view.selectedRange(), steps: 1)
            }
            return
        }
        guard let index = TextFind.previous(before: view.selectedRange(), in: matches) else {
            NSSound.beep()
            return
        }
        select(index)
    }

    private func select(_ index: Int) {
        guard let view, matches.indices.contains(index) else { return }
        let range = matches[index]
        selecting = true
        view.setSelectedRange(range)
        selecting = false
        reveal(range)
        panel?.update()
    }

    /// Scrolls the match into view, and out from under the widget.
    private func reveal(_ range: NSRange) {
        guard let view else { return }
        view.scrollRangeToVisible(range)
        guard let panel, !panel.isHidden, let scroll, let rect = view.rect(for: range) else { return }
        // In the clip view's coordinates, which follow the flipped text
        // view: y grows downward and the bounds origin is the scroll offset.
        let clip = scroll.contentView
        let match = clip.convert(rect, from: view)
        let covered = clip.convert(panel.frame, from: scroll)
        guard match.intersects(covered) else { return }
        var origin = clip.bounds.origin
        origin.y = max(-scroll.contentInsets.top, origin.y - (covered.maxY + 8 - match.minY))
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Replacing

    /// Enter in the replacement, or the Replace button: the current match
    /// becomes the replacement and the next match is selected. When the
    /// selection is not on a match, the first press only finds one, as in
    /// VS Code, so nothing is replaced unseen.
    func replaceCurrent() {
        guard isShown, replaceShown, let view, view.isEditable, !query.isEmpty else { return }
        // Until the search for the edited text delivers, the matches may
        // not fit the text: step to the next one then, replace nothing.
        guard !stale else {
            next()
            return
        }
        let selection = view.selectedRange()
        guard TextFind.index(of: selection, in: matches) != nil,
              let text = try? TextFind.replacement(for: selection, in: view.string, query: query, template: replacement)
        else {
            next()
            return
        }
        // A replacement that changes nothing is a step, not an edit.
        guard (view.string as NSString).substring(with: selection) != text else {
            next()
            return
        }
        // Through the storage, as scripts and Replace All go: the edit is
        // made while the widget's field has the keyboard, which is not
        // the typing path `insertText` is for.
        // The next match after the replacement, never one at the
        // replacement's end: a zero-length match (`$`) is there again.
        pendingAfterEdit = .next(after: NSRange(location: selection.location + (text as NSString).length, length: 0), steps: 1)
        // The caret the edit leaves is the controller's own move, not the
        // user's: it must not drop the queued step.
        selecting = true
        view.apply([(selection, text)], actionName: "Replace", selectingReplacements: false)
        selecting = false
    }

    /// Every match, as one undoable edit. Matches are found again on the
    /// text as it is now, off the main thread like a format (#97), and
    /// applied only if the note is the same one and its text has not
    /// changed meanwhile. Only with the replace row shown: the query and
    /// the replacement are then in view, not ones left by another note.
    func replaceAll() {
        guard isShown, replaceShown, let view, view.isEditable, !query.isEmpty else { return }
        let snapshot = view.string
        let query = query
        let template = replacement
        let generation = view.documentGeneration
        Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> Result<[(range: NSRange, text: String)], FindError> in
                do throws(FindError) {
                    // Every match, not the widget's counting cap: a replace
                    // that stopped at 20,000 would leave the rest unsaid.
                    return .success(try TextFind.replacements(in: snapshot, for: query, template: template, limit: .max))
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, let view = self.view else { return }
            // Another note with the same text in this reused editor is not
            // the note the replacements were found in.
            guard view.documentGeneration == generation, view.string == snapshot else {
                view.showMessage?("The note changed while its matches were being replaced, so it was left as it is.")
                return
            }
            switch result {
            case .failure(let error):
                NSSound.beep()
                self.error = error.message
                self.panel?.update()
            case .success(let found):
                let ns = snapshot as NSString
                // Only what changes counts: a replacement equal to its match
                // is no edit (and `apply` makes none).
                let edits = found.filter { !Self.inChip($0.range, view.chipRanges) && ns.substring(with: $0.range) != $0.text }
                guard !edits.isEmpty else {
                    NSSound.beep()
                    return
                }
                view.apply(edits.map { ($0.range, $0.text) }, actionName: "Replace All", selectingReplacements: false)
                view.showMessage?(edits.count == 1 ? "Replaced 1 match." : "Replaced \(edits.count) matches.")
            }
        }
    }

    // MARK: The editor's part

    /// The text changed under the search: matches are found again, and the
    /// selection is left alone unless the change was a Replace.
    func textDidChange() {
        guard isShown else { return }
        stale = true
        search(then: pendingAfterEdit ?? .keep)
        pendingAfterEdit = nil
    }

    /// Another note's text in this editor.
    func documentReplaced() {
        searching?.cancel()
        matches = []
        error = nil
        guard isShown else { return }
        search(then: .keep)
    }

    func selectionDidChange() {
        guard isShown, let view else { return }
        if !selecting, let origin = pending.origin, view.selectedRange() != origin { pending = .keep }
        panel?.update()
    }

    /// The match the selection is on, for "3 of 12".
    var currentIndex: Int? {
        guard let view else { return nil }
        return TextFind.index(of: view.selectedRange(), in: matches)
    }

    var reachedLimit: Bool { matches.count >= TextFind.matchLimit }

    /// Fills the matches on screen, under the text. The current match is
    /// the selection, which the view draws over this.
    func drawHighlights(in rect: NSRect) {
        guard isShown, !stale, !matches.isEmpty, let view, let layout = view.textLayoutManager, let content = layout.textContentManager,
              let visible = SyntaxPainter.visibleRange(of: view, in: content)
        else { return }
        let origin = view.textContainerOrigin
        view.findHighlightColor.setFill()
        // Matches are sorted: binary search to the first that can be on
        // screen, one back for a match that starts above and wraps in.
        var index = max(TextFind.firstIndex(in: matches, startingAtOrAfter: visible.location) - 1, 0)
        while index < matches.count, matches[index].location <= NSMaxRange(visible) {
            defer { index += 1 }
            let match = matches[index]
            guard NSMaxRange(match) >= visible.location, let textRange = SyntaxPainter.textRange(match, in: content) else { continue }
            layout.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
                var segment = frame.offsetBy(dx: origin.x, dy: origin.y)
                // A zero-length match (`^`) shows as a thin bar.
                if segment.width < 2 { segment.size.width = 2 }
                if segment.intersects(rect) { NSBezierPath(roundedRect: segment, xRadius: 2, yRadius: 2).fill() }
                return true
            }
        }
    }

    // MARK: Searching

    /// Finds the matches off the main thread (ADR 0006: a 1 MB note must
    /// not stall the window, and a regular expression can take as long as
    /// it likes), newest search wins, then applies `pending`.
    private func search(then pending: Pending) {
        self.pending = pending
        guard let view, isShown else { return }
        // Until it delivers, the matches on hand are not the answer:
        // steps queue, nothing is drawn (so a first Enter right after
        // opening is a step, not a beep at an empty list).
        stale = true
        generation += 1
        let generation = generation
        searching?.cancel()
        let text = view.string
        let query = query
        searching = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> Result<[NSRange], FindError> in
                do throws(FindError) {
                    return .success(try TextFind.matches(in: text, for: query))
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: Result<[NSRange], FindError>) {
        switch result {
        case .success(let found):
            // Text under an attachment chip is not on screen and a
            // selection there snaps to the whole chip, so it is no match.
            let chips = view?.chipRanges ?? []
            matches = chips.isEmpty ? found : found.filter { !Self.inChip($0, chips) }
            error = nil
        case .failure(let failure):
            matches = []
            error = failure.message
        }
        stale = false
        if let view {
            switch pending {
            case .keep: break
            case .first(let from): if let index = TextFind.first(from: from, in: matches) { select(index) }
            case .next(let after, let steps):
                if let index = TextFind.next(after: after, in: matches) { select((index + steps - 1) % matches.count) }
            case .previous(let before, let steps):
                if let index = TextFind.previous(before: before, in: matches) { select((index - (steps - 1) % matches.count + matches.count) % matches.count) }
            }
            view.needsDisplay = true
        }
        pending = .keep
        panel?.update()
    }

    /// Whether a match touches an attachment reference's text.
    static func inChip(_ match: NSRange, _ chips: [NSRange]) -> Bool {
        chips.contains { chip in
            NSIntersectionRange(chip, match).length > 0 || (chip.location < match.location && match.location < NSMaxRange(chip))
        }
    }
}

extension BoopTextView {
    /// The frame of a range's text in the view's coordinates, once laid
    /// out; nil for a range with no layout (hidden in a fold).
    func rect(for range: NSRange) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let textRange = SyntaxPainter.textRange(range, in: content) else { return nil }
        layout.ensureLayout(for: textRange)
        var union: NSRect?
        layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Under the text, so the glyphs keep their colour: the system's find
    /// highlight, lightened for a themed editor's own background.
    var findHighlightColor: NSColor {
        NSColor.findHighlightColor.withAlphaComponent(activeTheme == nil ? 0.5 : 0.4)
    }
}

/// The widget. AppKit rather than a hosted SwiftUI view so the keyboard
/// focus, the field editor's Enter and Escape, and the key equivalents
/// while a field is focused are all handled in one responder.
@MainActor
final class FindPanel: NSBox, NSTextFieldDelegate {
    unowned let controller: FindController

    let queryField = NSTextField()
    let replacementField = NSTextField()
    let matchCase: NSButton
    let wholeWord: NSButton
    let regex: NSButton
    let count = NSTextField(labelWithString: "")
    let previousButton: NSButton
    let nextButton: NSButton
    let closeButton: NSButton
    let replaceToggle: NSButton
    let findRow = NSStackView()
    let togglesRow = NSStackView()
    let replaceRow = NSStackView()
    private(set) var isCompact = false
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)

    enum Field { case query, replacement }

    init(controller: FindController) {
        self.controller = controller
        matchCase = Self.toggle("Aa", tip: "Match Case (⌥⌘C)")
        wholeWord = Self.toggle("ab", tip: "Match Whole Word (⌥⌘W)")
        regex = Self.toggle(".*", tip: "Use Regular Expression (⌥⌘R)")
        previousButton = Self.symbolButton("chevron.up", tip: "Previous Match (⇧Enter, ⇧⌘G)")
        nextButton = Self.symbolButton("chevron.down", tip: "Next Match (Enter, ⌘G)")
        closeButton = Self.symbolButton("xmark", tip: "Close (Escape)")
        replaceToggle = Self.symbolButton("chevron.right", tip: "Toggle Replace (⌥⌘F)")
        super.init(frame: .zero)
        boxType = .custom
        cornerRadius = 8
        borderWidth = 1
        borderColor = .separatorColor
        fillColor = .controlBackgroundColor
        contentViewMargins = .zero
        // Not layer-backed: a layer here would back the whole scroll view,
        // gutter included, which AppKit does not expect of a ruler.
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.shadowColor.withAlphaComponent(0.25)
        self.shadow = shadow
        build()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func toggle(_ title: String, tip: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.toolTip = tip
        button.refusesFirstResponder = true
        return button
    }

    private static func symbolButton(_ name: String, tip: String) -> NSButton {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.toolTip = tip
        button.refusesFirstResponder = true
        return button
    }

    private func build() {
        for field in [queryField, replacementField] {
            field.controlSize = .small
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.delegate = self
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            // As wide as VS Code's, giving way in a narrow editor.
            let preferred = field.widthAnchor.constraint(equalToConstant: 220)
            preferred.priority = .defaultLow
            preferred.isActive = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        }
        queryField.placeholderString = "Find"
        replacementField.placeholderString = "Replace"
        queryField.nextKeyView = replacementField
        replacementField.nextKeyView = queryField

        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.lineBreakMode = .byTruncatingTail
        let steady = count.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        steady.priority = .defaultHigh
        steady.isActive = true
        // The count truncates before the buttons beside it are cut off.
        count.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        for (button, action) in [
            (matchCase, #selector(toggleMatchCase)), (wholeWord, #selector(toggleWholeWord)), (regex, #selector(toggleRegex)),
            (previousButton, #selector(goPrevious)), (nextButton, #selector(goNext)), (closeButton, #selector(close)),
            (replaceToggle, #selector(toggleReplace)), (replaceButton, #selector(replaceOne)), (replaceAllButton, #selector(replaceAll)),
        ] {
            button.target = self
            button.action = action
        }
        for button in [replaceButton, replaceAllButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.refusesFirstResponder = true
        }
        replaceButton.toolTip = "Replace (Enter)"
        replaceAllButton.toolTip = "Replace All (⌥⌘Enter)"

        findRow.setViews([replaceToggle, queryField, matchCase, wholeWord, regex, count, previousButton, nextButton, closeButton], in: .leading)
        // Under the query, with the toggle's column left empty.
        let spacer = NSView()
        let togglesSpacer = NSView()
        togglesRow.setViews([togglesSpacer], in: .leading)
        togglesRow.isHidden = true
        replaceRow.setViews([spacer, replacementField, replaceButton, replaceAllButton], in: .leading)
        for row in [findRow, togglesRow, replaceRow] {
            row.orientation = .horizontal
            row.spacing = 4
        }

        let rows = NSStackView(views: [findRow, togglesRow, replaceRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        rows.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(rows)
        if let content = contentView {
            NSLayoutConstraint.activate([
                // Once both are in the hierarchy.
                spacer.widthAnchor.constraint(equalTo: replaceToggle.widthAnchor),
                togglesSpacer.widthAnchor.constraint(equalTo: replaceToggle.widthAnchor),
                rows.topAnchor.constraint(equalTo: content.topAnchor),
                rows.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
    }

    /// Compact: Match Case, Whole Word and Regex on a row under the query.
    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        let toggles = [matchCase, wholeWord, regex]
        for toggle in toggles { (compact ? findRow : togglesRow).removeView(toggle) }
        if compact {
            for toggle in toggles { togglesRow.addView(toggle, in: .leading) }
        } else {
            for (offset, toggle) in toggles.enumerated() { findRow.insertView(toggle, at: 2 + offset, in: .leading) }
        }
        togglesRow.isHidden = !compact
    }

    /// The widget shows the controller's state; nothing is kept here.
    func update() {
        if queryField.stringValue != controller.query.text { queryField.stringValue = controller.query.text }
        if replacementField.stringValue != controller.replacement { replacementField.stringValue = controller.replacement }
        matchCase.state = controller.query.matchCase ? .on : .off
        wholeWord.state = controller.query.wholeWord ? .on : .off
        regex.state = controller.query.isRegex ? .on : .off
        replaceRow.isHidden = !controller.replaceShown
        replaceToggle.image = NSImage(systemSymbolName: controller.replaceShown ? "chevron.down" : "chevron.right", accessibilityDescription: "Toggle Replace")
        let editable = controller.view?.isEditable ?? false
        replaceButton.isEnabled = editable
        replaceAllButton.isEnabled = editable
        let matches = controller.matches.count
        if let error = controller.error {
            count.stringValue = error
            count.textColor = .systemRed
        } else if controller.query.isEmpty {
            count.stringValue = ""
            count.textColor = .secondaryLabelColor
        } else if matches == 0 {
            count.stringValue = "No results"
            count.textColor = .systemRed
        } else {
            let total = controller.reachedLimit ? "\(matches)+" : "\(matches)"
            count.stringValue = "\(controller.currentIndex.map { String($0 + 1) } ?? "?") of \(total)"
            count.textColor = .secondaryLabelColor
        }
        previousButton.isEnabled = matches > 0
        nextButton.isEnabled = matches > 0
        // The replace row and the count change the size.
        controller.layoutPanel()
    }

    func focus(_ field: Field) {
        switch field {
        case .query: queryField.selectText(nil)
        case .replacement: replacementField.selectText(nil)
        }
    }

    /// Whether a field of this widget has the keyboard.
    var hasFocus: Bool {
        Self.focused(by: window?.firstResponder) === self
    }

    // MARK: Actions

    @objc private func toggleMatchCase() { controller.toggleMatchCase() }
    @objc private func toggleWholeWord() { controller.toggleWholeWord() }
    @objc private func toggleRegex() { controller.toggleRegex() }
    @objc private func goPrevious() { controller.previous() }
    @objc private func goNext() { controller.next() }
    @objc private func close() { controller.hide() }
    @objc private func toggleReplace() { controller.toggleReplaceRow() }
    @objc private func replaceOne() { controller.replaceCurrent() }
    @objc private func replaceAll() { controller.replaceAll() }

    /// Keyboard focus moving into or out of a field counts as the
    /// editor's (AppModel): the menus that depend on it stay in step.
    func controlTextDidBeginEditing(_ notification: Notification) {
        controller.view?.onFocusChange?(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        controller.view?.onFocusChange?(false)
    }

    /// Menu commands sent to the first responder while a field has the
    /// keyboard (Format Document, Fold, Paste as Markdown) go to the editor
    /// the widget belongs to; the field editor is not on its way otherwise.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let view = controller.view, view.responds(to: action) { return view }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === queryField {
            controller.setQueryText(field.stringValue)
        } else if field === replacementField {
            controller.setReplacement(field.stringValue)
        }
    }

    /// Enter finds the next match (Shift-Enter the previous) or, in the
    /// replacement, replaces; Escape closes. A field editor delivers
    /// Shift-Return as insertLineBreak and Option-Return as
    /// insertNewlineIgnoringFieldEditor, so those are Enter too: nothing
    /// may put a line break into the query.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertLineBreak(_:)):
            if control === replacementField { controller.replaceCurrent() } else { controller.previous() }
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if control === replacementField {
                controller.replaceCurrent()
            } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                controller.previous()
            } else {
                controller.next()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            controller.hide()
            return true
        default:
            return false
        }
    }

    /// The widget a field editor is typing into, if any.
    static func focused(by responder: NSResponder?) -> FindPanel? {
        guard let editor = responder as? NSTextView, var view = editor.delegate as? NSView else { return nil }
        while let next = view.superview {
            if let panel = next as? FindPanel { return panel }
            view = next
        }
        return nil
    }
}

/// The find keys, taken before the window sees them. SwiftUI's sidebar
/// filter (`.searchable`) claims ⌘F ahead of the editor's own key
/// handling, and with a field of the widget focused the editor is not
/// the first responder at all; a local monitor runs before either. Only
/// the find family goes this way, by the editor's bindings (the preset
/// and keybindings.json); every other key keeps its path.
@MainActor
enum FindKeys {
    private static var installed = false

    static let commands: Set<EditorCommand> = [
        .find, .findAndReplace, .findNext, .findPrevious, .useSelectionForFind,
        .toggleMatchCase, .toggleWholeWord, .toggleRegex, .replaceOne, .replaceAll,
    ]

    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handles(event) }
            return handled ? nil : event
        }
    }

    /// True when the event was a find key for the focused editor or
    /// widget, and was performed.
    static func handles(_ event: NSEvent) -> Bool {
        // No modifier precondition: Emacs binds ⌃S, and keybindings.json
        // may bind anything; the keymap decides.
        guard let window = event.window, let chord = KeyChord(event: event) else { return false }
        let responder = window.firstResponder
        guard let view = responder as? BoopTextView ?? FindPanel.focused(by: responder)?.controller.view,
              let command = view.keymap.command(for: chord), commands.contains(command)
        else { return false }
        view.perform(command)
        return true
    }
}
