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

    /// Detection reads at most this much; a 50 MB log should not stall a
    /// paste, and detection runs again on every edit.
    static let sampleLimit = 64 * 1024
    /// JSON is the one kind confirmed by parsing the whole text, up to this
    /// size; above it, the sample's shape decides.
    static let jsonParseLimit = 1024 * 1024
    static let urlLengthLimit = 4096

    /// The start of a text after its leading whitespace, at most
    /// `sampleLimit` characters. The skip walks scalars, not characters, and
    /// stops after `sampleLimit` of them, so a body of megabytes of blank
    /// lines costs no more than a sample.
    static func leadingSample(of text: String) -> String {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var skipped = 0
        while start < scalars.endIndex, skipped < sampleLimit, scalars[start].properties.isWhitespace {
            scalars.formIndex(after: &start)
            skipped += 1
        }
        // Cut the scalars before copying: copying the rest of a 20 MB buffer
        // to take its first characters made detection scale with the
        // buffer. A character is rarely more than a few scalars; a cluster
        // cut at the end only shortens the sample.
        let end = scalars.index(start, offsetBy: sampleLimit * 4, limitedBy: scalars.endIndex) ?? scalars.endIndex
        return String(String(String.UnicodeScalarView(scalars[start..<end])).prefix(sampleLimit))
    }

    public static func detect(_ text: String) -> ContentKind {
        // A byte-order mark is not content; JSON with one is still JSON (#80).
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let sample = leadingSample(of: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return .plain }
        let truncated = text.utf8.count > sampleLimit
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        if !truncated, isURL(sample) { return .url }
        if isJSON(text, sample: sample) { return .json }
        if isDiff(lines) { return .diff }
        if let markup = markupKind(sample, truncated: truncated) { return markup }
        if isStackTrace(sample, lines: lines) { return .stackTrace }
        if isLog(lines) { return .log }
        if isSQL(sample) { return .sql }
        if isMarkdown(lines) { return .markdown }
        if isYAML(lines) { return .yaml }
        if isCode(sample, lines: lines) { return .code }
        return .plain
    }

    static func isURL(_ text: String) -> Bool {
        guard text.utf8.count <= urlLengthLimit, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil
        else { return false }
        return true
    }

    static func isJSON(_ text: String, sample: String) -> Bool {
        guard let first = sample.first, first == "{" || first == "[" else { return false }
        if text.utf8.count <= jsonParseLimit {
            guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        }
        // Too big to parse on every edit: an object must open with a key, an
        // array with a value, and JSON has no other punctuation in between.
        let next = sample.dropFirst().first { !$0.isWhitespace }
        guard let next else { return false }
        return first == "{" ? (next == "\"" || next == "}") : "\"{[]-0123456789tfn".contains(next)
    }

    static func isDiff(_ lines: [String]) -> Bool {
        if lines.contains(where: { $0.hasPrefix("diff --git ") }) { return true }
        let minus = lines.contains { $0.hasPrefix("--- ") }
        let plus = lines.contains { $0.hasPrefix("+++ ") }
        let hunk = lines.contains { $0.hasPrefix("@@ ") }
        return minus && plus && hunk
    }

    static func markupKind(_ sample: String, truncated: Bool) -> ContentKind? {
        guard sample.first == "<" else { return nil }
        let lower = sample.prefix(2048).lowercased()
        if lower.hasPrefix("<!doctype html") || lower.contains("<html") || lower.contains("<body") || lower.contains("<div") {
            return .html
        }
        // A sample of a large document is cut mid-element and can never
        // parse; an XML declaration or a root element's opening tag is
        // enough to call it XML.
        if truncated {
            return sample.range(of: #"^<(\?xml\s|[A-Za-z_][\w:.-]*[\s>/])"#, options: .regularExpression) != nil ? .xml : nil
        }
        guard let data = sample.data(using: .utf8) else { return nil }
        return XMLParser(data: data).parse() ? .xml : nil
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
