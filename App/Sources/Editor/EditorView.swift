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
    /// Reports focus with this editor's identity, so the model can tell
    /// editors in different windows apart.
    var onFocusChange: (UUID, Bool) -> Void = { _, _ in }
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
        let editor = context.coordinator.editor
        view.onFocusChange = { onFocusChange(editor, $0) }
        context.coordinator.onFocusChange = onFocusChange
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

    /// An editor removed while focused never resigns first responder, so
    /// its departure counts as losing focus.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.onFocusChange?(coordinator.editor, false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let editor = UUID()
        var noteID: UUID?
        var onChange: ((String) -> Void)?
        var onFocusChange: ((UUID, Bool) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange?(view.string)
        }
    }
}
