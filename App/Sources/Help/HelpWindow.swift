import BoopstashCore
import SwiftUI

/// Help ▸ BoopStash Help (#254): one window showing the bundled README.
enum HelpWindow {
    static let windowID = "help"
    static let title = "BoopStash Help"
}

/// Help ▸ BoopStash Help, in place of the system's item, which would look
/// for a help book the app does not have.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            // A single-window scene: chosen again, it comes forward.
            Button(HelpWindow.title) { openWindow(id: HelpWindow.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
