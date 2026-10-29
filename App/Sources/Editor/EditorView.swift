import AppKit
import BoopstashCore
import SwiftUI
import UniformTypeIdentifiers

/// Hosts `BoopTextView` for one note. The text view owns the text while it
/// is on screen; SwiftUI only swaps documents when the note changes, so a
/// list refresh mid-typing never resets the caret.
struct EditorView: NSViewRepresentable {
    let noteID: UUID
    let initialText: String
    let keymap: Keymap
    var syntax: SyntaxChoice = .automatic
    var appearance = EditorAppearance()
    var showMessage: (String) -> Void = { _ in }
    /// Stores a pasted or dropped image for this note; returns its markdown.
    var storeImage: (Data, UTType) -> String? = { _, _ in nil }
    /// Called when this editor gains or loses focus, goes away, or its
    /// language changes: what the editor-only menu commands depend on.
    var onFocusChange: () -> Void = {}
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
        view.editorAppearance = appearance
        view.showMessage = showMessage
        view.storeImage = storeImage
        view.onFocusChange = { _ in onFocusChange() }
        view.syntax.onLanguageChange = onFocusChange
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
        coordinator.onFocusChange?()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteID: UUID?
        var onChange: ((String) -> Void)?
        var onFocusChange: (() -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange?(view.string)
        }
    }
}
