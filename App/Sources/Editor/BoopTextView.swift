import AppKit
import UniformTypeIdentifiers
import BoopstashCore

/// The note editor: a TextKit 2 `NSTextView` with every automatic
/// substitution off and key handling routed through Core's `Keymap`
/// (ADR 0003, ADR 0006).
final class BoopTextView: NSTextView {
    var keymap = Keymap()
    var indentUnit = "    "
    /// Shows a one-line message in the window (the app's banner).
    var showMessage: ((String) -> Void)?
    /// Told when the editor gains or loses keyboard focus, so menu commands
    /// that only make sense in an editor can be disabled elsewhere (#25).
    var onFocusChange: ((Bool) -> Void)?

    // MARK: Chips (#52)

    /// An attachment's file, or nil when it is missing; set by the host.
    /// While nil, references show as their markdown.
    var attachmentURL: ((UUID) -> URL?)? {
        didSet { scheduleChipUpdate() }
    }
    var chipViews: [ChipView] = []
    var chipRanges: [NSRange] = []
    var chipUpdate: Task<Void, Never>?
    var quickLookSource: QuickLookSource?
    @MainActor static let thumbnails = NSCache<NSURL, NSImage>()

    override func didChangeText() {
        super.didChangeText()
        // Ranges at once, for the next keystroke's snapping and deletion;
        // only the chip views wait for layout.
        chipRanges = attachmentURL == nil ? [] : AttachmentReference.matches(in: string).map(\.range)
        scheduleChipUpdate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { scheduleChipUpdate() }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let previous = selectedRange()
        super.setSelectedRanges(stillSelecting ? ranges : snapped(ranges, from: previous), affinity: affinity, stillSelecting: stillSelecting)
    }

    /// A reference goes in one keystroke, as one undo step.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let chip = chipRanges.first(where: { NSMaxRange($0) == selection.location }) {
            setSelectedRange(chip)
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let chip = chipRanges.first(where: { $0.location == selection.location }) {
            setSelectedRange(chip)
        }
        super.deleteForward(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
    let syntax = SyntaxPainter()

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
        view.syntax.attach(to: view)
        assert(view.textLayoutManager != nil, "the editor fell back to TextKit 1")
        return (scroll, view)
    }

    // MARK: - Appearance

    /// The font and themes from Settings ▸ Editor.
    var editorAppearance = EditorAppearance() {
        didSet { if editorAppearance != oldValue { applyAppearance() } }
    }

