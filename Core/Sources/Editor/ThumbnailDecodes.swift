import Foundation

/// Which bytes a file holds, as far as can be told without reading them
/// (#296): a file replaced at the same URL (iCloud bringing another
/// version of an image, or a file removed and written again) is another
/// file, was written at another time, or has another size.
public struct FileVersion: Hashable, Sendable {
    public var modified: Date?
    public var size: Int64?
    /// The file's number on its volume: a file moved into place over
    /// another has its own.
    public var fileNumber: UInt64?

    public init(modified: Date?, size: Int64?, fileNumber: UInt64?) {
        self.modified = modified
        self.size = size
        self.fileNumber = fileNumber
    }

    /// The version of the file at `url` now, or nil when there is none.
    public init?(of url: URL, fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        self.init(modified: attributes[.modificationDate] as? Date,
                  size: (attributes[.size] as? NSNumber)?.int64Value,
                  fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

/// The thumbnail decodes under way, one per file, each for the version of
/// the file it started on (#296). A thumbnail is kept only when its
/// decode is still the one the file is waiting for: a file replaced while
/// its thumbnail was being made starts another decode, and the first
/// one's picture, of the old bytes, is dropped when it arrives.
public struct ThumbnailDecodes<Key: Hashable, Version: Equatable> {
    private var inFlight: [Key: Version] = [:]

    public init() {}

    /// Whether a decode of `key` at `version` has to start: not when one
    /// for that version is under way. One under way for another version
    /// is superseded.
    public mutating func begin(_ key: Key, version: Version) -> Bool {
        guard inFlight[key] != version else { return false }
        inFlight[key] = version
        return true
    }

    /// A decode of `key` that started on `version` is done. True when its
    /// result is the one waited for, which ends the wait; false when the
    /// file changed meanwhile, and the result is to be dropped.
    public mutating func finish(_ key: Key, version: Version) -> Bool {
        guard inFlight[key] == version else { return false }
        inFlight[key] = nil
        return true
    }

    /// Whether a decode of `key` is under way.
    public func isDecoding(_ key: Key) -> Bool { inFlight[key] != nil }
}
