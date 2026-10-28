import AppKit
import SwiftTreeSitter
import TreeSitterJSON

/// One highlighted range, as plain values so results can cross from the
/// background parse to the main thread.
struct Highlight: Sendable {
    let range: NSRange
    let name: String
}

/// Parsing, with no main-actor state: each call builds its own parser, so it
/// can run on any thread.
enum JSONGrammar {
    /// SPM puts the grammar's queries in a resource bundle; look for the file
    /// in every bundle the app carries rather than guess the bundle's name.
    static func highlightsQuery() throws -> Data {
        let candidates = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in candidates {
            guard let resources = bundle.resourceURL,
                  let entries = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries where entry.lastPathComponent.contains("TreeSitterJSON") {
                for relative in ["queries/highlights.scm", "Contents/Resources/queries/highlights.scm"] {
                    if let data = try? Data(contentsOf: entry.appendingPathComponent(relative)) { return data }
                }
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Full parse and query. The real app parses incrementally; this is the
    /// upper bound one edit could cost.
    static func highlights(in source: String, query queryData: Data) throws -> [Highlight] {
        let language = Language(language: tree_sitter_json())
        let parser = Parser()
        try parser.setLanguage(language)
        let query = try Query(language: language, data: queryData)
        guard let tree = parser.parse(source) else { return [] }
        return query.execute(in: tree).resolve(with: .init(string: source)).highlights()
            .map { Highlight(range: $0.range, name: $0.name) }
    }
}

/// Holds the current highlights and paints them as TextKit 2 rendering
/// attributes, which colour text without touching storage (no undo entries,
/// no change notifications). Only the viewport is painted: the cost of a
/// 1 MB document is one parse, off the main thread, plus one screenful.
@MainActor
final class JSONHighlighter {
    let query: Data
    var highlights: [Highlight] = []
    private var pending: Task<Void, Never>?
    private var generation = 0

    init() throws {
        query = try JSONGrammar.highlightsQuery()
    }

    /// Synchronous parse, for the benchmark's worst-case figure.
    func parse(_ source: String) {
        highlights = (try? JSONGrammar.highlights(in: source, query: query)) ?? []
    }

    /// What edits use: wait for typing to pause, parse on a background task,
    /// and deliver only the newest result. The main thread pays for copying
    /// the string and nothing else.
    func schedule(_ source: String, debounce: Duration = .milliseconds(150), then done: @escaping @MainActor () -> Void) {
        pending?.cancel()
        generation += 1
        let generation = generation
        let query = query
        pending = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let result = (try? JSONGrammar.highlights(in: source, query: query)) ?? []
            await MainActor.run {
                guard let self, self.generation == generation else { return }
                self.highlights = result
                done()
            }
        }
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