    /// The theme for the appearance macOS is in now; nil is the system's.
    var activeTheme: Theme? {
        editorAppearance.theme(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    func applyAppearance() {
        let font = EditorSettings.font(for: editorAppearance)
        let theme = activeTheme
        let text = theme.map { NSColor($0.foreground) } ?? .textColor
        self.font = font
        if let storage = textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.addAttributes([.font: font, .foregroundColor: text], range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        typingAttributes = [.font: font, .foregroundColor: text]
        textColor = text
        if let theme {
            drawsBackground = true
            backgroundColor = NSColor(theme.background)
            insertionPointColor = NSColor(theme.caret)
            selectedTextAttributes = [.backgroundColor: NSColor(theme.selection)]
        } else {
            drawsBackground = false
            backgroundColor = .textBackgroundColor
            insertionPointColor = .textInsertionPointColor
            selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        }
        enclosingScrollView?.drawsBackground = theme != nil
        enclosingScrollView?.backgroundColor = backgroundColor
        syntax.theme = theme
        SyntaxPainter.markForRedisplay(self)
        // Chips take the theme's colours.
        scheduleChipUpdate()
    }

    /// Light and dark themes switch with the system appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Replaces the whole text with another note's, and highlights it.
    func load(_ text: String, syntax choice: SyntaxChoice = .automatic) {
        syntax.replacingDocument { string = text }
        // A replaced document sends no didChangeText.
        scheduleChipUpdate()
        // The new text arrives in the default font and colour.
        applyAppearance()
        syntax.load(text, choice: choice)
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
        if item.action == #selector(formatDocument(_:)) {
            return isEditable && DocumentFormatter.canFormat(syntax.currentLanguage)
        }
        if item.action == #selector(formatJSONSortingKeys(_:)) {
            return isEditable && DocumentFormatter.canFormat(syntax.currentLanguage, style: .sortedKeys)
        }
        if item.action == #selector(pasteAsMarkdown(_:)) {
            return isEditable && NSPasteboard.general.availableType(from: [.html, .rtf, .string]) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Scripts

    /// Runs a Boop script (ADR 0005) on each selected range, or on the whole
    /// note, in the script service (ADR 0007). The result is one undoable
    /// edit named after the script; what the script posts goes to the
    /// banner. If the note changed while the script ran, the result is
    /// dropped rather than written over the newer text.
    func run(_ script: BoopScript, with runner: LiveScriptRunner) async {
        let fullText = string
        let selections = selectedRanges.map(\.rangeValue)
        let request = ScriptRequest(scriptName: script.name, source: script.source,
                                    states: ScriptEdits.states(fullText: fullText, selections: selections))
        let response = await runner.run(request)
        if !response.errors.isEmpty {
            NSSound.beep()
            showMessage?(response.errors.joined(separator: " "))
        } else if let info = response.infos.last {
            showMessage?(info)
        }
        guard !response.outputs.isEmpty else { return }
        // The note was closed (another one selected) while the script ran.
        guard window != nil else {
            showMessage?("\(script.name) finished after its note was closed, so its result was not applied.")
            return
        }
        guard string == fullText else {
            showMessage?("\(script.name) finished after the note changed, so its result was not applied.")
            return
        }
        guard let edits = ScriptEdits.replacements(fullText: fullText, selections: selections, response: response) else { return }
        apply(edits, actionName: script.name)
    }

    /// Replaces each range with its text as one undoable edit, then selects
    /// the replacements (or keeps the caret, for a whole-note edit).
    func apply(_ edits: [(NSRange, String)], actionName: String) {
        let ns = string as NSString
        let edits = edits.sorted { $0.0.location < $1.0.location }
        let changed = edits.filter { ns.substring(with: $0.0) != $0.1 }
        guard !changed.isEmpty, let storage = textStorage else { return }
        let caret = selectedRange().location
        guard shouldChangeText(inRanges: changed.map { NSValue(range: $0.0) }, replacementStrings: changed.map(\.1)) else { return }
        storage.beginEditing()
        for (range, text) in changed.reversed() { storage.replaceCharacters(in: range, with: text) }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)
        let wholeNote = changed.count == 1 && changed[0].0 == NSRange(location: 0, length: ns.length)
        if wholeNote {
            setSelectedRange(NSRange(location: min(caret, (string as NSString).length), length: 0))
        } else {
            // Every range stays selected, changed or not, shifted by the
            // changes before it.
            var delta = 0
            let ranges = edits.map { range, text -> NSValue in
                let length = (text as NSString).length
                defer { delta += length - range.length }
                return NSValue(range: NSRange(location: range.location + delta, length: length))
            }
            selectedRanges = ranges
        }
    }

    // MARK: - Formatting

    /// Edit ▸ Format Document (ADR 0005): the selection, or the whole note,
    /// reformatted for the note's language as one undoable edit.
    @objc func formatDocument(_ sender: Any?) {
        format(style: .standard)
    }

    /// Edit ▸ Format JSON, Sorting Keys.
    @objc func formatJSONSortingKeys(_ sender: Any?) {
        format(style: .sortedKeys)
    }

    func format(style: DocumentFormatter.Style) {
        let whole = selectedRange().length == 0
        let range = whole ? NSRange(location: 0, length: (string as NSString).length) : selectedRange()
        let source = (string as NSString).substring(with: range)
        switch DocumentFormatter.format(source, as: syntax.currentLanguage, style: style) {
        case .failure(let error):
            NSSound.beep()
            showMessage?("Not formatted. \(error.description)")
        case .success(var formatted):
            // A selection keeps its own trailing newline, or lack of one.
            if !whole, !source.hasSuffix("\n"), formatted.hasSuffix("\n") { formatted.removeLast() }
            guard formatted != source else { return }
            // Sorting moves keys, so no character keeps its place; the caret
            // goes to the start rather than onto some other key.
            let caret = style == .sortedKeys ? 0 : DocumentFormatter.caret(selectedRange().location, from: string, to: formatted)
            guard shouldChangeText(in: range, replacementString: formatted) else { return }
            textStorage?.replaceCharacters(in: range, with: formatted)
            didChangeText()
            undoManager?.setActionName("Format")
            setSelectedRange(whole
                ? NSRange(location: caret, length: 0)
                : NSRange(location: range.location, length: (formatted as NSString).length))
            scrollRangeToVisible(selectedRange())
        }
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
        guard !refusesSecret(on: pasteboard) else { return }
        // No text but an image: stored with the note, referenced here (#51).
        // An empty string, which some apps add beside an image, is no text.
        if isEditable, pasteboard.string(forType: .string)?.isEmpty ?? true, insertImage(from: pasteboard) { return }
        guard isEditable, let text = pasteboard.string(forType: .string) else {
            NSSound.beep()
            // macOS's paste privacy can deny every read; say so instead of
            // looking broken.
            if pasteboard == .general, pasteboard.accessBehavior == .alwaysDeny {
                showMessage?("macOS is not letting BoopStash read the clipboard. Allow it in System Settings ▸ Privacy & Security ▸ Paste from Other Apps.")
            }
            return
        }
        insertText(text, replacementRange: selectedRange())
    }

    /// Stores an image's bytes for this note and returns the markdown that
    /// shows it, or nil (the reason goes to the banner). Set by the host.
    var storeImage: ((Data, UTType) -> String?)?

    /// Inserts references for the images on `pasteboard`: image files (a
    /// Finder drag) or image data. False when there were none.
    func insertImage(from pasteboard: NSPasteboard) -> Bool {
        guard let storeImage else { return false }
        var references: [String] = []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension), ImageImport.accepts(type),
                  let data = DropCapture.readPrefix(of: url, limit: ImageImport.sizeLimit + 1)
            else { continue }
            if let reference = storeImage(data, type) { references.append(reference) }
        }
        if urls.isEmpty, let type = ImageImport.preferredType(among: pasteboard.types?.map(\.rawValue) ?? []),
           let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)),
           let reference = storeImage(data, type) {
            references.append(reference)
        }
        guard !references.isEmpty else { return false }
        insertText(references.joined(separator: "\n"), replacementRange: selectedRange())
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + ImageImport.supported.map { NSPasteboard.PasteboardType($0.identifier) }
    }

    /// Drags into the editor (and Services that insert) arrive here rather
    /// than through paste, so the same rule is applied before AppKit reads.
    /// Images, as files or data, are stored with the note and referenced.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard !refusesSecret(on: pboard) else { return false }
        if pboard.string(forType: .string)?.isEmpty ?? true || type == .fileURL, insertImage(from: pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard !refusesSecret(on: pboard) else { return false }
        return super.readSelection(from: pboard)
    }

    /// What is pasted into a note is stored, so every paste follows the
    /// capture rule: password-manager and transient items are refused with a
    /// beep and a visible reason (ADR 0001, #21). True when refused.
    func refusesSecret(on pasteboard: NSPasteboard) -> Bool {
        switch CapturePolicy.decide(types: pasteboard.types?.map(\.rawValue) ?? []) {
        case .accept:
            return false
        case .refuseConcealed:
            NSSound.beep()
            showMessage?("Not pasted: the clipboard holds a password manager item.")
            return true
        case .refuseTransient:
            NSSound.beep()
            showMessage?("Not pasted: the app that copied this marked it as not to be kept.")
            return true
        }
    }

    /// ⌥⇧⌘V: the pasteboard's rich text as markdown source (ADR 0003).
    /// HTML goes straight to Core's converter. RTF-only sources (TextEdit,
    /// some mail) go through AppKit's HTML export first, which only writes
    /// and never fetches; that export styles with CSS classes, so emphasis
    /// from RTF may not survive. Without either, this is a plain paste.
    @objc func pasteAsMarkdown(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // What is pasted into a note is stored, so the capture rule applies:
        // password-manager and transient items are refused (ADR 0001).
        guard !refusesSecret(on: pasteboard) else { return }
        let markdown = Self.html(from: pasteboard).map(HTMLToMarkdown.convert) ?? ""
        guard !markdown.isEmpty else {
            // Nothing representable (an image without alt text, say): paste
            // the plain text if there is any rather than delete the selection.
            if pasteboard.string(forType: .string)?.isEmpty == false {
                pasteAsPlainText(sender)
            } else {
                NSSound.beep()
            }
            return
        }
        insertText(markdown, replacementRange: selectedRange())
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
        case .formatDocument: formatDocument(nil)
        case .formatJSONSortingKeys: formatJSONSortingKeys(nil)
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
        let edit = LineEditing.duplicate(string, lines: selectedLines, above: above)
        let selection = selectedRange()
        replace(edit.range, with: edit.replacement)
        setSelectedRange(NSRange(location: selection.location + edit.caretShift, length: selection.length))
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
