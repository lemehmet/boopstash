import Foundation
import Testing
@testable import BoopstashCore

/// Help ▸ Report a Problem… (#185): the report's Markdown, the issue
/// conversion, log capping and the `bug` label. Stores are in memory.
@Suite struct ProblemReportTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let date = Date(timeIntervalSince1970: 1_793_354_700) // 2026-10-30 10:05 UTC
    static let noteID = UUID(uuidString: "6F9A3C1E-0000-4000-8000-000000000001")!

    static let environment = ProblemReport.Environment(
        appVersion: "0.5.0", build: "42", distribution: .developerID, macOSVersion: "Version 26.1 (Build 25B78)",
        chip: "Apple M3 Pro", appleIntelligence: "available", iCloudEnvironment: "Production",
        sync: .on(lastSynced: date, problem: "The network is offline."), semanticSearch: true,
        keymapPreset: "VS Code", linuxHabits: false)

    static let list = ProblemReport.List(scope: "everywhere", days: 7, labels: ["bug", "work"], hasFilterText: true,
                                         similarNotes: "off")

    static let note = ProblemReport.SelectedNote(id: noteID, body: "{\n  \"a\": 1\n}\n", language: "JSON",
                                                 languageDetected: true, attachments: 2, folds: 1, preview: .beside)

    func full() -> ProblemReport {
        ProblemReport(createdAt: Self.date, environment: Self.environment, note: Self.note, list: Self.list,
                      logLines: ["10:01 sync: sent 3 records"], screenshot: "![](attachment:\(Self.noteID.uuidString.lowercased()))")
    }

    @Test func titleCarriesTheDate() {
        #expect(ProblemReport.title(for: Self.date, timeZone: Self.utc) == "Problem report — 2026-10-30 10:05")
    }

    @Test func everyFieldRenders() {
        let text = full().markdown(timeZone: Self.utc)
        // The user's sections come first, empty.
        #expect(text.hasPrefix("## What happened\n\n\n## What I expected\n\n\n## Steps\n"))
        for expected in [
            "- BoopStash: 0.5.0 (42), Developer ID (Homebrew)",
            "- macOS: Version 26.1 (Build 25B78)",
            "- Chip: Apple M3 Pro",
            "- Apple Intelligence: available",
            "- iCloud environment: Production",
            "- Sync: on, last synced 2026-10-30 10:05; problem: The network is offline.",
            "- Semantic search: on",
            "- Key bindings: VS Code, Linux habits off",
            "- Note: 6f9a3c1e-0000-4000-8000-000000000001",
            "- Language: JSON (detected)",
            "- Length: 13 characters, 3 lines",
            "- Attachments: 2",
            "- Folds: 1",
            "- Preview: beside the editor",
            "- List scope: everywhere",
            "- Age filter: last 7 days",
            "- Label filter: bug, work",
            "- Filter text: set",
            "- Similar notes: off",
            "## Recent logs\n\n```\n10:01 sync: sent 3 records\n```",
            "## Screenshot\n\n![](attachment:",
        ] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        #expect(text.range(of: "## What happened")!.lowerBound < text.range(of: "## Environment")!.lowerBound)
    }

    @Test func missingOptionalFields() {
        var report = full()
        report.note = nil
        report.logLines = nil
        report.screenshot = nil
        report.environment.sync = .off
        report.list = ProblemReport.List(scope: "title", days: nil, labels: [], hasFilterText: false, similarNotes: "off")
        let text = report.markdown(timeZone: Self.utc)
        #expect(text.contains("- Note: none selected"))
        #expect(text.contains("- Sync: off"))
        #expect(text.contains("- Age filter: none"))
        #expect(text.contains("- Label filter: none"))
        #expect(text.contains("- Filter text: none"))
        #expect(!text.contains("## Recent logs"))
        #expect(!text.contains("## Screenshot"))
        #expect(!text.contains("attachment:"))
    }

    @Test func syncStates() {
        var report = full()
        report.environment.sync = .on(lastSynced: nil, problem: nil)
        #expect(report.markdown(timeZone: Self.utc).contains("- Sync: on, last synced never\n"))
        report.environment.sync = .unavailable
        #expect(report.markdown(timeZone: Self.utc).contains("- Sync: not in this build"))
    }

    @Test func noteWithoutEditorAndChosenLanguage() {
        var report = full()
        report.note = ProblemReport.SelectedNote(id: Self.noteID, body: "", language: nil, languageDetected: false,
                                                 attachments: 0, folds: nil, preview: .hidden)
        let text = report.markdown(timeZone: Self.utc)
        #expect(text.contains("- Language: Plain Text (chosen)"))
        #expect(text.contains("- Length: 0 characters, 0 lines"))
        #expect(text.contains("- Folds: no editor"))
        #expect(text.contains("- Preview: hidden"))
    }

    @Test func emptyLogSaysSo() {
        var report = full()
        report.logLines = []
        let text = report.markdown(timeZone: Self.utc)
        #expect(text.contains("## Recent logs\n\n_No log lines in the last 10 minutes._"))
        #expect(!text.contains("```"))
    }

    @Test func logFenceOutlastsBackticksInside() {
        var report = full()
        report.logLines = ["a ``` b", "c ```` d"]
        let text = report.markdown(timeZone: Self.utc)
        #expect(text.contains("`````\na ``` b\nc ```` d\n`````"))
    }

    @Test func reportTextHoldsNoNoteText() {
        // Only facts go in: a note's body yields a length and nothing else.
        let marker = "SECRET-MARKER-7f3a"
        var report = full()
        report.note = ProblemReport.SelectedNote(id: Self.noteID, body: "title line \(marker)\n", language: nil,
                                                 languageDetected: true, attachments: 0, folds: 0, preview: .hidden)
        #expect(!report.markdown().contains(marker))
    }

    // MARK: Issue Markdown

    @Test func issueMarkdownWithoutAttachmentsIsUnchanged() {
        let body = "## What happened\n\nIt crashed.\n\n```\nlog\n```\n"
        #expect(ProblemReport.issueMarkdown(body) == body)
    }

    @Test func issueMarkdownReplacesOneAttachment() {
        let id = UUID().uuidString.lowercased()
        let body = "Before\n\n![shot](attachment:\(id))\n\nAfter"
        let issue = ProblemReport.issueMarkdown(body)
        #expect(issue == "Before\n\n\(ProblemReport.attachmentPlaceholder)\n\nAfter")
        #expect(!issue.contains("attachment:"))
    }

    @Test func issueMarkdownReplacesSeveralAttachmentsInEveryForm() {
        let ids = (0..<4).map { _ in UUID().uuidString.lowercased() }
        let body = """
            ![](attachment:\(ids[0]))
            text ![a \\] b](<ATTACHMENT:\(ids[1].uppercased())> "title") more
            ![ref][img]

            [img]: attachment:\(ids[2])
            ![](attachment:\(ids[3]))
            """
        let issue = ProblemReport.issueMarkdown(body)
        #expect(!issue.lowercased().contains("attachment:"))
        #expect(issue.components(separatedBy: ProblemReport.attachmentPlaceholder).count - 1 == 4)
        #expect(issue.contains("text \(ProblemReport.attachmentPlaceholder) more"))
    }

    // MARK: Logs and lines

    @Test func logCappingKeepsTheNewestLines() {
        let lines = (1...300).map { "line \($0)" }
        let capped = ProblemReport.cappedLog(lines)
        #expect(capped.count == ProblemReport.maxLogLines)
        #expect(capped.first == "line 101")
        #expect(capped.last == "line 300")
        #expect(ProblemReport.cappedLog(["a", "b"]) == ["a", "b"])
        #expect(ProblemReport.cappedLog(["a"], maxLines: 0).isEmpty)
    }

    @Test func logCappingShortensLongLines() {
        let long = String(repeating: "x", count: 600)
        let capped = ProblemReport.cappedLog([long, "short"], maxLines: 10, maxLineLength: 500)
        #expect(capped[0] == String(repeating: "x", count: 500) + "…")
        #expect(capped[1] == "short")
    }

    @Test func lineCounts() {
        #expect(ProblemReport.lineCount("") == 0)
        #expect(ProblemReport.lineCount("one") == 1)
        #expect(ProblemReport.lineCount("one\n") == 1)
        #expect(ProblemReport.lineCount("one\ntwo") == 2)
        #expect(ProblemReport.lineCount("one\n\nthree\n") == 3)
    }

    // MARK: The bug label

    @Test func bugLabelIsMadeOnceThenFoundInAnyCase() throws {
        let store = try NoteStore.inMemory()
        let made = try store.labelCreatingIfMissing(named: ProblemReport.labelName, color: ProblemReport.labelColor)
        #expect(made.name == "bug")
        #expect(made.color == "#d73a4a")
        #expect(try store.labelCreatingIfMissing(named: "BUG", color: "#000000").id == made.id)
        #expect(try store.labels().count == 1)
    }

    @Test func bugLabelKeepsAnExistingOnesColour() throws {
        let store = try NoteStore.inMemory()
        let mine = try store.createLabel(name: "Bug", color: "#00ff00")
        #expect(try store.labelCreatingIfMissing(named: "bug", color: ProblemReport.labelColor) == mine)
    }

    @Test func deletedBugLabelIsMadeAgain() throws {
        let store = try NoteStore.inMemory()
        let first = try store.labelCreatingIfMissing(named: "bug", color: ProblemReport.labelColor)
        try store.deleteLabel(id: first.id)
        let second = try store.labelCreatingIfMissing(named: "bug", color: ProblemReport.labelColor)
        #expect(second.id != first.id)
        #expect(try store.labels().map(\.name) == ["bug"])
    }
}
