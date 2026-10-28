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
