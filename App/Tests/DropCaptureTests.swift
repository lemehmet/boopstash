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
        try await Task.sleep(for: .milliseconds(300))
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
        #expect(model.banner?.contains("not a text file") == true)
    }

    @Test func passwordManagerDragsAreRefused() async throws {
        let provider = NSItemProvider(object: "hunter2" as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: "org.nspasteboard.ConcealedType", visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        _ = DropCapture.handle([provider], model: model)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try model.store.notes(matching: NoteQuery()).isEmpty)
        #expect(model.banner?.contains("password manager") == true)
    }
}
