import Foundation

extension ProblemReport {
    /// What a window is to a report (#289).
    public enum WindowRole<Window> {
        /// A window the report can describe as it is: the note's, or any
        /// other of the app's.
        case subject
        /// A sheet on another window: the report is about that one.
        case sheet(on: Window)
        /// A script workbench, which is one note's (#285): the report is
        /// about the note's window. Nil when the note's window is gone.
        case workbench(note: Window?)
    }

    /// The window a report describes, given the window the user is in:
    /// the one its screenshot is of, whose editor the note's facts are
    /// read from, and which the sheet asking about the report hangs on.
    ///
    /// A sheet stands for the window it is on, and a script workbench for
    /// its note's window, so a report asked for with the workbench in
    /// front is the report its note's window would give: the picture the
    /// sheet's words promise ("the open note included"), with the note's
    /// facts, and without the script, the diff or what the workbench says
    /// it would send to a model. A workbench whose note's window is gone
    /// has no window to describe: nil, and the report is made without a
    /// picture. With no key window the main window is looked at the same
    /// way.
    public static func subjectWindow<Window>(key: Window?, main: Window?, role: (Window) -> WindowRole<Window>) -> Window? {
        guard var window = key ?? main else { return nil }
        // A sheet on a workbench for a note is two steps; the bound only
        // keeps a role that leads in a circle from never ending.
        for _ in 0..<8 {
            switch role(window) {
            case .subject: return window
            case .sheet(let parent): window = parent
            case .workbench(let note):
                guard let note else { return nil }
                window = note
            }
        }
        return nil
    }
}
