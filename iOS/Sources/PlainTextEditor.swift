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

        func textViewDidChange(_ textView: UITextView) {
            onChange(textView.text)
            painter.schedule()
        }
    }

    /// Colours the text with rendering attributes, which change how text is
    /// drawn and never the text itself.
    @MainActor
    final class Painter {
        private weak var view: UITextView?
        private var choice: SyntaxChoice = .automatic
        private var task: Task<Void, Never>?

        func attach(to view: UITextView, choice: SyntaxChoice) {
            self.view = view
            self.choice = choice
            schedule(after: .zero)
        }

        func schedule(after delay: Duration = .milliseconds(300)) {
            task?.cancel()
            task = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.paint()
            }
        }

        private func paint() async {
            guard let view, let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
            let text = view.text ?? ""
            let choice = self.choice
            let language = await Task.detached { choice.resolve(for: text) }.value
            layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
            guard let language, let engine = try? SyntaxEngine(language: language) else { return }
            _ = await engine.reset(text)
            let highlights = await engine.highlights(in: NSRange(location: 0, length: (text as NSString).length)).highlights
            guard !Task.isCancelled, view.text == text else { return }
            for highlight in highlights {
                guard let role = HighlightRole.role(for: highlight.name),
                      let start = content.location(content.documentRange.location, offsetBy: highlight.range.location),
                      let end = content.location(start, offsetBy: highlight.range.length),
                      let range = NSTextRange(location: start, end: end)
                else { continue }
                layout.addRenderingAttribute(.foregroundColor, value: Self.color(for: role), for: range)
            }
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
