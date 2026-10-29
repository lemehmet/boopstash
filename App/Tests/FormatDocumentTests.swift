import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Edit ▸ Format Document in a real editor: one undoable edit, the caret
/// kept on its character, a selection formatted on its own.
@MainActor
@Suite(.serialized)
struct FormatDocumentTests {
    func host(_ text: String, _ language: SyntaxLanguage?) -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text, syntax: language.map { .language($0) } ?? .plain)
        return (window, view)
    }

    @Test func theWholeNoteIsFormattedAndUndoesInOneStep() async {
        let source = #"{"a":[1,2],"bc":3}"#
        let (window, view) = host(source, .json)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: #""bc""#).location, length: 0))
        await view.format(style: .standard).value
        #expect(view.string == "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"bc\": 3\n}\n")
        #expect((view.string as NSString).substring(from: view.selectedRange().location).hasPrefix(#""bc""#),
                "the caret stays before \"bc\"")
        view.undoManager?.undo()
        #expect(view.string == source)
        window.close()
    }

    @Test func aSelectionIsFormattedOnItsOwn() async {
        let source = #"before {"k":1} after"#
        let (window, view) = host(source, .json)
        view.setSelectedRange((source as NSString).range(of: #"{"k":1}"#))
        await view.format(style: .standard).value
        #expect(view.string == "before {\n  \"k\": 1\n} after")
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "{\n  \"k\": 1\n}")
        window.close()
    }

    @Test func invalidTextIsLeftAloneWithTheReason() async {
        var message: String?
        let (window, view) = host("{\"a\": }", .json)
        view.showMessage = { message = $0 }
        await view.format(style: .standard).value
        #expect(view.string == "{\"a\": }")
        #expect(message == "Not formatted. Line 1, column 7: expected a value")
        window.close()
    }

    @Test func theMenuItemFollowsTheLanguage() {
        let (window, view) = host("x = 1", .python)
        let item = NSMenuItem(title: "Format Document", action: #selector(BoopTextView.formatDocument(_:)), keyEquivalent: "")
        #expect(!view.validateUserInterfaceItem(item))
        view.load("{}", syntax: .language(.json))
        #expect(view.validateUserInterfaceItem(item))
        let sorting = NSMenuItem(title: "Sort", action: #selector(BoopTextView.formatJSONSortingKeys(_:)), keyEquivalent: "")
        #expect(view.validateUserInterfaceItem(sorting))
        window.close()
    }

    /// An edit made while a slow format runs wins: the stale result is
    /// dropped, with a message (#81).
    @Test func anEditDuringFormattingIsKept() async {
        let (window, view) = host(#"{"a":1}"#, .json)
        var message: String?
        view.showMessage = { message = $0 }
        view.formatter = { source, language, style in
            try? await Task.sleep(for: .milliseconds(300))
            return DocumentFormatter.format(source, as: language, style: style)
        }
        let running = view.format(style: .standard)
        view.insertText(" ", replacementRange: NSRange(location: 7, length: 0))
        await running.value
        #expect(view.string == #"{"a":1} "#)
        #expect(message == "The note changed while it was being formatted, so it was left as it is.")
        window.close()
    }

    /// The editor is reused across notes: a format started on one note is
    /// not applied to the next, even when its text is the same.
    @Test func aFormatIsNotAppliedToTheNextNote() async {
        let (window, view) = host("{}", .json)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.formatter = { source, language, style in
            try? await Task.sleep(for: .milliseconds(300))
            return DocumentFormatter.format(source, as: language, style: style)
        }
        let running = view.format(style: .standard)
        view.load("{}", syntax: .language(.json))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        await running.value
        #expect(view.string == "{}")
        window.close()
    }

    /// JavaScript goes to Prettier in the script service (#56).
    @Test func javaScriptIsFormattedByPrettier() async {
        let (window, view) = host("const a={b:1}", .javascript)
        let runner = LiveScriptRunner()
        view.jsFormat = { request in await runner.format(request) }
        await view.format(style: .standard).value
        #expect(view.string == "const a = { b: 1 };\n")
        window.close()
    }

    @Test func sortingKeysFormatsJSONInKeyOrder() async {
        let source = #"{"b":1,"a":2}"#
        let (window, view) = host(source, .json)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: #""a""#).location, length: 0))
        await view.format(style: .sortedKeys).value
        #expect(view.string == "{\n  \"a\": 2,\n  \"b\": 1\n}\n")
        #expect(view.selectedRange() == NSRange(location: 0, length: 0), "keys moved, so the caret goes to the start")
        window.close()
    }

    /// The menu items are SwiftUI commands, which AppKit does not validate:
    /// they read the model, which follows the key editor's language.
    @Test func theCommandsFollowTheKeyEditorsLanguage() {
        let model = AppModel(store: try! .inMemory())
        let (window, view) = host("x = 1", .python)
        model.keyResponder = { view }
        model.refreshEditorFocus()
        #expect(model.editorHasFocus && !model.canFormatDocument && !model.canSortJSONKeys)
        view.load("{}", syntax: .language(.xml))
        model.refreshEditorFocus()
        #expect(model.canFormatDocument && !model.canSortJSONKeys)
        view.load("{}", syntax: .language(.json))
        model.refreshEditorFocus()
        #expect(model.canFormatDocument && model.canSortJSONKeys)
        model.keyResponder = { nil }
        model.refreshEditorFocus()
        #expect(!model.canFormatDocument)
        window.close()
    }

    /// Switching to Automatic re-detects at once, not after the background
    /// parse: XML text formats as XML even if the note was just JSON.
    @Test func automaticLanguageIsReadFromTheTextNow() async {
        let (window, view) = host("<a><b>1</b></a>", .json)
        view.load(view.string, syntax: .automatic)
        #expect(view.syntax.currentLanguage == .xml)
        await view.format(style: .standard).value
        #expect(view.string.contains("\n    <b>1</b>"))
        window.close()
    }
}
