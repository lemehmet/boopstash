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
    /// When the file itself last changed, its bytes or anything kept
    /// about it: the system sets this and nothing can put it back, so it
    /// tells a file whose new bytes were given the old file's number, date
    /// and size. It also moves when only something about the file changed,
    /// which costs one more look at the same bytes.
    public var changed: Date?

    public init(modified: Date?, size: Int64?, fileNumber: UInt64?, changed: Date? = nil) {
        self.modified = modified
        self.size = size
        self.fileNumber = fileNumber
        self.changed = changed
    }

    /// The version of the file at `url` now, or nil when there is none.
    /// One call to the system, which reads none of the file's bytes.
    public init?(of url: URL) {
        var status = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in path.map { stat($0, &status) == 0 } ?? false }) else { return nil }
        self.init(modified: Self.date(status.st_mtimespec), size: Int64(status.st_size), fileNumber: UInt64(status.st_ino),
                  changed: Self.date(status.st_ctimespec))
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

/// The thumbnail decodes under way, one per file, each for the version of
/// the file it started on (#296). A thumbnail is kept only when its
/// decode is still the one the file is waiting for: a file replaced while
/// its thumbnail was being made starts another decode, and the first
/// one's picture, of the old bytes, is dropped when it arrives.
public struct ThumbnailDecodes<Key: Hashable, Version: Equatable> {
    private var inFlight: [Key: Version] = [:]
    /// The files whose earlier picture was shown while they wait.
    private var shownEarlier: Set<Key> = []

    public init() {}

    /// While `key` waits for its thumbnail, the picture of the version it
    /// had before was shown. Remembered here, and not read from the cache
    /// of pictures when the decode is done: that cache may have let the
    /// picture go meanwhile, and the chips drawn with it still show it.
    public mutating func showedEarlierPicture(_ key: Key) {
        shownEarlier.insert(key)
    }

    /// Whether the earlier picture of `key` was shown since this was last
    /// asked: asked once, when the decode waited for is done. True means
    /// that whoever waited has to draw again even when no picture came of
    /// the decode, to stop showing the earlier one. It outlives a decode
    /// that was superseded: those who were shown the picture still wait.
    public mutating func takeShowedEarlierPicture(_ key: Key) -> Bool {
        shownEarlier.remove(key) != nil
    }

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
