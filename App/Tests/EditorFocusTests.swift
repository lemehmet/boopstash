import AppKit
import BoopstashCore
import SwiftUI
import Testing
@testable import Boopstash

/// Paste as Markdown is enabled while the key window's focus is a note
/// editor (#25).
@MainActor
@Suite(.serialized)
struct EditorFocusTests {
    let model: AppModel

    init() throws {
        model = AppModel(store: try .inMemory())
    }

    func settle() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// An editor keeps first responder in a window that stops being key, so
    /// focus follows the key window, not the last editor that reported.
    @Test func focusFollowsTheKeyWindow() {
        let editor = BoopTextView(usingTextLayoutManager: true)
        model.keyResponder = { editor }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(model.editorHasFocus)
        model.keyResponder = { NSTextField() }  // Settings or the search field
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(!model.editorHasFocus)
        model.keyResponder = { nil }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nil)
        #expect(!model.editorHasFocus)
    }

    /// Tearing down an editor in a background window leaves the focused
    /// one's command enabled; tearing down the focused one disables it.
    @Test func dismantlingABackgroundEditorKeepsFocus() async {
        let focused = BoopTextView(usingTextLayoutManager: true)
        model.keyResponder = { focused }
        let background = EditorView.Coordinator()
        background.onFocusChange = { model.editorFocusMayHaveChanged() }
        model.refreshEditorFocus()
        EditorView.dismantleNSView(NSScrollView(), coordinator: background)
        await settle()
        #expect(model.editorHasFocus)
        model.keyResponder = { nil }
        let leaving = EditorView.Coordinator()
        leaving.onFocusChange = { model.editorFocusMayHaveChanged() }
        EditorView.dismantleNSView(NSScrollView(), coordinator: leaving)
        await settle()
        #expect(!model.editorHasFocus)
    }
}
