import AppKit
import BoopstashCore
import Observation

/// One open script workbench (#247, ADR 0013): a script the user edits,
/// what it would change in the note as a diff, and Keep, Discard and Save
/// as Script. The script runs only in the script service (ADR 0007), and
/// only when Run or Refresh is chosen; nothing reaches the note without
/// Keep, which goes through the diff review's own check that the note is
/// still the text the diff was made for.
///
/// It has a window of its own (#285), and the note stays editable in its
/// window meanwhile. So that check is what protects the note: Keep over a
/// note that changed since the run applies nothing and says so, and
/// Refresh reads the note again and runs. The workbench is one note's: it
/// closes when the note's window closes, when the editor leaves it, and
/// when another note is loaded into the editor.
///
/// What a run, a save and a generator's draft mean is Core's
/// (`ScriptWorkbenchResult`, `ScriptSave`, `ScriptGeneration`); this holds
/// the window's state and the script's text view.
@MainActor
@Observable
final class ScriptWorkbenchSession {
    /// Something the workbench says next to the script, apart from what the
    /// script itself posted.
    struct Notice: Equatable {
        var isError: Bool
        var text: String
    }

    /// The note text a result was made for, as the diff review keeps it.
    private struct Snapshot {
        let text: String
        let generation: Int
    }

    /// The unsaved script's name: in the time-limit message and the Undo
    /// menu until the user names it.
    static let unnamed = "Workbench Script"

    // MARK: What the window shows

    /// The last run, or nil before the first one and after the note
    /// changed under it.
    private(set) var result: ScriptWorkbenchResult?
    private(set) var isRunning = false
    /// The script was edited after the run the diff shows.
    private(set) var editedSinceRun = false
    private(set) var notice: Notice?
    /// The name Save as Script saves under.
    var name = "" {
        didSet { if name != oldValue { ask(nil) } }
    }
    /// A save that needs a yes first: the name is taken.
    private(set) var saveQuestion: String?
    /// The save `saveQuestion` asks about. A yes is a yes to this plan
    /// and to no other the folder may have turned it into since.
    @ObservationIgnored private var askedPlan: ScriptSave.Plan?
    /// Where Generate would send a request. Nil with no generator, with
    /// nothing configured, and with one that cannot be used now.
    private(set) var destination: ScriptGeneratorDestination?
    /// Why a generator that is set up cannot be used now: Generate is
    /// shown disabled, with this. Nil when nothing is set up, which shows
    /// no prompt field at all.
    private(set) var unavailableReason: String?
    var instruction = "" {
        didSet { if instruction != oldValue { refreshSample() } }
    }
    /// The sample Generate sends. The text is read from the note when the
    /// workbench learns where a request goes, on Check Again and on
    /// Refresh, and at no other time: the note can be edited while the
    /// workbench is open (#285), and an edit there changes nothing here
    /// until one of those is chosen and the new reading is on show. The
    /// sample is sized again from that reading when the instruction or
    /// the examples change, as they take room from it. The window shows
    /// this under What Is Sent, and `generate` sends this and nothing
    /// read from the note later.
    private(set) var sampleToSend: ScriptSample?
    /// The reading of the note the sample and the examples come from.
    @ObservationIgnored private var shownTarget = ""
    @ObservationIgnored private var sampleSource: ScriptSampleSource?
    /// Lines of the text the user marked as examples for the generator.
    private(set) var examples: [ScriptExample] = []
    /// Why a line could not be marked.
    private(set) var exampleProblem: String?
    private(set) var isGenerating = false
    /// What the script runs on, in words.
    private(set) var target: String
    /// The script pane's share of the width (#285): the divider between
    /// the script and the diff can be dragged, and where it was left is
    /// remembered.
    private(set) var split: Double

    // MARK: Parts

