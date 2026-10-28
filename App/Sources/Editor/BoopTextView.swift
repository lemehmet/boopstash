import AppKit
import BoopstashCore

/// The note editor: a TextKit 2 `NSTextView` with every automatic
/// substitution off and key handling routed through Core's `Keymap`
/// (ADR 0003, ADR 0006).
final class BoopTextView: NSTextView {
    var keymap = Keymap()
    var indentUnit = "    "
    /// Shows a one-line message in the window (the app's banner).
    var showMessage: ((String) -> Void)?

    /// Always `init(usingTextLayoutManager: true)`: the frame-based
    /// initializers can build a TextKit 1 view (ADR 0006).
    static func makeScrollable() -> (NSScrollView, BoopTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = BoopTextView(usingTextLayoutManager: true)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.drawsBackground = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.disableSubstitutions()
        scroll.documentView = view
        assert(view.textLayoutManager != nil, "the editor fell back to TextKit 1")
        return (scroll, view)
    }

    // MARK: - Substitutions

    func disableSubstitutions() {
        isRichText = false
        importsGraphics = false
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
    // choice in user defaults for every text view. Refuse and grey them out.
    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {}
    override func toggleAutomaticDashSubstitution(_ sender: Any?) {}
    override func toggleAutomaticTextReplacement(_ sender: Any?) {}
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {}
    override func toggleAutomaticLinkDetection(_ sender: Any?) {}
    override func toggleAutomaticDataDetection(_ sender: Any?) {}
    override func toggleSmartInsertDelete(_ sender: Any?) {}
    override func toggleAutomaticTextCompletion(_ sender: Any?) {}

    private static let refusedToggles: Set<Selector> = [
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
        if item.action == #selector(pasteAsMarkdown(_:)) {
            return isEditable && NSPasteboard.general.availableType(from: [.html, .rtf, .string]) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Paste

    /// ⌘V is always plain text (ADR 0003). The body is markdown source, so
    /// there is no style to match; rich text never enters the store.
    override func paste(_ sender: Any?) {
        pastePlainText(from: .general)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pastePlainText(from: .general)
    }

    /// Reads the text and inserts it ourselves rather than through AppKit's
    /// paste machinery, whose readable-type negotiation silently pasted
    /// nothing here. Taking the pasteboard as a parameter lets tests use a
    /// private one, which never triggers macOS's paste-privacy prompt.
    func pastePlainText(from pasteboard: NSPasteboard) {
        guard isEditable, let text = pasteboard.string(forType: .string) else {
            NSSound.beep()
            // macOS's paste privacy can deny every read; say so instead of
            // looking broken.
            if pasteboard == .general, pasteboard.accessBehavior == .alwaysDeny {
                showMessage?("macOS is not letting Boopstash read the clipboard. Allow it in System Settings ▸ Privacy & Security ▸ Paste from Other Apps.")
            }
            return
        }
        insertText(text, replacementRange: selectedRange())
    }

    /// ⌥⇧⌘V: the pasteboard's rich text as markdown source (ADR 0003).
    /// HTML goes straight to Core's converter. RTF-only sources (TextEdit,
    /// some mail) go through AppKit's HTML export first, which only writes
    /// and never fetches; that export styles with CSS classes, so emphasis
    /// from RTF may not survive. Without either, this is a plain paste.
    @objc func pasteAsMarkdown(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let html = Self.html(from: pasteboard) else {
            pasteAsPlainText(sender)
            return
        }
        insertText(HTMLToMarkdown.convert(html), replacementRange: selectedRange())
    }

    private static func html(from pasteboard: NSPasteboard) -> String? {
        if let html = pasteboard.string(forType: .html) { return html }
        guard let rtf = pasteboard.data(forType: .rtf),
              let text = NSAttributedString(rtf: rtf, documentAttributes: nil),
              let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        if let chord = KeyChord(event: event), let command = keymap.command(for: chord), perform(command) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let chord = KeyChord(event: event),
           let command = keymap.command(for: chord), perform(command) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Runs a command; false when it does not apply here, so the event falls
    /// through to AppKit.
    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        switch command {
        case .moveToLineStart: doCommand(by: #selector(moveToBeginningOfLine(_:)))
        case .moveToLineEnd: doCommand(by: #selector(moveToEndOfLine(_:)))
        case .selectToLineStart: doCommand(by: #selector(moveToBeginningOfLineAndModifySelection(_:)))
        case .selectToLineEnd: doCommand(by: #selector(moveToEndOfLineAndModifySelection(_:)))
        case .moveToDocumentStart: doCommand(by: #selector(moveToBeginningOfDocument(_:)))
        case .moveToDocumentEnd: doCommand(by: #selector(moveToEndOfDocument(_:)))
        case .moveWordLeft: doCommand(by: #selector(moveWordLeft(_:)))
        case .moveWordRight: doCommand(by: #selector(moveWordRight(_:)))
        case .selectWordLeft: doCommand(by: #selector(moveWordLeftAndModifySelection(_:)))
        case .selectWordRight: doCommand(by: #selector(moveWordRightAndModifySelection(_:)))
        case .moveUp: doCommand(by: #selector(moveUp(_:)))
        case .moveDown: doCommand(by: #selector(moveDown(_:)))
        case .moveCharacterLeft: doCommand(by: #selector(moveLeft(_:)))
        case .moveCharacterRight: doCommand(by: #selector(moveRight(_:)))
        case .deleteWordBackward: doCommand(by: #selector(deleteWordBackward(_:)))
        case .deleteWordForward: doCommand(by: #selector(deleteWordForward(_:)))
        case .deleteToLineEnd: doCommand(by: #selector(deleteToEndOfLine(_:)))
        case .deleteForward: doCommand(by: #selector(deleteForward(_:)))
        case .deleteLine: deleteLines()
        case .duplicateLineDown: duplicateLines(above: false)
        case .duplicateLineUp: duplicateLines(above: true)
        case .swapLineUp: swapLines(up: true)
        case .swapLineDown: swapLines(up: false)
        case .indentLines: indentLines()
        case .unindentLines: unindentLines()
        case .pasteAsMarkdown: pasteAsMarkdown(nil)
        case .fold, .unfold, .toggleComment:
            // Folding is deferred (ADR 0003); comments need the note's
            // language. Unbound until then, so the key does what AppKit does.
            return false
        }
        return true
    }

    // MARK: - Line editing

    private var selectedLines: NSRange {
        (string as NSString).lineRange(for: selectedRange())
    }

    /// Tab with a selection spanning lines indents every line it touches;
    /// otherwise it inserts the indent unit at the caret, as in VS Code.
    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        guard LineEditing.spansLines(string, selection) else {
            insertText(indentUnit, replacementRange: selection)
            return
        }
        indentLines()
    }

    override func insertBacktab(_ sender: Any?) {
        unindentLines()
    }

    /// The explicit commands (⌘] / ⌘[) always work on whole lines, so they
    /// never replace selected text.
    private func indentLines() {
        rewriteLines(in: selectedLines) { indentUnit + $0 }
    }

    private func unindentLines() {
        let width = indentUnit.count
        rewriteLines(in: selectedLines) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(min(line.prefix(while: { $0 == " " }).count, width)))
        }
    }

    private func rewriteLines(in range: NSRange, _ transform: (String) -> String) {
        let original = (string as NSString).substring(with: range)
        let rewritten = LineEditing.mapLines(original, transform)
        guard rewritten != original else { return }
        replace(range, with: rewritten)
        // Select the rewritten lines without their final terminator.
        let ns = rewritten as NSString
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: max(ns.length - 1, 0), length: 0))
        setSelectedRange(NSRange(location: range.location, length: contentsEnd))
    }

    private func deleteLines() {
        replace(selectedLines, with: "")
    }

    private func duplicateLines(above: Bool) {
        let lines = selectedLines
        let block = (string as NSString).substring(with: lines)
        let copy = block.hasSuffix("\n") ? block : "\n" + block
        let selection = selectedRange()
        if above {
            replace(NSRange(location: lines.location, length: 0), with: block.hasSuffix("\n") ? block : block + "\n")
            setSelectedRange(selection)
        } else {
            replace(NSRange(location: NSMaxRange(lines), length: 0), with: copy)
            setSelectedRange(NSRange(location: selection.location + (copy as NSString).length, length: selection.length))
        }
    }

    private func swapLines(up: Bool) {
        guard let edit = LineEditing.swap(string, lines: selectedLines, up: up) else { return }
        // Taken before the replacement, which collapses the selection.
        let selection = selectedRange()
        replace(edit.range, with: edit.replacement)
        setSelectedRange(NSRange(location: selection.location + edit.caretShift, length: selection.length))
    }

    /// Every programmatic edit goes through `insertText`, the path typing
    /// takes: one undo step, the typing attributes, and the delegate told.
    private func replace(_ range: NSRange, with text: String) {
        insertText(text, replacementRange: range)
    }
}
