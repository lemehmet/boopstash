import AppKit
import Testing
@testable import Boopstash

/// The editor's AppKit behaviour, in a real window. Tests that need the
/// general pasteboard save and restore it, so running them leaves the
/// clipboard as it was.
@MainActor
@Suite(.serialized)
struct BoopTextViewTests {
    final class Host {
        let window: NSWindow
        let view: BoopTextView

        init(_ text: String = "") {
            let (scroll, view) = BoopTextView.makeScrollable()
            scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            self.view = view
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        func close() { window.close() }
    }

    /// A pasteboard of the test's own. Never the general one: reading it
    /// without a user action can raise macOS's paste-privacy prompt, which
    /// nobody answers in a test run.
    func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        write(pasteboard)
        return pasteboard
    }

    @Test func pasteInsertsPlainText() {
        let host = Host("before ")
        host.view.pastePlainText(from: pasteboard { $0.setString("pasted", forType: .string) })
        #expect(host.view.string == "before pasted")
        host.close()
    }

    @Test func pasteOfRichTextInsertsOnlyItsText() {
        let host = Host()
        host.view.pastePlainText(from: pasteboard { pasteboard in
            let rich = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
            pasteboard.writeObjects([rich])
        })
        #expect(host.view.string == "bold")
        let font = host.view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize != 30, "rich text attributes must not come through")
        host.close()
    }

    @Test func pasteReplacesTheSelectionAndUndoesInOneStep() {
        let host = Host("one two three")
        host.view.setSelectedRange(NSRange(location: 4, length: 3))
        host.view.pastePlainText(from: pasteboard { $0.setString("2", forType: .string) })
        #expect(host.view.string == "one 2 three")
        host.view.undoManager?.undo()
        #expect(host.view.string == "one two three")
        host.close()
    }

    @Test func pasteWithNoTextChangesNothing() {
        let host = Host("keep")
        host.view.setSelectedRange(NSRange(location: 0, length: 4))
        host.view.pastePlainText(from: pasteboard { _ in })
        #expect(host.view.string == "keep")
        host.close()
    }

    /// End to end: a JSON note gets coloured, off the main thread, without
    /// any colour entering the text storage.
    @Test func jsonIsHighlighted() async throws {
        let host = Host()
        let text = #"{"name": "boop", "n": 42}"#
        host.view.load(text)
        let stringLocation = (text as NSString).range(of: "\"boop\"").location
        var painted: NSColor?
        for _ in 0..<100 where painted == nil {
            try await Task.sleep(for: .milliseconds(20))
            painted = Self.renderingColor(in: host.view, at: stringLocation)
        }
        #expect(host.view.syntax.language == .json)
        #expect(painted == SyntaxTheme.color(for: "string"), "got \(String(describing: painted))")
        // Storage keeps the view's own text colour; the highlight lives only
        // in rendering attributes, so it is never saved or undone.
        let stored = host.view.textStorage?.attribute(.foregroundColor, at: stringLocation, effectiveRange: nil) as? NSColor
        #expect(stored != painted)
        host.close()
    }

    @Test func plainProseIsNotHighlighted() async throws {
        let host = Host()
        host.view.load("Buy milk and call the plumber.")
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.syntax.language == nil)
        #expect(Self.renderingColor(in: host.view, at: 4) == nil)
        host.close()
    }

    @Test func chosenLanguageOverridesDetection() async throws {
        let host = Host()
        let text = "name: boop\nversion: 1"
        host.view.load(text, syntax: .language(.json))
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.syntax.language == .json)
        host.view.syntax.setChoice(.plain)
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.syntax.language == nil)
        #expect(Self.renderingColor(in: host.view, at: 0) == nil)
        host.view.syntax.setChoice(.automatic)
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.view.syntax.language == .yaml)
        host.close()
    }

    static func renderingColor(in view: NSTextView, at offset: Int) -> NSColor? {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        var found: NSColor?
        layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
            if range.contains(location), let color = attributes[.foregroundColor] as? NSColor { found = color; return false }
            return true
        }
        return found
    }
}
