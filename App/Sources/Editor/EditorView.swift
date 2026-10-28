import AppKit
import BoopstashCore
import SwiftUI

/// Hosts `BoopTextView` for one note. The text view owns the text while it
/// is on screen; SwiftUI only swaps documents when the note changes, so a
/// list refresh mid-typing never resets the caret.
struct EditorView: NSViewRepresentable {
    let noteID: UUID
    let initialText: String
    let keymap: Keymap
    var syntax: SyntaxChoice = .automatic
    var showMessage: (String) -> Void = { _ in }
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = BoopTextView.makeScrollable()
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? BoopTextView else { return }
        view.keymap = keymap
        view.showMessage = showMessage
        context.coordinator.onChange = onChange
        if context.coordinator.noteID != noteID {
            context.coordinator.noteID = noteID
            view.load(initialText, syntax: syntax)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.undoManager?.removeAllActions()
            view.scrollToBeginningOfDocument(nil)
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else {
            view.syntax.setChoice(syntax)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteID: UUID?
        var onChange: ((String) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange?(view.string)
        }
    }
}
