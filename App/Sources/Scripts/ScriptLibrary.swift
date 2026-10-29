import AppKit
import BoopstashCore

/// The scripts the picker offers: Boop's bundled set (ADR 0005) and the
/// user's own from the Scripts folder in the container (#59).
struct ScriptLibrary {
    var scripts: [BoopScript]
    var problems: [ScriptProblem]

    /// Bundled and user scripts together; a user script with a bundled
    /// script's name replaces it.
    static func all(in bundle: Bundle = .main, userFolder: URL? = UserScriptsFolder.url) -> ScriptLibrary {
        let bundled = Self.bundled(in: bundle)
        guard let userFolder else { return bundled }
        let user = load(from: userFolder, prefix: "user", bundled: false)
        return ScriptLibrary(scripts: ScriptCatalog.merge(bundled: bundled.scripts, user: user.scripts),
                             problems: bundled.problems + user.problems)
    }

    static func bundled(in bundle: Bundle = .main) -> ScriptLibrary {
        guard let folder = bundle.url(forResource: "scripts", withExtension: nil) else {
            return ScriptLibrary(scripts: [], problems: [])
        }
        return load(from: folder, prefix: "bundled", bundled: true)
    }

    static func load(from folder: URL, prefix: String, bundled: Bool) -> ScriptLibrary {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var library = ScriptLibrary(scripts: [], problems: [])
        for file in files.filter({ $0.pathExtension == "js" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = "\(prefix)/\(file.lastPathComponent)"
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                library.problems.append(ScriptProblem(scriptID: id, message: "not readable as UTF-8 text"))
                continue
            }
            switch BoopScript.parse(source, id: id, bundled: bundled) {
            case .success(let script): library.scripts.append(script)
            case .failure(let problem): library.problems.append(problem)
            }
        }
        return library
    }
}

/// `Application Support/Boopstash/Scripts` in the app's container: Boop
/// scripts dropped there join the picker. No folder outside the container,
/// so no extra entitlement (ADR 0005).
enum UserScriptsFolder {
    static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Boopstash/Scripts", isDirectory: true)
    }

    @MainActor
    static func reveal() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Calls back when a folder's contents change, so new or edited scripts
/// appear without a relaunch.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private let descriptor: Int32

    init?(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
