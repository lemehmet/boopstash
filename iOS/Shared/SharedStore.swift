import Foundation

/// Where the iOS app and its share extension keep the store (#66): the
/// App Group's container, which both can reach.
enum SharedStore {
    static let groupID = "group.com.lemehmet.boopstash"
    static let fileName = "notes.sqlite"

    /// The store's folder in the App Group; nil in a build without the
    /// group's entitlement.
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Library/Application Support/Boopstash", isDirectory: true)
    }
}
