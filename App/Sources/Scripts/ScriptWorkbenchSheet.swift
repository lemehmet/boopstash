import AppKit
import BoopstashCore
import SwiftUI

/// The script workbench's sheet (#247): the script on the left, what it
/// would change on the right, and Run, Keep, Discard and Save as Script
/// below. The prompt row is there only when a generator is available,
/// which none is yet.
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

/// The prompt field and Generate, only with a generator that is available.
private struct WorkbenchPrompt: View {
    @Bindable var session: ScriptWorkbenchSession

    var body: some View {
        if let destination: ScriptGeneratorDestination = session.destination {
            WorkbenchPromptRow(session: session, destination: destination)
            Divider()
        }
    }
}

private struct WorkbenchPromptRow: View {
    @Bindable var session: ScriptWorkbenchSession
    let destination: ScriptGeneratorDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("What should the script do?", text: $session.instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.generate() }
                    .disabled(session.isGenerating)
                WorkbenchGenerateButton(session: session)
            }
            Text(destination.notice).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
