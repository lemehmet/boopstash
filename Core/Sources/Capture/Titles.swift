import Foundation

/// Produces a title for a note nobody named. The app tries the on-device
/// model first (a `Live*` adapter over Foundation Models) and falls back to
/// `RuleTitler`, which is also what runs on Macs without Apple Intelligence.
public protocol Titler: Sendable {
    func title(for body: String, kind: ContentKind) async -> String
}

/// Titles from the text itself: the first line that says something, or a
/// summary of the structure for kinds whose first line says nothing (JSON,
/// diffs, URLs, stack traces).
public struct RuleTitler: Titler {
    public static let maxLength = 60

    public init() {}

    public func title(for body: String, kind: ContentKind) async -> String {
        Self.title(for: body, kind: kind)
    }

    public static func title(for body: String, kind: ContentKind) -> String {
        // A byte-order mark is not content, as detection already treats it.
        let body = body.hasPrefix("\u{FEFF}") ? String(body.dropFirst()) : body
        // Titles come from the start of a note (and, for Python, the end);
        // never scan a whole multi-megabyte body on every edit.
        // Leading whitespace is skipped, as detection skips it, so an
        // indented JSON array is still seen to start with "[" (#13).
        let head = ContentKind.leadingSample(of: body)
        let structured: String? = switch kind {
        case .json: jsonTitle(body, head: head)
        case .url: urlTitle(head)
        case .diff: diffTitle(head)
        case .stackTrace: traceTitle(head: head, tail: String(body.suffix(8 * 1024)))
        default: nil
        }
        if let structured { return truncated(structured) }
        if let line = firstMeaningfulLine(head) { return truncated(line) }
        // Nothing but images: say so rather than "Plain text".
        if !AttachmentReference.ids(in: head).isEmpty { return "Image" }
        return kind.displayName
    }

    // MARK: Lines

    /// Skips blank lines, code fences, lone braces and other lines made only
    /// of punctuation; strips markdown heading, list and quote markers.
    static func firstMeaningfulLine(_ body: String) -> String? {
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true).prefix(200) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            // Checklist first: the list-marker pattern would otherwise take
            // its "- " and leave "[ ]" behind.
            line = line.replacingOccurrences(of: #"^[-*+] \[[ xX]\]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(#{1,6}|[-*+]|\d+[.)]|>)\s+"#, with: "", options: .regularExpression)
            // An image reference reads as its alt text, so "![](attachment:…)"
            // never becomes a title.
            line = line.replacingOccurrences(of: #"!\[((?:[^\]\\]|\\.)*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard line.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            return line
        }
        return nil
    }

    /// Cuts at a word boundary when one is near the limit, and marks the cut.
    static func truncated(_ text: String, limit: Int = maxLength) -> String {
        guard text.count > limit else { return text }
        let hard = text.prefix(limit - 1)
        if let space = hard.lastIndex(of: " "), hard.distance(from: hard.startIndex, to: space) >= limit / 2 {
            return hard[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return hard + "…"
    }

    // MARK: Structured kinds

    static func jsonTitle(_ body: String, head: String) -> String? {
        guard body.utf8Fits(ContentKind.jsonParseLimit) else {
            // Too big to parse for a title: name the shape from the head.
            if head.first == "[" { return "JSON array" }
            let keys = orderedTopLevelKeys(head).prefix(3)
            return keys.isEmpty ? "JSON object" : "JSON {" + keys.joined(separator: ", ") + ", …}"
        }
        guard let data = body.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        if let object = value as? [String: Any] {
            // JSONSerialization does not keep key order; read the first keys
            // from the text so the title matches what the user sees.
            let keys = orderedTopLevelKeys(body).prefix(3)
            let more = object.count > keys.count ? ", …" : ""
            return keys.isEmpty ? "JSON object" : "JSON {" + keys.joined(separator: ", ") + more + "}"
        }
        if let array = value as? [Any] {
            return "JSON array of \(array.count)"
        }
        return "JSON value"
    }

    /// Keys at depth one, in source order, found by a small scan that tracks
    /// nesting and strings. Each key keeps its escapes while scanning and is
    /// decoded as a JSON string afterwards, so `\u0061` reads as `a`.
    static func orderedTopLevelKeys(_ body: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var current = ""
        var expectingKey = false
        for character in body {
            if inString {
                if escaped { escaped = false; current.append(character); continue }
                if character == "\\" { escaped = true; current.append(character); continue }
                if character == "\"" {
                    inString = false
                    if depth == 1 && expectingKey { keys.append(decodedJSONString(current)); expectingKey = false }
                    continue
                }
                current.append(character)
                continue
            }
            switch character {
            case "\"": inString = true; current = ""
            case "{", "[":
                depth += 1
                if depth == 1 && character == "{" { expectingKey = true }
            case "}", "]": depth -= 1
            case ",": if depth == 1 { expectingKey = true }
            case ":": if depth == 1 { expectingKey = false }
            default: break
            }
            if keys.count >= 4 { break }
        }
        return keys
    }

    static func decodedJSONString(_ raw: String) -> String {
        guard let data = ("\"" + raw + "\"").data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
        else { return raw }
        return decoded
    }

    static func urlTitle(_ body: String) -> String? {
        guard let url = URL(string: body.trimmingCharacters(in: .whitespacesAndNewlines)), let rawHost = url.host() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : host + "/" + path
    }

    static func diffTitle(_ body: String) -> String? {
        func path(_ line: Substring) -> String {
            var path = line.dropFirst(4).split(separator: "\t").first.map(String.init) ?? ""
            if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
            return path
        }
        // Each file is a "--- old" / "+++ new" pair; a deleted file's new side
        // is /dev/null, so its name comes from the old side.
        var files: [String] = []
        var old: String?
        for line in body.split(separator: "\n") {
            if line.hasPrefix("--- ") {
                old = path(line)
            } else if line.hasPrefix("+++ ") {
                let new = path(line)
                let name = new == "/dev/null" ? old : new
                if let name, name != "/dev/null" { files.append((name as NSString).lastPathComponent) }
                old = nil
            }
        }
        guard !files.isEmpty else { return nil }
        let shown = files.prefix(3).joined(separator: ", ")
        return "Diff: " + shown + (files.count > 3 ? " and \(files.count - 3) more" : "")
    }

    /// The line naming the failure, which is rarely the first one.
    static func traceTitle(head: String, tail: String) -> String? {
        let lines = head.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Python puts the exception on the last line, whatever it is called
        // (KeyboardInterrupt, SystemExit, a custom class).
        if lines.first?.hasPrefix("Traceback") == true {
            return tail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        }
        let pattern = #"(Error|Exception|panicked at|Fatal error|Crashed)"#
        return lines.first { $0.range(of: pattern, options: .regularExpression) != nil }
    }
}
