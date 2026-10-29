import Foundation

/// Paste as Markdown (ADR 0003): turns pasteboard HTML into markdown source.
/// Headings, paragraphs, emphasis, strikethrough, inline code, code blocks
/// with their language, links, images, lists (nested, ordered), quotes,
/// rules and tables. Everything else contributes its text.
///
/// Text is not escaped: the result is source a programmer reads and edits,
/// and `snake_case` or `a*b` should stay as written. Non-breaking spaces
/// become ordinary ones, since invisible characters in source only surprise. Nothing is fetched; an
/// image becomes a reference, and inline `data:` images only their alt text.
public enum HTMLToMarkdown {
    public static func convert(_ html: String) -> String {
        let root = TreeBuilder.build(HTMLTokenizer.tokens(html))
        // Blocks are trimmed and never empty, so joining them is the only
        // place blank lines come from; code blocks keep theirs untouched.
        let blocks = Writer().blocks(root.children)
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tree

final class HTMLNode {
    let name: String // "#text" for text
    let attributes: [String: String]
    var children: [HTMLNode] = []
    let text: String

    init(name: String, attributes: [String: String] = [:], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    var isText: Bool { name == "#text" }

    /// All text below this node, unmodified (for code).
    var rawText: String {
        isText ? text : children.map { $0.name == "br" ? "\n" : $0.rawText }.joined()
    }
}

enum TreeBuilder {
    static let voidElements: Set<String> = ["br", "hr", "img", "meta", "link", "input", "wbr", "col", "source", "area", "base"]
    /// Elements a `<p>` cannot contain; opening one closes an open paragraph.
    static let blockElements: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "nav", "aside",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "table", "hr", "dl", "figure",
    ]

    /// Deeper elements are flattened into their ancestor at this depth: the
    /// writer recurses once per level, and no real document nests this far.
    static let maxDepth = 128

    static func build(_ tokens: [HTMLToken]) -> HTMLNode {
        let root = HTMLNode(name: "#root")
        var stack = [root]

        func close(_ name: String, stoppingAt barriers: Set<String> = []) {
            guard let index = stack.lastIndex(where: { $0.name == name }) else { return }
            if stack[(index + 1)...].contains(where: { barriers.contains($0.name) }) { return }
            stack.removeSubrange(index...)
        }

        for token in tokens {
            switch token {
            case .text(let text):
                stack.last!.children.append(HTMLNode(name: "#text", text: text))
            case .start(let name, let attributes, let selfClosing):
                if blockElements.contains(name) { close("p") }
                switch name {
                case "li": close("li", stoppingAt: ["ul", "ol"])
                case "tr": close("tr", stoppingAt: ["table"])
                case "td", "th": close("td", stoppingAt: ["tr"]); close("th", stoppingAt: ["tr"])
                default: break
                }
                guard stack.count < maxDepth else { continue }
                let node = HTMLNode(name: name, attributes: attributes)
                stack.last!.children.append(node)
                if !selfClosing && !voidElements.contains(name) { stack.append(node) }
            case .end(let name):
                if name == "p", !stack.contains(where: { $0.name == "p" }) {
                    continue // a stray </p> closes nothing
                }
                close(name)
            }
        }
        return root
    }
}

// MARK: - Writing

struct Writer {
    static let headings = ["h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6]
    static let invisible: Set<String> = ["script", "style", "title", "template", "noscript", "head", "meta", "link"]

    /// Inside a link's text, the page's own brackets and backslashes are
    /// escaped as text, before any Markdown is generated around them; the
    /// code spans and hard breaks the writer adds are left alone.
    var inLinkLabel = false

    /// Renders a run of siblings as blocks. Consecutive inline content forms
    /// one paragraph.
    func blocks(_ nodes: [HTMLNode]) -> [String] {
        var result: [String] = []
        var run: [HTMLNode] = []

        func flush() {
            let paragraph = inline(run).trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { result.append(paragraph) }
            run.removeAll()
        }

        for node in nodes {
            if Self.invisible.contains(node.name) { continue }
            if node.isText || (!TreeBuilder.blockElements.contains(node.name) && !containsBlock(node)) {
                run.append(node)
                continue
            }
            flush()
            // An inline wrapper around blocks (<body>, or the <b> Google Docs
            // puts around a whole document) is a container, not emphasis.
            result.append(contentsOf: TreeBuilder.blockElements.contains(node.name) ? block(node) : blocks(node.children))
        }
        flush()
        return result
    }

    func containsBlock(_ node: HTMLNode) -> Bool {
        node.children.contains { TreeBuilder.blockElements.contains($0.name) || (!$0.isText && containsBlock($0)) }
    }

    func block(_ node: HTMLNode) -> [String] {
        if let level = Self.headings[node.name] {
            let text = inline(node.children).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]
        }
        switch node.name {
        case "ul", "ol": return [list(node)].filter { !$0.isEmpty }
        case "blockquote":
            let inner = blocks(node.children).joined(separator: "\n\n")
            guard !inner.isEmpty else { return [] }
            return [inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")]
        case "pre": return [codeBlock(node)]
        case "hr": return ["---"]
        case "table": return [table(node)].filter { !$0.isEmpty }
        case "li": return [list(HTMLNode(name: "ul"), items: [node])]
        default: return blocks(node.children)
        }
    }

    // MARK: Lists

    func list(_ node: HTMLNode, items: [HTMLNode]? = nil) -> String {
        let items = items ?? node.children.filter { $0.name == "li" }
        // CommonMark list numbers have at most nine digits; anything else
        // (including a start that would overflow) restarts at 1.
        let start = Int(node.attributes["start"] ?? "").flatMap { (0...1_000_000_000 - items.count).contains($0) ? $0 : nil } ?? 1
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            let marker = node.name == "ol" ? "\(start + index). " : "- "
            let content = listItemContent(item)
            let pad = String(repeating: " ", count: marker.count)
            let itemLines = content.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIndex, line) in itemLines.enumerated() {
                if lineIndex == 0 {
                    lines.append(marker + line)
                } else {
                    lines.append(line.isEmpty ? "" : pad + line)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A tight item: its text, then any nested lists directly below it.
    func listItemContent(_ item: HTMLNode) -> String {
        let parts = blocks(item.children)
        guard let first = parts.first else { return "" }
        let checkbox = item.children.first { $0.name == "input" && $0.attributes["type"] == "checkbox" }
        let prefix = checkbox.map { $0.attributes["checked"] != nil ? "[x] " : "[ ] " } ?? ""
        return ([prefix + first] + parts.dropFirst()).joined(separator: "\n")
    }

    // MARK: Code

    func codeBlock(_ node: HTMLNode) -> String {
        let code = node.children.first { $0.name == "code" }
        let classes = ((code?.attributes["class"] ?? "") + " " + (node.attributes["class"] ?? "")).split(separator: " ")
        let language = classes.lazy.compactMap { cls -> String? in
            for prefix in ["language-", "lang-"] where cls.hasPrefix(prefix) { return String(cls.dropFirst(prefix.count)) }
            return nil
        }.first ?? ""
        var text = node.rawText
        if text.hasPrefix("\n") { text.removeFirst() }
        while text.hasSuffix("\n") { text.removeLast() }
        let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: text) + 1))
        return fence + language + "\n" + text + "\n" + fence
    }

    func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0, current = 0
        for c in text {
            current = c == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    // MARK: Tables

    func table(_ node: HTMLNode) -> String {
        var rows: [HTMLNode] = []
        func collect(_ n: HTMLNode) {
            for child in n.children {
                if child.name == "tr" { rows.append(child) } else if ["thead", "tbody", "tfoot"].contains(child.name) { collect(child) }
            }
        }
        collect(node)
        let cells = rows.map { row in
            row.children.filter { $0.name == "td" || $0.name == "th" }.map { cell in
                // A cell is one line: its paragraphs, list items and breaks
                // are joined with spaces rather than run together.
                blocks(cell.children).joined(separator: " ")
                    .replacingOccurrences(of: "\\\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .trimmingCharacters(in: .whitespaces)
            }
        }.filter { !$0.isEmpty }
        guard let header = cells.first else { return "" }
        let width = cells.map(\.count).max() ?? header.count
        func row(_ values: [String]) -> String {
            "| " + (values + Array(repeating: "", count: width - values.count)).joined(separator: " | ") + " |"
        }
        return ([row(header), "|" + Array(repeating: " --- ", count: width).joined(separator: "|") + "|"]
            + cells.dropFirst().map(row)).joined(separator: "\n")
    }

    // MARK: Inline

    func inline(_ nodes: [HTMLNode]) -> String {
        nodes.map(inline).joined()
            .replacingOccurrences(of: #"[ \t]*\\\n[ \t]*"#, with: "\\\\\n", options: .regularExpression)
    }

    func inline(_ node: HTMLNode) -> String {
        if node.isText {
            let text = node.text.replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return inLinkLabel ? Self.escapedLabel(text) : text
        }
        if Self.invisible.contains(node.name) { return "" }
        let content = { inline(node.children) }
        switch node.name {
        case "br": return "\\\n"
        case "strong": return wrap(content(), "**")
        case "b":
            // Google Docs wraps whole documents in <b style="font-weight:normal">.
            return isNotBold(node) ? content() : wrap(content(), "**")
        case "em", "i": return wrap(content(), "*")
        case "del", "s", "strike": return wrap(content(), "~~")
        case "code", "kbd", "samp": return inlineCode(node.rawText)
        case "a": return link(node, text: Writer(inLinkLabel: true).inline(node.children))
        case "img": return image(node)
        case "span": return styled(node, content())
        case "input": return ""
        default: return content()
        }
    }

    func isNotBold(_ node: HTMLNode) -> Bool {
        let style = (node.attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        return style.contains("font-weight:normal") || style.contains("font-weight:400")
    }

    /// Google Docs and some editors mark emphasis with inline styles only.
    func styled(_ node: HTMLNode, _ content: String) -> String {
        let style = (node.attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        var result = content
        if style.range(of: #"font-weight:(bold|[6-9]00)"#, options: .regularExpression) != nil { result = wrap(result, "**") }
        if style.contains("font-style:italic") { result = wrap(result, "*") }
        if style.contains("text-decoration:line-through") { result = wrap(result, "~~") }
        return result
    }

    /// Markers hug the text; surrounding spaces stay outside, or "** x **"
    /// would not render as emphasis.
    /// Spaces and hard breaks (`\` + newline) at either end move outside
    /// the markers: emphasis cannot span a line break, and "** x **" would
    /// not render at all.
    func wrap(_ text: String, _ marker: String) -> String {
        var core = Substring(text)
        var leading = ""
        var trailing = ""
        while true {
            if core.hasPrefix(" ") { leading += " "; core = core.dropFirst() }
            else if core.hasPrefix("\\\n") { leading += "\\\n"; core = core.dropFirst(2) }
            else { break }
        }
        while true {
            if core.hasSuffix(" ") { trailing = " " + trailing; core = core.dropLast() }
            else if core.hasSuffix("\\\n") { trailing = "\\\n" + trailing; core = core.dropLast(2) }
            else { break }
        }
        guard !core.isEmpty else { return text }
        return leading + marker + core + marker + trailing
    }

    func inlineCode(_ text: String) -> String {
        let code = text.replacingOccurrences(of: "\n", with: " ")
        guard !code.isEmpty else { return "" }
        let ticks = String(repeating: "`", count: longestRun(of: "`", in: code) + 1)
        let pad = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return ticks + pad + code + pad + ticks
    }

    func link(_ node: HTMLNode, text: String) -> String {
        let href = (node.attributes["href"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !href.isEmpty, !href.lowercased().hasPrefix("javascript:"), !href.hasPrefix("#") else { return text }
        // Spaces at the anchor's edges belong to the sentence around it, so
        // they stay outside the link rather than vanish (#24).
        // An anchor of nothing but spaces keeps them once, before the link.
        let label = text.trimmingCharacters(in: .whitespaces)
        let leading = label.isEmpty ? text : String(text.prefix(while: \.isWhitespace))
        let trailing = label.isEmpty ? "" : String(text.reversed().prefix(while: \.isWhitespace).reversed())
        let destination = Self.destination(href)
        let link: String
        if label.isEmpty || label == href || "mailto:" + label == href {
            link = "<\(destination)>"
        } else {
            link = "[\(label)](\(destination))"
        }
        return leading + link + trailing
    }

    func image(_ node: HTMLNode) -> String {
        let alt = node.attributes["alt"] ?? ""
        let src = node.attributes["src"] ?? ""
        // With no usable source the alt text stands in as plain text, so
        // inside a link it is escaped like any other text there (#46).
        guard !src.isEmpty, !src.lowercased().hasPrefix("data:") else { return inLinkLabel ? Self.escapedLabel(alt) : alt }
        return "![\(Self.escapedLabel(alt))](\(Self.destination(src)))"
    }

    /// A link destination that cannot end early: spaces and every ASCII
    /// control (which CommonMark does not allow in one), parentheses, angle
    /// brackets and backslashes (which would escape a closing parenthesis)
    /// are percent-encoded, which every URL reader accepts
    /// (#23). Other characters are left as the page wrote them.
    static func destination(_ url: String) -> String {
        var out = ""
        for scalar in url.unicodeScalars {
            switch scalar {
            case "(", ")", "<", ">", "\\", "\u{7F}", "\u{00}"..."\u{20}":
                out += String(format: "%%%02X", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Link text with brackets escaped, so a `]` cannot close the label.
    static func escapedLabel(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
