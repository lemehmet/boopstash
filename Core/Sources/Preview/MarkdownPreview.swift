import Foundation
import Markdown

/// A note's markdown as blocks the app draws natively (#54). There is no
/// web view: WebKit needs the network-client entitlement even for local
/// pages, which the app does not have (ADR 0001), so the preview can make
/// no request at all. What the note says is shown, never run: raw HTML is
/// text, remote images are named but not fetched, and only web, mail and
/// attachment links stay links.
public enum PreviewBlock: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// Fenced or indented code; `highlights` are UTF-16 ranges in `code`.
    case code(language: String?, code: String, highlights: [PreviewHighlight])
    case quote([PreviewBlock])
    case list(ordered: Bool, start: Int, items: [PreviewListItem])
    case table(header: [AttributedString], rows: [[AttributedString]], alignments: [PreviewAlignment])
    case rule
    case image(PreviewImage)
    /// Raw HTML from the note, shown as written.
    case rawHTML(String)
}

public struct PreviewHighlight: Equatable, Sendable {
    public var range: NSRange
    public var role: HighlightRole
}

public struct PreviewListItem: Equatable, Sendable {
    /// Nil for a plain item; true or false for a task.
    public var checked: Bool?
    public var blocks: [PreviewBlock]
}

public enum PreviewAlignment: Equatable, Sendable {
    case leading, center, trailing
}

public enum PreviewImage: Equatable, Sendable {
    /// An image stored with the note.
    case attachment(UUID, alt: String)
    /// Anything else: named, never loaded.
    case blocked(source: String, alt: String)
}

public enum MarkdownPreview {
    /// The blocks for a note. Fenced code is highlighted with the editor's
    /// grammars.
    public static func blocks(for markdown: String) async -> [PreviewBlock] {
        let document = Document(parsing: markdown)
        var builder = BlockBuilder()
        var blocks = builder.blocks(document.children)
        for (path, code, language) in builder.codeBlocks {
            let highlights = await highlight(code, language: language)
            if !highlights.isEmpty { blocks = replacing(path, in: blocks, with: .code(language: language, code: code, highlights: highlights)) }
        }
        return blocks
    }

    /// A link destination the preview may offer: web, mail, an attachment.
    /// Anything else (`javascript:`, `file:`) keeps its text, not its link.
    public static func safeLink(_ destination: String?) -> URL? {
        guard let destination = destination?.trimmingCharacters(in: .whitespaces), !destination.isEmpty,
              let url = URL(string: destination), let scheme = url.scheme?.lowercased()
        else { return nil }
        return ["http", "https", "mailto", "attachment"].contains(scheme) ? url : nil
    }

    static func highlight(_ code: String, language: String?) async -> [PreviewHighlight] {
        guard let name = language?.lowercased(), let syntax = SyntaxLanguage(fenceName: name),
              let engine = try? SyntaxEngine(language: syntax) else { return [] }
        _ = await engine.reset(code)
        return await engine.highlights(in: NSRange(location: 0, length: (code as NSString).length)).highlights
            .compactMap { highlight in HighlightRole.role(for: highlight.name).map { PreviewHighlight(range: highlight.range, role: $0) } }
    }

    /// Puts a highlighted code block back where the builder found it.
    static func replacing(_ path: [Int], in blocks: [PreviewBlock], with block: PreviewBlock) -> [PreviewBlock] {
        guard let first = path.first else { return blocks }
        var blocks = blocks
        let rest = Array(path.dropFirst())
        if rest.isEmpty {
            blocks[first] = block
            return blocks
        }
        switch blocks[first] {
        case .quote(let inner):
            blocks[first] = .quote(replacing(rest, in: inner, with: block))
        case .list(let ordered, let start, var items):
            let item = rest[0]
            items[item].blocks = replacing(Array(rest.dropFirst()), in: items[item].blocks, with: block)
            blocks[first] = .list(ordered: ordered, start: start, items: items)
        default:
            break
        }
        return blocks
    }
}

/// Walks the markdown tree into blocks, noting where each code block sits
/// so highlighting can fill it in afterwards.
struct BlockBuilder {
    var codeBlocks: [(path: [Int], code: String, language: String?)] = []
    private var path: [Int] = []

    mutating func blocks(_ children: some Sequence<Markup>) -> [PreviewBlock] {
        var out: [PreviewBlock] = []
        for child in children {
            path.append(out.count)
            out.append(contentsOf: blocks(for: child))
            path.removeLast()
        }
        return out
    }

