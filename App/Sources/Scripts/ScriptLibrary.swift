import BoopstashCore
import Foundation

/// The scripts the picker offers: Boop's bundled set (ADR 0005), parsed
/// once. User scripts join them from a folder in the container (#59).
struct ScriptLibrary {
    var scripts: [BoopScript]
    var problems: [ScriptProblem]

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