    @ObservationIgnored let scriptScroll: NSScrollView
    @ObservationIgnored let scriptView: ScriptTextView
    @ObservationIgnored private let painter = SyntaxPainter()
    @ObservationIgnored private(set) weak var editor: BoopTextView?
    /// The window, from `open` until the workbench closes.
    @ObservationIgnored private var presented: ScriptWorkbenchWindow?
    @ObservationIgnored private let layout: ScriptWorkbenchLayoutStore
    /// The library's scripts that can be a starting point, by name.
    @ObservationIgnored let libraryScripts: [BoopScript]
    @ObservationIgnored private let bundledNames: [String]
    @ObservationIgnored private let runner: @MainActor (ScriptRequest) async -> ScriptResponse
    @ObservationIgnored private let generator: (any ScriptGenerator)?
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let onSaved: @MainActor () -> Void
    @ObservationIgnored private let onClose: @MainActor (String) -> Void
    /// Seconds a run may take in the service.
    @ObservationIgnored var timeLimit: Double = 2
    @ObservationIgnored private var snapshot: Snapshot?
    @ObservationIgnored private var generating: Task<Void, Never>?
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var textObserver: NSObjectProtocol?
    /// The note's window closing.
    @ObservationIgnored private var noteWindowObserver: NSObjectProtocol?
    @ObservationIgnored private(set) var isClosed = false
    /// The script it started from, whose description and tags a save keeps.
    @ObservationIgnored private var base: BoopScript?

