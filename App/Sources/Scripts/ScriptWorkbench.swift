import AppKit
import BoopstashCore
import Observation

/// One open script workbench (#247, ADR 0013): a script the user edits,
/// what it would change in the note as a diff, and Keep, Discard and Save
/// as Script. The script runs only in the script service (ADR 0007), and
/// only when Run is chosen; nothing reaches the note without Keep, which
/// goes through the diff review's own check that the note is still the
/// text the diff was made for.
///
/// What a run, a save and a generator's draft mean is Core's
/// (`ScriptWorkbenchResult`, `ScriptSave`, `ScriptGeneration`); this holds
/// the sheet's state and the script's text view.
@MainActor
@Observable
final class ScriptWorkbenchSession {
    /// Something the sheet says next to the script, apart from what the
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

    // MARK: What the sheet shows

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
    /// The sample Generate sends: taken from the note when the sheet
    /// learns where a request goes, and again when the instruction or the
    /// examples change (they take room from it). The sheet shows this
    /// under What Is Sent, and `generate` sends this and nothing read
    /// from the note later.
    private(set) var sampleToSend: ScriptSample?
    /// Lines of the text the user marked as examples for the generator.
    private(set) var examples: [ScriptExample] = []
    /// Why a line could not be marked.
    private(set) var exampleProblem: String?
    private(set) var isGenerating = false
    /// What the script runs on, in words.
    private(set) var target: String

    // MARK: Parts

    @ObservationIgnored let scriptScroll: NSScrollView
    @ObservationIgnored let scriptView: ScriptTextView
    @ObservationIgnored private let painter = SyntaxPainter()
    @ObservationIgnored private(set) weak var editor: BoopTextView?
    @ObservationIgnored private(set) weak var sheet: NSWindow?
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
    @ObservationIgnored private(set) var isClosed = false
    /// The script it started from, whose description and tags a save keeps.
    @ObservationIgnored private var base: BoopScript?

    /// - Parameters:
    ///   - script: the text the editor starts with.
    ///   - scripts: the library, for starting points and name clashes.
    ///   - folder: the user's Scripts folder, where Save as Script writes.
    ///   - runner: the script service.
    ///   - generator: what writes a draft (ADR 0014), or nil for none.
    ///   - onSaved: a script was written to the folder.
    ///   - onClose: the sheet closed; its script, to offer again next time.
    init(editor: BoopTextView, script: String, scripts: [BoopScript], folder: URL?,
         runner: @escaping @MainActor (ScriptRequest) async -> ScriptResponse,
         generator: (any ScriptGenerator)? = nil,
         onSaved: @escaping @MainActor () -> Void = {},
         onClose: @escaping @MainActor (String) -> Void = { _ in }) {
        self.editor = editor
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
        scriptView.onCancel = { [weak self] in self?.discard() }
        textObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: scriptView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scriptChanged() }
        }
    }

    isolated deinit {
        if let textObserver { NotificationCenter.default.removeObserver(textObserver) }
    }

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

    // MARK: Keep and Discard

    /// There is a diff on show to keep, and no run on its way to replace it.
    var canKeep: Bool { !isClosed && !isRunning && (result?.canKeep ?? false) }

    /// Applies the diff on show as one undoable edit and closes, unless
    /// the note is no longer the text the diff was made for. Then nothing
    /// is applied, the sheet stays, and the diff is dropped: Run makes it
    /// again for the note as it is.
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
            notice = Notice(isError: true, text: "The note changed since the last run, so nothing was applied. Run again to see the change against the note as it is now.")
            return
        }
        close()
    }

    /// Closes without touching the note or its undo stack.
    func discard() {
        close()
    }

    /// Ends the sheet. The script is handed back, to start from next time.
    func close(refocus: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        generating?.cancel()
        checking?.cancel()
        onClose(script)
        if let sheet {
            if let parent = sheet.sheetParent { parent.endSheet(sheet) }
            sheet.orderOut(nil)
        }
        if let editor {
            if editor.workbench === self { editor.workbench = nil }
            if refocus { editor.window?.makeFirstResponder(editor) }
        }
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
    /// the sheet closed is dropped. Asking sends nothing anywhere.
    private func checkAvailability() {
        guard let generator, checking == nil, !isClosed else { return }
        checking = Task { [weak self] in
            let availability = await generator.availability()
            guard let self, !self.isClosed else { return }
            self.destination = ScriptGeneration.destination(availability)
            self.unavailableReason = ScriptGeneration.unavailableReason(availability)
            self.refreshSample()
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

    /// Takes the sample again from the note as it is now, for this
    /// instruction and these examples. Not while a request is out.
    private func refreshSample() {
        guard !isGenerating else { return }
        sampleToSend = destination.map {
            $0.allowance.sample(of: generationTarget, instruction: instruction, examples: examples)
        }
    }

    /// Marks line `line` of the text as an example.
    func markExample(line: Int) {
        guard !isGenerating else { return }
        switch ScriptExamples.marking(line: line, of: generationTarget, in: examples) {
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
    /// examples and the sample, exactly as the sheet shows them, to the
    /// destination it shows. Nothing is read from the note here: if the
    /// note changed under the sheet since the sample was taken, what is
    /// sent is still what was shown. The draft replaces the editor's text
    /// and does not run.
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
                // is asked again and the sheet shows where a request goes.
                if case .unavailable(let reason) = failure {
                    self.destination = nil
                    self.unavailableReason = reason
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

    // MARK: The sheet

    /// Opens a workbench on `editor`'s window. One sheet at a time: not
    /// over a review, not twice, and a sheet that is closing (the script
    /// picker's) is waited for, as the review waits. The task ends when
    /// the sheet is up, or when it is known not to be. It does not wait
    /// for the generator to say whether it is available: the editor is
    /// held for the workbench only while a sheet is on its way or up.
    @discardableResult
    static func open(_ session: ScriptWorkbenchSession) -> Task<Void, Never> {
        // A note that cannot be edited has nothing to keep a result in.
        guard let editor = session.editor, editor.isEditable else {
            NSSound.beep()
            return Task {}
        }
        guard editor.workbench == nil, editor.pendingReview == nil else {
            NSSound.beep()
            editor.showMessage?("The script workbench could not open while another sheet is open.")
            return Task {}
        }
        editor.workbench = session
        let wait = editor.reviewSheetWait
        session.checkAvailability()
        return Task { [weak editor] in
            let deadline = ContinuousClock.now + wait
            while editor?.window?.attachedSheet != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard let editor, editor.workbench === session, !session.isClosed else { return }
            // Never over a sheet that is staying.
            guard let window = editor.window, window.attachedSheet == nil else {
                session.close(refocus: false)
                NSSound.beep()
                editor.showMessage?("The script workbench could not open while another sheet is open.")
                return
            }
            session.sheet = ScriptWorkbenchPresenter.present(session, over: window)
        }
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
    /// Escape.
    var onCancel: (() -> Void)?

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
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.font = font
        view.textColor = .textColor
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
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

    /// Escape closes the sheet; a text view would offer completions.
    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}
