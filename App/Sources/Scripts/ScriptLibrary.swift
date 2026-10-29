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
/// appear without a relaunch. A watch is on the folder itself, so when the
/// folder is deleted or renamed away, the watcher makes the folder again at
/// its path and watches that instead.
@MainActor
final class FolderWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?

    init?(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        guard attach() else { return nil }
    }

    private func attach() -> Bool {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.source?.data else { return }
                if !event.isDisjoint(with: [.delete, .rename]) {
                    // The folder this watch was on is gone from its path.
                    self.source?.cancel()
                    self.source = nil
                    _ = self.attach()
                }
                self.onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    deinit { source?.cancel() }
}
