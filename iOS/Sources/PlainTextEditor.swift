import BoopstashCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A TextKit 2 text view that leaves text alone (ADR 0003): no smart
/// quotes, dashes or autocorrection, and paste inserts plain text only.
/// Highlighting comes from Core's syntax engine.
struct PlainTextEditor: UIViewRepresentable {
    let text: String
    let choice: SyntaxChoice
    /// Why a paste was refused, for the banner (ADR 0001).
    var showMessage: (String) -> Void = { _ in }
    /// Stores a pasted image for this note (#310); returns its markdown.
    var storeImage: (Data, UTType) -> String? = { _, _ in nil }
    /// An image's text, read on demand, for Insert Text Below (#310).
    var imageText: (@MainActor (UUID) async -> ImageTextRead)?
    /// Copy Text on the image the caret is on, as in the preview (#243).
    var copyImageText: ((UUID) -> Void)?
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: true)
        // Text off the screen's edges, as the title field above it.
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.showMessage = showMessage
        view.storeImage = storeImage
        view.imageText = imageText
        view.copyImageText = copyImageText
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.textContentType = .none
        view.alwaysBounceVertical = true
        view.text = text
        view.delegate = context.coordinator
        context.coordinator.painter.attach(to: view, choice: choice)
        return view
    }

    func updateUIView(_ view: PlainTextView, context: Context) {
        context.coordinator.onChange = onChange
        view.showMessage = showMessage
        view.storeImage = storeImage
        view.imageText = imageText
        view.copyImageText = copyImageText
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void
        let painter = Painter()

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        /// Every edit reaches the engine as an edit, in order, so it
        /// re-parses incrementally instead of from scratch.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            painter.edited(TextChange(range: range, replacementLength: (text as NSString).length))
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            onChange(textView.text)
            painter.textChanged()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            painter.schedulePaint(after: .milliseconds(40))
        }

        /// On an image's reference, the edit menu has the image's two
        /// commands (#310), as the Mac's chip menu does.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let view = textView as? PlainTextView,
                  let reference = ImageTextInsertion.reference(in: view.text, at: range) else { return nil }
            var actions: [UIMenuElement] = []
            if view.copyImageText != nil {
                actions.append(UIAction(title: "Copy Text from Image") { [weak view] _ in view?.copyImageText?(reference.id) })
            }
            if view.imageText != nil, view.isEditable {
                actions.append(UIAction(title: "Insert Text Below") { [weak view] _ in
                    view?.insertImageText(of: reference.id, chosenAt: reference.range.location)
                })
            }
            return UIMenu(children: suggestedActions + actions)
        }
    }

    /// Colours what is on screen with rendering attributes, which change
    /// how text is drawn and never the text itself. As on the Mac
    /// (ADR 0006): one engine per note, fed each edit incrementally, and
    /// highlights asked for only for the visible text plus a margin.
    @MainActor
    final class Painter {
        private weak var view: UITextView?
        private var choice: SyntaxChoice = .automatic
        private var language: SyntaxLanguage?
        private var engine: SyntaxEngine?
        /// Engine work runs one step at a time, in the order edits happened.
        private var queue: Task<Void, Never>?
        private var paintTask: Task<Void, Never>?
        private var pendingChanges: [TextChange] = []
        /// Whether colours were painted, so clearing them needs a redraw.
        private var hasColours = false
        /// Characters either side of the viewport that are painted too, so a
        /// short scroll shows colour at once.
        static let margin = 2_000

        func attach(to view: UITextView, choice: SyntaxChoice) {
            self.view = view
            self.choice = choice
            reset()
        }

        func edited(_ change: TextChange) {
            pendingChanges.append(change)
        }

        func textChanged() {
            guard let text = view?.text else { return }
            let changes = pendingChanges
            pendingChanges = []
            // Undo and redo change the text without asking first, so there
            // is no edit to apply: parse the text as it now is.
            guard !changes.isEmpty else {
                reset()
                return
            }
            enqueue { engine in
                for change in changes { _ = await engine.apply(change, newText: text) }
            }
            // Automatic detection can change its mind as the note is written.
            if choice == .automatic {
                schedulePaint(after: .milliseconds(300), redetect: true)
            } else {
                schedulePaint(after: .milliseconds(300))
            }
        }

        private func reset() {
            guard let text = view?.text else { return }
            let choice = self.choice
            queue = Task { [weak self, previous = queue] in
                await previous?.value
                let language = await Task.detached { choice.resolve(for: text) }.value
                guard let self else { return }
                self.language = language
                self.engine = language.flatMap { try? SyntaxEngine(language: $0) }
                if let engine = self.engine { _ = await engine.reset(text) }
            }
            schedulePaint(after: .zero)
        }

        private func enqueue(_ step: @escaping @Sendable (SyntaxEngine) async -> Void) {
            queue = Task { [weak self, previous = queue] in
                await previous?.value
                guard let engine = await self?.engine else { return }
                await step(engine)
            }
        }

        func schedulePaint(after delay: Duration, redetect: Bool = false) {
            paintTask?.cancel()
            paintTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if redetect, let text = self.view?.text {
                    let detected = await Task.detached { SyntaxLanguage.detect(text) }.value
                    if detected != self.language { self.reset(); return }
                }
                await self.paintVisible()
            }
        }

        private func paintVisible() async {
            await queue?.value
            guard let view, let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
            let length = (view.text as NSString).length
            let visible = visibleRange(in: view, layout: layout, content: content, length: length)
            guard let target = textRange(visible, in: content) else { return }
            layout.removeRenderingAttribute(.foregroundColor, for: target)
            guard let engine else {
                // Plain text: colours painted earlier may lie anywhere, not
                // just on screen, so the whole document is cleared on the
                // way from code to plain text; then redraw only that once,
                // not on every edit and scroll (as the Mac painter does).
                if hasColours {
                    layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
                    Self.redisplay(view)
                }
                hasColours = false
                return
            }
            let text = view.text
            let highlights = await engine.highlights(in: visible).highlights
            guard !Task.isCancelled, view.text == text else { return }
            for highlight in highlights {
                guard let role = HighlightRole.role(for: highlight.name), let range = textRange(highlight.range, in: content) else { continue }
                layout.addRenderingAttribute(.foregroundColor, value: Self.color(for: role), for: range)
            }
            hasColours = true
            Self.redisplay(view)
        }

        /// Rendering attributes change no text, so nothing asks for a
        /// redraw by itself: the text view and its layout fragment views are
        /// told to draw again (#100), as on the Mac.
        static func redisplay(_ view: UIView) {
            view.setNeedsDisplay()
            for subview in view.subviews { redisplay(subview) }
        }

        /// The viewport's characters plus a margin, clamped to the text.
        private func visibleRange(in view: UITextView, layout: NSTextLayoutManager, content: NSTextContentManager, length: Int) -> NSRange {
            layout.textViewportLayoutController.layoutViewport()
            guard let viewport = layout.textViewportLayoutController.viewportRange else { return NSRange(location: 0, length: min(length, 4 * Self.margin)) }
            let start = content.offset(from: content.documentRange.location, to: viewport.location)
            let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
            let lower = max(0, start - Self.margin)
            let upper = min(length, end + Self.margin)
            return NSRange(location: lower, length: max(0, upper - lower))
        }

        private func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length)
            else { return nil }
            return NSTextRange(location: start, end: end)
        }

        nonisolated static func color(for role: HighlightRole) -> UIColor {
            switch role {
            case .comment: .secondaryLabel
            case .string, .removed: .systemRed
            case .escape, .builtin: .systemOrange
            case .number: .systemPurple
            case .keyword: .systemPink
            case .function: .systemTeal
            case .type: .systemCyan
            case .property, .heading, .changed: .systemBlue
            case .link: .link
            case .added: .systemGreen
            }
        }
    }
}

