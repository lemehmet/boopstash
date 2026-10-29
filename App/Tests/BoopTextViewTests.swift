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

    /// What the user sees: render the view and look for strongly coloured
    /// pixels. Rendering attributes that are set but never drawn pass the
    /// attribute check above and fail this one.
    @Test func highlightIsActuallyDrawn() async throws {
        let host = Host()
        let text = "[\n" + Array(repeating: #"  {"name": "boop", "count": 42, "ok": true}"#, count: 5).joined(separator: ",\n") + "\n]\n"
        host.view.load(text)
        var colouredPixels = 0
        for _ in 0..<100 where colouredPixels == 0 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.displayIfNeeded()
            colouredPixels = Self.colouredPixels(in: host.view)
        }
        #expect(colouredPixels > 0, "nothing coloured was drawn")
        host.close()
    }

    /// The control: colour written into storage must be seen by the pixel
    /// check, or `highlightIsActuallyDrawn` proves nothing.
    @Test func pixelCheckSeesStorageColour() {
        let host = Host()
        host.view.string = String(repeating: "coloured text here\n", count: 5)
        host.view.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 40))
        host.view.displayIfNeeded()
        let pixels = Self.colouredPixels(in: host.view)
        #expect(pixels > 0)
        host.close()
    }

    static func colouredPixels(in view: NSView) -> Int {
        let bounds = view.visibleRect
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return 0 }
        view.cacheDisplay(in: bounds, to: rep)
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let maxC = max(c.redComponent, c.greenComponent, c.blueComponent)
                let minC = min(c.redComponent, c.greenComponent, c.blueComponent)
                if maxC - minC > 0.35 { count += 1 } // saturated: not black, white or grey
            }
        }
        return count
    }

    /// A paint must leave every view that draws text needing display, or
    /// the window keeps showing the previous colours until something else
    /// relays out (the hands-on bug behind this test).
    @Test func paintingMarksTheTextForRedisplay() async throws {
        let host = Host()
        host.view.load("let a = 1\nlet b = \"two\"\n", syntax: .plain)
        try await Task.sleep(for: .milliseconds(200))
        host.window.display()
        var dirty: [Bool] = []
        await withCheckedContinuation { continuation in
            host.view.syntax.didPaint = {
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                // These views are layer-backed: the mark lands on the layer,
                // and NSView's getter does not report it.
                dirty = all(host.view).filter { !$0.isHidden }.map { $0.needsDisplay || $0.layer?.needsDisplay() == true }
                host.view.syntax.didPaint = nil
                continuation.resume()
            }
            host.view.syntax.setChoice(.language(.swift))
        }
        #expect(dirty.count > 1, "expected the text view's paragraph subviews")
        #expect(dirty.allSatisfy { $0 }, "\(dirty.filter { !$0 }.count) of \(dirty.count) views were not marked")
        host.close()
    }

    /// The clearing path redraws too (#32): switching a coloured note to
    /// Plain Text must not leave the old colours on screen.
    @Test func switchingToPlainTextMarksTheTextForRedisplay() async throws {
        let host = Host()
        let text = "let a = 1\nlet b = \"two\"\n"
        // Inside the string literal, which Swift highlighting colours.
        let literal = (text as NSString).range(of: "\"two\"").location + 1
        host.view.load(text, syntax: .language(.swift))
        for _ in 0..<100 where Self.renderingColor(in: host.view, at: literal) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Self.renderingColor(in: host.view, at: literal) != nil, "the literal must be coloured before switching")
        host.window.display()
        var dirty: [Bool] = []
        await withCheckedContinuation { continuation in
            host.view.syntax.didPaint = {
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                dirty = all(host.view).filter { !$0.isHidden }.map { $0.needsDisplay || $0.layer?.needsDisplay() == true }
                host.view.syntax.didPaint = nil
                continuation.resume()
            }
            host.view.syntax.setChoice(.plain)
        }
        #expect(dirty.count > 1)
        #expect(dirty.allSatisfy { $0 }, "\(dirty.filter { !$0 }.count) of \(dirty.count) views were not marked")
        #expect(Self.renderingColor(in: host.view, at: literal) == nil)
        host.close()
    }

    /// Plain text has nothing to clear: typing and scrolling in it must not
    /// redraw the whole text view on every change.
    @Test func plainTextEditsDoNotRedraw() async throws {
        let host = Host()
        host.view.load("Buy milk.\n", syntax: .plain)
        try await Task.sleep(for: .milliseconds(200))
        var redraws = 0
        host.view.syntax.didPaint = { redraws += 1 }
        for character in "and call the plumber " {
            host.view.insertText(String(character), replacementRange: host.view.selectedRange())
        }
        host.view.scroll(NSPoint(x: 0, y: 20))
        try await Task.sleep(for: .milliseconds(300))
        #expect(redraws == 0)
        host.close()
    }

    /// #25: the editor reports focus, which disables editor-only commands
    /// elsewhere.
    @Test func editorReportsFocusChanges() {
        let host = Host()
        var focus: [Bool] = []
        host.view.onFocusChange = { focus.append($0) }
        host.window.makeFirstResponder(nil)
        host.window.makeFirstResponder(host.view)
        #expect(focus == [false, true])
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
    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
    func pasteRefusesSecrets(_ marker: String) {
        let host = Host("keep")
        var messages: [String] = []
        host.view.showMessage = { messages.append($0) }
        let secret = pasteboard { pasteboard in
            pasteboard.declareTypes([.string, NSPasteboard.PasteboardType(marker)], owner: nil)
            pasteboard.setString("hunter2", forType: .string)
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        host.view.pastePlainText(from: secret)
        #expect(host.view.string == "keep")
        #expect(messages.count == 1)
        host.close()
    }

    /// Drag and drop into the editor goes through readSelection, not paste.
    @Test func droppedSecretsAreRefusedToo() {
        let host = Host("keep")
        let secret = pasteboard { pasteboard in
            pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
            pasteboard.setString("hunter2", forType: .string)
        }
        #expect(!host.view.readSelection(from: secret, type: .string))
        #expect(!host.view.readSelection(from: secret))
        #expect(host.view.string == "keep")

        let ordinary = pasteboard { $0.setString(" more", forType: .string) }
        #expect(host.view.readSelection(from: ordinary, type: .string))
        #expect(host.view.string == "keep more")
        host.close()
    }
}
