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

    public static func format(_ text: String) -> Result<String, FormatError> {
        #if os(macOS)
        do {
            // External entities and DTDs are never loaded: formatting must not
            // reach the network or the disk (ADR 0001).
            let document = try XMLDocument(xmlString: text, options: [.nodePreserveCDATA, .nodeLoadExternalEntitiesNever])
            var out = document.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA, .nodeCompactEmptyElement])
            if !out.hasSuffix("\n") { out += "\n" }
            return .success(out)
        } catch let error as NSError {
            return .failure(failure(from: error.userInfo[NSLocalizedDescriptionKey] as? String))
        }
        #else
        return .failure(FormatError(message: "XML formatting needs macOS", line: nil, column: nil))
        #endif
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
