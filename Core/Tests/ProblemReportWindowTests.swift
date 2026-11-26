import Testing
@testable import BoopstashCore

/// Which window Help ▸ Report a Problem… describes (#289). Windows are
/// names here; the app passes its own.
@Suite struct ProblemReportWindowTests {
    /// The note's window with a review sheet on it, the note's script
    /// workbench with a save question on that, and Help's window.
    static func role(_ window: String) -> ProblemReport.WindowRole<String> {
        switch window {
        case "review": .sheet(on: "note")
        case "workbench": .workbench(note: "note")
        case "save question": .sheet(on: "workbench")
        case "orphan": .workbench(note: nil)
        case "orphan's sheet": .sheet(on: "orphan")
        case "loop": .sheet(on: "loop")
        default: .subject
        }
    }

    func subject(key: String?, main: String? = nil) -> String? {
        ProblemReport.subjectWindow(key: key, main: main, role: Self.role)
    }

    /// The scenario of #289: the workbench is in front, and the report is
    /// its note's window's.
    @Test func aWorkbenchStandsForItsNotesWindow() {
        #expect(subject(key: "workbench") == "note")
        #expect(subject(key: "workbench", main: "help") == "note")
        #expect(subject(key: "save question") == "note", "a sheet on the workbench")
        #expect(subject(key: nil, main: "workbench") == "note", "the workbench can be the main window")
    }

    @Test func theNotesWindowAndASheetOnItAreAsBefore() {
        #expect(subject(key: "note") == "note")
        #expect(subject(key: "review") == "note")
        #expect(subject(key: "help", main: "note") == "help", "the window the user is in")
        #expect(subject(key: nil, main: "note") == "note")
        #expect(subject(key: nil, main: nil) == nil)
    }

    @Test func aWorkbenchWithoutItsNotesWindowHasNothingToDescribe() {
        #expect(subject(key: "orphan") == nil)
        #expect(subject(key: "orphan's sheet", main: "note") == nil, "never the workbench itself, nor another window's note")
    }

    @Test func rolesThatLeadInACircleEnd() {
        #expect(subject(key: "loop") == nil)
    }
}
