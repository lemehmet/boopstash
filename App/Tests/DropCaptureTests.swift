import AppKit
import BoopstashCore
import Testing
import UniformTypeIdentifiers
@testable import Boopstash

@MainActor
@Suite(.serialized)
struct DropCaptureTests {
    let model: AppModel

    init() throws {
        model = AppModel(store: try .inMemory())
        model.dropSource = { ("com.example.source", "Example Source") }
    }

    /// Drops finish on their own schedule; wait for `condition` instead of
    /// a fixed delay, failing after `timeout`.
    func eventually(timeout: Duration = .seconds(5), _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try condition()
    }

    /// Drops load asynchronously; wait for the store to reflect them.
    func notes(after drop: () -> Bool, expecting count: Int) async throws -> [Note] {
        #expect(drop())
        for _ in 0..<100 {
            let notes = try model.store.notes(matching: NoteQuery())
            if notes.count >= count { return notes }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try model.store.notes(matching: NoteQuery())
    }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    @Test func droppedTextBecomesANote() async throws {
        let provider = NSItemProvider(object: "dropped words" as NSString)
        let notes = try await notes(after: { DropCapture.handle([provider], model: model) }, expecting: 1)
        #expect(notes.map(\.body) == ["dropped words"])
        #expect(notes.first?.sourceAppName == "Example Source", "drops record where they came from")
        #expect(notes.first?.sourceBundleID == "com.example.source")
    }

    @Test func droppedTextFileIsTitledByItsName() async throws {
        let url = try file("nginx.conf", Data("server { listen 80; }".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = try #require(NSItemProvider(contentsOf: url))
        let notes = try await notes(after: { DropCapture.handle([provider], model: model) }, expecting: 1)
        #expect(notes.first?.body == "server { listen 80; }")
        #expect(notes.first?.title == TextFileImport.title(forFileNamed: url.lastPathComponent))
        #expect(notes.first?.title.hasSuffix("-nginx") == true)
        #expect(notes.first?.titleIsUserSet == true)
    }

    @Test func binaryFilesAreRefused() async throws {
        let url = try file("blob.bin", Data([0x00, 0x01, 0x02, 0xFF]))
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = try #require(NSItemProvider(contentsOf: url))
        _ = DropCapture.handle([provider], model: model)
        #expect(try await eventually { model.banner?.contains("not a text file") == true })
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
    }

    @Test func passwordManagerDragsAreRefused() async throws {
        let provider = NSItemProvider(object: "hunter2" as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: "org.nspasteboard.ConcealedType", visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        _ = DropCapture.handle([provider], model: model)
        #expect(try await eventually { model.banner?.contains("password manager") == true })
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
    }

    @Test func emptyAndUnreadableDropsAreReported() async throws {
        _ = DropCapture.handle([NSItemProvider(object: "   \n" as NSString)], model: model)
        #expect(try await eventually { model.banner == "The dropped text is empty." })

        let failing = NSItemProvider()
        failing.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        _ = DropCapture.handle([failing], model: model)
        #expect(try await eventually { model.banner == "Could not read the dropped text." })
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
    }

    @Test func oversizedFilesAreRefusedBeforeReading() async throws {
        let url = try file("huge.log", Data(repeating: 0x61, count: TextFileImport.sizeLimit + 1))
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = try #require(NSItemProvider(contentsOf: url))
        _ = DropCapture.handle([provider], model: model)
        #expect(try await eventually { model.banner?.contains("the limit is 5 MB") == true })
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
    }
}
