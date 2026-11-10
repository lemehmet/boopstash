import Foundation

/// What Window ▸ BoopStash does: bring a main window that already exists to
/// the front, or open one when the last was closed. App Review needs a menu
/// item that brings a closed main window back (guideline 4).
public enum MainWindowReopen {
    /// The main scene's identifier, for opening a window of it.
    public static let sceneID = "main"

    /// A window of the app, as far as the choice needs it.
    public struct Candidate: Equatable, Sendable {
        /// Whether the window shows the main scene. The app records that
        /// itself as each window appears, rather than reading it off the
        /// identifiers SwiftUI gives its windows, which are not documented.
        public var isMain: Bool
        public var isVisible: Bool
        public var isMiniaturized: Bool

        public init(isMain: Bool, isVisible: Bool, isMiniaturized: Bool) {
            self.isMain = isMain
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
        }
    }

    public enum Action: Equatable, Sendable {
        /// Bring the window at this index of the candidates to the front.
        case front(Int)
        /// No main window is left: open a new one.
        case open
    }

    /// The candidates are in front-to-back order. A window on screen wins
    /// over one in the Dock; a closed window (neither) is not a candidate,
    /// since AppKit may keep it around after it closes.
    public static func action(for windows: [Candidate]) -> Action {
        let main = windows.indices.filter { windows[$0].isMain }
        if let onScreen = main.first(where: { windows[$0].isVisible && !windows[$0].isMiniaturized }) {
            return .front(onScreen)
        }
        if let inDock = main.first(where: { windows[$0].isMiniaturized }) {
            return .front(inDock)
        }
        return .open
    }
}