    /// - Parameters:
    ///   - script: the text the editor starts with.
    ///   - scripts: the library, for starting points and name clashes.
    ///   - folder: the user's Scripts folder, where Save as Script writes.
    ///   - runner: the script service.
    ///   - generator: what writes a draft (ADR 0014), or nil for none.
    ///   - layout: where the window's frame and split are remembered.
    ///   - onSaved: a script was written to the folder.
    ///   - onClose: the workbench closed; its script, to offer again next time.
    init(editor: BoopTextView, script: String, scripts: [BoopScript], folder: URL?,
         runner: @escaping @MainActor (ScriptRequest) async -> ScriptResponse,
         generator: (any ScriptGenerator)? = nil,
         layout: ScriptWorkbenchLayoutStore = .standard,
         onSaved: @escaping @MainActor () -> Void = {},
         onClose: @escaping @MainActor (String) -> Void = { _ in }) {
        self.editor = editor
        self.layout = layout
        split = layout.split
        self.runner = runner
        self.generator = generator
        self.folder = folder
        self.onSaved = onSaved
        self.onClose = onClose
        libraryScripts = scripts.filter { $0.builtIn == nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        bundledNames = scripts.filter(\.isBundled).map(\.name)
        target = ScriptWorkbenchResult.targetDescription(selections: editor.selectedRanges.map(\.rangeValue))
        let (scroll, view) = ScriptTextView.makeScrollable()
        scriptScroll = scroll
        scriptView = view
        painter.attach(to: scriptView)
        painter.replacingDocument { scriptView.string = script }
        painter.load(script, choice: .language(.javascript))
        textObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: scriptView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scriptChanged() }
        }
    }

    isolated deinit {
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
        if let noteWindowObserver { NotificationCenter.default.removeObserver(noteWindowObserver) }
    }

    /// The workbench's window, while it is open.
    var window: NSWindow? { presented?.window }

    var script: String { scriptView.string }

    /// The name a run and a kept result go under.
    var runName: String {
        let name = ScriptHeader.cleanName(name)
        return name.isEmpty ? Self.unnamed : name
    }

    private func scriptChanged() {
        if result != nil, !editedSinceRun { editedSinceRun = true }
    }

    // MARK: Starting points

    func start(from skeleton: ScriptSkeleton) {
        base = nil
        replaceScript(with: skeleton.source)
    }

    /// A script from the library as the base to adapt: its code without
    /// the header, and its name, which saving asks about before it takes
    /// the place of the original.
    func start(from script: BoopScript) {
        guard script.builtIn == nil else { return }
        base = script
        if ScriptHeader.cleanName(name).isEmpty { name = script.name }
        replaceScript(with: ScriptHeader.body(of: script.source))
    }

    /// Replaces the editor's text as one edit that its own Undo takes back.
    private func replaceScript(with text: String) {
        let whole = NSRange(location: 0, length: (scriptView.string as NSString).length)
        guard scriptView.shouldChangeText(in: whole, replacementString: text) else { return }
        scriptView.textStorage?.replaceCharacters(in: whole, with: text)
        scriptView.didChangeText()
        scriptView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: Run

    /// Runs the script as it is now on the note as it is now, each
    /// selected range or the whole note, and shows the result as a diff.
    /// The note is not touched.
    func run() async {
        guard !isRunning, !isClosed, let editor else { return }
        isRunning = true
        defer { isRunning = false }
        let fullText = editor.string
        let selections = editor.selectedRanges.map(\.rangeValue)
        let generation = editor.documentGeneration
        let request = ScriptRequest(scriptName: runName, source: script,
                                    states: ScriptEdits.states(fullText: fullText, selections: selections), timeLimit: timeLimit)
        let started = Date()
        let response = await runner(request)
        let elapsed = Date().timeIntervalSince(started)
        Log.scripts.info("workbench run: \(response.outputs.count) outputs, \(response.errors.count) errors, \(elapsed, format: .fixed(precision: 2)) s")
        // A long diff takes a moment, as in the review.
        let made = await Task.detached(priority: .userInitiated) {
            ScriptWorkbenchResult.make(response: response, fullText: fullText, selections: selections)
        }.value
        guard !isClosed else { return }
        target = ScriptWorkbenchResult.targetDescription(selections: selections)
        snapshot = Snapshot(text: fullText, generation: generation)
        result = made
        editedSinceRun = script != request.source
        notice = nil
    }

    /// Refresh can be chosen: nothing is running and no request is out
    /// (the sample a request was sent with stays on show until it is back).
    var canRefresh: Bool { !isClosed && !isRunning && !isGenerating }

    /// Refresh (#285): reads the note again, the selection or the whole
    /// of it as it is now, and runs the script on it. What Is Sent shows
    /// the new reading too, so what Generate would send is still exactly
    /// what is on show.
    func refresh() async {
        guard canRefresh, let editor else { return }
        target = ScriptWorkbenchResult.targetDescription(selections: editor.selectedRanges.map(\.rangeValue))
        readTarget()
        await run()
    }

    // MARK: Keep and Discard

    /// There is a diff on show to keep, and no run on its way to replace it.
    var canKeep: Bool { !isClosed && !isRunning && (result?.canKeep ?? false) }

    /// Applies the diff on show as one undoable edit and closes, unless
    /// the note is no longer the text the diff was made for: it was
    /// edited in its own window, a review's Keep changed it, or iCloud
    /// did. Then nothing is applied, the workbench stays, and the diff is
    /// dropped: Refresh, or Run, makes it again for the note as it is.
    func keep() {
        guard canKeep, let editor, let edits = result?.edits, let snapshot else {
            NSSound.beep()
            return
        }
        guard editor.applyReviewed(edits, of: snapshot.text, generation: snapshot.generation, named: runName) else {
            NSSound.beep()
            result = nil
            self.snapshot = nil
            editedSinceRun = false
            notice = Notice(isError: true, text: "The note changed since the last run, so nothing was applied. Choose Refresh to run the script on the note as it is now.")
            return
        }
        close()
    }

    /// Closes without touching the note or its undo stack.
    func discard() {
        close()
    }

    /// Ends the workbench and closes its window. The script is handed
    /// back, to start from next time. With `refocus` the note's window
    /// comes forward with the keyboard in the note.
    func close(refocus: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        generating?.cancel()
        checking?.cancel()
        onClose(script)
        if let noteWindowObserver { NotificationCenter.default.removeObserver(noteWindowObserver) }
        noteWindowObserver = nil
        let window = presented
        presented = nil
        window?.close()
        if let editor {
            if editor.workbench === self { editor.workbench = nil }
            if refocus, let noteWindow = editor.window {
                if !noteWindow.isMiniaturized { noteWindow.makeKeyAndOrderFront(nil) }
                noteWindow.makeFirstResponder(editor)
            }
        }
    }

    // MARK: The split

    /// The divider was dragged to make the script pane `width` wide, of
    /// `total` for both panes. Remembered for the next workbench.
    func moveDivider(toScriptWidth width: Double, of total: Double) {
        guard let share = ScriptWorkbenchLayout.split(draggedTo: width, total: total), share != split else { return }
        split = share
        layout.split = share
    }

    // MARK: Save as Script

    /// Writes the script, with a Boop header for `name`, into the Scripts
    /// folder. A name something else has is asked about first; nothing is
    /// written over until `confirmed`, and a yes counts only for the save
    /// that was asked about: if the folder changed since, so that saving
    /// would now do something else, the new question is asked instead.
    func save(confirmed: Bool = false) {
        guard let folder else {
            notice = Notice(isError: true, text: "The Scripts folder is not available.")
            return
        }
        let clean = ScriptHeader.cleanName(name)
        // The folder as it is now, not as the library last read it.
        let plan = ScriptSave.plan(name: clean, existing: UserScriptFiles.existing(in: folder), bundledNames: bundledNames)
        let fileName: String
        var replacing = false
        switch plan {
        case .refused(let why):
            notice = Notice(isError: true, text: why)
            return
        case .write(let name):
            fileName = name
        case .clash(let clash, let name):
            guard confirmed, saveQuestion != nil, askedPlan == plan else {
                ask(plan, name: clean)
                return
            }
            fileName = name
            if case .yours = clash { replacing = true }
        }
        ask(nil)
        let file = ScriptHeader.file(name: clean, description: base?.description ?? "", author: base?.isBundled == false ? base?.author : nil,
                                     icon: base?.icon, tags: base?.tags ?? [], script: script)
        do {
            try UserScriptFiles.write(file, as: fileName, in: folder, replacing: replacing)
        } catch {
            notice = Notice(isError: true, text: "Could not save the script: \(error.localizedDescription)")
            return
        }
        Log.scripts.info("workbench script saved, \(replacing ? "replacing one" : "new", privacy: .public)")
        onSaved()
        notice = Notice(isError: false, text: "Saved as \(clean). It is in the script picker.")
    }

    func cancelSave() {
        ask(nil)
    }

    /// Shows the question for `plan` and remembers which save it is
    /// about; nil takes the question away.
    private func ask(_ plan: ScriptSave.Plan?, name: String = "") {
        askedPlan = plan
        saveQuestion = plan?.question(name: name)
    }

    // MARK: Generate (ADR 0014)

    /// Asks the generator, if there is one, whether it can be used,
    /// without waiting for the answer: a generator that is slow to say
    /// delays the prompt row and nothing else. An answer that comes after
    /// the workbench closed is dropped. Asking sends nothing anywhere.
    private func checkAvailability() {
        guard let generator, checking == nil, !isClosed else { return }
        checking = Task { [weak self] in
            let availability = await generator.availability()
            guard let self, !self.isClosed else { return }
            self.destination = ScriptGeneration.destination(availability)
            self.unavailableReason = ScriptGeneration.unavailableReason(availability)
            self.readTarget()
        }
    }

    /// The availability check in flight or done, for tests to wait on.
    var availabilityCheck: Task<Void, Never>? { checking }

    /// Asks again whether the generator can be used, after it could not:
    /// the user changed something in Settings, or the model is back.
    func checkAgain() {
        guard !isGenerating, !isClosed else { return }
        checking?.cancel()
        checking = nil
        checkAvailability()
    }

    /// The text the script would run on, which is what a sample and the
    /// examples are taken from: the selection, or the whole note.
    var generationTarget: String {
        guard let editor else { return "" }
        let states = ScriptEdits.states(fullText: editor.string, selections: editor.selectedRanges.map(\.rangeValue))
        return states.first?.text ?? ""
    }

    /// Reads the note for what the window shows and Generate sends: when
    /// the workbench learns where a request goes, and on Refresh. Examples
    /// marked on an earlier reading whose lines are no longer there go,
    /// and the window shows the ones that stay.
    private func readTarget() {
        guard let destination else {
            sampleSource = nil
            sampleToSend = nil
            return
        }
        shownTarget = generationTarget
        sampleSource = ScriptSampleSource(target: shownTarget, allowance: destination.allowance)
        if !examples.isEmpty {
            let lines = ScriptExamples.lines(of: shownTarget)
            examples.removeAll { $0.line > lines.count || lines[$0.line - 1] != $0.text }
        }
        refreshSample()
    }

    /// Sizes the sample again for this instruction and these examples,
    /// from the reading the workbench already has: the note is not read, and
    /// the cost does not grow with it. Not while a request is out.
    private func refreshSample() {
        guard !isGenerating else { return }
        sampleToSend = sampleSource?.sample(instruction: instruction, examples: examples)
    }

    /// Marks line `line` of the text as an example.
    func markExample(line: Int) {
        guard !isGenerating, sampleSource != nil else { return }
        switch ScriptExamples.marking(line: line, of: shownTarget, in: examples) {
        case .success(let marked):
            examples = marked
            exampleProblem = nil
            refreshSample()
        case .failure(let refusal):
            exampleProblem = refusal.reason
        }
    }

    func unmarkExample(line: Int) {
        guard !isGenerating else { return }
        examples.removeAll { $0.line == line }
        exampleProblem = nil
        refreshSample()
    }

    /// What the marked line should become; empty for "just handle it".
    func setExpected(_ expected: String, forExampleAt line: Int) {
        guard !isGenerating, let index = examples.firstIndex(where: { $0.line == line }) else { return }
        examples[index].expected = expected
        refreshSample()
    }

    /// Asks the generator for a draft from the instruction, the marked
    /// examples and the sample, exactly as the window shows them, to the
    /// destination it shows. Nothing is read from the note here: if the
    /// note changed since the sample was taken, as it can while the
    /// workbench is open, what is sent is still what was shown. The draft
    /// replaces the editor's text and does not run.
    func generate() {
        guard let generator, let destination, let sample = sampleToSend, generating == nil, !isClosed, editor != nil else { return }
        let examples = examples
        let instruction = instruction
        isGenerating = true
        generating = Task { [weak self] in
            let answer = await ScriptGeneration.run(generator, instruction: instruction, sample: sample,
                                                    examples: examples, destination: destination)
            guard let self else { return }
            self.generating = nil
            self.isGenerating = false
            guard !self.isClosed else { return }
            switch answer {
            case .success(let draft):
                self.base = nil
                self.replaceScript(with: draft)
                self.notice = Notice(isError: false, text: "A draft is in the editor and has not run. Read it, then choose Run.")
            case .failure(let failure):
                if let message = failure.message { self.notice = Notice(isError: true, text: message) }
                // A generator that cannot be used now (the model is not
                // reachable, or the settings are no longer the ones
                // shown) has Generate disabled, with the reason, until it
                // is asked again and the window shows where a request goes.
                if case .unavailable(let reason) = failure {
                    self.destination = nil
                    self.unavailableReason = reason
                    self.sampleSource = nil
                    self.sampleToSend = nil
                }
            }
        }
    }

    func cancelGenerating() {
        generating?.cancel()
    }

    /// The request in flight, for tests to wait on.
    var generatingTask: Task<Void, Never>? { generating }

    // MARK: The window

    /// Opens `session`'s workbench in a window of its own (#285), or, when
    /// its editor already has one, brings that one forward: one workbench
    /// per note window. False when nothing opened.
    ///
    /// A diff review sheet on the note's window (Run Script with Preview)
    /// does not stand in the way, nor the workbench in a review's: each
    /// applies through `BoopTextView.applyReviewed`, which refuses the
    /// second of two changes made for the same text.
    @discardableResult
    static func open(_ session: ScriptWorkbenchSession) -> Bool {
        // A note that cannot be edited has nothing to keep a result in.
        guard !session.isClosed, let editor = session.editor, editor.isEditable, let noteWindow = editor.window else {
            NSSound.beep()
            return false
        }
        if let open = editor.workbench {
            open.bringForward()
            return false
        }
        editor.workbench = session
        session.checkAvailability()
        let window = ScriptWorkbenchWindow(
            session: session, title: ScriptWorkbenchLayout.windowTitle(note: editor.noteTitle),
            layout: session.layout, noteWindow: noteWindow,
            onClose: { [weak session] in session?.close(refocus: false) })
        session.presented = window
        session.noteWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: noteWindow, queue: nil
        ) { [weak session] _ in
            MainActor.assumeIsolated { session?.close(refocus: false) }
        }
        window.show()
        // The script's view joins the window when SwiftUI first lays it out.
        DispatchQueue.main.async { [weak session] in
            guard let session, let window = session.window, session.scriptView.window === window else { return }
            window.makeFirstResponder(session.scriptView)
        }
        return true
    }

    /// Asked for again: the open window comes forward.
    func bringForward() {
        presented?.bringForward()
    }

    /// The note's title changed: the window's follows.
    func noteTitleChanged() {
        guard let editor else { return }
        presented?.window.title = ScriptWorkbenchLayout.windowTitle(note: editor.noteTitle)
    }
}

