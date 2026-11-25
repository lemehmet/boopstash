import AppKit
import BoopstashCore
import SwiftUI

/// What the script workbench's window shows (#247, #285): the script on
/// the left, what it would change on the right, with a divider between
/// them that can be dragged, and Run, Keep, Discard and Save as Script
/// below. The prompt row is there only when a model endpoint is set up
/// (ADR 0014). The panes take whatever room the window has.
struct ScriptWorkbenchView: View {
    @Bindable var session: ScriptWorkbenchSession

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchHeader(session: session)
            Divider()
            WorkbenchPrompt(session: session)
            WorkbenchPanes(session: session)
            Divider()
            WorkbenchFooter(session: session)
        }
        .frame(minWidth: ScriptWorkbenchLayout.minimumSize.width, idealWidth: ScriptWorkbenchLayout.defaultSize.width, maxWidth: .infinity,
               minHeight: ScriptWorkbenchLayout.minimumSize.height, idealHeight: ScriptWorkbenchLayout.defaultSize.height, maxHeight: .infinity)
    }
}

private struct WorkbenchHeader: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Runs on").font(.subheadline).foregroundStyle(.secondary)
            Text(session.target).font(.headline)
            WorkbenchRefreshButton(session: session)
            Spacer()
            WorkbenchStartMenu(session: session)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Refresh (#285): the note can be edited while the workbench is open, so
/// this reads it again and runs.
private struct WorkbenchRefreshButton: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        Button("Refresh") { Task { await session.refresh() } }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!session.canRefresh)
            .help("Read the selection, or the whole note, again as it is now and run the script on it (⌘R). The note is not touched.")
    }
}

/// Where the script starts: a skeleton, or a script from the library.
private struct WorkbenchStartMenu: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        Menu("Start From") {
            ForEach(ScriptSkeleton.allCases) { (skeleton: ScriptSkeleton) in
                Button(skeleton.name) { session.start(from: skeleton) }
                    .help(skeleton.summary)
            }
            Divider()
            Menu("A Script in the Library") {
                ForEach(session.libraryScripts) { (script: BoopScript) in
                    Button(script.isBundled ? script.name : "\(script.name) (yours)") { session.start(from: script) }
                }
            }
        }
        .fixedSize()
        .help("Replace the script with a starting point. Undo in the script brings the old one back.")
    }
}

/// The prompt field and Generate (ADR 0014): there with a generator that
/// is set up, disabled with the reason when it cannot be used now, and
/// absent when nothing is set up.
private struct WorkbenchPrompt: View {
    @Bindable var session: ScriptWorkbenchSession

    var body: some View {
        if let destination: ScriptGeneratorDestination = session.destination {
            WorkbenchPromptRow(session: session, destination: destination)
            Divider()
        } else if let reason: String = session.unavailableReason {
            WorkbenchUnavailablePrompt(session: session, reason: reason)
            Divider()
        }
    }
}

/// Generate, disabled, and why: a model is set up and cannot be used now.
private struct WorkbenchUnavailablePrompt: View {
    @Bindable var session: ScriptWorkbenchSession
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("What should the script do?", text: $session.instruction)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("Generate") {}
                    .disabled(true)
                    .help(reason)
                Button("Check Again") { session.checkAgain() }
                    .help("Ask again whether the model can be used. This sends nothing.")
            }
            Text("Generate is not available: \(reason)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct WorkbenchPromptRow: View {
    @Bindable var session: ScriptWorkbenchSession
    let destination: ScriptGeneratorDestination
    /// Open from the start: what is sent is shown before Generate.
    @State private var showsSent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("What should the script do?", text: $session.instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.generate() }
                    .disabled(session.isGenerating)
                if let indicator: ModelEndpointIndicator = destination.indicator {
                    ModelEndpointMark(indicator: indicator)
                }
                WorkbenchGenerateButton(session: session)
            }
            Text(destination.notice).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("What Is Sent", isExpanded: $showsSent) {
                if showsSent { WorkbenchSent(session: session) }
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The warning mark (ADR 0014): a Unicode symbol whose details, what is
/// sent and to which host, are its hover text and its accessibility
/// label. The stronger mark, for text that leaves the local network, is
/// also coloured.
struct ModelEndpointMark: View {
    let indicator: ModelEndpointIndicator

    var body: some View {
        Text(indicator.symbol)
            .font(.body.weight(indicator.isStrong ? .bold : .regular))
            .foregroundStyle(indicator.isStrong ? Color.orange : Color.secondary)
            .help(indicator.details)
            .accessibilityLabel(indicator.details)
            .focusable()
    }
}

/// Exactly what Generate sends from the note: the marked examples, then
/// the sample the session holds, line by line. A line is marked as an
/// example with the button before it, or by its number.
private struct WorkbenchSent: View {
    let session: ScriptWorkbenchSession
    @State private var lineNumber = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkbenchExamples(session: session)
            HStack {
                TextField("Line number", text: $lineNumber)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { mark() }
                Button("Mark Line as Example") { mark() }
                    .disabled(Int(lineNumber.trimmingCharacters(in: .whitespaces)) == nil)
                    .help("Send this line of the text as an example, with what it should become if you say.")
                if let problem: String = session.exampleProblem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            if let sample: ScriptSample = session.sampleToSend {
                Text(sample.summary).foregroundStyle(.secondary)
                WorkbenchSampleLines(session: session, lines: ScriptExamples.lines(of: sample.text).map(String.init))
            }
        }
        .padding(.top, 4)
    }

    private func mark() {
        guard let line = Int(lineNumber.trimmingCharacters(in: .whitespaces)) else { return }
        session.markExample(line: line)
        if session.exampleProblem == nil { lineNumber = "" }
    }
}

