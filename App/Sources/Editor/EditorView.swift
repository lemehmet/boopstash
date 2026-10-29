import AppKit
import BoopstashCore
import SwiftUI
import UniformTypeIdentifiers

/// Hosts `BoopTextView` for one note. The text view owns the text while it
/// is on screen; SwiftUI only swaps documents when the note changes, so a
/// list refresh mid-typing never resets the caret.
struct EditorView: NSViewRepresentable {
    let noteID: UUID
    /// Bumped when the note changed in iCloud while open: the editor
    /// reloads `initialText`, which is then the merged text.
    var revision = 0
    let initialText: String
    let keymap: Keymap
    var syntax: SyntaxChoice = .automatic
    var appearance = EditorAppearance()
    var showMessage: (String) -> Void = { _ in }
    /// Prettier and sql-formatter, in the script service.
    var jsFormat: (@Sendable (JSFormatRequest) async -> Result<String, FormatError>)?
    /// An attachment's file for its chip, nil when missing.
    var attachmentURL: ((UUID) -> URL?)?
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
        if view.attachmentURL == nil { view.attachmentURL = attachmentURL }
        view.storeImage = storeImage
        view.jsFormat = jsFormat
        view.onFocusChange = { _ in onFocusChange() }
        view.syntax.onLanguageChange = onFocusChange
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onChange = onChange
        if context.coordinator.noteID != noteID {
            context.coordinator.noteID = noteID
            context.coordinator.revision = revision
            view.load(initialText, syntax: syntax)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.undoManager?.removeAllActions()
            view.scrollToBeginningOfDocument(nil)
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else {
            view.syntax.setChoice(syntax)
            if context.coordinator.revision != revision {
                context.coordinator.revision = revision
                if view.string != initialText {
                    // Keep the caret where it was, as far as the new text goes.
                    let selection = view.selectedRange()
                    view.load(initialText, syntax: syntax)
                    let length = (view.string as NSString).length
                    view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                    view.undoManager?.removeAllActions()
                }
            }
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
        var revision = 0
        var onChange: ((String) -> Void)?
        var onFocusChange: (() -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange?(view.string)
        }
    }
}
