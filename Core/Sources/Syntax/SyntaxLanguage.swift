import Foundation

/// A language the editor can highlight (ADR 0006). Detected from the note's
/// text; nil means "plain text, no colouring".
public enum SyntaxLanguage: String, CaseIterable, Codable, Sendable {
    case json, yaml, toml, xml, markdown, html, css
    case javascript, typescript, python, ruby, bash, go, rust, c, cpp, java, swift, sql, diff

    public var displayName: String {
        switch self {
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .xml: "XML"
        case .markdown: "Markdown"
        case .html: "HTML"
        case .css: "CSS"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .bash: "Shell"
        case .go: "Go"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .ruby: "Ruby"
        case .sql: "SQL"
        case .java: "Java"
        case .swift: "Swift"
        case .diff: "Diff"
        }
    }

    /// The language to highlight a note in. Structured kinds map directly;
    /// "code" and plain text are scored against each language's telltales,
    /// and nothing below `threshold` is coloured, since a wrong grammar is
    /// worse than none.
    public static func detect(_ body: String, kind: ContentKind? = nil) -> SyntaxLanguage? {
        let kind = kind ?? ContentKind.detect(body)
        switch kind {
        case .json: return .json
        case .yaml: return .yaml
        case .xml: return .xml
        case .html: return .html
        case .markdown: return .markdown
        case .diff: return .diff
        case .sql: return .sql
        case .url, .stackTrace, .log: return nil
        case .code, .plain:
            let sample = String(body.prefix(16 * 1024))
            if isJSONLines(sample) { return .json }
            if isTOML(sample) { return .toml }
            let best = scores(sample).max { $0.value < $1.value }
            guard let best, best.value >= (kind == .plain ? plainThreshold : threshold) else { return nil }
            return best.key
        }
    }

    static let threshold = 3.0
    /// Plain text needs much stronger evidence: prose mentions "if" and "let".
    static let plainThreshold = 8.0

