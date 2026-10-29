import Foundation

/// A Boop-compatible script (ADR 0005): JavaScript with a JSON header in a
/// `/** … **/` comment and a `main(state)` function. Boop's own scripts run
/// unchanged.
public struct BoopScript: Identifiable, Hashable, Sendable {
    /// Where it came from and its file name, such as `bundled/Base64Encode.js`.
    public var id: String
    public var name: String
    public var description: String
    public var author: String?
    public var icon: String?
    public var tags: [String]
    /// Boop's ranking nudge; higher sorts earlier among equal matches.
    public var bias: Double
    public var source: String
    public var isBundled: Bool

    /// Reads the header Boop's way: the first `/**` to the first `**/`,
    /// parsed as JSON. `name` is required; everything else is optional.
    public static func parse(_ source: String, id: String, bundled: Bool) -> Result<BoopScript, ScriptProblem> {
        guard let open = source.range(of: "/**"), let close = source.range(of: "**/", range: open.upperBound..<source.endIndex) else {
            return .failure(ScriptProblem(scriptID: id, message: "no /** … **/ header"))
        }
        let header = source[open.upperBound..<close.lowerBound]
        guard let object = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any] else {
            return .failure(ScriptProblem(scriptID: id, message: "the header is not a JSON object"))
        }
        guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .failure(ScriptProblem(scriptID: id, message: "the header has no \"name\""))
        }
        let tags = (object["tags"] as? String)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        return .success(BoopScript(
            id: id,
            name: name,
            description: (object["description"] as? String) ?? "",
            author: object["author"] as? String,
            icon: (object["icon"] as? String)?.lowercased(),
            tags: tags,
            bias: (object["bias"] as? NSNumber)?.doubleValue ?? 0,
            source: source,
            isBundled: bundled
        ))
    }
}

/// A script that could not be loaded, and why.
public struct ScriptProblem: Error, Hashable, Sendable {
    public var scriptID: String
    public var message: String

    public init(scriptID: String, message: String) {
        self.scriptID = scriptID
        self.message = message
    }
}

/// The script picker's search: fuzzy over name, tags and description, with
/// Boop's weights (0.9, 0.6, 0.2), so a name match beats a tag match beats
/// a description match.
public enum ScriptSearch {
    public static func rank(_ scripts: [BoopScript], for query: String) -> [BoopScript] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return scripts.map { ($0, 1.0) }.sorted(by: ordered).map(\.0)
        }
        let scored: [(script: BoopScript, score: Double)] = scripts
            .map { ($0, score($0, needle)) }
            .filter { $0.score > 0 }
        return scored.sorted(by: ordered).map(\.script)
    }

    static func ordered(_ lhs: (script: BoopScript, score: Double), _ rhs: (script: BoopScript, score: Double)) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.script.bias != rhs.script.bias { return lhs.script.bias > rhs.script.bias }
        return lhs.script.name.lowercased() < rhs.script.name.lowercased()
    }

    static func score(_ script: BoopScript, _ needle: String) -> Double {
        let fields: [(String, Double)] = [
            (script.name, 0.9),
            (script.tags.joined(separator: " "), 0.6),
            (script.description, 0.2),
        ]
        return fields.map { match($0.0.lowercased(), needle) * $0.1 }.max() ?? 0
    }

    /// 1 for a prefix, 0.8 for a word prefix, 0.6 anywhere, 0.3 for the
    /// letters in order (`b64` finds "Base64"), 0 otherwise.
    static func match(_ haystack: String, _ needle: String) -> Double {
        if haystack.hasPrefix(needle) { return 1 }
        if let range = haystack.range(of: needle) {
            let before = haystack[..<range.lowerBound].last
            let atWordStart = before.map { !$0.isLetter && !$0.isNumber } ?? true
            return atWordStart ? 0.8 : 0.6
        }
        var rest = haystack[...]
        for character in needle {
            guard let found = rest.firstIndex(of: character) else { return 0 }
            rest = rest[rest.index(after: found)...]
        }
        return 0.3
    }
}

/// The scripts on offer: Boop's bundled set and the user's own (#59).
public enum ScriptCatalog {
    /// A user script with the same name as a bundled one replaces it, so a
    /// tweaked copy of a Boop script is the one that runs.
    public static func merge(bundled: [BoopScript], user: [BoopScript]) -> [BoopScript] {
        let mine = Set(user.map(\.name))
        return bundled.filter { !mine.contains($0.name) } + user
    }
}