/// The lines marked as examples, each with what it should become.
private struct WorkbenchExamples: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        if !session.examples.isEmpty {
            Text("Examples, sent ahead of the sample:").foregroundStyle(.secondary)
            // Scrolls when the examples are long, so each is shown whole.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.examples) { (example: ScriptExample) in
                        WorkbenchExampleRow(session: session, example: example)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }
}

private struct WorkbenchExampleRow: View {
    let session: ScriptWorkbenchSession
    let example: ScriptExample

    /// The line is shown whole, wrapped, however long it is: it is sent
    /// whole, and nothing is sent that was not shown.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(example.line)").monospacedDigit().foregroundStyle(.secondary)
                Text(example.text)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("Should become (optional)", text: Binding(
                    get: { example.expected },
                    set: { session.setExpected($0, forExampleAt: example.line) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button("Remove") { session.unmarkExample(line: example.line) }
            }
        }
    }
}

/// The sample's lines, each with a button that marks it as an example.
private struct WorkbenchSampleLines: View {
    let session: ScriptWorkbenchSession
    let lines: [String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { (index: Int, line: String) in
                    WorkbenchSampleLine(session: session, number: index + 1, line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 130)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("The sample that will be sent")
    }
}

private struct WorkbenchSampleLine: View {
    let session: ScriptWorkbenchSession
    let number: Int
    let line: String

    var body: some View {
        let marked: Bool = session.examples.contains { $0.line == number }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(marked ? "◆" : "◇") {
                if marked { session.unmarkExample(line: number) } else { session.markExample(line: number) }
            }
            .buttonStyle(.plain)
            .help(marked ? "Line \(number) is an example. Click to unmark it." : "Mark line \(number) as an example.")
            .accessibilityLabel(marked ? "Unmark line \(number) as an example" : "Mark line \(number) as an example")
            Text("\(number)").monospacedDigit().foregroundStyle(.secondary)
            Text(line)
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct WorkbenchGenerateButton: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        if session.isGenerating {
            ProgressView().controlSize(.small)
            Button("Cancel") { session.cancelGenerating() }
        } else {
            Button("Generate") { session.generate() }
                .disabled(session.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// The script and the diff side by side, with the divider where the user
/// left it (#285): the script has its share of the width, whatever the
/// window's size, and the diff has the rest.
private struct WorkbenchPanes: View {
    let session: ScriptWorkbenchSession
    static let space = "workbench.panes"
    /// The divider's width: a line, with room either side to take hold of.
    static let divider: CGFloat = 9

    var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            let total: Double = max(Double(geometry.size.width - Self.divider), 0)
            let width: Double = ScriptWorkbenchLayout.scriptWidth(split: session.split, total: total)
            HStack(spacing: 0) {
                WorkbenchScriptPane(session: session)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                WorkbenchDivider(session: session, total: total)
                WorkbenchDiffPane(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(.named(Self.space))
        }
    }
}

/// The divider between the script and the diff. Dragged, or moved with
/// the accessibility increment and decrement.
private struct WorkbenchDivider: View {
    let session: ScriptWorkbenchSession
    /// The width the two panes share.
    let total: Double

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: WorkbenchPanes.divider)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(drag)
            .help("Drag to give the script or the diff more room")
            .accessibilityElement()
            .accessibilityLabel("Divider between the script and the diff")
            .accessibilityValue("\(Int((session.split * 100).rounded())) percent for the script")
            .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
                let step: Double = direction == .increment ? 0.05 : -0.05
                session.moveDivider(toScriptWidth: (session.split + step) * total, of: total)
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(WorkbenchPanes.space))
            .onChanged { (value: DragGesture.Value) in
                session.moveDivider(toScriptWidth: Double(value.location.x - WorkbenchPanes.divider / 2), of: total)
            }
    }
}

/// The script, and under it what the last run and the workbench have to say.
private struct WorkbenchScriptPane: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchScriptEditor(scroll: session.scriptScroll)
            Divider()
            WorkbenchNotes(session: session)
        }
    }
}

