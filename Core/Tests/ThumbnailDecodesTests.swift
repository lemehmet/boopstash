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
    }
}
