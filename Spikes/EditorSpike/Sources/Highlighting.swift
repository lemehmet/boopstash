import AppKit
import SwiftTreeSitter
import TreeSitterJSON

/// Tree-sitter highlighting applied as TextKit 2 rendering attributes, which
/// colour the text without touching storage (no undo entries, no change
/// notifications). Only the viewport is painted, which is the point: the cost
/// of a 1 MB document should be one parse plus one screenful.
@MainActor
final class JSONHighlighter {
    private let parser = Parser()
    private let query: Query
    private(set) var tree: MutableTree?
    private(set) var highlights: [NamedRange] = []

    init() throws {
        let language = Language(language: tree_sitter_json())
        try parser.setLanguage(language)
        query = try Self.loadHighlightsQuery(language: language)
    }

    /// SPM puts the grammar's queries in a resource bundle. Under Tuist the
    /// bundle name differs from what `LanguageConfiguration` guesses, so look
    /// for the file in every bundle the app carries.
    private static func loadHighlightsQuery(language: Language) throws -> Query {
        let candidates = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in candidates {
            guard let resources = bundle.resourceURL,
                  let entries = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries where entry.lastPathComponent.contains("TreeSitterJSON") {
                let url = entry.appendingPathComponent("queries/highlights.scm")
                if let data = try? Data(contentsOf: url) { return try Query(language: language, data: data) }
                let flat = entry.appendingPathComponent("Contents/Resources/queries/highlights.scm")
                if let data = try? Data(contentsOf: flat) { return try Query(language: language, data: data) }
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Full parse and query. The real app parses incrementally; this is the
    /// upper bound a keystroke could cost.
    func parse(_ source: String) {
        tree = parser.parse(source)
        guard let tree else { highlights = []; return }
        highlights = query.execute(in: tree).resolve(with: .init(string: source)).highlights()
    }

    /// Paints the highlights intersecting `visible` (a character range).
    func paint(_ view: NSTextView, visible: NSRange) {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
        guard let visibleText = Self.textRange(visible, in: content) else { return }
        layout.removeRenderingAttribute(.foregroundColor, for: visibleText)
        for highlight in highlights where NSIntersectionRange(highlight.range, visible).length > 0 {
            guard let range = Self.textRange(highlight.range, in: content) else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: Self.color(for: highlight.name), for: range)
        }
    }

    static func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    static func color(for name: String) -> NSColor {
        switch name.split(separator: ".").first {
        case "string": .systemRed
        case "number": .systemBlue
        case "constant": .systemPurple
        case "property": .systemTeal
        case "punctuation": .secondaryLabelColor
        default: .labelColor
        }
    }
}

enum Samples {
    static let markdown = """
    # Boopstash editor spike

    Type here. Quotes ' " and dashes -- must stay exactly as typed.
    Home/End move within the line. Tab and Shift-Tab indent selected lines.
    ⌥⌘[ folds the section under the caret's heading; press it again to unfold.

    ## Folding

    The lines under this heading fold away.
    Arrow keys should jump over them.
    Copying across a fold copies the hidden text too.

    ### A nested heading

    Folds with its parent.

    ## After the fold

    The caret should land here when moving down from "## Folding" while it is folded.

    """

    /// About 1 MB of JSON shaped like an API response.
    static func largeJSON(targetBytes: Int = 1_000_000) -> String {
        var out = "[\n"
        var index = 0
        while out.utf8.count < targetBytes {
            out += """
              {"id": \(index), "name": "item-\(index)", "active": \(index % 2 == 0), "score": \(Double(index) * 1.5), "tags": ["alpha", "beta"], "owner": null},

            """
            index += 1
        }
        out += "  {\"id\": -1}\n]\n"
        return out
    }
}

enum Attachments {
    /// A placeholder image attachment the size of a small screenshot chip.
    static func chip(size: NSSize = NSSize(width: 120, height: 72)) -> NSAttributedString {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: size)
        return NSAttributedString(attachment: attachment)
    }
}
