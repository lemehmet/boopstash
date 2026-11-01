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
        if let folder = CommandLineInstall.defaultFolder(home: realHome, exists: { FileManager.default.fileExists(atPath: $0) }) {
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

    /// The recorded link path, if it still runs this app's command (#212):
    /// Settings ▸ General shows it only then.
    static func verifiedLinkPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let link = URL(fileURLWithPath: path)
        let helper = CommandLineInstall.helperPath(appPath: Bundle.main.bundleURL.path)
        let folder = link.deletingLastPathComponent().path
        return CommandLineInstall.stillInstalled(existing: existing(at: link), folder: folder, helper: helper) ? path : nil
    }

    /// What is at `link`, or nil when the sandbox does not let the app look.
    private static func existing(at link: URL) -> CommandLineInstall.Existing? {
        var info = stat()
        guard lstat(link.path, &info) == 0 else { return CommandLineInstall.existing(afterLookupError: errno) }
        if info.st_mode & S_IFMT == S_IFLNK, let destination = FileManager.default.destinationOfSymbolicLinkIfAny(at: link) {
            return .link(destination: destination, resolves: FileManager.default.fileExists(atPath: link.path))
        }
        return .other
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
