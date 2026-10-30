import AppKit
import BoopstashCore
import os
import SwiftUI
import Testing
@testable import Boopstash

/// Help ▸ Report a Problem… and Copy as GitHub Issue (#185), against an
/// in-memory store and private pasteboards.
@MainActor
@Suite(.serialized)
struct ProblemReportFlowTests {
    let model: AppModel
    let marker = "MARKER-185-c0ffee"
    let open: Note

    let png: Data = {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }()

    init() throws {
        model = AppModel(store: try .inMemory())
        var note = Note(title: "Title \(marker)", body: "{\"secret\": \"\(marker)\"}\n", createdAt: Date())
        note.titleIsUserSet = true
        try model.store.save(note)
        open = note
        model.selection = note.id
    }

    @discardableResult
    func report(logs: [String]?, screenshot: Bool) throws -> Note {
        let made = model.createProblemReport(environment: model.problemReportEnvironment(),
                                             note: model.problemReportNote(editor: nil), list: model.problemReportList(),
                                             logLines: logs, screenshot: screenshot ? png : nil)
        return try #require(made)
    }

    func attachments(of note: Note) throws -> [NoteAttachment] {
        try model.store.attachments(referencedBy: try #require(try model.store.note(id: note.id)).body)
    }

    @Test func aReportIsSelectedLabelledAndHasEverySection() throws {
        let note = try report(logs: ["12:00:00.000 store info: opened"], screenshot: true)
        #expect(model.selection == note.id)
        #expect(note.title.hasPrefix("Problem report — "))
        #expect(note.titleIsUserSet)
        let body = note.body
        #expect(body.hasPrefix("## What happened\n\n\n## What I expected\n\n\n## Steps\n"))
        #expect(body.contains("## Environment"))
        #expect(body.contains("- Note: \(open.id.uuidString.lowercased())"))
        #expect(body.contains("- Language: JSON (detected)"))
        #expect(body.contains("## Recent logs"))
        #expect(body.contains("## Screenshot"))
        let shots = try attachments(of: note)
        #expect(shots.count == 1)
        #expect(try model.store.data(for: try #require(shots.first)) == png)
        #expect(try model.store.labels(of: note.id).map(\.name) == ["bug"])
    }

    @Test func aReportHoldsNeitherTheNotesTextNorItsTitle() throws {
        let note = try report(logs: [], screenshot: false)
        #expect(!note.body.contains(marker))
        #expect(!note.body.contains(open.title))
        #expect(!note.title.contains(marker))
    }

    @Test func withBothOptionsOffThereIsNoScreenshotAndNoLogs() throws {
        let note = try report(logs: nil, screenshot: false)
        #expect(try attachments(of: note).isEmpty)
        #expect(!note.body.contains("## Recent logs"))
        #expect(!note.body.contains("attachment:"))
    }

    @Test func aDeletedBugLabelIsMadeAgain() throws {
        let first = try report(logs: nil, screenshot: false)
        let label = try #require(try model.store.labels(of: first.id).first)
        try model.store.deleteLabel(id: label.id)
        let second = try report(logs: nil, screenshot: false)
        let again = try #require(try model.store.labels(of: second.id).first)
        #expect(again.name == "bug")
        #expect(again.color == ProblemReport.labelColor)
        #expect(again.id != label.id)
    }

    @Test func aLabelFilterThatWouldHideTheReportIsCleared() throws {
        let work = try model.store.createLabel(name: "work", color: "#0e8a16")
        model.query.labels = [work.id]
        let note = try report(logs: nil, screenshot: false)
        #expect(model.selection == note.id)
        #expect(model.query.labels.isEmpty)
    }

    @Test func aBugLabelFilterStays() throws {
        let bug = try model.store.labelCreatingIfMissing(named: "bug", color: ProblemReport.labelColor)
        let work = try model.store.createLabel(name: "work", color: "#0e8a16")
        model.query.labels = [bug.id, work.id]
        _ = try report(logs: nil, screenshot: false)
        #expect(model.query.labels == [bug.id])
    }

    @Test func theListFilterIsDescribedWithoutItsText() throws {
        let label = try model.store.createLabel(name: "work", color: "#0e8a16")
        model.query = NoteQuery(text: marker, scope: .content, days: 7, labels: [label.id])
        let list = model.problemReportList()
        #expect(list == ProblemReport.List(scope: "content", days: 7, labels: ["work"], hasFilterText: true, similarNotes: "off"))
    }

    @Test func copyAsGitHubIssueLeavesNoAttachmentReferences() throws {
        let note = try report(logs: nil, screenshot: true)
        #expect(model.selection == note.id)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var opened: [URL] = []
        #expect(model.copySelectionAsGitHubIssue(pasteboard: pasteboard) { opened.append($0) })
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(!copied.lowercased().contains("attachment:"))
        #expect(copied.contains(ProblemReport.attachmentPlaceholder))
        #expect(opened == [URL(string: "https://github.com/lemehmet/boopstash/issues/new")!])
        #expect(opened.first?.query == nil)
    }

    @Test func copyAsGitHubIssueNeedsASelection() {
        model.selection = nil
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var opened: [URL] = []
        #expect(!model.copySelectionAsGitHubIssue(pasteboard: pasteboard) { opened.append($0) })
        #expect(opened.isEmpty)
    }

    // MARK: The live parts

    @Test func theWindowImageShowsTheEditorsText() throws {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        window.appearance = NSAppearance(named: .aqua)
        view.load(String(repeating: "████████ ████ ██████\n", count: 8))
        window.displayIfNeeded()
        #expect(LiveDiagnostics.editor(in: window) === view)
        let data = try #require(LiveDiagnostics.png(of: window))
        let rep = try #require(NSBitmapImageRep(data: data))
        // Drawn text means dark pixels on the light background; a blank
        // render would have none.
        var dark = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                if let color = rep.colorAt(x: x, y: y), color.brightnessComponent < 0.3, color.alphaComponent > 0.5 { dark += 1 }
            }
        }
        #expect(dark > 50, "\(dark) dark pixels")
    }

    @Test func recentLogReadsThisProcesssOwnLines() async throws {
        let token = UUID().uuidString
        let since = Date().addingTimeInterval(-5)
        Log.diagnostics.notice("report test \(token, privacy: .public)")
        let lines = await Task.detached { LiveDiagnostics.recentLog(since: since) }.value
        #expect(lines.contains { $0.contains(token) && $0.contains("diagnostics") }, "\(lines.suffix(5))")
    }
}

