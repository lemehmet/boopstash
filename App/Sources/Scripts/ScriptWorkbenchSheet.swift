import AppKit
import BoopstashCore
import SwiftUI

/// The script workbench's sheet (#247): the script on the left, what it
/// would change on the right, and Run, Keep, Discard and Save as Script
/// below. The prompt row is there only when a model endpoint is set up
/// (ADR 0014).
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
        .frame(minWidth: 780, idealWidth: 1000, minHeight: 440, idealHeight: 620)
    }
}

private struct WorkbenchHeader: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Script Workbench").font(.headline)
            Text(session.target).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            WorkbenchStartMenu(session: session)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
    @State private var showsSent = false

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

/// Exactly what Generate would send from the note now: the marked
/// examples, then the sample, line by line. A line is marked as an
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
            ForEach(session.examples) { (example: ScriptExample) in
                WorkbenchExampleRow(session: session, example: example)
            }
        }
    }
}

private struct WorkbenchExampleRow: View {
    let session: ScriptWorkbenchSession
    let example: ScriptExample

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(example.line)").monospacedDigit().foregroundStyle(.secondary)
            Text(example.text).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.tail)
            TextField("Should become (optional)", text: Binding(
                get: { example.expected },
                set: { session.setExpected($0, forExampleAt: example.line) }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Button("Remove") { session.unmarkExample(line: example.line) }
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
            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
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

private struct WorkbenchPanes: View {
    let session: ScriptWorkbenchSession

    var body: some View {
        HSplitView {
            WorkbenchScriptPane(session: session)
                .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            WorkbenchDiffPane(session: session)
                .frame(minWidth: 320, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The script, and under it what the last run and the sheet have to say.
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
/// redraw of the sheet.
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
        Button("Discard", role: .cancel) { session.discard() }
            .keyboardShortcut(.cancelAction)
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

/// The sheet's words. Pure, so the hosted tests can check them without
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

/// Shows a workbench as a sheet on a window.
@MainActor
enum ScriptWorkbenchPresenter {
    /// The sheet, already attached to `window`. The session ends it.
    static func present(_ session: ScriptWorkbenchSession, over window: NSWindow) -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = "Script Workbench"
        sheet.contentViewController = NSHostingController(rootView: ScriptWorkbenchView(session: session))
        sheet.setContentSize(NSSize(width: 1000, height: 620))
        window.beginSheet(sheet, completionHandler: nil)
        // The script's view joins the sheet when SwiftUI first lays it out.
        DispatchQueue.main.async { [weak sheet] in
            guard let sheet, session.scriptView.window === sheet else { return }
            sheet.makeFirstResponder(session.scriptView)
        }
        return sheet
    }
}