    mutating func blocks(for markup: Markup) -> [PreviewBlock] {
        switch markup {
        case let heading as Heading:
            return [.heading(level: min(max(heading.level, 1), 6), text: Inline.text(heading.children))]
        case let paragraph as Paragraph:
            // Images become blocks of their own, after the paragraph's text.
            let text = Inline.text(paragraph.children)
            // Images anywhere in the paragraph, including inside a link or
            // emphasis ([![alt](…)](…)), not only its direct children.
            let images = Self.images(in: paragraph).map { PreviewBlock.image(Inline.image($0)) }
            let hasText = !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (hasText ? [.paragraph(text)] : []) + images
        case let code as CodeBlock:
            codeBlocks.append((path, code.code, code.language))
            return [.code(language: code.language, code: code.code, highlights: [])]
        case let quote as BlockQuote:
            return [.quote(blocks(quote.children))]
        case let list as UnorderedList:
            return [.list(ordered: false, start: 1, items: items(list.listItems))]
        case let list as OrderedList:
            return [.list(ordered: true, start: Int(list.startIndex), items: items(list.listItems))]
        case let table as Table:
            let alignments = table.columnAlignments.map { alignment -> PreviewAlignment in
                switch alignment {
                case .center: .center
                case .right: .trailing
                default: .leading
                }
            }
            let header = table.head.cells.map { Inline.text($0.children) }
            let rows = table.body.rows.map { row in Array(row.cells.map { Inline.text($0.children) }) }
            return [.table(header: Array(header), rows: Array(rows), alignments: alignments)]
        case is ThematicBreak:
            return [.rule]
        case let html as HTMLBlock:
            return [.rawHTML(html.rawHTML)]
        default:
            return blocks(markup.children)
        }
    }

    static func images(in markup: Markup) -> [Markdown.Image] {
        markup.children.flatMap { child -> [Markdown.Image] in
            if let image = child as? Markdown.Image { return [image] }
            return images(in: child)
        }
    }

    mutating func items(_ listItems: some Sequence<ListItem>) -> [PreviewListItem] {
        var out: [PreviewListItem] = []
        for item in listItems {
            path.append(out.count)
            let checked: Bool? = switch item.checkbox {
            case .checked: true
            case .unchecked: false
            case nil: nil
            }
            out.append(PreviewListItem(checked: checked, blocks: blocks(item.children)))
            path.removeLast()
        }
        return out
    }
}

/// Inline markdown as an `AttributedString` with Foundation's presentation
/// intents, which SwiftUI's `Text` draws as emphasis, code and so on.
enum Inline {
    static func text(_ children: some Sequence<Markup>) -> AttributedString {
        children.reduce(into: AttributedString()) { $0 += text($1) }
    }

    static func text(_ markup: Markup) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return AttributedString(text.string)
        case let emphasis as Emphasis:
            return styled(text(emphasis.children), .emphasized)
        case let strong as Strong:
            return styled(text(strong.children), .stronglyEmphasized)
        case let strike as Strikethrough:
            return styled(text(strike.children), .strikethrough)
        case let code as InlineCode:
            return styled(AttributedString(code.code), .code)
        case let link as Markdown.Link:
            var inner = text(link.children)
            if let url = MarkdownPreview.safeLink(link.destination) { inner.link = url }
            return inner
        case let html as InlineHTML:
            return AttributedString(html.rawHTML)
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case is Markdown.Image:
            // Drawn as a block after the paragraph.
            return AttributedString()
        default:
            return text(markup.children)
        }
    }

    static func styled(_ text: AttributedString, _ intent: InlinePresentationIntent) -> AttributedString {
        var text = text
        for run in text.runs {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
        }
        return text
    }

    static func image(_ image: Markdown.Image) -> PreviewImage {
        let alt = image.plainText
        let source = image.source ?? ""
        if source.lowercased().hasPrefix("attachment:"), let id = UUID(uuidString: String(source.dropFirst("attachment:".count))) {
            return .attachment(id, alt: alt)
        }
        return .blocked(source: source, alt: alt)
    }
}

extension SyntaxLanguage {
    /// The language a code fence names (` ```swift `), with common aliases.
    init?(fenceName: String) {
        let aliases: [String: SyntaxLanguage] = [
            "js": .javascript, "jsx": .javascript, "ts": .typescript, "tsx": .typescript,
            "py": .python, "rb": .ruby, "sh": .bash, "shell": .bash, "zsh": .bash, "console": .bash,
            "golang": .go, "rs": .rust, "c++": .cpp, "cc": .cpp, "h": .c, "yml": .yaml, "md": .markdown,
            "htm": .html, "plist": .xml, "svg": .xml, "patch": .diff,
        ]
        guard let language = aliases[fenceName] ?? SyntaxLanguage(rawValue: fenceName) else { return nil }
        self = language
    }
}
