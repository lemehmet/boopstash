import AppKit
import Testing
@testable import EditorSpike

/// The ADR 0003 criteria, as far as they can be measured. Every check that can
/// pass vacuously has a control: the same input to a stock NSTextView must
/// show the behaviour we are removing, or the check proves nothing.
@MainActor
@Suite(.serialized)
struct SpikeChecks {
    // MARK: Harness

    final class Host {
        let window: NSWindow
        let view: NSTextView

        init(_ view: NSTextView, scroll: NSScrollView, text: String) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            self.view = view
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: 0))
            layout()
        }

        func layout() {
            guard let layout = view.textLayoutManager else { return }
            layout.ensureLayout(for: layout.documentRange)
            layout.textViewportLayoutController.layoutViewport()
        }

        func key(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )!
            window.sendEvent(event)
        }

        func type(_ text: String) {
            for character in text { key(String(character)) }
            // AppKit runs text checking (smart quotes, dashes, replacements)
            // after the event, on the next turns of the run loop.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        var caretLine: String {
            let ns = view.string as NSString
            let line = ns.lineRange(for: NSRange(location: view.selectedRange().location, length: 0))
            return ns.substring(with: line).trimmingCharacters(in: .newlines)
        }

        func close() { window.close() }
    }

    static func spike(_ text: String) -> Host {
        let (scroll, view) = SpikeTextView.make()
        return Host(view, scroll: scroll, text: text)
    }

    /// A stock text view with AppKit's substitutions switched on, the way a
    /// user who ticked them in Edit ▸ Substitutions would have it.
    static func stock(_ text: String) -> Host {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        return Host(view, scroll: scroll, text: text)
    }

    static let home = String(Character(UnicodeScalar(NSHomeFunctionKey)!))
    static let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    static let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))

    // MARK: 3. No substitutions

    /// What AppKit may rewrite is the view's `enabledTextCheckingTypes`. The
    /// control proves the mask is where the switches land (a stock view with
    /// smart quotes on carries the bits); the spike must carry none of them,
    /// and typed text must come back exactly. Synthesized key events do not
    /// reach AppKit's text checking the way a real keyboard does (verified:
    /// a stock view keeps straight quotes when typed this way, even after an
    /// explicit `checkText`), so substitution while really typing is checked
    /// by hand in the spike app.
    @Test func noSubstitutionIsEnabled() {
        let forbidden = NSTextCheckingResult.CheckingType([
            .quote, .dash, .replacement, .correction, .link, .spelling, .grammar,
        ]).rawValue

        let control = Self.stock("")
        #expect(control.view.enabledTextCheckingTypes & NSTextCheckingResult.CheckingType([.quote, .dash]).rawValue != 0,
                "the stock view should carry the bits it was given")
        control.close()

        let typed = "He said \"hi\" -- it's 'fine' (c) teh"
        let host = Self.spike("")
        #expect(host.view.enabledTextCheckingTypes & forbidden == 0,
                "enabled: \(host.view.enabledTextCheckingTypes)")
        host.type(typed)
        #expect(host.view.string == typed, "got \(host.view.string.debugDescription)")
        host.close()
    }

    @Test func substitutionMenuTogglesAreRefused() {
        let host = Self.spike("")
        let view = host.view as! SpikeTextView
        view.toggleAutomaticQuoteSubstitution(nil)
        view.toggleAutomaticDashSubstitution(nil)
        #expect(!view.isAutomaticQuoteSubstitutionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        let item = NSMenuItem(title: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        #expect(!view.validateUserInterfaceItem(item))
        host.close()
    }

    // MARK: 2. Key handling

    @Test func homeMovesToLineStart() {
        let text = "first line\nsecond line\n"
        let caret = NSRange(location: 17, length: 0) // inside "second line"

        let control = Self.stock(text)
        control.view.setSelectedRange(caret)
        control.key(Self.home, keyCode: 115, modifiers: [.function])
        // AppKit's Home scrolls and leaves the caret where it was.
        #expect(control.view.selectedRange() == caret)
        control.close()

        let host = Self.spike(text)
        host.view.setSelectedRange(caret)
        host.key(Self.home, keyCode: 115, modifiers: [.function])
        #expect(host.view.selectedRange() == NSRange(location: 11, length: 0))
        host.close()
    }

    @Test func viewTakesAChordBeforeTheMenu() {
        let host = Self.spike("")
        let view = host.view as! SpikeTextView
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
            windowNumber: host.window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        )!
        // NSApplication offers a key equivalent to the key window's views
        // before the main menu; claiming it here keeps it from the menu.
        #expect(host.window.performKeyEquivalent(with: event))
        #expect(view.probes == ["ctrl-cmd-space"])
        host.close()
    }

    @Test func shiftOptionDownDuplicatesTheLine() {
        let host = Self.spike("alpha\nbeta\n")
        host.view.setSelectedRange(NSRange(location: 2, length: 0))
        host.key(Self.downArrow, keyCode: 125, modifiers: [.shift, .option, .function])
        #expect(host.view.string == "alpha\nalpha\nbeta\n")
        host.close()
    }

    // MARK: 4. Tab / Shift-Tab

    @Test func tabIndentsSelectedLinesAsOneUndoStep() {
        let text = "one\ntwo\nthree\n"
        let host = Self.spike(text)
        host.view.setSelectedRange(NSRange(location: 1, length: 6)) // "ne\ntwo"
        host.key("\t", keyCode: 48)
        #expect(host.view.string == "    one\n    two\nthree\n")

        host.key("\u{19}", keyCode: 48, modifiers: [.shift]) // Shift-Tab arrives as backtab
        #expect(host.view.string == text)

        host.key("\t", keyCode: 48)
        host.view.undoManager?.undo()
        #expect(host.view.string == text, "one undo should revert the whole indent")
        host.close()
    }

    @Test func tabWithoutSelectionInsertsIndentAtCaret() {
        let host = Self.spike("ab")
        host.view.setSelectedRange(NSRange(location: 1, length: 0))
        host.key("\t", keyCode: 48)
        #expect(host.view.string == "a    b")
        host.close()
    }

    // MARK: 1. Folding

    @Test func foldedSectionIsSkippedByTheCaret() throws {
        let host = Self.spike(Samples.markdown)
        let view = host.view as! SpikeTextView
        let ns = view.string as NSString
        let heading = ns.range(of: "## Folding")
        view.setSelectedRange(NSRange(location: NSMaxRange(heading), length: 0))

        let fragmentsBefore = Self.fragmentCount(view)
        view.toggleFoldAtCaret()
        host.layout()
        let fragmentsAfter = Self.fragmentCount(view)
        #expect(fragmentsAfter < fragmentsBefore, "folding should remove layout fragments (\(fragmentsBefore) → \(fragmentsAfter))")

        host.key(Self.downArrow, keyCode: 125, modifiers: [.function])
        #expect(host.caretLine == "## After the fold")

        host.key(Self.upArrow, keyCode: 126, modifiers: [.function])
        #expect(host.caretLine == "## Folding")

        // Copy across the fold carries the hidden text: what is folded is
        // hidden, not removed.
        let after = ns.range(of: "## After the fold")
        view.setSelectedRange(NSRange(location: heading.location, length: NSMaxRange(after) - heading.location))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        #expect(board.string(forType: .string)?.contains("Arrow keys should jump over them.") == true)

        view.toggleFoldAtCaret()
        host.layout()
        #expect(Self.fragmentCount(view) == fragmentsBefore)
        #expect(view.textLayoutManager != nil, "fell back to TextKit 1")
        host.close()
    }

    static func fragmentCount(_ view: NSTextView) -> Int {
        guard let layout = view.textLayoutManager else { return -1 }
        var count = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { _ in
            count += 1
            return true
        }
        return count
    }

    // MARK: 6. Inline image chip

    @Test func imageAttachmentLaysOutInlineOnTextKit2() {
        let host = Self.spike("before\nafter\n")
        host.view.textStorage?.insert(Attachments.chip(), at: 7)
        host.layout()
        guard let layout = host.view.textLayoutManager else {
            Issue.record("fell back to TextKit 1")
            return
        }
        var tallest: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            tallest = max(tallest, fragment.layoutFragmentFrame.height)
            return true
        }
        #expect(tallest >= 72, "the chip's line should be at least the image's height, got \(tallest)")
        host.close()
    }

    // MARK: 5. Highlighting a 1 MB file

    @Test func highlightingOneMegabyteOfJSON() async throws {
        let json = Samples.largeJSON()
        let host = Self.spike(json)
        let highlighter = try JSONHighlighter()

        // Worst case for one edit if parsing were synchronous: the reason the
        // app must not do it on the main thread.
        let parse = ContinuousClock().measure { highlighter.parse(json) }
        #expect(!highlighter.highlights.isEmpty)

        let paint = ContinuousClock().measure {
            highlighter.paint(host.view, visible: NSRange(location: 0, length: 8_000))
            host.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }

        // The edit path the spike app runs: insert, lay out the viewport, and
        // schedule the re-highlight. All of that is main-thread time; the
        // parse itself is not.
        let middle = (json as NSString).length / 2
        host.view.setSelectedRange(NSRange(location: middle, length: 0))
        host.view.scrollRangeToVisible(host.view.selectedRange())
        let clock = ContinuousClock()
        let editStart = clock.now
        var mainThreadKeystroke = Duration.zero
        let rehighlighted: Duration = await withCheckedContinuation { continuation in
            mainThreadKeystroke = clock.measure {
                host.view.insertText("x", replacementRange: host.view.selectedRange())
                host.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                highlighter.schedule(host.view.string, debounce: .zero) {
                    highlighter.paint(host.view, visible: NSRange(location: middle - 4_000, length: 8_000))
                    continuation.resume(returning: clock.now - editStart)
                }
            }
        }

        print("SPIKE-BENCH bytes=\(json.utf8.count) highlights=\(highlighter.highlights.count) syncParse=\(parse) paint=\(paint) mainThreadKeystroke=\(mainThreadKeystroke) editToRehighlighted=\(rehighlighted)")
        #expect(host.view.textLayoutManager != nil)
        // Generous bounds: this is a smoke alarm, not a benchmark.
        #expect(mainThreadKeystroke < .milliseconds(50))
        #expect(highlighter.highlights.count > 0)
        host.close()
    }

    @Test func replacingTheDocumentClearsFolds() {
        let host = Self.spike(Samples.markdown)
        let view = host.view as! SpikeTextView
        let heading = (view.string as NSString).range(of: "## Folding")
        view.setSelectedRange(NSRange(location: NSMaxRange(heading), length: 0))
        view.toggleFoldAtCaret()
        #expect(!view.folds.folded.isEmpty)

        let json = "[\n  {\"a\": 1},\n  {\"b\": 2},\n  {\"c\": 3}\n]\n"
        view.replaceDocument(json)
        host.layout()
        #expect(view.folds.folded.isEmpty)
        // Every paragraph of the new document is laid out: none inherited a fold.
        #expect(Self.fragmentCount(view) == json.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
        host.close()
    }
    /// Highlight ranges index the NSString (UTF-16) the text view paints,
    /// not UTF-8 bytes: every string highlight must cover exactly a quoted
    /// string, including after accented and astral-plane characters.
    @Test func highlightRangesAreUTF16() throws {
        let json = #"{"café": "naïve 🙂", "after": "plain", "n": 1}"#
        let highlights = try JSONGrammar.highlights(in: json, query: JSONGrammar.highlightsQuery())
        let ns = json as NSString
        let strings = highlights.filter { $0.name.hasPrefix("string") }.map { ns.substring(with: $0.range) }
        #expect(strings.contains(#""naïve 🙂""#), "got \(strings)")
        #expect(strings.contains(#""plain""#), "got \(strings)")
        #expect(highlights.allSatisfy { NSMaxRange($0.range) <= ns.length })
    }

    @Test func editingClearsFolds() {
        let host = Self.spike(Samples.markdown)
        let view = host.view as! SpikeTextView
        let heading = (view.string as NSString).range(of: "## Folding")
        view.setSelectedRange(NSRange(location: NSMaxRange(heading), length: 0))
        view.toggleFoldAtCaret()
        #expect(!view.folds.folded.isEmpty)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("inserted above\n", replacementRange: view.selectedRange())
        #expect(view.folds.folded.isEmpty, "a fold's offsets are stale after an edit above it")
        // Inserting an image chip is an edit too.
        view.setSelectedRange(NSRange(location: NSMaxRange((view.string as NSString).range(of: "## Folding")), length: 0))
        view.toggleFoldAtCaret()
        #expect(!view.folds.folded.isEmpty)
        let before = view.string.utf16.count
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertChip()
        #expect(view.string.utf16.count == before + 1, "the chip is one attachment character")
        #expect(view.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment,
                "the character carries its attachment, not a bare U+FFFC")
        #expect(view.folds.folded.isEmpty, "a chip inserted above a fold clears it")
        host.close()
    }
}
