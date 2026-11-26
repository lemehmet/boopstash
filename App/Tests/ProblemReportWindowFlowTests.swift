import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Help ▸ Report a Problem… with the script workbench in front (#289):
/// the report is its note's window's. Windows are passed in; nothing here
/// depends on which window the system made key. What a report may say is
/// tested in `ProblemReportFlowTests` and in Core.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProblemReportWindowFlowTests {
    let model: AppModel
    let open: Note
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("report-workbench-\(UUID().uuidString)", isDirectory: true)
    let suite = "report-workbench-layout-\(UUID().uuidString)"
    static let body = "{\n  \"a\": {\n    \"b\": 1\n  }\n}\n"

    init() throws {
        model = AppModel(store: try .inMemory())
        let note = Note(title: "Synthetic", body: Self.body, createdAt: Date())
        try model.store.save(note)
        open = note
        model.selection = note.id
    }

    func host() -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.load(Self.body, syntax: .language(.json))
        return (window, view)
    }

    func workbench(on view: BoopTextView) -> ScriptWorkbenchSession {
        let session = ScriptWorkbenchSession(
            editor: view, script: ScriptSkeleton.lineByLine.source, scripts: [], folder: folder,
            runner: { _ in ScriptResponse(outputs: [], errors: ["not run in this test"]) },
            generator: nil,
            layout: ScriptWorkbenchLayoutStore(defaults: UserDefaults(suiteName: suite)!),
            onSaved: {}, onClose: { _ in })
        ScriptWorkbenchSession.open(session)
        return session
    }

    func close(_ window: NSWindow, _ view: BoopTextView) {
        view.workbench?.close(refocus: false)
        window.close()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    /// The scenario of #289: a note is open, its workbench is in front,
    /// and the report has the facts of the note the workbench is for,
    /// those only its editor knows included.
    @Test func withTheWorkbenchInFrontTheReportIsItsNotesWindows() async throws {
        let (window, view) = host()
        defer { close(window, view) }
        try #require(try await eventually { !view.folding.regions.isEmpty })
        view.folding.foldAll()
        let folds = view.folding.folded.count
        try #require(folds > 0)
        let session = workbench(on: view)
        let own = try #require(session.window)

        let subject = try #require(ProblemReportSheet.subject(key: own, main: nil))
        #expect(subject === window, "the note's window, not the workbench's")
        #expect(ProblemReportSheet.subject(key: nil, main: own) === window, "the workbench as the main window")
        let editor = try #require(LiveDiagnostics.editor(in: subject))
        #expect(editor === view)
        let facts = try #require(model.problemReportNote(editor: editor))
        #expect(facts.id == open.id && facts.folds == folds && facts.language == "JSON")
        // The picture is of the note's window: its size, not the workbench's.
        let picture = try #require(LiveDiagnostics.png(of: subject).flatMap(NSBitmapImageRep.init(data:)))
        let frame = try #require(window.contentView?.superview?.bounds.size)
        #expect(own.frame.size != window.frame.size)
        #expect(abs(CGFloat(picture.pixelsWide) / CGFloat(picture.pixelsHigh) - frame.width / frame.height) < 0.01)
    }

    /// A sheet on the workbench's window leads to the note's too.
    @Test func aSheetOnTheWorkbenchLeadsToTheNotesWindow() throws {
        let (window, view) = host()
        defer { close(window, view) }
        let own = try #require(workbench(on: view).window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        own.beginSheet(sheet, completionHandler: nil)
        defer { own.endSheet(sheet) }
        #expect(ProblemReportSheet.subject(key: sheet, main: nil) === window)
    }

    /// From the note's window, and from a sheet on it, as before.
    @Test func theNotesWindowAndASheetOnItAreUnchanged() throws {
        let (window, view) = host()
        defer { close(window, view) }
        #expect(ProblemReportSheet.subject(key: window, main: nil) === window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        defer { window.endSheet(sheet) }
        #expect(ProblemReportSheet.subject(key: sheet, main: nil) === window)
        // With the workbench open but the note's window in front, too.
        _ = workbench(on: view)
        #expect(ProblemReportSheet.subject(key: window, main: nil) === window)
        #expect(ProblemReportSheet.subject(key: nil, main: nil) == nil)
    }

    /// A workbench that has closed is no workbench: its window is no
    /// longer anything's, and nothing of it leads to the note.
    @Test func aClosedWorkbenchLeadsNowhere() throws {
        let (window, view) = host()
        defer { close(window, view) }
        let session = workbench(on: view)
        let own = try #require(session.window)
        session.close(refocus: false)
        // Asked of the closed workbench's own window: it is described as
        // it is, like any window, and does not stand for the note's.
        #expect(ProblemReportSheet.subject(key: own, main: window) === own)
        #expect(ProblemReportSheet.subject(key: nil, main: own) === own)
        #expect(ProblemReportSheet.subject(key: window, main: own) === window)
    }
}
