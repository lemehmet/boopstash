import BoopstashCore
import Foundation
import Testing
@testable import Boopstash

/// User scripts from the Scripts folder (#59), with a temporary folder
/// standing in for the container's.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct UserScriptsTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-\(UUID().uuidString)", isDirectory: true)

    func write(_ name: String, _ source: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try source.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func userScriptsJoinAndReplaceBundledOnes() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("Mine.js", "/**\n{\"api\":1,\"name\":\"Shout\"}\n**/\nfunction main(s) { s.text = s.text.toUpperCase() }")
        try write("Base64.js", "/**\n{\"api\":1,\"name\":\"Base64 Encode\",\"description\":\"mine\"}\n**/\nfunction main(s) {}")
        try write("Broken.js", "function main(s) {}")
        let library = ScriptLibrary.all(userFolder: folder)
        #expect(library.scripts.contains { $0.name == "Shout" && !$0.isBundled })
        let base64 = library.scripts.filter { $0.name == "Base64 Encode" }
        #expect(base64.count == 1 && base64.first?.description == "mine", "the user's copy replaces the bundled one")
        #expect(library.problems.contains(ScriptProblem(scriptID: "user/Broken.js", message: "no /** … **/ header")))
    }

    /// Deleting the folder and making it again (Show Scripts Folder) keeps
    /// new scripts coming.
    @Test func theWatcherSurvivesTheFolderBeingDeleted() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var changes = 0
        let watcher = FolderWatcher(folder) { changes += 1 }
        try FileManager.default.removeItem(at: folder)
        var deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, !FileManager.default.fileExists(atPath: folder.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = changes
        try write("Later.js", "/** {\"name\":\"Later\"} **/ function main(s) {}")
        deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, changes == before { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes > before, "a script added to the recreated folder is seen")
        _ = watcher
    }

    @Test func theWatcherSeesNewScripts() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var changes = 0
        let watcher = FolderWatcher(folder) { changes += 1 }
        #expect(watcher != nil)
        try write("New.js", "/** {\"name\":\"New\"} **/ function main(s) {}")
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, changes == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes > 0)
        _ = watcher
    }
}
