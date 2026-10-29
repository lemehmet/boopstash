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

    @Test func theWholeNoteIsFormattedAndUndoesInOneStep() {
        let source = #"{"a":[1,2],"bc":3}"#
        let (window, view) = host(source, .json)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: #""bc""#).location, length: 0))
        view.formatDocument(nil)
        #expect(view.string == "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"bc\": 3\n}\n")
        #expect((view.string as NSString).substring(from: view.selectedRange().location).hasPrefix(#""bc""#),
                "the caret stays before \"bc\"")
        view.undoManager?.undo()
        #expect(view.string == source)
        window.close()
    }

    @Test func aSelectionIsFormattedOnItsOwn() {
        let source = #"before {"k":1} after"#
        let (window, view) = host(source, .json)
        view.setSelectedRange((source as NSString).range(of: #"{"k":1}"#))
        view.formatDocument(nil)
        #expect(view.string == "before {\n  \"k\": 1\n} after")
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "{\n  \"k\": 1\n}")
        window.close()
    }

    @Test func invalidTextIsLeftAloneWithTheReason() {
        var message: String?
        let (window, view) = host("{\"a\": }", .json)
        view.showMessage = { message = $0 }
        view.formatDocument(nil)
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

    @Test func sortingKeysFormatsJSONInKeyOrder() {
        let (window, view) = host(#"{"b":1,"a":2}"#, .json)
        view.formatJSONSortingKeys(nil)
        #expect(view.string == "{\n  \"a\": 2,\n  \"b\": 1\n}\n")
        window.close()
    }
}
