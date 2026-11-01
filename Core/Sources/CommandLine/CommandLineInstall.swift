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
        /// and whether that destination exists: nil when the sandbox would
        /// not let the app look (another copy's helper is outside the grant).
        case link(destination: String, resolves: Bool?)
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
            // Only a destination known to be gone is replaced; one the app
            // cannot see may be a working copy's.
            return resolves == false ? .replaceBroken : .linkedElsewhere(target)
        }
    }

    /// Whether a `stat`/`lstat` found its path, from the call's `errno`
    /// (nil when it succeeded): `ENOENT` or `ENOTDIR` mean the path is not
    /// there; anything else (the sandbox's `EPERM` outside the panel's
    /// grant, or after a relaunch) means the app could not look: nil.
    public static func found(lookupError code: Int32?) -> Bool? {
        guard let code else { return true }
        return code == ENOENT || code == ENOTDIR ? false : nil
    }

    /// Whether Settings may say the command is linked at a path it linked
    /// earlier: true while it still links to this app's helper, false once
    /// it is gone or links elsewhere (removed, the cask uninstalled, the
    /// app moved), nil when the app cannot look any more.
    public static func stillInstalled(existing: Existing?, folder: String, helper: String) -> Bool? {
        guard let existing else { return nil }
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
