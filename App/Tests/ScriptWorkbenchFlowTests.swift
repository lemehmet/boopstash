import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// The script workbench (#247) on a real editor, with the real script
/// service: run, edit and run again, keep, discard, save, the time limit,
/// a note that changed, and the sheet with and without a generator. What a
/// header, a name clash and a sample are is tested in Core.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ScriptWorkbenchFlowTests {
    static let numbers = "4821\n1093\n77"
    static let links = "https://tracker.example.test/issue/4821\nhttps://tracker.example.test/issue/1093\nhttps://tracker.example.test/issue/77"
    /// The line-by-line skeleton, edited to add a prefix.
    nonisolated static let prefixing = ScriptSkeleton.lineByLine.source
        .replacingOccurrences(of: "out.push(line);", with: "out.push(\"https://tracker.example.test/issue/\" + line);")

    final class Seen {
        var messages: [String] = []
        var closedWith: [String] = []
        var saves = 0
    }

    let seen = Seen()
    let runner = LiveScriptRunner()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID().uuidString)", isDirectory: true)

    func host(_ text: String) -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(text, syntax: .plain)
        view.showMessage = { [seen] in seen.messages.append($0) }
        return (window, view)
    }

    func workbench(on view: BoopTextView, script: String = Self.prefixing, scripts: [BoopScript] = [],
                   generator: (any ScriptGenerator)? = nil, awaitingGenerator: Bool = true) async -> ScriptWorkbenchSession {
        let session = ScriptWorkbenchSession(
            editor: view, script: script, scripts: scripts, folder: folder,
            runner: { [runner] request in await runner.run(request) },
            generator: generator,
            onSaved: { [seen] in seen.saves += 1 },
            onClose: { [seen] script in seen.closedWith.append(script) })
        await ScriptWorkbenchSession.open(session).value
        // The sheet does not wait for the generator's answer; most tests do.
        if awaitingGenerator { await session.availabilityCheck?.value }
        return session
    }

    func close(_ window: NSWindow, _ view: BoopTextView) {
        view.workbench?.close(refocus: false)
        view.discardPendingReview()
        window.close()
        try? FileManager.default.removeItem(at: folder)
    }

    func setScript(_ session: ScriptWorkbenchSession, _ text: String) {
        let view = session.scriptView
        view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
    }

    func library(_ name: String, body: String = "function main(state) { state.text = state.text.toUpperCase() }", bundled: Bool) throws -> BoopScript {
        let source = "/**\n{\"api\":1,\"name\":\"\(name)\",\"description\":\"shouts\",\"tags\":\"loud,caps\"}\n**/\n\n" + body + "\n"
        return try BoopScript.parse(source, id: "\(bundled ? "bundled" : "user")/\(name).js", bundled: bundled).get()
    }

    // MARK: Run, Keep, Discard

    @Test func numbersBecomeLinksAndOneUndoRestoresThem() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        #expect(view.workbench === session)
        #expect(session.sheet != nil && window.attachedSheet === session.sheet, "the sheet is up")
        #expect(session.target == "The whole note")
        #expect(session.result == nil && ScriptWorkbenchStyle.status(running: false, result: nil, edited: false) == "Not run yet.")

        await session.run()
        let result = try #require(session.result)
        #expect(result.canKeep)
        #expect(result.content.summary == TextDiff.Summary(removed: 3, added: 3))
        #expect(result.notes.isEmpty)
        #expect(view.string == Self.numbers, "a run does not touch the note")
        #expect(view.undoManager?.canUndo == false)

        session.keep()
        #expect(view.string == Self.links)
        #expect(view.undoManager?.undoActionName == ScriptWorkbenchSession.unnamed)
        #expect(session.isClosed && view.workbench == nil && window.attachedSheet == nil)
        #expect(window.firstResponder === view, "the editor has the keyboard again")
        view.undoManager?.undo()
        #expect(view.string == Self.numbers)
        #expect(view.undoManager?.canUndo == false, "it was one step")
        #expect(seen.closedWith == [Self.prefixing], "the script is handed back for next time")
        #expect(seen.messages.isEmpty)
        close(window, view)
    }

    @Test func aSelectionAloneIsRunAndKeptUnderTheScriptsName() async throws {
        let source = "before\n" + Self.numbers + "\nafter"
        let (window, view) = host(source)
        view.setSelectedRange(NSRange(location: 7, length: (Self.numbers as NSString).length))
        let session = await workbench(on: view)
        #expect(session.target == "The selection")
        session.name = " Numbers to Links "
        await session.run()
        let texts = try #require(session.result).content.parts.flatMap(\.hunks).flatMap(\.lines).map(\.text)
        #expect(!texts.contains("before") && !texts.contains("after"), "only the selection is diffed")
        session.keep()
        #expect(view.string == "before\n" + Self.links + "\nafter")
        #expect(view.undoManager?.undoActionName == "Numbers to Links")
        close(window, view)
    }

    @Test func aMistakeIsShownAndFixingItUpdatesTheDiff() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, script: "function main(state) { state.text = state.txt.trim() }")
        await session.run()
        var result = try #require(session.result)
        #expect(!result.canKeep && result.content.isEmpty)
        #expect(result.notes.first?.kind == .error)
        #expect(result.notes.first?.text.contains("TypeError") == true, "\(result.notes)")
        session.keep()
        #expect(!session.isClosed && view.string == Self.numbers, "nothing to keep, so nothing happens")

        // A wrong result runs fine: only the diff shows it.
        setScript(session, "function main(state) { state.text = state.text.split('\\n').map(line => '#' + line) }")
        #expect(session.editedSinceRun)
        #expect(ScriptWorkbenchStyle.status(running: false, result: session.result, edited: true).hasSuffix("run it again."))
        await session.run()
        result = try #require(session.result)
        #expect(!session.editedSinceRun)
        #expect(result.content.summary == TextDiff.Summary(removed: 3, added: 1), "the array arrived as one comma-separated line")

        setScript(session, Self.prefixing)
        await session.run()
        result = try #require(session.result)
        #expect(result.canKeep && result.notes.isEmpty)
        #expect(result.content.summary == TextDiff.Summary(removed: 3, added: 3))
        #expect(view.string == Self.numbers)
        session.keep()
        #expect(view.string == Self.links)
        close(window, view)
    }

    @Test func aScriptThatLoopsForeverStopsAtTheTimeLimitAndTheSheetStaysUsable() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, script: "function main(state) { while (true) {} }")
        session.timeLimit = 1
        let started = ContinuousClock.now
        await session.run()
        #expect(ContinuousClock.now - started < .seconds(20))
        let result = try #require(session.result)
        #expect(!result.canKeep)
        #expect(result.notes.map(\.text) == ["Workbench Script took longer than 1 seconds and was stopped."])
        #expect(!session.isClosed && !session.isRunning && window.attachedSheet === session.sheet)
        #expect(view.string == Self.numbers)

        setScript(session, Self.prefixing)
        await session.run()
        #expect(try #require(session.result).canKeep, "the next run works")
        session.keep()
        #expect(view.string == Self.links)
        close(window, view)
    }

    @Test func aScriptsMessagesAreShownAndARunThatChangesNothingSaysSo() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, script: "function main(state) { state.postInfo('3 lines seen') }")
        await session.run()
        let result = try #require(session.result)
        #expect(!result.canKeep)
        #expect(result.status == "The script ran and would change nothing.")
        #expect(result.notes.map(\.text) == ["3 lines seen"] && result.notes.first?.kind == .info)
        #expect(ScriptWorkbenchStyle.placeholder(result: result) == result.status)
        #expect(ScriptWorkbenchStyle.placeholder(result: nil).hasPrefix("Run the script"))
        close(window, view)
    }

    @Test func discardChangesNothingAndKeepsTheScriptForNextTime() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        await session.run()
        session.discard()
        #expect(view.string == Self.numbers)
        #expect(view.undoManager?.canUndo == false)
        #expect(session.isClosed && view.workbench == nil && window.attachedSheet == nil)
        #expect(seen.closedWith == [Self.prefixing])
        session.keep()
        #expect(view.string == Self.numbers, "a closed workbench keeps nothing")
        #expect(seen.closedWith.count == 1)
        close(window, view)
    }

    @Test func escapeInTheScriptDiscards() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        session.scriptView.cancelOperation(nil)
        #expect(session.isClosed && view.string == Self.numbers)
        close(window, view)
    }

    // MARK: A note that changed

    @Test func keepRefusesOverANoteThatChangedAndRunningAgainUsesTheNewNote() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        await session.run()
        view.insertText("9\n", replacementRange: NSRange(location: 0, length: 0))
        session.keep()
        #expect(view.string == "9\n" + Self.numbers, "the newer text is not written over")
        #expect(!session.isClosed, "the sheet and its script stay")
        #expect(session.result == nil, "the diff was for another text")
        #expect(session.notice?.isError == true)
        #expect(session.notice?.text.hasPrefix("The note changed since the last run, so nothing was applied.") == true)

        await session.run()
        #expect(session.notice == nil)
        #expect(try #require(session.result).content.summary == TextDiff.Summary(removed: 4, added: 4))
        session.keep()
        #expect(view.string == "https://tracker.example.test/issue/9\n" + Self.links)
        close(window, view)
    }

    @Test func keepRefusesAfterAnotherNoteWasLoaded() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        await session.run()
        // The same text again is still another load.
        view.load(Self.numbers, syntax: .plain)
        session.keep()
        #expect(view.string == Self.numbers)
        #expect(!session.isClosed && session.result == nil && session.notice?.isError == true)
        close(window, view)
    }

    // MARK: One sheet at a time

    @Test func aSecondWorkbenchOrAReviewDoesNotOpenOverTheFirst() async {
        let (window, view) = host(Self.numbers)
        let first = await workbench(on: view)
        let second = await workbench(on: view)
        #expect(view.workbench === first && second.sheet == nil)
        #expect(seen.messages == ["The script workbench could not open while another sheet is open."])
        let whole = NSRange(location: 0, length: (Self.numbers as NSString).length)
        await view.review([(whole, "x")], of: Self.numbers, named: "Sort Lines").value
        #expect(view.pendingReview == nil)
        #expect(seen.messages.last == "Sort Lines could not show its changes while another sheet is open.")
        #expect(window.attachedSheet === first.sheet)
        close(window, view)
    }

    @Test func aWorkbenchDoesNotOpenOverAReview() async {
        let (window, view) = host(Self.numbers)
        let whole = NSRange(location: 0, length: (Self.numbers as NSString).length)
        await view.review([(whole, "x")], of: Self.numbers, named: "Sort Lines").value
        let session = await workbench(on: view)
        #expect(view.workbench == nil && session.sheet == nil)
        #expect(view.pendingReview != nil)
        close(window, view)
    }

    @Test func anEditorLeavingItsWindowTakesTheWorkbenchWithIt() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        window.contentView = NSView()
        #expect(session.isClosed && view.workbench == nil && window.attachedSheet == nil)
        close(window, view)
    }

    // MARK: Save as Script

    @Test func aSavedScriptIsInTheLibraryAndAClashingNameIsAskedAbout() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, scripts: [try library("Sort Lines", bundled: true)])
        session.save()
        #expect(session.notice == ScriptWorkbenchSession.Notice(isError: true, text: "Give the script a name."))
        #expect(seen.saves == 0)

        session.name = "Numbers to Links"
        session.save()
        #expect(session.notice == ScriptWorkbenchSession.Notice(isError: false, text: "Saved as Numbers to Links. It is in the script picker."))
        #expect(seen.saves == 1)
        let file = folder.appendingPathComponent("NumbersToLinks.js")
        #expect(try String(contentsOf: file, encoding: .utf8) == ScriptHeader.file(name: "Numbers to Links", script: Self.prefixing))
        var saved = try #require(ScriptLibrary.all(userFolder: folder).scripts.first { $0.name == "Numbers to Links" })
        #expect(!saved.isBundled && saved.id == "user/NumbersToLinks.js")
        // The saved script is the one that ran.
        let response = await runner.run(ScriptRequest(scriptName: saved.name, source: saved.source,
                                                      states: [ScriptState(selection: nil, fullText: Self.numbers)]))
        #expect(response.outputs == [Self.links])

        // The same name again, in another case: asked first, nothing written.
        setScript(session, "function main(state) { state.text = 'changed' }")
        session.name = "numbers to links"
        session.save(confirmed: true)
        #expect(session.saveQuestion == "You already have a script named numbers to links. Replace it?", "a yes needs a question first")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("out.push"), "not written over")
        #expect(seen.saves == 1)
        session.cancelSave()
        #expect(session.saveQuestion == nil)
        session.save()
        #expect(session.saveQuestion != nil)
        session.save(confirmed: true)
        #expect(session.saveQuestion == nil && seen.saves == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["NumbersToLinks.js"], "the same file, replaced")
        saved = try #require(ScriptLibrary.all(userFolder: folder).scripts.first { $0.name == "numbers to links" })
        #expect(saved.source.contains("'changed'"))

        // A bundled script's name: asked too, and a file of its own.
        session.name = "Sort Lines"
        session.save()
        #expect(session.saveQuestion?.contains("comes with BoopStash") == true)
        #expect(seen.saves == 2)
        session.name = "Sort Lines!"
        #expect(session.saveQuestion == nil, "another name is another question")
        session.name = "Sort Lines"
        session.save()
        session.save(confirmed: true)
        #expect(seen.saves == 3)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SortLines.js").path))
        #expect(view.string == Self.numbers, "saving does not run or apply anything")
        close(window, view)
    }

    @Test func aYesIsOnlyForTheSaveThatWasAskedAbout() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, scripts: [try library("Sort Lines", bundled: true)])
        session.name = "Sort Lines"
        session.save()
        #expect(session.saveQuestion?.contains("comes with BoopStash") == true)
        // Meanwhile something else, another window's workbench say, saves a script of that name.
        let other = ScriptHeader.file(name: "Sort Lines", script: "function main(state) { state.text = 'theirs' }")
        try UserScriptFiles.write(other, as: "SortLines.js", in: folder, replacing: false)
        let file = folder.appendingPathComponent("SortLines.js")

        // The yes was to adding a file, not to replacing that one.
        session.save(confirmed: true)
        #expect(session.saveQuestion == "You already have a script named Sort Lines. Replace it?")
        #expect(try String(contentsOf: file, encoding: .utf8) == other, "not written over")
        #expect(seen.saves == 0)
        // A yes to the new question is a yes to replacing it.
        session.save(confirmed: true)
        #expect(session.saveQuestion == nil && seen.saves == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == ScriptHeader.file(name: "Sort Lines", script: Self.prefixing))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["SortLines.js"])
        close(window, view)
    }

    @Test func aSaveUnderABundledNameInAnotherCaseTakesItsPlaceInTheLibrary() async throws {
        let bundled = try library("Sort Lines", bundled: true)
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, scripts: [bundled])
        session.name = "sort lines"
        session.save()
        #expect(session.saveQuestion == "A script that comes with BoopStash is named sort lines. Yours will take its place in the picker. Save it?")
        session.save(confirmed: true)
        #expect(seen.saves == 1)
        // The library as it is read again after a save: one script of that name, the user's.
        let mine = ScriptLibrary.load(from: folder, prefix: "user", bundled: false).scripts
        let merged = ScriptCatalog.all(bundled: [bundled], user: mine).filter { $0.name.lowercased() == "sort lines" }
        #expect(merged.map(\.name) == ["sort lines"] && merged.first?.isBundled == false)
        close(window, view)
    }

    @Test func aNewFileNeverReplacesAnotherScriptsFile() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let other = "/**\n{\"api\":1,\"name\":\"Something Else\"}\n**/\nfunction main(state) {}\n"
        try other.write(to: folder.appendingPathComponent("NumbersToLinks.js"), atomically: true, encoding: .utf8)
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        session.name = "Numbers to Links"
        session.save()
        #expect(session.saveQuestion == nil && seen.saves == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("NumbersToLinks.js"), encoding: .utf8) == other)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("NumbersToLinks2.js").path))
        // A file that appears between the plan and the write is not written over either.
        #expect(throws: (any Error).self) {
            try UserScriptFiles.write("new", as: "NumbersToLinks.js", in: folder, replacing: false)
        }
        #expect(try String(contentsOf: folder.appendingPathComponent("NumbersToLinks.js"), encoding: .utf8) == other)
        close(window, view)
    }

    // MARK: The script's text view

    @Test func theScriptEditorKeepsSubstitutionsAndWritingToolsOff() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        let script = session.scriptView
        #expect(script.writingToolsBehavior == .none, "nothing in the script goes to Writing Tools")
        // Edit ▸ Substitutions is greyed out, and choosing an item anyway changes nothing.
        for action in ScriptTextView.refusedToggles {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            #expect(!script.validateUserInterfaceItem(item), "\(action)")
            script.perform(action, with: nil)
        }
        #expect(!script.isAutomaticQuoteSubstitutionEnabled && !script.isAutomaticDashSubstitutionEnabled)
        #expect(!script.isAutomaticTextReplacementEnabled && !script.isAutomaticSpellingCorrectionEnabled)
        #expect(!script.isAutomaticLinkDetectionEnabled && !script.isAutomaticDataDetectionEnabled)
        #expect(!script.smartInsertDeleteEnabled && !script.isAutomaticTextCompletionEnabled)
        close(window, view)
    }

    // MARK: Starting points

    @Test func aLibraryScriptIsABaseToAdapt() async throws {
        let (window, view) = host(Self.numbers)
        let shout = try library("Shout", bundled: false)
        let builtIn = BuiltInCommand.cleanUpPastedText.script
        let session = await workbench(on: view, scripts: [builtIn, try library("Zebra", bundled: true), shout])
        #expect(session.libraryScripts.map(\.name) == ["Shout", "Zebra"], "by name, without the built-in commands")
        session.start(from: shout)
        #expect(session.script == "function main(state) { state.text = state.text.toUpperCase() }\n", "the code without its header")
        #expect(session.name == "Shout")
        session.start(from: builtIn)
        #expect(session.script.contains("toUpperCase"), "a built-in command has no script to adapt")

        // Saved under another name, it keeps the original's description and tags.
        session.name = "Shout Louder"
        session.save()
        let saved = try #require(ScriptLibrary.all(userFolder: folder).scripts.first { $0.name == "Shout Louder" })
        #expect(saved.description == "shouts" && saved.tags == ["loud", "caps"])

        session.start(from: .blank)
        #expect(session.script == ScriptSkeleton.blank.source)
        #expect(session.name == "Shout Louder", "the name is the user's")
        close(window, view)
    }

    // MARK: The editor's font and colour (#286)

    /// Every character is in the editor's font and its text colour. The
    /// highlighter paints rendering attributes over that and never writes
    /// to the text, so any other colour here is one the text was given by
    /// mistake.
    func expectBaseAttributes(_ session: ScriptWorkbenchSession, _ when: String) {
        let view = session.scriptView
        guard let storage = view.textStorage, storage.length > 0 else {
            Issue.record("no text to check \(when)")
            return
        }
        var fonts: [NSFont?] = []
        var colours: [NSColor?] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            fonts.append(attributes[.font] as? NSFont)
            colours.append(attributes[.foregroundColor] as? NSColor)
        }
        #expect(fonts.allSatisfy { $0 == ScriptTextView.baseFont }, "the font \(when)")
        #expect(colours.allSatisfy { $0 == ScriptTextView.baseColor }, "the colour \(when)")
    }

    /// What the next typed character gets.
    func expectBaseTypingAttributes(_ session: ScriptWorkbenchSession, _ when: String) {
        let typing = session.scriptView.typingAttributes
        #expect(typing[.font] as? NSFont == ScriptTextView.baseFont, "the typing font \(when)")
        #expect(typing[.foregroundColor] as? NSColor == ScriptTextView.baseColor, "the typing colour \(when)")
    }

    func type(_ text: String, in session: ScriptWorkbenchSession) {
        let view = session.scriptView
        view.insertText(text, replacementRange: view.selectedRange())
    }

    func deleteAll(_ session: ScriptWorkbenchSession) {
        let view = session.scriptView
        view.selectAll(nil)
        view.deleteBackward(nil)
        #expect(view.string.isEmpty)
    }

    func generate(_ session: ScriptWorkbenchSession) async {
        session.instruction = "make links"
        session.generate()
        await session.generatingTask?.value
        #expect(session.script == Self.prefixing, "the draft is in the editor")
    }

    @Test func aDraftAfterTheScriptWasDeletedHasTheEditorsFontAndColour() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, script: ScriptSkeleton.blank.source, generator: FakeGenerator())
        expectBaseAttributes(session, "for the script the workbench opened with")
        deleteAll(session)
        await generate(session)
        expectBaseAttributes(session, "for a draft in an emptied editor")
        expectBaseTypingAttributes(session, "after the draft")

        // A draft over a script, and over a draft.
        await generate(session)
        expectBaseAttributes(session, "for a draft over a script")
        close(window, view)
    }

    @Test func typingInAnEmptiedEditorHasTheEditorsFontAndColour() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        deleteAll(session)
        expectBaseTypingAttributes(session, "in an emptied editor")
        type("function main(state) {}", in: session)
        expectBaseAttributes(session, "for text typed in an emptied editor")
        type("\n// more", in: session)
        expectBaseAttributes(session, "for text typed after it")
        close(window, view)
    }

    @Test func aWorkbenchOpenedEmptyHasTheEditorsFontAndColour() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, script: "", generator: FakeGenerator())
        expectBaseTypingAttributes(session, "in an editor that opened empty")
        type("let a = 1", in: session)
        expectBaseAttributes(session, "for text typed in an editor that opened empty")
        close(window, view)

        let (other, editor) = host(Self.numbers)
        let drafted = await workbench(on: editor, script: "", generator: FakeGenerator())
        await generate(drafted)
        expectBaseAttributes(drafted, "for a draft in an editor that opened empty")
        close(other, editor)
    }

    /// Cut is a copy and then this deletion; the copy is left out so the
    /// tests do not write to the clipboard of whoever runs them.
    @Test func afterTheDeletionOfACutTheEditorKeepsItsFontAndColour() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, generator: FakeGenerator())
        session.scriptView.selectAll(nil)
        session.scriptView.delete(nil)
        #expect(session.script.isEmpty)
        expectBaseTypingAttributes(session, "after everything was cut")
        await generate(session)
        expectBaseAttributes(session, "for a draft after everything was cut")

        session.scriptView.selectAll(nil)
        session.scriptView.delete(nil)
        type("let a = 1", in: session)
        expectBaseAttributes(session, "for text typed after everything was cut")
        close(window, view)
    }

    @Test func afterUndoBackToEmptyTheEditorKeepsItsFontAndColour() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, script: "", generator: FakeGenerator())
        type("let a = 1", in: session)
        session.scriptView.undoManager?.undo()
        #expect(session.script.isEmpty, "undo took the typing back")
        expectBaseTypingAttributes(session, "after undo back to empty")
        await generate(session)
        expectBaseAttributes(session, "for a draft after undo back to empty")
        close(window, view)

        let (other, editor) = host(Self.numbers)
        let typed = await workbench(on: editor, script: "")
        type("let a = 1", in: typed)
        typed.scriptView.undoManager?.undo()
        #expect(typed.script.isEmpty)
        type("let b = 2", in: typed)
        expectBaseAttributes(typed, "for text typed after undo back to empty")
        close(other, editor)
    }

    @Test func aStartingPointHasTheEditorsFontAndColour() async throws {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, scripts: [try library("Shout", bundled: false)])
        deleteAll(session)
        session.start(from: .blank)
        #expect(session.script == ScriptSkeleton.blank.source)
        expectBaseAttributes(session, "for Start From ▸ Blank in an emptied editor")
        type("// a note\n", in: session)
        expectBaseAttributes(session, "for text typed into the blank script")

        deleteAll(session)
        session.start(from: .lineByLine)
        expectBaseAttributes(session, "for a skeleton in an emptied editor")
        session.start(from: .blank)
        expectBaseAttributes(session, "for Start From ▸ Blank over a script")

        deleteAll(session)
        session.start(from: try #require(session.libraryScripts.first))
        expectBaseAttributes(session, "for a library script in an emptied editor")

        // Undo takes the edits back (in a hosted test, all of them at once).
        session.scriptView.undoManager?.undo()
        type("let a = 1", in: session)
        expectBaseAttributes(session, "for text typed after an undo")
        close(window, view)
    }

    static let registerTable = """
    Name Bit Description
    ENABLE 0 Enables the block. Writing 0 holds
    the block in reset.
    IRQ_MASK 1
    Masks the interrupt output. The status
    bit is still set.
    MODE_SEL 2 Selects the sampling mode.
    AVG16 7
    16 samples are averaged when set.
    WAKE_EN 20 Lets a pin change wake
    the block
    from sleep.
    """

    func run(_ source: String, on text: String) async -> ScriptResponse {
        await runner.run(ScriptRequest(scriptName: "Skeleton", source: source, states: [ScriptState(selection: nil, fullText: text)]))
    }

    @Test func theSkeletonsRunInTheScriptService() async {
        for text in [Self.numbers, Self.numbers + "\n", "", "a\r\nb\n\n"] {
            #expect(await run(ScriptSkeleton.blank.source, on: text) == ScriptResponse(outputs: [text]))
            #expect(await run(ScriptSkeleton.lineByLine.source, on: text) == ScriptResponse(outputs: [text]), "as it stands it changes nothing")
        }
        #expect(await run(Self.prefixing, on: Self.numbers) == ScriptResponse(outputs: [Self.links]))

        // The rows skeleton joins each wrapped description to its row.
        let rows = await run(ScriptSkeleton.wrappedRows.source, on: Self.registerTable)
        #expect(rows == ScriptResponse(outputs: ["""
        ENABLE 0 Enables the block. Writing 0 holds the block in reset.
        IRQ_MASK 1 Masks the interrupt output. The status bit is still set.
        MODE_SEL 2 Selects the sampling mode.
        AVG16 7 16 samples are averaged when set.
        WAKE_EN 20 Lets a pin change wake the block from sleep.
        """]))
        // Edited where it says to: the register table to #define lines.
        let defines = ScriptSkeleton.wrappedRows.source.replacingOccurrences(
            of: #"row.name + " " + row.value + " " + row.words.join(" ")"#,
            with: ##""#define REG_" + row.name + " (" + row.value + ") /* " + row.words.join(" ") + " */""##)
        #expect(defines != ScriptSkeleton.wrappedRows.source)
        #expect(await run(defines, on: Self.registerTable).outputs.first?.split(separator: "\n").map(String.init) == [
            "#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */",
            "#define REG_IRQ_MASK (1) /* Masks the interrupt output. The status bit is still set. */",
            "#define REG_MODE_SEL (2) /* Selects the sampling mode. */",
            "#define REG_AVG16 (7) /* 16 samples are averaged when set. */",
            "#define REG_WAKE_EN (20) /* Lets a pin change wake the block from sleep. */",
        ])
        let none = await run(ScriptSkeleton.wrappedRows.source, on: "no rows\nin this text")
        #expect(none == ScriptResponse(outputs: [], errors: ["No line looks like the start of a row. Change rowStart."]))
    }

    // MARK: The generator seam

    /// Stands in for a model (#269): answers as told, and counts.
    actor FakeGenerator: ScriptGenerator {
        var requests: [ScriptGenerationRequest] = []
        let answer: Result<String, ScriptGenerationFailure>
        let state: ScriptGeneratorAvailability
        let waits: Bool
        /// Availability is not answered until `say()`.
        var slowToSay: Bool

        init(answer: Result<String, ScriptGenerationFailure> = .success(ScriptWorkbenchFlowTests.prefixing),
             state: ScriptGeneratorAvailability = .available(ScriptGeneratorDestination(summary: "a fake model")),
             waits: Bool = false, slowToSay: Bool = false) {
            self.answer = answer
            self.state = state
            self.waits = waits
            self.slowToSay = slowToSay
        }

        func say() { slowToSay = false }

        func availability() async -> ScriptGeneratorAvailability {
            while slowToSay { try? await Task.sleep(for: .milliseconds(5)) }
            return state
        }

        func generate(_ request: ScriptGenerationRequest) async -> Result<String, ScriptGenerationFailure> {
            requests.append(request)
            if waits {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return .failure(.cancelled)
            }
            return answer
        }
    }

    @Test func withoutAGeneratorThereIsNoPromptFieldOrGenerate() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view)
        #expect(session.destination == nil, "the sheet draws the prompt row only for a destination")
        session.instruction = "make links"
        session.generate()
        #expect(session.generatingTask == nil && !session.isGenerating)
        #expect(session.script == Self.prefixing)
        close(window, view)

        // A generator that is set up and not usable now sends nothing
        // either; the sheet shows Generate disabled, with the reason.
        let (other, editor) = host(Self.numbers)
        let fake = FakeGenerator(state: .unavailable(reason: "No model is set up."))
        let idle = await workbench(on: editor, generator: fake)
        #expect(idle.destination == nil)
        #expect(idle.unavailableReason == "No model is set up.")
        #expect(session.unavailableReason == nil, "with no generator there is nothing to say")
        idle.instruction = "make links"
        idle.generate()
        #expect(idle.generatingTask == nil)
        #expect(await fake.requests.isEmpty)
        close(other, editor)
    }

    @Test func aGeneratorThatIsSlowToSayItIsAvailableDoesNotHoldTheSheetBack() async throws {
        let (window, view) = host(Self.numbers)
        let fake = FakeGenerator(slowToSay: true)
        let session = await workbench(on: view, generator: fake, awaitingGenerator: false)
        #expect(session.sheet != nil && window.attachedSheet === session.sheet, "the sheet is up without the answer")
        #expect(session.destination == nil, "and has no prompt row yet")
        await session.run()
        #expect(session.canKeep, "the workbench is usable meanwhile")
        await fake.say()
        await session.availabilityCheck?.value
        #expect(session.destination == ScriptGeneratorDestination(summary: "a fake model"))

        // An answer that comes after the sheet closed is dropped, and the editor is free at once.
        let late = FakeGenerator(slowToSay: true)
        session.discard()
        let closed = await workbench(on: view, generator: late, awaitingGenerator: false)
        closed.discard()
        #expect(view.workbench == nil)
        await late.say()
        await closed.availabilityCheck?.value
        #expect(closed.destination == nil)
        close(window, view)
    }

    @Test func aGeneratorsDraftGoesIntoTheEditorAndDoesNotRun() async throws {
        let (window, view) = host(Self.numbers)
        let fake = FakeGenerator()
        let session = await workbench(on: view, script: ScriptSkeleton.blank.source, generator: fake)
        #expect(session.destination == ScriptGeneratorDestination(summary: "a fake model"))
        session.instruction = " turn each number into a tracker link "
        session.generate()
        #expect(session.isGenerating)
        await session.generatingTask?.value
        #expect(!session.isGenerating)
        #expect(session.script == Self.prefixing, "the draft is in the editor")
        #expect(session.result == nil && view.string == Self.numbers, "it has not run, and the note is as it was")
        #expect(session.notice?.isError == false)
        let request = try #require(await fake.requests.first)
        #expect(request.instruction == "turn each number into a tracker link")
        #expect(request.sample == ScriptSample(text: Self.numbers, isWholeText: true, totalLines: 3))

        // Running and keeping it is the user's choice, as for any script.
        await session.run()
        session.keep()
        #expect(view.string == Self.links)
        close(window, view)
    }

    @Test func aGeneratorIsShownOnlyASampleOfALongSelection() async throws {
        let long = (1...400).map { "ticket \($0)" }.joined(separator: "\n")
        let (window, view) = host("title\n" + long)
        view.setSelectedRange(NSRange(location: 6, length: (long as NSString).length))
        let fake = FakeGenerator()
        let session = await workbench(on: view, generator: fake)
        session.instruction = "links"
        session.generate()
        await session.generatingTask?.value
        let sample = try #require(await fake.requests.first).sample
        #expect(!sample.isWholeText && sample.totalLines == 400)
        #expect(sample.text.hasPrefix("ticket 1\nticket 2\n") && !sample.text.contains("title"))
        #expect(sample.text.count <= ScriptSampling.defaultBudget)
        #expect(sample.text.split(separator: "\n").count <= ScriptSampling.defaultMaxLines)
        close(window, view)
    }

    @Test func aGeneratorsFailureIsSaidAndTheScriptStays() async {
        let (window, view) = host(Self.numbers)
        let session = await workbench(on: view, generator: FakeGenerator(answer: .failure(.noScript)))
        session.instruction = "links"
        session.generate()
        await session.generatingTask?.value
        #expect(session.notice == ScriptWorkbenchSession.Notice(isError: true, text: "The reply held no script with a main function."))
        #expect(session.script == Self.prefixing)
        close(window, view)
    }

    @Test func aRequestCanBeCancelledAndClosingTheSheetCancelsIt() async throws {
        let (window, view) = host(Self.numbers)
        let fake = FakeGenerator(waits: true)
        let session = await workbench(on: view, generator: fake)
        session.instruction = "links"
        session.generate()
        let first = try #require(session.generatingTask)
        session.generate()
        let deadline = ContinuousClock.now + .seconds(10)
        while await fake.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await fake.requests.count == 1, "a second Generate while one is out sends nothing")
        session.cancelGenerating()
        await first.value
        #expect(!session.isGenerating && session.notice == nil, "the user's own cancel needs no message")
        #expect(session.script == Self.prefixing)

        session.generate()
        let second = try #require(session.generatingTask)
        session.discard()
        await second.value
        #expect(session.isClosed && !session.isGenerating && session.script == Self.prefixing)
        #expect(session.notice == nil)
        close(window, view)
    }

    // MARK: From the menu

    @Test func theMenuOpensTheWorkbenchWithTheLineSkeletonThenWithTheLastScript() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(store: try .inMemory())
        model.scriptsFolder = folder
        let (window, view) = host(Self.numbers)
        await model.openWorkbench(in: view).value
        var session = try #require(view.workbench)
        #expect(session.script == ScriptSkeleton.lineByLine.source)
        #expect(session.destination == nil, "no generator ships")
        #expect(session.libraryScripts.contains { $0.isBundled }, "the bundled scripts are bases to adapt")
        setScript(session, Self.prefixing)
        session.name = "Numbers to Links"
        session.save()
        #expect(model.scriptLibrary.scripts.contains { $0.name == "Numbers to Links" && !$0.isBundled }, "saved, it is in the picker")
        session.discard()
        #expect(model.workbenchDraft == Self.prefixing)

        await model.openWorkbench(in: view).value
        session = try #require(view.workbench)
        #expect(session.script == Self.prefixing, "the script from last time")
        await session.run()
        session.keep()
        #expect(view.string == Self.links)
        close(window, view)
    }
}
