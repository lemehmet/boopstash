import AppKit
import BoopstashCore
import SwiftUI
import Testing
@testable import Boopstash

/// Paste as Markdown is enabled while a note editor has focus (#25), and
/// every window's editor reports to the one model.
@MainActor
@Suite(.serialized)
struct EditorFocusTests {
    let model: AppModel

    init() throws {
        model = AppModel(store: try .inMemory())
    }

    @Test func onlyTheFocusedEditorCanClearFocus() {
        let first = UUID()
        let second = UUID()
        model.editor(first, hasFocus: true)
        model.editor(second, hasFocus: true)
        model.editor(first, hasFocus: false)
        #expect(model.editorHasFocus, "a background editor going away leaves the focused one alone")
        model.editor(second, hasFocus: false)
        #expect(!model.editorHasFocus)
    }

    /// Two hosted editors: tearing down the one without focus keeps the
    /// command enabled for the other.
    @Test func dismantlingABackgroundEditorKeepsFocus() {
        let reports = { (editor: UUID, focused: Bool) in model.editor(editor, hasFocus: focused) }
        let background = EditorView.Coordinator()
        let focused = EditorView.Coordinator()
        background.onFocusChange = reports
        focused.onFocusChange = reports
        reports(background.editor, true)
        reports(focused.editor, true)
        EditorView.dismantleNSView(NSScrollView(), coordinator: background)
        #expect(model.editorHasFocus)
        EditorView.dismantleNSView(NSScrollView(), coordinator: focused)
        #expect(!model.editorHasFocus, "the focused editor leaving clears it")
    }
}
