import Foundation

/// What a captured buffer looks like. Drives the highlighting language, the
/// generated title, and what the list says about a note. Detection is a set
/// of cheap heuristics tried most-specific first; it only has to be right
/// often enough to be useful, and wrong in harmless ways.
public enum ContentKind: String, CaseIterable, Codable, Sendable {
    case json, xml, html, yaml, sql, diff, stackTrace, log, url, markdown, code, plain

    public var displayName: String {
        switch self {
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .yaml: "YAML"
        case .sql: "SQL"
        case .diff: "Diff"
        case .stackTrace: "Stack trace"
        case .log: "Log"
        case .url: "Link"
        case .markdown: "Markdown"
        case .code: "Code"
        case .plain: "Text"
        }
    }

    /// Detection reads at most this much; a 50 MB log should not stall a paste.
    static let sampleLimit = 64 * 1024

    public static func detect(_ text: String) -> ContentKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }
        let sample = String(trimmed.prefix(sampleLimit))
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        if isURL(trimmed) { return .url }
        if isJSON(trimmed) { return .json }
        if isDiff(lines) { return .diff }
        if let markup = markupKind(sample) { return markup }
        if isStackTrace(sample, lines: lines) { return .stackTrace }
        if isLog(lines) { return .log }
        if isSQL(sample) { return .sql }
        if isMarkdown(lines) { return .markdown }
        if isYAML(lines) { return .yaml }
        if isCode(sample, lines: lines) { return .code }
        return .plain
    }

    static func isURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil
        else { return false }
        return true
    }

    static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[",
              text.utf8.count <= 8 * 1024 * 1024,
              let data = text.data(using: .utf8)
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    static func isDiff(_ lines: [String]) -> Bool {
        if lines.contains(where: { $0.hasPrefix("diff --git ") }) { return true }
        let minus = lines.contains { $0.hasPrefix("--- ") }
        let plus = lines.contains { $0.hasPrefix("+++ ") }
        let hunk = lines.contains { $0.hasPrefix("@@ ") }
        return minus && plus && hunk
    }

    static func markupKind(_ sample: String) -> ContentKind? {
        guard sample.first == "<" else { return nil }
        let lower = sample.prefix(2048).lowercased()
        if lower.hasPrefix("<!doctype html") || lower.contains("<html") || lower.contains("<body") || lower.contains("<div") {
            return .html
        }
        guard let data = sample.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        return parser.parse() ? .xml : nil
    }

    static let traceMarkers = [
        "Traceback (most recent call last):",
        "Exception in thread ",
        "panicked at ",
        "Thread 0 Crashed",
        "Fatal error: ",
        "Unhandled exception",
    ]

    static func isStackTrace(_ sample: String, lines: [String]) -> Bool {
        if traceMarkers.contains(where: sample.contains) { return true }
        if sample.range(of: #"^goroutine \d+ \["#, options: .regularExpression) != nil { return true }
        // Java/Kotlin "at com.x.Y.method(File.java:12)" and JavaScript
        // "at fn (file.js:3:9)" frames.
        let frames = lines.filter {
            $0.range(of: #"^\s+at .+[(:]\S*:\d+"#, options: .regularExpression) != nil
        }
        return frames.count >= 2
    }

    static func isLog(_ lines: [String]) -> Bool {
        guard lines.count >= 3 else { return false }
        let stamped = lines.prefix(50).filter {
            $0.range(of: #"^\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}"#, options: .regularExpression) != nil
                || $0.range(of: #"^\[?\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil
                || $0.range(of: #"^\[?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\b"#, options: .regularExpression) != nil
        }
        return Double(stamped.count) / Double(min(lines.count, 50)) >= 0.6
    }

    static func isSQL(_ sample: String) -> Bool {
        let head = sample.prefix(4096)
        return head.range(
            of: #"^\s*(SELECT\s[\s\S]+\sFROM\s|INSERT\s+INTO\s|UPDATE\s+\S+\s+SET\s|DELETE\s+FROM\s|CREATE\s+(TABLE|INDEX|VIEW)\s|ALTER\s+TABLE\s|WITH\s+\w+\s+AS\s*\()"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func isMarkdown(_ lines: [String]) -> Bool {
        let markers = lines.prefix(200).filter {
            $0.range(of: #"^(#{1,6} \S|```|- \[[ x]\] |\* \S|> \S|\|.+\|$)"#, options: .regularExpression) != nil
                || $0.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil
        }
        return markers.count >= 2 || lines.first?.range(of: #"^#{1,6} \S"#, options: .regularExpression) != nil
    }

    static func isYAML(_ lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }
        if lines.first == "---" { return true }
        let shaped = lines.prefix(100).filter {
            $0.range(of: #"^\s*(- )?[A-Za-z_][\w.-]*:( .*)?$"#, options: .regularExpression) != nil
                || $0.range(of: #"^\s*- \S"#, options: .regularExpression) != nil
                || $0.hasPrefix("#")
        }
        let hasBraces = lines.contains { $0.contains("{") || $0.hasSuffix(";") }
        return !hasBraces && Double(shaped.count) / Double(min(lines.count, 100)) >= 0.8
    }

    static let codeKeywords = #"^\s*(func|def|class|struct|enum|import|from \S+ import|package|const|let|var|fn|pub fn|impl|interface|public|private|#include|using|return|if|for|while)\b"#

    static func isCode(_ sample: String, lines: [String]) -> Bool {
        let keywordLines = lines.prefix(200).filter { $0.range(of: codeKeywords, options: .regularExpression) != nil }.count
        let punctuation = sample.prefix(8192).filter { "{};()".contains($0) }.count
        let density = Double(punctuation) / Double(max(sample.prefix(8192).count, 1))
        return keywordLines >= 2 || (keywordLines >= 1 && density > 0.02) || density > 0.06
    }
}
