import AppKit
import BoopstashCore
import SwiftUI
import Testing
@testable import Boopstash

/// Paste as Markdown is enabled while the key window's focus is a note
/// editor (#25).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct EditorFocusTests {
    let model: AppModel
    /// The model's own center: posts here never reach AppKit or SwiftUI
    /// observers in the host app.
    let notifications = NotificationCenter()

    init() throws {
        model = AppModel(store: try .inMemory(), notifications: notifications)
    }

    func post(_ name: Notification.Name) {
        notifications.post(name: name, object: NSWindow())
    }

    /// Focus is re-read on a later main-queue turn; wait for it, failing
    /// after `timeout` rather than hanging.
    func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// An editor keeps first responder in a window that stops being key, so
    /// focus follows the key window, not the last editor that reported.
    @Test func focusFollowsTheKeyWindow() {
        let editor = BoopTextView(usingTextLayoutManager: true)
        model.keyResponder = { editor }
        post(NSWindow.didBecomeKeyNotification)
        #expect(model.editorHasFocus)
        model.keyResponder = { NSTextField() }  // Settings or the search field
        post(NSWindow.didBecomeKeyNotification)
        #expect(!model.editorHasFocus)
        model.keyResponder = { nil }
        post(NSWindow.didResignKeyNotification)
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
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.editorHasFocus)
        model.keyResponder = { nil }
        let leaving = EditorView.Coordinator()
        leaving.onFocusChange = { model.editorFocusMayHaveChanged() }
        EditorView.dismantleNSView(NSScrollView(), coordinator: leaving)
        #expect(await eventually { !model.editorHasFocus })
    }
}