/// Paste is plain text, as on the Mac (ADR 0003); with no text on the
/// clipboard, an image becomes the note's attachment (#310).
final class PlainTextView: UITextView {
    var showMessage: (String) -> Void = { _ in }
    var storeImage: (Data, UTType) -> String? = { _, _ in nil }
    var imageText: (@MainActor (UUID) async -> ImageTextRead)?
    var copyImageText: ((UUID) -> Void)?

    /// Paste is offered for an image too. `hasImages` and `hasStrings`
    /// say what kind of thing is there without reading it (ADR 0001).
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // A refusal says why rather than looking like a broken paste (#102).
        switch ClipboardRead.read() {
        case .refused(let decision):
            if let message = ClipboardPaste.message(for: decision, verb: "pasted") { showMessage(message) }
        case .text(let text):
            insertText(text)
        case .image(let data, let type):
            // A refusal (too large, not kept) is in the banner already.
            if let reference = storeImage(data, type) { insertText(reference) }
        case .unsupportedImage(let name):
            showMessage(ImageImport.message(for: .unsupported(type: name)))
        case .unreadableImage:
            showMessage("Could not read the image on the clipboard.")
        case .empty(let blank):
            if let blank { insertText(blank) }
        }
    }

    /// Insert Text Below (#310): the image's text on a line of its own
    /// under the reference's line, as one undo step, and selected. The
    /// image is read first if it has not been; the note may change
    /// meanwhile, so where the text goes is decided on the text as it is
    /// then (`ImageTextInsertion`), and when that cannot be told nothing
    /// is inserted and a message says so.
    @discardableResult
    func insertImageText(of id: UUID, chosenAt: Int) -> Task<Void, Never> {
        Task { [weak self] in
            guard let read = await self?.imageText?(id), let self else { return }
            guard case .text(let text) = read else {
                if let message = read.message { self.showMessage(message) }
                return
            }
            // Gone from the screen meanwhile: there is no note to change.
            guard self.window != nil, self.isEditable else { return }
            switch ImageTextInsertion.insertion(of: text, under: id, chosenAt: chosenAt, in: self.text) {
            case .edit(let edit):
                // One insertText, the path typing takes: one undo step.
                self.selectedRange = NSRange(location: edit.location, length: 0)
                self.insertText(edit.text)
                self.selectedRange = edit.selection
                self.scrollRangeToVisible(edit.selection)
            case let refusal:
                if let message = refusal.message { self.showMessage(message) }
            }
        }
    }
}
