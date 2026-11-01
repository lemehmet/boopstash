import Foundation

/// BoopStash ▸ Install Command Line Tool… (#212, ADR 0009): linking the
/// bundled `boopstash` into a folder on `PATH` for installs the Homebrew
/// cask did not make. Everything but the panel and the file system, so it
/// can be tested.
public enum CommandLineInstall {
    public static let commandName = "boopstash"

    /// Where the command sits inside the app.
    public static func helperPath(appPath: String) -> String {
        (appPath as NSString).appendingPathComponent("Contents/Helpers/\(commandName)")
    }

    /// An app opened from Downloads without being moved runs from a random
    /// read-only copy; a link to it breaks on the next launch.
    public static func isTranslocated(appPath: String) -> Bool {
        appPath.contains("/AppTranslocation/")
    }

    /// Folders the panel offers first, in order: Homebrew's on Apple
    /// silicon, the usual one on Intel, then the user's own. `home` is the
    /// real home folder, not the sandbox container's.
    public static func candidateFolders(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", (home as NSString).appendingPathComponent(".local/bin")]
    }

    /// The first candidate that exists: the panel ignores a missing folder.
    public static func defaultFolder(home: String, exists: (String) -> Bool) -> String? {
        candidateFolders(home: home).first(where: exists)
    }

    /// What is already at the command's path in the chosen folder.
    public enum Existing: Equatable, Sendable {
        case nothing
        /// A symbolic link, its destination as written (maybe relative),
        /// and whether that destination exists.
        case link(destination: String, resolves: Bool)
        /// A file, folder or anything else not made by a link.
        case other
    }

    public enum Plan: Equatable, Sendable {
        /// Make the link.
        case link
        /// A link to this app's command is there already (the cask makes one).
        case alreadyInstalled
        /// A link to a BoopStash command that is gone: replace it.
        case replaceBroken
        /// A link to another BoopStash's command that still exists; left
        /// alone, so the installer never fights the cask or another copy.
        case linkedElsewhere(String)
        /// Something not ours: never overwritten.
        case occupied
    }

    public static func plan(existing: Existing, folder: String, helper: String) -> Plan {
        switch existing {
        case .nothing:
            return .link
        case .other:
            return .occupied
        case let .link(destination, resolves):
            let target = resolved(destination, in: folder)
            if target == standardized(helper) { return .alreadyInstalled }
            guard isBoopStashHelper(target) else { return .occupied }
            return resolves ? .linkedElsewhere(target) : .replaceBroken
        }
    }

    /// What a failed `lstat` of the command's path says is there: `ENOENT`
    /// or `ENOTDIR` mean nothing is; anything else (the sandbox's `EPERM`
    /// once the panel's grant is gone after a relaunch) means the app
    /// could not look, so nothing is known.
    public static func existing(afterLookupError code: Int32) -> Existing? {
        code == ENOENT || code == ENOTDIR ? .nothing : nil
    }

    /// Whether Settings may still say the command is linked at a path it
    /// linked earlier. A path the app cannot read any more keeps the
    /// claim; one that is gone, or no longer links to this app's helper
    /// (the link was removed, the cask uninstalled, the app moved), drops it.
    public static func stillInstalled(existing: Existing?, folder: String, helper: String) -> Bool {
        guard let existing else { return true }
        return plan(existing: existing, folder: folder, helper: helper) == .alreadyInstalled
    }

    /// A link's destination as an absolute, standardized path.
    static func resolved(_ destination: String, in folder: String) -> String {
        let absolute = destination.hasPrefix("/") ? destination : (folder as NSString).appendingPathComponent(destination)
        return standardized(absolute)
    }

    static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func isBoopStashHelper(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Helpers/\(commandName)")
    }

    /// The line to run in Terminal when the folder cannot be written from
    /// the app (`/usr/local/bin` is often root's). `replacing` a broken
    /// link needs `-f`: plain `ln -s` stops at the link still there.
    public static func shellCommand(helper: String, folder: String, replacing: Bool = false) -> String {
        "sudo ln -s\(replacing ? "f" : "") \(shellQuoted(helper)) \(shellQuoted((folder as NSString).appendingPathComponent(commandName)))"
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