/// The screenshot of a real window: on macOS 26 the sidebar is glass and
/// its rows are SwiftUI's, neither of which a window's views draw as they
/// are (`LiveDiagnostics.png(of:)`).
@MainActor
@Suite(.serialized)
struct ProblemReportWindowImageTests {
    @Test func theNoteListsRowsAreInTheImage() async throws {
        let model = AppModel(store: try .inMemory())
        for (index, title) in ["First note", "Second note", "Third note"].enumerated() {
            try model.store.save(Note(title: title, body: "text", createdAt: Date().addingTimeInterval(Double(-60 * index))))
        }
        let hosting = NSHostingView(rootView: MainWindow(model: model, keymap: Keymap(preset: .vsCode), appearance: EditorAppearance()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<50 where model.notes.count < 3 { try await Task.sleep(for: .milliseconds(100)) }
        try #require(model.notes.count == 3)
        try await Task.sleep(for: .milliseconds(500))
        let png = try #require(LiveDiagnostics.png(of: window))
        let rep = try #require(NSBitmapImageRep(data: png))
        // Below the toolbar and the filter field, in the sidebar: the rows'
        // text is dark on the light background. Undrawn rows leave it blank,
        // and undrawn glass leaves it black.
        let scale = Double(rep.pixelsWide) / window.frame.width
        var dark = 0, total = 0
        for x in stride(from: Int(30 * scale), to: Int(250 * scale), by: 2) {
            for y in stride(from: Int(110 * scale), to: Int(300 * scale), by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if color.brightnessComponent < 0.4 { dark += 1 }
            }
        }
        #expect(dark > 100, "\(dark) dark pixels")
        #expect(dark < total / 3, "\(dark) of \(total) pixels dark")
    }
}
