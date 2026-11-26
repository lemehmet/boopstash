import Foundation
import Testing
@testable import BoopstashCore

/// A chip's thumbnail follows the file's bytes, not only its URL (#296).
@Suite struct ThumbnailDecodesTests {
    /// The decodes of a test, and what each call answered.
    final class Log {
        var decodes = ThumbnailDecodes<String, Int>()
        func begin(_ key: String, _ version: Int) -> Bool { decodes.begin(key, version: version) }
        func finish(_ key: String, _ version: Int) -> Bool { decodes.finish(key, version: version) }
        func isDecoding(_ key: String) -> Bool { decodes.isDecoding(key) }
        func showedEarlierPicture(_ key: String) { decodes.showedEarlierPicture(key) }
        func takeShowedEarlierPicture(_ key: String) -> Bool { decodes.takeShowedEarlierPicture(key) }
    }

    /// A chip that kept the old picture while the new file was decoded has
    /// to be drawn again when the decode is done, whatever came of it and
    /// whatever the cache of pictures still holds by then.
    @Test func theEarlierPictureShownIsRememberedUntilTheDecodeIsDone() {
        let log = Log()
        #expect(log.begin("a.png", 1))
        #expect(!log.takeShowedEarlierPicture("a.png"), "a first decode: no picture was shown")

        log.showedEarlierPicture("a.png")
        #expect(log.begin("a.png", 2))
        log.showedEarlierPicture("a.png")
        #expect(log.finish("a.png", 2))
        #expect(log.takeShowedEarlierPicture("a.png"))
        #expect(!log.takeShowedEarlierPicture("a.png"), "asked once")
        #expect(!log.takeShowedEarlierPicture("b.png"), "another file")
    }

    /// The old picture was shown for a decode that was then superseded,
    /// and nothing was shown for the one that replaced it (the cache had
    /// let the picture go): those shown it for the first still wait.
    @Test func theEarlierPictureShownOutlivesASupersededDecode() {
        let log = Log()
        log.showedEarlierPicture("a.png")
        #expect(log.begin("a.png", 2))
        #expect(log.begin("a.png", 3), "replaced again")
        #expect(!log.finish("a.png", 2))
        #expect(log.finish("a.png", 3))
        #expect(log.takeShowedEarlierPicture("a.png"))
    }

    @Test func oneDecodeRunsPerVersionOfAFile() {
        let log = Log()
        #expect(log.begin("a.png", 1))
        #expect(!log.begin("a.png", 1), "a second editor waits for the first one's decode")
        #expect(log.begin("b.png", 1), "another file")
        #expect(log.isDecoding("a.png"))
        #expect(log.finish("a.png", 1))
        #expect(!log.isDecoding("a.png") && log.isDecoding("b.png"))
        #expect(log.begin("a.png", 1), "evicted from the cache later: decoded again")
    }

    /// The scenario of #296: the file is replaced while its thumbnail is
    /// being made, and the old bytes' picture arrives after.
    @Test func aDecodeOfTheOldBytesIsDroppedWhenItArrives() {
        let log = Log()
        #expect(log.begin("a.png", 1))
        #expect(log.begin("a.png", 2), "the file was replaced: another decode starts")
        #expect(!log.finish("a.png", 1), "the old picture is not kept")
        #expect(log.isDecoding("a.png"), "and the new one is still waited for")
        #expect(log.finish("a.png", 2))
        #expect(!log.finish("a.png", 2), "done once")
        #expect(!log.finish("never started", 1))
    }

    /// The old picture arriving last, after the new one, changes nothing.
    @Test func theOldDecodeArrivingLastIsDroppedToo() {
        let log = Log()
        #expect(log.begin("a.png", 1))
        #expect(log.begin("a.png", 2))
        #expect(log.finish("a.png", 2))
        #expect(!log.finish("a.png", 1))
        #expect(!log.isDecoding("a.png"))
    }

    @Test func aFileReplacedAtTheSameURLIsAnotherVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("image.png")
        #expect(FileVersion(of: url) == nil, "no file")

        try Data([1, 2, 3]).write(to: url, options: .atomic)
        let first = try #require(FileVersion(of: url))
        #expect(first.size == 3)
        #expect(FileVersion(of: url) == first, "read again, unchanged")

        // As sync puts the server's file in place: written beside, then
        // moved over. The same size, to show the size is not what tells.
        let incoming = folder.appendingPathComponent("image.incoming")
        try Data([4, 5, 6]).write(to: incoming, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: incoming)
        let second = try #require(FileVersion(of: url))
        #expect(second != first)

        // Removed and written again.
        try FileManager.default.removeItem(at: url)
        #expect(FileVersion(of: url) == nil)
        try Data([7, 8, 9, 10]).write(to: url, options: .atomic)
        let third = try #require(FileVersion(of: url))
        #expect(third != second && third.size == 4)

        // New bytes with everything that can be put back put back: the
        // same file, written in place, the same size, its date set to what
        // it was. The system's own record of the change still tells.
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data([4, 3, 2, 1]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: try #require(third.modified)], ofItemAtPath: url.path)
        let fourth = try #require(FileVersion(of: url))
        #expect(fourth.fileNumber == third.fileNumber && fourth.size == third.size)
        #expect(fourth.changed != third.changed && fourth != third)
    }
}
