import AppKit
import BoopstashCore

/// BoopStash ▸ Install Command Line Tool… (#212, ADR 0009): asks for a
/// folder on `PATH`, then links `boopstash` there to this app's helper. The
/// sandbox lets the app write only into the folder the user picks.
@MainActor
enum CommandLineInstaller {
    /// Where the last link was made, for Settings ▸ General.
    static let linkPathKey = "commandLineLinkPath"

    static func run() {
        let appPath = Bundle.main.bundleURL.path
        guard !CommandLineInstall.isTranslocated(appPath: appPath) else {
            alert("Move BoopStash to Applications first",
                  "macOS is running BoopStash from a temporary copy, and a link to it would stop working. Move BoopStash to your Applications folder, open it from there, then install the command.")
            return
        }
        let helper = CommandLineInstall.helperPath(appPath: appPath)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Install"
        panel.message = "Choose a folder on your PATH. BoopStash links the boopstash command there."
        // Before the panel nothing is granted: a folder the sandbox hides
        // counts as there, only one known to be missing is skipped.
        if let folder = CommandLineInstall.defaultFolder(home: realHome, exists: { CommandLineInstall.found(lookupError: lookupError($0, following: false)) != false }) {
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        }
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        let folder = folderURL.path
        let link = folderURL.appendingPathComponent(CommandLineInstall.commandName)

        // The panel's grant makes the path readable; an unreadable one is
        // left alone like anything else not ours.
        let plan = CommandLineInstall.plan(existing: existing(at: link) ?? .other, folder: folder, helper: helper)
        switch plan {
        case .alreadyInstalled:
            UserDefaults.standard.set(link.path, forKey: linkPathKey)
            alert("The command is already installed", "\(link.path) runs this BoopStash's command.")
        case let .linkedElsewhere(target):
            alert("Another BoopStash's command is there",
                  "\(link.path) links to \(target). Remove that link to use this copy of BoopStash instead.")
        case .occupied:
            alert("Something else is called boopstash there",
                  "\(link.path) is not a link to BoopStash, so it was left alone. Choose another folder.")
        case .link, .replaceBroken:
            do {
                if FileManager.default.destinationOfSymbolicLinkIfAny(at: link) != nil {
                    try FileManager.default.removeItem(at: link)
                }
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: helper)
                UserDefaults.standard.set(link.path, forKey: linkPathKey)
                alert("The command is installed",
                      "\(link.path) now runs BoopStash's command. In a new terminal window, try `boopstash --help`. If the shell cannot find it, add \(folder) to your PATH.")
            } catch {
                offerShellCommand(CommandLineInstall.shellCommand(helper: helper, folder: folder, replacing: plan == .replaceBroken), folder: folder)
            }
        }
    }

    /// The folder could not be written from the app: give the line to run.
    private static func offerShellCommand(_ command: String, folder: String) {
        let alert = NSAlert()
        alert.messageText = "BoopStash cannot write to \(folder)"
        alert.informativeText = "To link the command there, run this in Terminal:\n\n\(command)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// Whether the recorded link path still runs this app's command
    /// (#212), for Settings ▸ General; nil when the app cannot look.
    static func linkStatus(_ path: String) -> Bool? {
        guard !path.isEmpty else { return false }
        let link = URL(fileURLWithPath: path)
        let helper = CommandLineInstall.helperPath(appPath: Bundle.main.bundleURL.path)
        let folder = link.deletingLastPathComponent().path
        return CommandLineInstall.stillInstalled(existing: existing(at: link), folder: folder, helper: helper)
    }

    /// What is at `link`, or nil when the sandbox does not let the app look.
    private static func existing(at link: URL) -> CommandLineInstall.Existing? {
        switch CommandLineInstall.found(lookupError: lookupError(link.path, following: false)) {
        case .some(false): return .nothing
        case .none: return nil
        case .some(true):
            guard let destination = FileManager.default.destinationOfSymbolicLinkIfAny(at: link) else { return .other }
            // stat follows the link; the destination may be outside the grant.
            return .link(destination: destination, resolves: CommandLineInstall.found(lookupError: lookupError(link.path, following: true)))
        }
    }

    /// `errno` of a failed `stat` (`following` a link) or `lstat`, nil
    /// when it succeeded.
    private static func lookupError(_ path: String, following: Bool) -> Int32? {
        var info = stat()
        let result = following ? stat(path, &info) : lstat(path, &info)
        return result == 0 ? nil : errno
    }

    /// The user's home, not the sandbox container `NSHomeDirectory()` gives.
    private static var realHome: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }
}

private extension FileManager {
    func destinationOfSymbolicLinkIfAny(at url: URL) -> String? {
        try? destinationOfSymbolicLink(atPath: url.path)
    }
}
