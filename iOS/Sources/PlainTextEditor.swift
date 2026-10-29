import BoopstashCore
import SwiftUI
import UIKit

/// A TextKit 2 text view that leaves text alone (ADR 0003): no smart
/// quotes, dashes or autocorrection, and paste inserts plain text only.
/// Highlighting comes from Core's syntax engine.
struct PlainTextEditor: UIViewRepresentable {
    let text: String
    let choice: SyntaxChoice
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: true)
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
            guard let engine else { return }
            let text = view.text
            let highlights = await engine.highlights(in: visible).highlights
            guard !Task.isCancelled, view.text == text else { return }
            for highlight in highlights {
                guard let role = HighlightRole.role(for: highlight.name), let range = textRange(highlight.range, in: content) else { continue }
                layout.addRenderingAttribute(.foregroundColor, value: Self.color(for: role), for: range)
            }
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

        static func color(for role: HighlightRole) -> UIColor {
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

/// Paste is plain text, as on the Mac (ADR 0003).
final class PlainTextView: UITextView {
    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        let types = UIPasteboard.general.types
        guard CapturePolicy.decide(types: types) == .accept else { return }
        insertText(text)
    }
}