/// The session's own text view, so its text and undo stack outlive any
/// redraw of the window.
private struct WorkbenchScriptEditor: NSViewRepresentable {
    let scroll: NSScrollView

    func makeNSView(context: Context) -> NSScrollView { scroll }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

private struct WorkbenchNotes: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                WorkbenchStatus(session: session)
                ForEach(session.result?.notes ?? []) { (note: ScriptWorkbenchResult.Note) in
                    WorkbenchNoteRow(isError: note.kind == .error, text: note.text)
                }
                if let notice: ScriptWorkbenchSession.Notice = session.notice {
                    WorkbenchNoteRow(isError: notice.isError, text: notice.text)
                }
                WorkbenchSaveQuestion(session: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 64, idealHeight: 96, maxHeight: 140)
    }
}

/// How the last run ended, in a line.
private struct WorkbenchStatus: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        Text(ScriptWorkbenchStyle.status(running: session.isRunning, result: session.result, edited: session.editedSinceRun))
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// An error or a message: an icon as well as a colour.
private struct WorkbenchNoteRow: View {
    let isError: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.callout)
            .foregroundStyle(isError ? Color.red : Color.primary)
            .textSelection(.enabled)
            .accessibilityLabel(isError ? "Error: \(text)" : text)
    }
}

/// A save whose name is taken: nothing is written until this is answered.
private struct WorkbenchSaveQuestion: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        if let question: String = session.saveQuestion {
            HStack {
                Label(question, systemImage: "questionmark.circle").font(.callout)
                Button("Save") { session.save(confirmed: true) }
                Button("Don’t Save") { session.cancelSave() }
            }
        }
    }
}

/// The diff of the last run, or why there is none.
private struct WorkbenchDiffPane: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        if let result: ScriptWorkbenchResult = session.result, result.canKeep {
            DiffReviewBody(content: result.content)
        } else {
            Text(ScriptWorkbenchStyle.placeholder(result: session.result))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct WorkbenchFooter: View {
    @Bindable var session: ScriptWorkbenchSession

    var body: some View {
        HStack {
            TextField("Script name", text: $session.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { session.save() }
            Button("Save as Script") { session.save() }
                .disabled(ScriptHeader.cleanName(session.name).isEmpty)
                .help("Save the script in your Scripts folder, where the script picker finds it")
            Spacer()
            WorkbenchActions(session: session)
        }
        .padding(12)
    }
}

private struct WorkbenchActions: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        // No Escape: this is a window, closed as windows are (⌘W).
        Button("Discard") { session.discard() }
            .help("Close the workbench without touching the note. The script is offered again the next time it opens.")
        Button("Run") { Task { await session.run() } }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(session.isRunning)
            .help("Run the script (⌘↩) and show what it would change. The note is not touched.")
        Button("Keep") { session.keep() }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(!session.canKeep)
            .help("Apply the change on show to the note (⇧⌘↩), as one undo step")
    }
}

/// The workbench's words. Pure, so the hosted tests can check them without
/// drawing anything.
enum ScriptWorkbenchStyle {
    static func status(running: Bool, result: ScriptWorkbenchResult?, edited: Bool) -> String {
        if running { return "Running…" }
        guard let result else { return "Not run yet." }
        return edited ? "\(result.status) The script has changed since: run it again." : result.status
    }

    static func placeholder(result: ScriptWorkbenchResult?) -> String {
        guard let result else { return "Run the script to see what it would change.\nNothing reaches the note until you choose Keep." }
        return result.status
    }
}
