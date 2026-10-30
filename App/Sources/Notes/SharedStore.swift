import Foundation

/// Where the Mac app and its `boopstash` command keep the store (ADR 0009):
/// the team-prefixed App Group's container, which both can reach.
enum SharedStore {
    static let groupID = "A658882T2K.com.lemehmet.boopstash"
    static let teamID = "A658882T2K"
    static let fileName = "notes.sqlite"
    /// Posted by the command after it writes; carries nothing.
    static let changedNotification = "com.lemehmet.boopstash.changed"

    /// The store's folder in the group; nil unless the app is signed by the
    /// team, since macOS refuses (or asks about) the group container for
    /// any other signature.
    static var folder: URL? {
        guard LiveSigning.teamIdentifier == teamID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Library/Application Support/Boopstash", isDirectory: true)
    }
}
