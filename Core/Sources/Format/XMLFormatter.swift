import Foundation

/// XML and XML property lists, re-indented by Foundation's `XMLDocument`,
/// which keeps comments, CDATA and the order of everything. Property lists
/// take this path rather than `PropertyListSerialization`, whose round trip
/// reorders dictionary keys and drops comments. `XMLDocument` is macOS only;
/// on iOS XML is not formatted.
public enum XMLFormatter {
    public static var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public static func format(_ text: String, indent: Int = 4) -> Result<String, FormatError> {
        #if os(macOS)
        do {
            // External entities and DTDs are never loaded: formatting must not
            // reach the network or the disk (ADR 0001).
            let document = try XMLDocument(xmlString: text, options: [.nodePreserveCDATA, .nodeLoadExternalEntitiesNever])
            var out = reindent(document.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA, .nodeCompactEmptyElement]), to: indent)
            if !out.hasSuffix("\n") { out += "\n" }
            return .success(out)
        } catch let error as NSError {
            return .failure(failure(from: error.userInfo[NSLocalizedDescriptionKey] as? String))
        }
        #else
        return .failure(FormatError(message: "XML formatting needs macOS", line: nil, column: nil))
        #endif
    }

    /// `XMLDocument` always indents by four spaces; this scales the
    /// indentation of lines that start with markup to `width`. Lines inside
    /// CDATA sections, comments, processing instructions and declarations
    /// keep their own whitespace, which may matter.
    static func reindent(_ xml: String, to width: Int) -> String {
        guard width != 4 else { return xml }
        // Inside a CDATA section or comment, and what ends it.
        var closer: String?
        var lines: [String] = []
        for line in xml.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.drop { $0 == " " }
            if closer == nil, content.hasPrefix("<") {
                lines.append(String(repeating: " ", count: (line.count - content.count) / 4 * width) + content)
            } else {
                lines.append(String(line))
            }
            closer = openSection(after: Substring(line), inside: closer)
        }
        return lines.joined(separator: "\n")
    }

    /// What opens a section whose contents are data, and what closes it.
    /// A DOCTYPE counts up to its first ">": the declarations of an
    /// internal subset are markup, where whitespace carries no meaning.
    static let sections = [("<![CDATA[", "]]>"), ("<!--", "-->"), ("<?", "?>"), ("<!DOCTYPE", ">")]

    /// Whether `line` leaves a CDATA section or comment open, given the one
    /// open before it: returns what still has to close it.
    static func openSection(after line: Substring, inside: String?) -> String? {
        var rest = line[...]
        var closer = inside
        while true {
            if let open = closer {
                guard let end = rest.range(of: open) else { return open }
                rest = rest[end.upperBound...]
                closer = nil
            } else {
                let starts = sections.compactMap { pair in rest.range(of: pair.0).map { ($0, pair.1) } }
                guard let first = starts.min(by: { $0.0.lowerBound < $1.0.lowerBound }) else { return nil }
                rest = rest[first.0.upperBound...]
                closer = first.1
            }
        }
    }

    /// libxml2's message reads "Line 3: Opening and ending tag mismatch…";
    /// the line moves into the error's own field.
    static func failure(from description: String?) -> FormatError {
        let text = (description ?? "not well-formed XML").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.firstMatch(of: /^Line (\d+): (.*)$/.dotMatchesNewlines()) else {
            return FormatError(message: text, line: nil, column: nil)
        }
        return FormatError(message: String(match.2), line: Int(match.1), column: nil)
    }
}
