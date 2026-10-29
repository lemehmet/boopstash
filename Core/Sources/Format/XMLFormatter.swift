import Foundation

/// XML and XML property lists, parsed by Foundation's `XMLDocument` and
/// printed from the tree, keeping comments, CDATA and the order of
/// everything, and text exactly as written. Property lists
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
            // The parser drops whitespace-only text, which a document using
            // xml:space="preserve" asks to keep; such a document is left as
            // it is rather than changed (#149). (Parsing with whitespace kept
            // makes libxml2 write stray whitespace inside tags.)
            if text.contains("xml:space") {
                return .failure(FormatError(message: #"The document keeps its whitespace (xml:space="preserve"), so it is left as it is"#, line: nil, column: nil))
            }
            let document = try XMLDocument(xmlString: text, options: [.nodePreserveCDATA, .nodeLoadExternalEntitiesNever])
            return .success(render(document, source: text, width: indent))
        } catch let error as NSError {
            return .failure(failure(from: error.userInfo[NSLocalizedDescriptionKey] as? String))
        }
        #else
        return .failure(FormatError(message: "XML formatting needs macOS", line: nil, column: nil))
        #endif
    }

    #if os(macOS)
    /// The document printed from its tree (#112): an element whose content
    /// is only elements, comments and processing instructions has one per
    /// line, indented by `width`; any element with text in it (mixed
    /// content, CDATA) is written exactly as it is, since its whitespace is
    /// part of the text. `XMLDocument`'s own pretty print re-indents even
    /// that, and only by four spaces.
    static func render(_ document: XMLDocument, source: String, width: Int) -> String {
        var out: [String] = []
        // The source's own declaration, word for word (XMLDocument adds a
        // standalone it did not have); without one, XMLDocument's.
        let start = source.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if start.hasPrefix("<?xml "), let end = start.range(of: "?>") {
            out.append(String(start[..<end.upperBound]))
        } else {
            let pretty = document.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA, .nodeCompactEmptyElement])
            if let first = pretty.split(separator: "\n", maxSplits: 1).first, first.hasPrefix("<?xml ") { out.append(String(first)) }
        }
        if let dtd = document.dtd {
            out.append(dtd.xmlString(options: [.nodePrettyPrint]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for child in document.children ?? [] where child.kind != .DTDKind {
            render(child, depth: 0, width: width, into: &out)
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func render(_ node: XMLNode, depth: Int, width: Int, into out: inout [String]) {
        let pad = String(repeating: " ", count: depth * width)
        guard let element = node as? XMLElement else {
            // Comments and processing instructions, word for word; whitespace
            // between elements is the formatter's to replace.
            if node.kind == .text, !isCharacterData(node) { return }
            out.append(pad + node.xmlString(options: [.nodePreserveCDATA]))
            return
        }
        let children = element.children ?? []
        // Text or CDATA in it, even CDATA of only whitespace (#149): written
        // exactly as it is.
        guard !children.isEmpty, !children.contains(where: isCharacterData) else {
            out.append(pad + element.xmlString(options: [.nodePreserveCDATA, .nodeCompactEmptyElement]))
            return
        }
        // The start tag, attributes and namespaces included: the element
        // without its children, written as an empty one.
        let shell = element.copy() as! XMLElement
        shell.setChildren(nil)
        let empty = shell.xmlString(options: [.nodeCompactEmptyElement])
        out.append(pad + String(empty.dropLast(2)) + ">")
        for child in children { render(child, depth: depth + 1, width: width, into: &out) }
        out.append(pad + "</\(element.name ?? "")>")
    }
    /// Text that is content, not layout: any CDATA section, and any text
    /// that is not only whitespace.
    static func isCharacterData(_ node: XMLNode) -> Bool {
        guard node.kind == .text else { return false }
        return node.xmlString.hasPrefix("<![CDATA[") || !(node.stringValue ?? "").allSatisfy(\.isWhitespace)
    }
    #endif

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