    /// (pattern, weight) per language; a pattern counts once per line it
    /// matches, capped so one repetitive line cannot win alone.
    static let telltales: [SyntaxLanguage: [(String, Double)]] = [
        .swift: [
            (#"^\s*import (Foundation|SwiftUI|UIKit|AppKit|Combine|Observation)\b"#, 6),
            (#"\b(guard|if) let \w+"#, 3), (#"\bfunc \w+\("#, 2), (#"->\s*[\w\[\]?<>, ]+\s*\{"#, 2),
            (#"@(MainActor|Observable|State|Binding|Published|objc)\b"#, 4), (#"\b(let|var) \w+\s*:\s*\w+"#, 1),
        ],
        .python: [
            (#"^\s*def \w+\(.*\)\s*(->.*)?:\s*$"#, 4), (#"^\s*(from \S+ )?import \w[\w.]*(\s+as \w+)?\s*$"#, 2),
            (#"\bself\.\w+"#, 1), (#"^\s*(elif|except|finally)\b.*:\s*$"#, 3), (#"__(init|name|main)__"#, 4),
            (#"^\s*class \w+(\(.*\))?:\s*$"#, 4),
        ],
        .javascript: [
            (#"\b(const|let) \w+\s*=\s*"#, 1.5), (#"=>"#, 1), (#"\bfunction\s*\w*\s*\("#, 2),
            (#"\bconsole\.(log|error|warn)\("#, 3), (#"\brequire\(|module\.exports|^\s*export (default |const |function )"#, 3),
            (#"\bdocument\.|\bwindow\.|\bawait fetch\("#, 3),
        ],
        .typescript: [
            (#":\s*(string|number|boolean|any|void|unknown|never)\b"#, 3), (#"^\s*(export )?interface \w+"#, 4),
            (#"^\s*(export )?type \w+(<.*>)?\s*="#, 3), (#"\bas const\b|\breadonly \w+"#, 3),
            (#"\b(const|let) \w+\s*:\s*\w+"#, 2),
        ],
        .go: [
            (#"^package \w+\s*$"#, 6), (#"\bfunc (\(\w+ \*?\w+\) )?\w+\("#, 2), (#":="#, 2),
            (#"\bfmt\.\w+\("#, 3), (#"\bif err != nil\b"#, 5),
        ],
        .rust: [
            (#"\bfn \w+(<.*>)?\("#, 2), (#"\blet mut\b"#, 4), (#"^\s*impl\b"#, 3), (#"\bpub (fn|struct|enum|mod)\b"#, 3),
            (#"\b(println|vec|format|panic)!\("#, 3), (#"&(mut )?self\b"#, 3), (#"^\s*use \w+(::\w+)+"#, 3),
        ],
        .c: [
            (#"^\s*#include\s*[<"]"#, 5), (#"\bint main\s*\("#, 4), (#"\b(printf|malloc|free|sizeof)\s*\("#, 2),
            (#"^\s*#define \w+"#, 3),
        ],
        .cpp: [
            (#"^\s*#include\s*<(iostream|vector|string|map|memory|algorithm|unordered_map|cstdio|cstdlib)>"#, 6),
            (#"\bstd::\w+"#, 3), (#"^\s*template\s*<"#, 4), (#"^\s*namespace \w+"#, 4), (#"^\s*(public|private|protected):\s*$"#, 4),
            (#"\bnullptr\b|\bauto \w+\s*="#, 2),
        ],
        .ruby: [
            (#"^\s*def \w+[?!=]?(\(.*\))?\s*$"#, 3), (#"^\s*end\s*$"#, 2), (#"^\s*require(_relative)? ['"]"#, 4),
            (#"\.each(_with_index)? do \|"#, 4), (#"\bputs\b"#, 2), (#"\battr_(reader|writer|accessor)\b"#, 5),
            (#"^\s*(module|class) [A-Z]\w*( < [A-Z][\w:]*)?\s*$"#, 2),
        ],
        .java: [
            (#"\bpublic (static )?(final )?(class|void|interface|enum)\b"#, 4), (#"\bSystem\.(out|err)\."#, 4),
            (#"@Override\b"#, 4), (#"^\s*import java(x)?\."#, 6), (#"\bprivate (static )?(final )?\w+(<.*>)? \w+\s*[;=]"#, 2),
        ],
        .bash: [
            (#"^#!.*\b(ba|z|k)?sh\b"#, 10), (#"^\s*(export|alias) \w+="#, 3), (#"^\s*(if|while) \[\[? "#, 3),
            (#"^\s*(fi|done|esac)\s*$"#, 3), (#"^\s*\$ \w"#, 3),
            (#"^\s*(sudo |)(git|brew|npm|pnpm|yarn|docker|kubectl|curl|ssh|cd|ls|grep|sed|awk|cat|echo|mkdir|rm|cp|mv|chmod|tar|make|cargo|go|python3?|pip3?|swift|xcodebuild|mise|tuist|gh) "#, 1.5),
        ],
        .css: [
            (#"^\s*[.#]?[\w-]+([\s,>+~:]+[.#:]?[\w-]+)*\s*\{\s*$"#, 2), (#"^\s*[\w-]+\s*:\s*[^;{}]+;\s*$"#, 2),
            (#"^\s*@(media|import|keyframes|font-face)\b"#, 3),
        ],
    ]

    static func scores(_ sample: String) -> [SyntaxLanguage: Double] {
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true).prefix(400).map(String.init)
        var scores: [SyntaxLanguage: Double] = [:]
        for (language, patterns) in telltales {
            var score = 0.0
            for (pattern, weight) in patterns {
                let hits = lines.lazy.filter { $0.range(of: pattern, options: .regularExpression) != nil }.prefix(5).count
                score += Double(hits) * weight
            }
            scores[language] = score
        }
        // TypeScript is JavaScript plus types: only call it TypeScript when
        // the types are there, and then it also gets JavaScript's evidence.
        if let ts = scores[.typescript], ts > 0 {
            scores[.typescript] = ts + (scores[.javascript] ?? 0)
        }
        return scores
    }

    /// One JSON value per line (logs, agent output, `jq -c`). Tree-sitter's
    /// JSON grammar accepts a sequence of values, so it highlights these.
    static func isJSONLines(_ sample: String) -> Bool {
        let lines = sample.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(50)
        guard lines.count >= 2 else { return false }
        // The last line of a sample may be cut short.
        return lines.dropLast().allSatisfy { line in
            guard let first = line.first, first == "{" || first == "[" else { return false }
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
        }
    }

    static func isTOML(_ sample: String) -> Bool {
        let lines = sample.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.prefix(100)
        guard lines.count >= 2 else { return false }
        let tables = lines.filter { $0.range(of: #"^\[\[?[\w.\-" ]+\]\]?$"#, options: .regularExpression) != nil }.count
        let pairs = lines.filter { $0.range(of: #"^[\w.\-"]+\s*=\s*\S"#, options: .regularExpression) != nil }.count
        return tables >= 1 && Double(tables + pairs) / Double(lines.count) >= 0.8
    }
}

/// A note's highlighting setting: detect from the text, never colour, or a
/// language the user chose (Format ▸ Language). Stored on the note as text:
/// nil for automatic, "plain", or a `SyntaxLanguage` raw value.
public enum SyntaxChoice: Hashable, Sendable {
    case automatic
    case plain
    case language(SyntaxLanguage)

    public init(stored: String?) {
        switch stored {
        case nil: self = .automatic
        case "plain": self = .plain
        case let value?: self = SyntaxLanguage(rawValue: value).map(SyntaxChoice.language) ?? .automatic
        }
    }

    public var stored: String? {
        switch self {
        case .automatic: nil
        case .plain: "plain"
        case .language(let language): language.rawValue
        }
    }

    /// The language to highlight `body` in under this choice.
    public func resolve(for body: String) -> SyntaxLanguage? {
        switch self {
        case .automatic: SyntaxLanguage.detect(body)
        case .plain: nil
        case .language(let language): language
        }
    }
}
