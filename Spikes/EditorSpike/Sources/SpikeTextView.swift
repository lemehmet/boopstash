import AppKit

/// A key combination: the key as AppKit reports it ignoring modifiers, plus
/// the device-independent modifier flags that matter for bindings.
struct KeyChord: Hashable {
    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    let key: String
    let modifiers: UInt

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
    }

    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        self.init(key, event.modifierFlags)
    }

    static func function(_ scalar: Int, _ modifiers: NSEvent.ModifierFlags = []) -> KeyChord {
        KeyChord(String(Character(UnicodeScalar(scalar)!)), modifiers)
    }
}

/// What a chord does. The real app's presets are data in Core; the spike only
/// needs enough of them to prove the text view lets us own every key.
enum EditorAction: Equatable {
    case selector(Selector)
    case duplicateLine
    case toggleFold
    case probe(String)
}

/// A TextKit 2 `NSTextView` with every automatic substitution off and key
/// handling routed through a table.
final class SpikeTextView: NSTextView {
    var keymap: [KeyChord: EditorAction] = SpikeTextView.vsCode
    var indentUnit = "    "
    let folds = FoldController()
    /// Records `.probe` actions so tests can see that a chord reached us.
    private(set) var probes: [String] = []

    static let vsCode: [KeyChord: EditorAction] = [
        // AppKit's default Home/End scroll the document without moving the
        // caret. VS Code (and every Linux editor) moves to the line's ends.
        .function(NSHomeFunctionKey): .selector(#selector(moveToBeginningOfLine(_:))),
        .function(NSEndFunctionKey): .selector(#selector(moveToEndOfLine(_:))),
        .function(NSHomeFunctionKey, .shift): .selector(#selector(moveToBeginningOfLineAndModifySelection(_:))),
        .function(NSEndFunctionKey, .shift): .selector(#selector(moveToEndOfLineAndModifySelection(_:))),
        .function(NSDownArrowFunctionKey, [.shift, .option]): .duplicateLine,
        KeyChord("[", [.command, .option]): .toggleFold,
        KeyChord("]", [.command, .option]): .toggleFold,
        // Claimed by AppKit's automatic Edit ▸ Emoji & Symbols item. Bound here
        // only to prove a view can take a chord before the menu sees it.
        KeyChord(" ", [.command, .control]): .probe("ctrl-cmd-space"),
    ]

    static func make(frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 400)) -> (NSScrollView, SpikeTextView) {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // `init(frame:textContainer: nil)` builds a TextKit 1 view; this is
        // the initializer that guarantees TextKit 2.
        let view = SpikeTextView(usingTextLayoutManager: true)
        view.frame = frame
        view.minSize = NSSize(width: 0, height: frame.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.allowsUndo = true
        view.disableSubstitutions()
        view.textContentStorage?.delegate = view.folds
        scroll.documentView = view
        return (scroll, view)
    }

    // MARK: - Substitutions

    func disableSubstitutions() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none
    }

    // Edit ▸ Substitutions would turn these back on, and AppKit persists the
    // choice in user defaults for every text view. Refuse the toggles and grey
    // the menu items out.
    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {}
    override func toggleAutomaticDashSubstitution(_ sender: Any?) {}
    override func toggleAutomaticTextReplacement(_ sender: Any?) {}
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {}
    override func toggleAutomaticLinkDetection(_ sender: Any?) {}
    override func toggleAutomaticDataDetection(_ sender: Any?) {}
    override func toggleSmartInsertDelete(_ sender: Any?) {}
    override func toggleAutomaticTextCompletion(_ sender: Any?) {}

    static let refusedToggles: Set<Selector> = [
        #selector(toggleAutomaticQuoteSubstitution(_:)),
        #selector(toggleAutomaticDashSubstitution(_:)),
        #selector(toggleAutomaticTextReplacement(_:)),
        #selector(toggleAutomaticSpellingCorrection(_:)),
        #selector(toggleAutomaticLinkDetection(_:)),
        #selector(toggleAutomaticDataDetection(_:)),
        #selector(toggleSmartInsertDelete(_:)),
        #selector(toggleAutomaticTextCompletion(_:)),
    ]

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.refusedToggles.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        if let chord = KeyChord(event: event), let action = keymap[chord] {
            perform(action)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let chord = KeyChord(event: event), let action = keymap[chord] {
            perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func perform(_ action: EditorAction) {
        switch action {
        case .selector(let selector): doCommand(by: selector)
        case .duplicateLine: duplicateLine()
        case .toggleFold: toggleFoldAtCaret()
        case .probe(let name): probes.append(name)
        }
    }

    // MARK: - Indentation

    /// Tab with a multi-line selection indents every line it touches, as one
    /// undo step. Without one it inserts the indent unit at the caret.
    override func insertTab(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let lines = ns.lineRange(for: selection)
        let spansLines = ns.substring(with: selection).contains("\n")
        guard spansLines else {
            insertText(indentUnit, replacementRange: selection)
            return
        }
        rewriteLines(in: lines) { indentUnit + $0 }
    }

    override func insertBacktab(_ sender: Any?) {
        let lines = (string as NSString).lineRange(for: selectedRange())
        let width = indentUnit.count
        rewriteLines(in: lines) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            // Up to one indent unit of spaces, so a line indented by two
            // spaces still moves left.
            let spaces = min(line.prefix(while: { $0 == " " }).count, width)
            return String(line.dropFirst(spaces))
        }
    }

    private func rewriteLines(in range: NSRange, _ transform: (String) -> String) {
        let ns = string as NSString
        let original = ns.substring(with: range)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        var rewritten = lines.map(transform).joined(separator: "\n")
        if hasTrailingNewline { rewritten += "\n" }
        guard rewritten != original else { return }
        // One replacement is one undo step.
        insertText(rewritten, replacementRange: range)
        let length = (rewritten as NSString).length - (hasTrailingNewline ? 1 : 0)
        setSelectedRange(NSRange(location: range.location, length: length))
    }

    private func duplicateLine() {
        let ns = string as NSString
        let line = ns.lineRange(for: selectedRange())
        var text = ns.substring(with: line)
        if !text.hasSuffix("\n") { text = "\n" + text }
        let caret = selectedRange()
        insertText(text, replacementRange: NSRange(location: NSMaxRange(line), length: 0))
        setSelectedRange(NSRange(location: caret.location + (text as NSString).length, length: caret.length))
    }

    // MARK: - Folding

    func toggleFoldAtCaret() {
        guard let body = MarkdownFolds.body(forHeadingContaining: selectedRange().location, in: string) else { return }
        folds.toggle(body)
        // A caret left inside hidden text would be invisible and typing there
        // would edit what the user cannot see.
        if folds.isHidden(selectedRange().location) {
            setSelectedRange(NSRange(location: max(body.location - 1, 0), length: 0))
        }
        refreshLayout()
    }

    /// Fold ranges are character offsets, so any edit can invalidate them.
    /// The spike clears them; the app will remap them through the edit.
    override func didChangeText() {
        super.didChangeText()
        if !folds.folded.isEmpty {
            folds.removeAll()
            refreshLayout()
        }
    }

    /// Loads a different document. Fold ranges are character offsets into
    /// the old text, so they go with it.
    func replaceDocument(_ text: String) {
        folds.removeAll()
        string = text
        setSelectedRange(NSRange(location: 0, length: 0))
        refreshLayout()
    }

    func refreshLayout() {
        guard let layout = textLayoutManager else { return }
        layout.invalidateLayout(for: layout.documentRange)
        layout.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }
}

/// Hides whole paragraphs from TextKit 2 by refusing to enumerate them. The
/// text stays in storage, so copy, search and save see everything.
final class FoldController: NSObject, NSTextContentStorageDelegate {
    private(set) var folded: [NSRange] = []

    func toggle(_ range: NSRange) {
        if let index = folded.firstIndex(of: range) {
            folded.remove(at: index)
        } else {
            folded.append(range)
        }
    }

    func removeAll() {
        folded.removeAll()
    }

    func isHidden(_ location: Int) -> Bool {
        folded.contains { NSLocationInRange(location, $0) }
    }

    func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions = []
    ) -> Bool {
        guard !folded.isEmpty, let range = textElement.elementRange else { return true }
        let start = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        let length = textContentManager.offset(from: range.location, to: range.endLocation)
        let element = NSRange(location: start, length: length)
        return !folded.contains { NSIntersectionRange($0, element).length == element.length && element.length > 0 }
    }
}

/// Fold ranges for markdown: a heading's body runs to the next heading of the
/// same or a higher level.
enum MarkdownFolds {
    static func body(forHeadingContaining location: Int, in text: String) -> NSRange? {
        let ns = text as NSString
        var lineStart = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0)).location
        // Walk up to the nearest heading at or above the caret.
        while true {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            if level(of: ns.substring(with: line)) != nil { break }
            if lineStart == 0 { return nil }
            lineStart = ns.lineRange(for: NSRange(location: lineStart - 1, length: 0)).location
        }
        let heading = ns.lineRange(for: NSRange(location: lineStart, length: 0))
        guard let headingLevel = level(of: ns.substring(with: heading)) else { return nil }
        var end = NSMaxRange(heading)
        while end < ns.length {
            let line = ns.lineRange(for: NSRange(location: end, length: 0))
            if let next = level(of: ns.substring(with: line)), next <= headingLevel { break }
            end = NSMaxRange(line)
        }
        let body = NSRange(location: NSMaxRange(heading), length: end - NSMaxRange(heading))
        return body.length > 0 ? body : nil
    }

    static func level(of line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }
}