/// The Scripts folder's files, for Save as Script.
enum UserScriptFiles {
    /// Every file in the folder, with the script name of each `.js` file
    /// whose header reads.
    static func existing(in folder: URL) -> [ScriptSave.Existing] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.map { file in
            let name = file.lastPathComponent
            guard file.pathExtension == "js", let source = try? String(contentsOf: file, encoding: .utf8),
                  let script = try? BoopScript.parse(source, id: name, bundled: false).get()
            else { return ScriptSave.Existing(fileName: name, scriptName: nil) }
            return ScriptSave.Existing(fileName: name, scriptName: script.name)
        }
    }

    /// Writes one script file. A new file never replaces one that
    /// appeared since the folder was read.
    static func write(_ text: String, as fileName: String, in folder: URL, replacing: Bool) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        try Data(text.utf8).write(to: url, options: replacing ? .atomic : .withoutOverwriting)
    }
}

/// The workbench's script editor: a plain text view coloured as
/// JavaScript by the note editor's painter. Not a note editor, so the
/// commands that act on the focused note do not reach it.
final class ScriptTextView: NSTextView {
    /// The font of every character in the editor. A font is immutable;
    /// AppKit does not mark it Sendable, and the storage delegate, which is
    /// not isolated, reads it.
    nonisolated(unsafe) static let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// The colour of text the highlighter does not colour. The workbench
    /// has the system's colours, not a theme's, so this is the system's
    /// text colour, which follows light and dark appearance by itself.
    nonisolated static let baseColor = NSColor.textColor
    nonisolated static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: baseColor]
    }

    static func makeScrollable() -> (NSScrollView, ScriptTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let view = ScriptTextView(usingTextLayoutManager: true)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.font = baseFont
        view.textColor = baseColor
        view.typingAttributes = baseAttributes
        view.textStorage?.delegate = view
        view.drawsBackground = false
        view.allowsUndo = true
        view.isRichText = false
        view.importsGraphics = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.inlinePredictionType = .no
        view.mathExpressionCompletionType = .no
        // Privacy (ADR 0001, ADR 0006): Writing Tools may leave the device.
        view.writingToolsBehavior = .none
        view.setAccessibilityLabel("Script")
        scroll.documentView = view
        return (scroll, view)
    }

    // As in the note editor (ADR 0003): Edit ▸ Substitutions would turn
    // these back on and rewrite the JavaScript as it is typed. Refuse and
    // grey them out.
    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {}
    override func toggleAutomaticDashSubstitution(_ sender: Any?) {}
    override func toggleAutomaticTextReplacement(_ sender: Any?) {}
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {}
    override func toggleAutomaticLinkDetection(_ sender: Any?) {}
    override func toggleAutomaticDataDetection(_ sender: Any?) {}
    override func toggleSmartInsertDelete(_ sender: Any?) {}
    override func toggleAutomaticTextCompletion(_ sender: Any?) {}

    static let refusedToggles: Set<Selector> = [
        #selector(toggleAutomaticQuoteSubstitution(_:)),
        #selector(toggleAutomaticDashSubstitution(_:)),
        #selector(toggleAutomaticTextReplacement(_:)),
        #selector(toggleAutomaticSpellingCorrection(_:)),
        #selector(toggleAutomaticLinkDetection(_:)),
        #selector(toggleAutomaticDataDetection(_:)),
        #selector(toggleSmartInsertDelete(_:)),
        #selector(toggleAutomaticTextCompletion(_:)),
    ]

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.refusedToggles.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }

    /// What is typed next is in the base font and colour too, so the
    /// insertion point in an emptied editor is the height of its text.
    override func didChangeText() {
        super.didChangeText()
        typingAttributes = Self.baseAttributes
    }

    /// Escape does nothing here. A text view would offer completions; and
    /// the workbench is a window (#285), which Escape does not close: a
    /// stray Escape would take a script half written off the screen.
    override func cancelOperation(_ sender: Any?) {}
}

/// Text that enters the editor takes the base font and colour, however it
/// arrives (#286). The font and colour set when the view was made were not
/// enough: a string that replaces the text of an emptied editor (a draft
/// from Generate, a starting point) has no character to take its
/// attributes from, and came out in the text system's default font and
/// black, whatever the appearance. The painter colours with rendering
/// attributes over this and never writes to the text.
extension ScriptTextView: NSTextStorageDelegate {
    nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.length > 0 else { return }
        textStorage.addAttributes(Self.baseAttributes, range: editedRange)
    }
}
